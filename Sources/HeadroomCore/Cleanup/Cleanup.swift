import Foundation

public enum ExecutionMode: String, Codable, Sendable {
    /// Report what would happen; change nothing.
    case dryRun
    /// Really remove.
    case live
}

/// Debug builds can only act on a fixture home in a temporary folder. Release builds use the
/// mode the user picked (dry-run is the default until they turn it off).
public enum ExecutionPolicy {
    public static func effectiveMode(requested: ExecutionMode, paths: HostPaths) -> ExecutionMode {
        #if DEBUG
        return paths.isFixture && HostPaths.isInsideTemporaryLocation(paths.home) ? requested : .dryRun
        #else
        return requested
        #endif
    }

    public static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }
}

// MARK: - Plan

public struct CleanupTarget: Sendable, Hashable {
    public var url: URL
    public var bytes: Int64
}

public struct CleanupItem: Sendable, Identifiable, Hashable {
    public var id: String { entry.id }
    public var entry: CatalogEntry
    public var targets: [CleanupTarget]
    public var bytes: Int64 { targets.reduce(0) { $0 + $1.bytes } }
    /// Set when this item will be skipped, with the reason.
    public var blockedReason: String?
}

public struct CleanupPlan: Sendable {
    public var items: [CleanupItem]
    public var createdAt: Date
    public var runnable: [CleanupItem] { items.filter { $0.blockedReason == nil && !$0.targets.isEmpty } }
    public var bytes: Int64 { runnable.reduce(0) { $0 + $1.bytes } }
}

/// What's running, as far as clean-up guards care.
public struct RunningWork: Sendable {
    public var categories: Set<ProcessCategory>
    public var processNames: Set<String>

    public init(categories: Set<ProcessCategory> = [], processNames: Set<String> = []) {
        self.categories = categories
        self.processNames = processNames
    }

    public init(records: [ProcessRecord]) {
        categories = Set(records.map(\.category))
        // Names like "Xcode" or "Xcode (SourceKitService)" both count as Xcode.
        processNames = Set(records.flatMap { [$0.name, $0.name.components(separatedBy: " (").first ?? $0.name] })
    }
}

/// Turns selected catalog entries into a concrete list of items to remove. Pure apart from
/// listing and sizing folders; it never removes anything.
public struct CleanupPlanner: Sendable {
    public var paths: HostPaths
    public var catalog: [CatalogEntry]

    public init(paths: HostPaths, catalog: [CatalogEntry] = StorageCatalog.entries) {
        self.paths = paths
        self.catalog = catalog
    }

    public func makeGuard() -> PathGuard {
        let caches = catalog.filter { $0.kind == .rebuildableCache }
        var roots: [URL] = []
        var prefixes: [String] = []
        for entry in caches {
            if case .temporaryPrefix(let prefix) = entry.location { prefixes.append(prefix) } else { roots.append(entry.root(in: paths)) }
        }
        return PathGuard(paths: paths, roots: roots, temporaryPrefixes: prefixes)
    }

    public func plan(entryIDs: [String], running: RunningWork, measure: (URL) -> Int64 = { DirectorySizer.measure($0).bytes }) -> CleanupPlan {
        let pathGuard = makeGuard()
        let items = entryIDs.compactMap { id -> CleanupItem? in
            guard let entry = catalog.first(where: { $0.id == id }) else { return nil }
            guard entry.kind == .rebuildableCache else {
                return CleanupItem(entry: entry, targets: [], blockedReason: "Not a rebuildable cache. Headroom only shows its size.")
            }
            if let blocker = entry.blockingCategories.first(where: running.categories.contains) {
                return CleanupItem(entry: entry, targets: [], blockedReason: "\(blocker.title) is running. Stop it first, then clean.")
            }
            if let blocker = entry.blockingProcessNames.first(where: running.processNames.contains) {
                return CleanupItem(entry: entry, targets: [], blockedReason: "\(blocker) is running. Quit it first, then clean.")
            }
            var targets: [CleanupTarget] = []
            for url in entry.targets(in: paths) {
                do {
                    try pathGuard.validate(url)
                } catch {
                    return CleanupItem(entry: entry, targets: [], blockedReason: String(describing: error))
                }
                targets.append(CleanupTarget(url: url, bytes: measure(url)))
            }
            return CleanupItem(entry: entry, targets: targets.sorted { $0.bytes > $1.bytes }, blockedReason: nil)
        }
        return CleanupPlan(items: items, createdAt: Date())
    }
}

// MARK: - Execution

public protocol FileRemoving: Sendable {
    func removeItem(at url: URL) throws
    func trashItem(at url: URL) throws
}

public struct FileManagerRemover: FileRemoving {
    public init() {}
    public func removeItem(at url: URL) throws { try FileManager.default.removeItem(at: url) }
    public func trashItem(at url: URL) throws { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
}

public struct CleanupReport: Sendable {
    public struct ItemResult: Sendable, Identifiable {
        public var id: String
        public var name: String
        public var bytes: Int64
        public var removedCount: Int
        public var failures: [String]
        public var skippedReason: String?
    }

    public var mode: ExecutionMode
    public var results: [ItemResult]
    public var bytes: Int64 { results.reduce(0) { $0 + $1.bytes } }
}

public struct CleanupExecutor: Sendable {
    public var pathGuard: PathGuard
    public var mode: ExecutionMode
    public var remover: FileRemoving

    public init(pathGuard: PathGuard, mode: ExecutionMode, remover: FileRemoving = FileManagerRemover()) {
        self.pathGuard = pathGuard
        self.mode = mode
        self.remover = remover
    }

    public func execute(_ plan: CleanupPlan) -> CleanupReport {
        let results = plan.items.map { item -> CleanupReport.ItemResult in
            if let reason = item.blockedReason {
                return .init(id: item.id, name: item.entry.name, bytes: 0, removedCount: 0, failures: [], skippedReason: reason)
            }
            var bytes: Int64 = 0
            var removed = 0
            var failures: [String] = []
            for target in item.targets {
                do {
                    // Check again right before acting: things may have changed since the preview.
                    try pathGuard.validate(target.url)
                    if mode == .live { try remover.removeItem(at: target.url) }
                    bytes += target.bytes
                    removed += 1
                } catch let violation as GuardViolation {
                    failures.append(violation.description)
                } catch {
                    failures.append("\(target.url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            return .init(id: item.id, name: item.entry.name, bytes: bytes, removedCount: removed, failures: failures, skippedReason: nil)
        }
        return CleanupReport(mode: mode, results: results)
    }
}

// MARK: - Per-item developer items

public struct DevItemRemovalResult: Sendable {
    public var item: DevItem
    public var mode: ExecutionMode
    public var succeeded: Bool
    public var message: String
    public var command: String
}

/// Removes one developer item, after its own confirmation, through the official tool or by
/// moving it to the Trash.
public struct DevItemRemover: Sendable {
    public var paths: HostPaths
    public var mode: ExecutionMode
    public var runner: CommandRunning
    public var remover: FileRemoving

    public init(paths: HostPaths, mode: ExecutionMode, runner: CommandRunning = ProcessCommandRunner(), remover: FileRemoving = FileManagerRemover()) {
        self.paths = paths
        self.mode = mode
        self.runner = runner
        self.remover = remover
    }

    public func remove(_ item: DevItem) async -> DevItemRemovalResult {
        if let reason = item.blockedReason {
            return DevItemRemovalResult(item: item, mode: mode, succeeded: false, message: reason, command: "")
        }
        switch item.kind {
        case .simulatorRuntime:
            let id = String(item.id.dropFirst("runtime:".count))
            return await runSimctl(item, ["simctl", "runtime", "delete", id])
        case .simulatorDevice:
            let udid = String(item.id.dropFirst("device:".count))
            return await runSimctl(item, ["simctl", "delete", udid])
        case .androidAVD, .androidSystemImage, .xcodeArchive:
            return moveToTrash(item)
        }
    }

    private func runSimctl(_ item: DevItem, _ arguments: [String]) async -> DevItemRemovalResult {
        let command = "xcrun " + arguments.joined(separator: " ")
        guard arguments.last.map(Self.isSafeIdentifier) == true else {
            return DevItemRemovalResult(item: item, mode: mode, succeeded: false, message: "Unexpected identifier.", command: command)
        }
        guard mode == .live else {
            return DevItemRemovalResult(item: item, mode: mode, succeeded: true, message: "Dry run: would run \(command)", command: command)
        }
        do {
            let result = try await runner.run(ToolLocator.xcrun, arguments, timeout: 300)
            return DevItemRemovalResult(item: item, mode: mode, succeeded: result.succeeded,
                                        message: result.succeeded ? "Removed." : "simctl reported an error (exit \(result.status)).", command: command)
        } catch {
            return DevItemRemovalResult(item: item, mode: mode, succeeded: false, message: String(describing: error), command: command)
        }
    }

    private func moveToTrash(_ item: DevItem) -> DevItemRemovalResult {
        guard let location = item.location else {
            return DevItemRemovalResult(item: item, mode: mode, succeeded: false, message: "No location.", command: "")
        }
        let scanner = DevItemScanner(paths: paths, runner: runner)
        let pathGuard = PathGuard(paths: paths, roots: scanner.trashableRoots())
        var urls = [location]
        if item.kind == .androidAVD {
            // The AVD's registration file sits next to its folder: Pixel_9a.avd + Pixel_9a.ini
            let ini = location.deletingPathExtension().appendingPathExtension("ini")
            if FileManager.default.fileExists(atPath: ini.path) { urls.append(ini) }
        }
        let command = "Move to Trash: " + urls.map(\.lastPathComponent).joined(separator: ", ")
        do {
            for url in urls { try pathGuard.validate(url) }
            if mode == .live { for url in urls { try remover.trashItem(at: url) } }
            return DevItemRemovalResult(item: item, mode: mode, succeeded: true,
                                        message: mode == .live ? "Moved to the Trash." : "Dry run: would move to the Trash.", command: command)
        } catch let violation as GuardViolation {
            return DevItemRemovalResult(item: item, mode: mode, succeeded: false, message: violation.description, command: command)
        } catch {
            return DevItemRemovalResult(item: item, mode: mode, succeeded: false, message: error.localizedDescription, command: command)
        }
    }

    /// UUIDs and simulator identifiers only: letters, digits, dots and dashes.
    static func isSafeIdentifier(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix("-") && value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." }
    }
}

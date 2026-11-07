import AppKit
import HeadroomCore
import ServiceManagement
import SwiftUI
import UserNotifications

@MainActor
@Observable
final class AppModel {
    let paths = HostPaths.current()
    let hardware = HardwareInfo.current()

    var settings: HeadroomSettings {
        didSet {
            guard settings != oldValue else { return }
            try? settingsStore.save(settings)
        }
    }

    // Live health
    private(set) var latest: MetricsSample?
    private(set) var samples: [MetricsSample] = []
    private(set) var processes: ProcessSnapshot?
    /// Views that show per-process detail register here so sampling is frequent only while they're visible.
    var detailViewers = 0

    // Storage
    private(set) var entrySizes: [String: DirectorySize] = [:]
    private(set) var scanningStorage = false
    private(set) var lastStorageScan: Date?
    private(set) var docker: DockerUsage.Status?
    var pendingPlan: CleanupPlan?
    private(set) var preparingPlan = false
    var lastReport: CleanupReport?

    // Developer items
    private(set) var devItems: [DevItemKind: [DevItem]] = [:]
    private(set) var devItemErrors: [DevItemKind: String] = [:]
    private(set) var scanningDevItems = false
    var lastDevItemResult: DevItemRemovalResult?

    // Worktrees
    private(set) var worktrees: [WorktreeInfo] = []
    private(set) var scanningWorktrees = false
    private(set) var lastWorktreeScan: Date?

    // Snapshots and history
    private(set) var recording: SnapshotAccumulator?
    private(set) var snapshots: [WorkloadSnapshot] = []
    private(set) var history: [HistoryEntry] = []

    private let settingsStore: SettingsStore
    private let historyStore: HistoryStore
    private let snapshotStore: SnapshotStore
    private var metricsReader: SystemMetricsReader
    private let sampler = ProcessSampler()
    private var alertEvaluator = AlertEvaluator()
    private var loopTask: Task<Void, Never>?
    private var tick = 0
    private var askedForNotifications = false

    init() {
        let support = paths.supportDirectory
        settingsStore = SettingsStore(directory: support)
        historyStore = HistoryStore(directory: support)
        snapshotStore = SnapshotStore(directory: support)
        settings = settingsStore.load()
        metricsReader = SystemMetricsReader(volume: paths.home)
        history = historyStore.load()
        snapshots = snapshotStore.load()
    }

    var requestedMode: ExecutionMode { settings.dryRun ? .dryRun : .live }
    var effectiveMode: ExecutionMode { ExecutionPolicy.effectiveMode(requested: requestedMode, paths: paths) }
    var assessment: HealthAssessment? { latest.map { HealthAssessment(sample: $0, settings: settings) } }

    // MARK: Sampling

    func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.sampleOnce()
                try? await Task.sleep(for: .seconds(max(2, self.settings.sampleIntervalSeconds)))
            }
        }
    }

    func sampleOnce() async {
        let sample = metricsReader.sample()
        tick += 1
        // Processes: every tick while someone looks at them or a snapshot records, otherwise every 6th tick.
        if detailViewers > 0 || recording != nil || tick % 6 == 1 || processes == nil {
            processes = await sampleProcesses()
        }
        latest = sample
        samples.append(sample)
        let cutoff = sample.date.addingTimeInterval(-3600)
        if let first = samples.first, first.date < cutoff { samples.removeAll { $0.date < cutoff } }
        recording?.add(sample, groups: processes?.groups ?? [], deviceCount: processes?.testDeviceCount)

        let alerts = alertEvaluator.evaluate(sample, settings: settings)
        if !alerts.isEmpty { await notify(alerts) }
    }

    private func sampleProcesses() async -> ProcessSnapshot {
        let sampler = self.sampler
        return await Task.detached(priority: .utility) { sampler.sample() }.value
    }

    private func notify(_ alerts: [HealthAlert]) async {
        guard settings.notificationsEnabled, Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        if !askedForNotifications {
            askedForNotifications = true
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
        for alert in alerts {
            let content = UNMutableNotificationContent()
            content.title = alert.title
            content.body = alert.body
            try? await center.add(UNNotificationRequest(identifier: "headroom.\(alert.kind.rawValue)", content: content, trigger: nil))
        }
    }

    // MARK: Storage

    func scanStorage() {
        guard !scanningStorage else { return }
        scanningStorage = true
        let paths = self.paths
        Task {
            let entries = StorageCatalog.entries
            await forEachLimited(entries, limit: 3) { entry in
                let size = await Task.detached(priority: .utility) { Self.measure(entry, paths: paths) }.value
                self.entrySizes[entry.id] = size
            }
            self.docker = await DockerUsage.read(paths: paths, runner: ProcessCommandRunner())
            self.lastStorageScan = Date()
            self.scanningStorage = false
        }
    }

    nonisolated static func measure(_ entry: CatalogEntry, paths: HostPaths) -> DirectorySize {
        switch entry.location {
        case .temporaryPrefix:
            let parts = entry.targets(in: paths).map { DirectorySizer.measure($0) }
            return DirectorySize(bytes: parts.reduce(0) { $0 + $1.bytes }, fileCount: parts.reduce(0) { $0 + $1.fileCount },
                                 newestModification: parts.compactMap(\.newestModification).max(), partial: parts.contains { $0.partial })
        default:
            return DirectorySizer.measure(entry.root(in: paths))
        }
    }

    func children(of url: URL) async -> [(url: URL, size: DirectorySize)] {
        await Task.detached(priority: .utility) { DirectorySizer.children(of: url) }.value
    }

    func preparePlan(entryIDs: [String]) {
        guard !preparingPlan else { return }
        preparingPlan = true
        let paths = self.paths
        Task {
            let current = await sampleProcesses()
            processes = current
            let running = RunningWork(records: current.records)
            let plan = await Task.detached(priority: .userInitiated) {
                CleanupPlanner(paths: paths).plan(entryIDs: entryIDs, running: running)
            }.value
            self.lastReport = nil
            self.pendingPlan = plan
            self.preparingPlan = false
        }
    }

    func execute(_ plan: CleanupPlan) {
        let paths = self.paths
        let mode = effectiveMode
        Task {
            let report = await Task.detached(priority: .userInitiated) {
                let planner = CleanupPlanner(paths: paths)
                return CleanupExecutor(pathGuard: planner.makeGuard(), mode: mode).execute(plan)
            }.value
            for result in report.results {
                let entry = plan.items.first { $0.id == result.id }?.entry
                record(HistoryEntry(
                    action: "Clean \(result.name)",
                    detail: result.skippedReason ?? (result.failures.isEmpty ? "\(result.removedCount) items" : "\(result.removedCount) items, \(result.failures.count) failed"),
                    bytes: result.bytes, dryRun: mode == .dryRun,
                    succeeded: result.skippedReason == nil && result.failures.isEmpty,
                    undo: "Nothing to restore: it rebuilds by itself. \(entry?.rebuildNote ?? "")"
                ))
            }
            self.lastReport = report
            if mode == .live {
                for result in report.results {
                    if let entry = StorageCatalog.entry(result.id) {
                        self.entrySizes[entry.id] = await Task.detached(priority: .utility) { Self.measure(entry, paths: paths) }.value
                    }
                }
            }
        }
    }

    // MARK: Developer items

    func scanDevItems() {
        guard !scanningDevItems else { return }
        scanningDevItems = true
        let paths = self.paths
        let emulatorRunning = processes?.records.contains { $0.category == .androidEmulator && $0.name.hasPrefix("qemu") } ?? false
        Task {
            let scanner = DevItemScanner(paths: paths)
            switch await scanner.simulatorRuntimes() {
            case .success(let items): devItems[.simulatorRuntime] = items; devItemErrors[.simulatorRuntime] = nil
            case .failure(let error): devItemErrors[.simulatorRuntime] = String(describing: error)
            }
            switch await scanner.simulatorDevices() {
            case .success(let items): devItems[.simulatorDevice] = items; devItemErrors[.simulatorDevice] = nil
            case .failure(let error): devItemErrors[.simulatorDevice] = String(describing: error)
            }
            let (avds, images, archives) = await Task.detached(priority: .utility) {
                (scanner.androidAVDs(emulatorRunning: emulatorRunning), scanner.androidSystemImages(), scanner.xcodeArchives())
            }.value
            devItems[.androidAVD] = avds
            devItems[.androidSystemImage] = images
            devItems[.xcodeArchive] = archives
            scanningDevItems = false
        }
    }

    func remove(_ item: DevItem) {
        let remover = DevItemRemover(paths: paths, mode: effectiveMode)
        Task {
            let result = await remover.remove(item)
            record(HistoryEntry(action: "Remove \(item.kind.title.lowercased()): \(item.name)", detail: result.message + (result.command.isEmpty ? "" : " — \(result.command)"),
                                bytes: result.succeeded ? item.bytes : 0, dryRun: result.mode == .dryRun, succeeded: result.succeeded, undo: item.kind.removalNote))
            lastDevItemResult = result
            if result.mode == .live, result.succeeded { scanDevItems() }
        }
    }

    // MARK: Worktrees

    func scanWorktrees() {
        guard !scanningWorktrees else { return }
        scanningWorktrees = true
        let scanner = WorktreeScanner(paths: paths)
        let roots = settings.worktreeRootURLs(home: paths.home)
        Task {
            // Git status first (fast), then folder sizes one by one as they finish.
            let found = await scanner.scan(roots: roots, measureFolders: false)
            worktrees = found
            await forEachLimited(found, limit: 2) { info in
                let measured = await Task.detached(priority: .utility) { WorktreeScanner.withFolderSizes(info) }.value
                if let index = self.worktrees.firstIndex(where: { $0.path == info.path }) { self.worktrees[index] = measured }
            }
            lastWorktreeScan = Date()
            scanningWorktrees = false
        }
    }

    // MARK: Snapshots

    func startRecording(label: String) {
        recording = SnapshotAccumulator(label: label.isEmpty ? "Workload" : label)
    }

    func stopRecording() {
        guard let snapshot = recording?.finish() else {
            recording = nil
            return
        }
        recording = nil
        snapshots.insert(snapshot, at: 0)
        try? snapshotStore.save(snapshots)
    }

    func deleteSnapshot(_ snapshot: WorkloadSnapshot) {
        snapshots.removeAll { $0.id == snapshot.id }
        try? snapshotStore.save(snapshots)
    }

    // MARK: History

    func record(_ entry: HistoryEntry) {
        try? historyStore.append(entry)
        history.insert(entry, at: 0)
    }

    func exportHistory() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "headroom-change-log.md"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? HistoryStore.markdown(history).write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: Login item

    var launchesAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                record(HistoryEntry(action: newValue ? "Open at login: on" : "Open at login: off", detail: "SMAppService login item", bytes: 0,
                                    dryRun: false, succeeded: true, undo: "Toggle it back in Headroom ▸ Settings, or System Settings ▸ General ▸ Login Items."))
            } catch {
                record(HistoryEntry(action: "Open at login", detail: error.localizedDescription, bytes: 0, dryRun: false, succeeded: false, undo: "Nothing changed."))
            }
        }
    }
}

/// Runs `body` over `items` with at most `limit` running at once.
@MainActor
func forEachLimited<T: Sendable>(_ items: [T], limit: Int, _ body: @escaping @MainActor (T) async -> Void) async {
    await withTaskGroup(of: Void.self) { group in
        var iterator = items.makeIterator()
        for _ in 0..<limit {
            guard let item = iterator.next() else { break }
            group.addTask { await body(item) }
        }
        while await group.next() != nil {
            if let item = iterator.next() { group.addTask { await body(item) } }
        }
    }
}

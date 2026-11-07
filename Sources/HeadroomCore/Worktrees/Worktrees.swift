import Foundation

/// One git worktree, as reported by read-only git commands.
public struct WorktreeInfo: Sendable, Identifiable, Hashable {
    public var id: String { path }
    public var repository: String
    public var path: String
    public var branch: String?
    public var isDetached: Bool
    public var isMainWorktree: Bool
    public var upstream: String?
    /// Commits not on any remote-tracking branch, as of the last fetch.
    public var unpushedCommits: Int?
    public var behind: Int?
    /// Changed, staged or untracked files.
    public var uncommittedChanges: Int?
    public var lastCommit: Date?
    public var isMissing: Bool
    public var nodeModulesBytes: Int64?
    public var nxCacheBytes: Int64?
    public var error: String?

    public enum Status: String, Sendable {
        case uncommitted, unpushed, noUpstream, clean, missing, unknown

        public var label: String {
            switch self {
            case .uncommitted: "Uncommitted work"
            case .unpushed: "Unpushed commits"
            case .noUpstream: "No upstream"
            case .clean: "Clean and pushed"
            case .missing: "Folder missing"
            case .unknown: "Unknown"
            }
        }
    }

    /// The most important thing to know before deciding about this worktree.
    public var status: Status {
        if isMissing { return .missing }
        guard let uncommittedChanges, let unpushedCommits else { return .unknown }
        if uncommittedChanges > 0 { return .uncommitted }
        if unpushedCommits > 0 { return .unpushed }
        if upstream == nil, !isDetached { return .noUpstream }
        return .clean
    }
}

// MARK: - Parsers (pure)

public enum GitParsers {
    public struct WorktreeEntry: Equatable, Sendable {
        public var path: String
        public var head: String?
        public var branch: String?
        public var isDetached = false
        public var isBare = false
        public var isPrunable = false
    }

    /// Parses `git worktree list --porcelain`.
    public static func worktreeList(_ output: String) -> [WorktreeEntry] {
        var entries: [WorktreeEntry] = []
        var current: WorktreeEntry?
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("worktree ") {
                if let current { entries.append(current) }
                current = WorktreeEntry(path: String(line.dropFirst("worktree ".count)))
            } else if line.hasPrefix("HEAD ") {
                current?.head = String(line.dropFirst(5))
            } else if line.hasPrefix("branch ") {
                let ref = String(line.dropFirst("branch ".count))
                current?.branch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
            } else if line == "detached" {
                current?.isDetached = true
            } else if line == "bare" {
                current?.isBare = true
            } else if line.hasPrefix("prunable") {
                current?.isPrunable = true
            }
        }
        if let current { entries.append(current) }
        return entries
    }

    public struct BranchStatus: Equatable, Sendable {
        public var branch: String?
        public var upstream: String?
        public var ahead: Int?
        public var behind: Int?
        public var changes: Int
    }

    /// Parses `git status --porcelain=v2 --branch`. Counts changes; never keeps file names.
    public static func status(_ output: String) -> BranchStatus {
        var status = BranchStatus(changes: 0)
        for line in output.split(separator: "\n") {
            if line.hasPrefix("# branch.head ") {
                let head = String(line.dropFirst("# branch.head ".count))
                status.branch = head == "(detached)" ? nil : head
            } else if line.hasPrefix("# branch.upstream ") {
                status.upstream = String(line.dropFirst("# branch.upstream ".count))
            } else if line.hasPrefix("# branch.ab ") {
                let parts = line.dropFirst("# branch.ab ".count).split(separator: " ")
                if parts.count == 2 {
                    status.ahead = Int(parts[0].dropFirst())
                    status.behind = Int(parts[1].dropFirst())
                }
            } else if !line.hasPrefix("#") {
                status.changes += 1
            }
        }
        return status
    }
}

// MARK: - Scanner

/// Finds git repositories under the configured folders and reports each worktree.
/// Only read-only git commands are run, with optional locks off so the index isn't rewritten.
/// It never fetches, so push status is as of your last fetch.
public struct WorktreeScanner: Sendable {
    public var paths: HostPaths
    public var runner: CommandRunning
    public var maxDepth: Int

    public init(paths: HostPaths, runner: CommandRunning = ProcessCommandRunner(), maxDepth: Int = 4) {
        self.paths = paths
        self.runner = runner
        self.maxDepth = maxDepth
    }

    static let skippedFolders: Set<String> = ["node_modules", "Pods", "build", "DerivedData", "Library", ".build", "dist", "vendor", "android", "ios"]

    /// Main repositories (folders with a `.git` directory) under the roots.
    public func findRepositories(roots: [URL]) -> [URL] {
        var found: [URL] = []
        let fm = FileManager.default
        func walk(_ url: URL, depth: Int) {
            var isDirectory: ObjCBool = false
            let gitPath = url.appending(path: ".git").path
            if fm.fileExists(atPath: gitPath, isDirectory: &isDirectory) {
                if isDirectory.boolValue { found.append(url) }
                return
            }
            guard depth < maxDepth else { return }
            let children = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])) ?? []
            for child in children {
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values?.isDirectory == true, values?.isSymbolicLink != true, !Self.skippedFolders.contains(child.lastPathComponent) else { continue }
                walk(child, depth: depth + 1)
            }
        }
        for root in roots { walk(root, depth: 0) }
        return found
    }

    public func scan(roots: [URL], measureFolders: Bool = true) async -> [WorktreeInfo] {
        var results: [WorktreeInfo] = []
        var seen = Set<String>()
        for repo in findRepositories(roots: roots) {
            guard let list = try? await git(["worktree", "list", "--porcelain"], in: repo.path), list.succeeded else { continue }
            let entries = GitParsers.worktreeList(list.stdout).filter { !$0.isBare }
            for (index, entry) in entries.enumerated() where !seen.contains(entry.path) {
                seen.insert(entry.path)
                results.append(await inspect(entry, repository: repo.lastPathComponent, isMain: index == 0, measureFolders: false))
            }
        }
        return measureFolders ? await Self.withFolderSizes(results) : results
    }

    /// How many worktrees are measured at once. Measuring is mostly waiting on file-system
    /// metadata, so a few in parallel finish much sooner without keeping the CPU busy.
    public static let folderSizeConcurrency = 6

    /// Adds folder sizes to many worktrees, `folderSizeConcurrency` at a time, keeping the input order.
    /// `onEach` is called as each one finishes, so a UI can fill in sizes progressively.
    public static func withFolderSizes(_ worktrees: [WorktreeInfo], onEach: (@Sendable (WorktreeInfo) async -> Void)? = nil) async -> [WorktreeInfo] {
        var measured = worktrees
        await withTaskGroup(of: (Int, WorktreeInfo).self) { group in
            var next = 0
            func startNext() {
                guard next < worktrees.count else { return }
                let index = next, info = worktrees[index]
                next += 1
                group.addTask(priority: .utility) { (index, withFolderSizes(info)) }
            }
            for _ in 0..<folderSizeConcurrency { startNext() }
            while let (index, info) = await group.next() {
                measured[index] = info
                await onEach?(info)
                startNext()
            }
        }
        return measured
    }

    func inspect(_ entry: GitParsers.WorktreeEntry, repository: String, isMain: Bool, measureFolders: Bool) async -> WorktreeInfo {
        var info = WorktreeInfo(repository: repository, path: entry.path, branch: entry.branch, isDetached: entry.isDetached, isMainWorktree: isMain,
                                upstream: nil, unpushedCommits: nil, behind: nil, uncommittedChanges: nil, lastCommit: nil,
                                isMissing: entry.isPrunable || !FileManager.default.fileExists(atPath: entry.path), nodeModulesBytes: nil, nxCacheBytes: nil, error: nil)
        guard !info.isMissing else { return info }
        do {
            let status = try await git(["status", "--porcelain=v2", "--branch"], in: entry.path, timeout: 60)
            if status.succeeded {
                let parsed = GitParsers.status(status.stdout)
                info.upstream = parsed.upstream
                info.behind = parsed.behind
                info.uncommittedChanges = parsed.changes
            } else {
                info.error = "git status failed"
            }
            let unpushed = try await git(["rev-list", "--count", "HEAD", "--not", "--remotes"], in: entry.path)
            if unpushed.succeeded { info.unpushedCommits = Int(unpushed.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) }
            let last = try await git(["log", "-1", "--format=%ct"], in: entry.path)
            if last.succeeded, let seconds = TimeInterval(last.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) {
                info.lastCommit = Date(timeIntervalSince1970: seconds)
            }
        } catch {
            info.error = String(describing: error)
        }
        return measureFolders ? Self.withFolderSizes(info) : info
    }

    /// Adds node_modules and Nx cache sizes. Slow on big repos, so the app runs it after the git pass.
    public static func withFolderSizes(_ info: WorktreeInfo) -> WorktreeInfo {
        var info = info
        guard !info.isMissing else { return info }
        let root = URL(fileURLWithPath: info.path)
        let nodeModules = root.appending(path: "node_modules")
        if FileManager.default.fileExists(atPath: nodeModules.path) { info.nodeModulesBytes = DirectorySizer.measure(nodeModules).bytes }
        let nx = root.appending(path: ".nx/cache")
        if FileManager.default.fileExists(atPath: nx.path) { info.nxCacheBytes = DirectorySizer.measure(nx).bytes }
        return info
    }

    private func git(_ arguments: [String], in directory: String, timeout: TimeInterval = 30) async throws -> CommandResult {
        try await runner.run(ToolLocator.git, ["--no-optional-locks", "-C", directory] + arguments,
                             environment: ToolLocator.cleanEnvironment(home: paths.home), timeout: timeout)
    }
}

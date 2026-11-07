import Darwin
import Foundation

/// Removes a worktree's `node_modules` folder, and nothing else, when the worktree is safe to touch.
///
/// This is the one place Headroom deletes inside a git working tree. It only ever targets exactly
/// `<worktree>/node_modules`, and only when, checked again right before removal:
/// - the worktree has no uncommitted changes (including untracked files) and no unpushed commits;
/// - git confirms `node_modules` is ignored and has no tracked files;
/// - `node_modules` is a real folder (not a symlink) and holds no `.env*.local` file;
/// - no running process has its working folder in the worktree or runs a program from its `node_modules`.
public struct NodeModulesCleanup: Sendable {
    public enum Blocker: Error, Equatable, Sendable, CustomStringConvertible {
        case worktreeMissing
        case notUnderHome
        case worktreeRedirected
        case statusUnknown
        case uncommittedChanges(Int)
        case unpushedCommits(Int)
        case noNodeModules
        case nodeModulesIsSymlink
        case notIgnored
        case hasTrackedFiles
        case containsEnvLocalFile(String)
        case inUse([String])
        case gitFailed(String)

        public var description: String {
            switch self {
            case .worktreeMissing: "The worktree folder no longer exists."
            case .notUnderHome: "The worktree isn't inside your home folder."
            case .worktreeRedirected: "The worktree path goes through a symlink, so it was skipped."
            case .statusUnknown: "Its git status isn't known yet. Rescan first."
            case .uncommittedChanges(let count): "It has \(count) uncommitted change\(count == 1 ? "" : "s"). Commit or discard them first."
            case .unpushedCommits(let count): "It has \(count) unpushed commit\(count == 1 ? "" : "s"). Push first."
            case .noNodeModules: "It has no node_modules folder."
            case .nodeModulesIsSymlink: "Its node_modules is a symlink, so it was skipped."
            case .notIgnored: "Git doesn't ignore its node_modules, so it may be part of the project."
            case .hasTrackedFiles: "Git tracks files inside its node_modules, so it's part of the project."
            case .containsEnvLocalFile(let path): "Its node_modules contains a .env*.local file, which Headroom never touches: \(path)"
            case .inUse(let names): "Something is running from this worktree: \(names.joined(separator: ", ")). Stop it first."
            case .gitFailed(let message): "Git couldn't check this worktree: \(message)"
            }
        }
    }

    public struct Result: Sendable {
        public var worktree: String
        public var mode: ExecutionMode
        public var bytes: Int64
        public var blocker: Blocker?
        public var error: String?
        public var succeeded: Bool { blocker == nil && error == nil }

        public var message: String {
            if let blocker { return "Not removed. \(blocker.description)" }
            if let error { return "Not removed: \(error)" }
            return mode == .dryRun ? "Dry run: node_modules would be removed. Nothing was deleted." : "node_modules was removed."
        }
    }

    public var paths: HostPaths
    public var mode: ExecutionMode
    public var runner: CommandRunning
    public var remover: FileRemoving
    /// Names of running processes using a folder (working folder inside it, or a program run from inside it).
    public var processesUsing: @Sendable (String) -> [String]

    public init(paths: HostPaths, mode: ExecutionMode, runner: CommandRunning = ProcessCommandRunner(),
                remover: FileRemoving = FileManagerRemover(),
                processesUsing: @escaping @Sendable (String) -> [String] = { ProcessSampler.processesUsing(folder: $0) }) {
        self.paths = paths
        self.mode = mode
        self.runner = runner
        self.remover = remover
        self.processesUsing = processesUsing
    }

    // MARK: Quick check (from the last scan, for the UI)

    /// Why the last scan says this worktree's node_modules can't be removed, or nil if it looks removable.
    /// The full check runs again in `remove(_:)`.
    public static func quickBlocker(for info: WorktreeInfo) -> Blocker? {
        if info.isMissing { return .worktreeMissing }
        guard let changes = info.uncommittedChanges, let unpushed = info.unpushedCommits else { return .statusUnknown }
        if changes > 0 { return .uncommittedChanges(changes) }
        if unpushed > 0 { return .unpushedCommits(unpushed) }
        if (info.nodeModulesBytes ?? 0) == 0 { return .noNodeModules }
        return nil
    }

    /// How to bring node_modules back, based on the lockfile in the worktree.
    public static func reinstallCommand(in worktree: String) -> String {
        let fm = FileManager.default
        func has(_ name: String) -> Bool { fm.fileExists(atPath: worktree + "/" + name) }
        if has("pnpm-lock.yaml") { return "pnpm install" }
        if has("yarn.lock") { return "yarn install" }
        if has("bun.lockb") || has("bun.lock") { return "bun install" }
        return "npm install"
    }

    // MARK: Full check and removal

    /// Runs every check again on the current state, then removes (or, in dry run, simulates removing)
    /// `<worktree>/node_modules`.
    public func remove(_ info: WorktreeInfo) async -> Result {
        var result = Result(worktree: info.path, mode: mode, bytes: info.nodeModulesBytes ?? 0)
        let target: URL
        switch await verify(worktree: info.path) {
        case .failure(let blocker):
            result.blocker = blocker
            return result
        case .success(let url):
            target = url
        }
        guard mode == .live else { return result }
        do {
            try remover.removeItem(at: target)
        } catch {
            result.error = error.localizedDescription
        }
        return result
    }

    /// The full safety check. Returns the exact folder to remove.
    public func verify(worktree path: String) async -> Swift.Result<URL, Blocker> {
        // The worktree must exist, sit inside home (not be home), and not be reached through a symlink.
        let given = URL(fileURLWithPath: path).standardizedFileURL.path
        guard let canonical = Canonical.path(of: URL(fileURLWithPath: given)) else { return .failure(.worktreeMissing) }
        let home = Canonical.path(of: paths.home) ?? paths.home.path
        guard Canonical.isStrictlyInside(canonical, home) else { return .failure(.notUnderHome) }
        let expectedUnderHome = paths.home.standardizedFileURL.path
        if given.hasPrefix(expectedUnderHome + "/"), canonical != home + given.dropFirst(expectedUnderHome.count) {
            return .failure(.worktreeRedirected)
        }

        // node_modules must be a real folder directly inside the worktree.
        let target = canonical + "/node_modules"
        var info = stat()
        guard lstat(target, &info) == 0 else { return .failure(.noNodeModules) }
        if (info.st_mode & S_IFMT) == S_IFLNK { return .failure(.nodeModulesIsSymlink) }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { return .failure(.noNodeModules) }

        // Git: clean, pushed, ignored, not tracked.
        do {
            let status = try await git(["status", "--porcelain=v2", "--branch"], in: canonical, timeout: 60)
            guard status.succeeded else { return .failure(.gitFailed("status")) }
            let parsed = GitParsers.status(status.stdout)
            if parsed.changes > 0 { return .failure(.uncommittedChanges(parsed.changes)) }

            let unpushed = try await git(["rev-list", "--count", "HEAD", "--not", "--remotes"], in: canonical)
            guard unpushed.succeeded, let count = Int(unpushed.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                return .failure(.gitFailed("rev-list"))
            }
            if count > 0 { return .failure(.unpushedCommits(count)) }

            // Tracked files first: git won't call a folder ignored while it holds tracked files.
            let tracked = try await git(["ls-files", "--", "node_modules"], in: canonical)
            guard tracked.succeeded else { return .failure(.gitFailed("ls-files")) }
            if !tracked.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .failure(.hasTrackedFiles) }

            let ignored = try await git(["check-ignore", "-q", "node_modules"], in: canonical)
            if ignored.status == 1 { return .failure(.notIgnored) }
            guard ignored.status == 0 else { return .failure(.gitFailed("check-ignore")) }
        } catch {
            return .failure(.gitFailed(String(describing: error)))
        }

        // Nothing running from the worktree.
        let users = processesUsing(canonical)
        if !users.isEmpty { return .failure(.inUse(Array(Set(users)).sorted())) }

        // Never remove a .env*.local file, even one shipped inside a package.
        if let found = EnvLocalScanner.firstMatch(in: target) { return .failure(.containsEnvLocalFile(found)) }

        return .success(URL(fileURLWithPath: target, isDirectory: true))
    }

    private func git(_ arguments: [String], in directory: String, timeout: TimeInterval = 30) async throws -> CommandResult {
        try await runner.run(ToolLocator.git, ["--no-optional-locks", "-C", directory] + arguments,
                             environment: ToolLocator.cleanEnvironment(home: paths.home), timeout: timeout)
    }
}

/// Finds `.env*.local` files by name with fts(3), without reading any file.
enum EnvLocalScanner {
    static func firstMatch(in path: String) -> String? {
        let handle: UnsafeMutablePointer<FTS>? = path.withCString { cPath in
            var arguments: [UnsafeMutablePointer<CChar>?] = [strdup(cPath), nil]
            defer { free(arguments[0]) }
            return fts_open(&arguments, FTS_PHYSICAL | FTS_NOCHDIR | FTS_NOSTAT, nil)
        }
        guard let handle else { return nil }
        defer { fts_close(handle) }
        while let entry = fts_read(handle) {
            let name = withUnsafePointer(to: &entry.pointee.fts_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.fts_namelen) + 1) {
                    String(cString: $0)
                }
            }
            if PathGuard.isEnvLocal(name) { return String(cString: entry.pointee.fts_path) }
        }
        return nil
    }
}

extension ProcessSampler {
    /// Names of your processes whose working folder is inside `folder`, or whose program file is.
    /// Reads only paths, never command lines.
    public static func processesUsing(folder: String) -> [String] {
        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
        var names: [String] = []
        for pid in allPIDs() where pid != getpid() {
            let cwd = workingDirectory(pid)
            let program = path(pid)
            let inside = [cwd, program].contains { candidate in
                guard let candidate else { return false }
                return candidate == folder || candidate.hasPrefix(prefix)
            }
            if inside { names.append(name(pid) ?? (program.map { ($0 as NSString).lastPathComponent } ?? "pid \(pid)")) }
        }
        return names
    }
}

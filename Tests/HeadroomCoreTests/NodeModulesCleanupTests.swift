import Foundation
import Testing
@testable import HeadroomCore

/// Every test uses real git repositories with a local "remote", inside a throwaway fixture home.
@Suite("node_modules clean-up")
struct NodeModulesCleanupTests {
    /// A pushed repo whose .gitignore ignores node_modules, with a populated node_modules.
    private func cleanRepo(_ fx: Fixture, ignore: Bool = true) throws -> URL {
        let remote = try fx.folder("remote.git")
        let repo = try fx.folder("Developer/app")
        try git(["init", "-q", "--bare", "-b", "main", remote.path], in: fx.home)
        try git(["init", "-q", "-b", "main", repo.path], in: fx.home)
        try fx.file("package.json", bytes: 20, in: repo)
        try fx.file("yarn.lock", bytes: 20, in: repo)
        if ignore { try "node_modules\n".write(to: repo.appending(path: ".gitignore"), atomically: true, encoding: .utf8) }
        try git(["add", "."], in: repo)
        try git(["commit", "-q", "-m", "init"], in: repo)
        try git(["remote", "add", "origin", remote.path], in: repo)
        try git(["push", "-q", "-u", "origin", "main"], in: repo)
        return repo
    }

    private func info(_ repo: URL, bytes: Int64? = 10_000) -> WorktreeInfo {
        WorktreeInfo(repository: "app", path: repo.path, branch: "main", isDetached: false, isMainWorktree: true,
                     upstream: "origin/main", unpushedCommits: 0, behind: 0, uncommittedChanges: 0, lastCommit: nil,
                     isMissing: false, nodeModulesBytes: bytes, nxCacheBytes: nil, error: nil)
    }

    private func cleanup(_ fx: Fixture, mode: ExecutionMode = .live, using: [String] = []) -> NodeModulesCleanup {
        NodeModulesCleanup(paths: fx.paths, mode: mode, processesUsing: { _ in using })
    }

    @Test func removesOnlyNodeModulesFromACleanPushedWorktree() async throws {
        let fx = try Fixture()
        let repo = try cleanRepo(fx)
        try fx.file("node_modules/react/index.js", bytes: 50_000, in: repo)
        try fx.file("node_modules/.bin/tool", bytes: 100, in: repo)

        let result = await cleanup(fx).remove(info(repo))

        #expect(result.succeeded, "\(result.message)")
        #expect(!fx.exists(repo.appending(path: "node_modules")))
        #expect(fx.exists(repo.appending(path: "package.json")))
        #expect(fx.exists(repo.appending(path: ".gitignore")))
        #expect(fx.exists(repo.appending(path: ".git")))
    }

    @Test func dryRunChecksEverythingButDeletesNothing() async throws {
        let fx = try Fixture()
        let repo = try cleanRepo(fx)
        try fx.file("node_modules/react/index.js", in: repo)

        let result = await cleanup(fx, mode: .dryRun).remove(info(repo))

        #expect(result.succeeded)
        #expect(result.message.contains("Dry run"))
        #expect(fx.exists(repo.appending(path: "node_modules/react/index.js")))
    }

    @Test func refusesWhenThereIsUncommittedWork() async throws {
        let fx = try Fixture()
        let repo = try cleanRepo(fx)
        try fx.file("node_modules/react/index.js", in: repo)
        try fx.file("notes.md", bytes: 10, in: repo)  // untracked counts as uncommitted

        let result = await cleanup(fx).remove(info(repo))

        #expect(result.blocker == .uncommittedChanges(1))
        #expect(fx.exists(repo.appending(path: "node_modules/react/index.js")))
    }

    @Test func refusesWhenCommitsAreNotPushed() async throws {
        let fx = try Fixture()
        let repo = try cleanRepo(fx)
        try fx.file("node_modules/react/index.js", in: repo)
        try fx.file("src.js", bytes: 10, in: repo)
        try git(["add", "src.js"], in: repo)
        try git(["commit", "-q", "-m", "local only"], in: repo)

        let result = await cleanup(fx).remove(info(repo))

        #expect(result.blocker == .unpushedCommits(1))
        #expect(fx.exists(repo.appending(path: "node_modules")))
    }

    @Test func refusesWhenGitDoesNotIgnoreNodeModules() async throws {
        let fx = try Fixture()
        let repo = try cleanRepo(fx, ignore: false)
        try fx.folder("node_modules", in: repo)  // empty, so git status stays clean

        let result = await cleanup(fx).remove(info(repo))

        #expect(result.blocker == .notIgnored)
        #expect(fx.exists(repo.appending(path: "node_modules")))
    }

    @Test func refusesWhenNodeModulesHasTrackedFiles() async throws {
        let fx = try Fixture()
        let repo = try cleanRepo(fx)
        try fx.file("node_modules/vendored/index.js", bytes: 10, in: repo)
        try git(["add", "-f", "node_modules/vendored/index.js"], in: repo)
        try git(["commit", "-q", "-m", "vendor"], in: repo)
        try git(["push", "-q"], in: repo)

        let result = await cleanup(fx).remove(info(repo))

        #expect(result.blocker == .hasTrackedFiles)
        #expect(fx.exists(repo.appending(path: "node_modules/vendored/index.js")))
    }

    @Test func refusesASymlinkedNodeModules() async throws {
        let fx = try Fixture()
        let repo = try cleanRepo(fx)
        let shared = try fx.folder("shared-modules")
        try fx.file("shared-modules/react/index.js", in: fx.home)
        _ = try fx.symlink("node_modules", to: shared, in: repo)

        let result = await cleanup(fx).remove(info(repo))

        #expect(result.blocker == .nodeModulesIsSymlink)
        #expect(fx.exists(shared.appending(path: "react/index.js")))
    }

    @Test func refusesWhileSomethingRunsFromTheWorktree() async throws {
        let fx = try Fixture()
        let repo = try cleanRepo(fx)
        try fx.file("node_modules/react/index.js", in: repo)

        let result = await cleanup(fx, using: ["node", "node"]).remove(info(repo))

        #expect(result.blocker == .inUse(["node"]))
        #expect(fx.exists(repo.appending(path: "node_modules")))
    }

    @Test func refusesWhenNodeModulesHoldsAnEnvLocalFile() async throws {
        let fx = try Fixture()
        let repo = try cleanRepo(fx)
        try fx.file("node_modules/some-pkg/.env.local", bytes: 10, in: repo)

        let result = await cleanup(fx).remove(info(repo))

        guard case .containsEnvLocalFile(let path) = result.blocker else {
            Issue.record("expected an .env*.local blocker, got \(String(describing: result.blocker))")
            return
        }
        #expect(path.hasSuffix("node_modules/some-pkg/.env.local"))
        #expect(fx.exists(repo.appending(path: "node_modules/some-pkg/.env.local")))
    }

    @Test func refusesAWorktreeOutsideHome() async throws {
        let fx = try Fixture()
        let outside = fx.root.appending(path: "elsewhere", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outside.appending(path: "node_modules"), withIntermediateDirectories: true)

        let result = await cleanup(fx).remove(info(outside))

        #expect(result.blocker == .notUnderHome)
    }

    @Test func quickCheckExplainsWhyNot() {
        let base = WorktreeInfo(repository: "app", path: "/x", branch: "b", isDetached: false, isMainWorktree: false,
                                upstream: "origin/b", unpushedCommits: 0, behind: 0, uncommittedChanges: 0, lastCommit: nil,
                                isMissing: false, nodeModulesBytes: 1_000, nxCacheBytes: nil, error: nil)
        #expect(NodeModulesCleanup.quickBlocker(for: base) == nil)
        var dirty = base; dirty.uncommittedChanges = 3
        #expect(NodeModulesCleanup.quickBlocker(for: dirty) == .uncommittedChanges(3))
        var ahead = base; ahead.unpushedCommits = 2
        #expect(NodeModulesCleanup.quickBlocker(for: ahead) == .unpushedCommits(2))
        var unknown = base; unknown.unpushedCommits = nil
        #expect(NodeModulesCleanup.quickBlocker(for: unknown) == .statusUnknown)
        var none = base; none.nodeModulesBytes = nil
        #expect(NodeModulesCleanup.quickBlocker(for: none) == .noNodeModules)
    }

    @Test func suggestsTheRightReinstallCommand() throws {
        let fx = try Fixture()
        let repo = try fx.folder("p")
        #expect(NodeModulesCleanup.reinstallCommand(in: repo.path) == "npm install")
        try fx.file("yarn.lock", bytes: 1, in: repo)
        #expect(NodeModulesCleanup.reinstallCommand(in: repo.path) == "yarn install")
        try fx.file("pnpm-lock.yaml", bytes: 1, in: repo)
        #expect(NodeModulesCleanup.reinstallCommand(in: repo.path) == "pnpm install")
    }

    @Test func findsAProcessRunningInsideAFolder() async throws {
        let fx = try Fixture()
        let folder = try fx.folder("busy")
        let canonical = try #require(Canonical.path(of: folder))
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        child.currentDirectoryURL = folder
        try child.run()
        defer { child.terminate() }
        try await Task.sleep(for: .milliseconds(200))

        #expect(ProcessSampler.processesUsing(folder: canonical).contains("sleep"))
        #expect(ProcessSampler.processesUsing(folder: canonical + "-other").isEmpty)
    }

    // MARK: Helpers

    private func git(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false",
                             "-c", "core.hooksPath=/dev/null", "-c", "init.defaultBranch=main"] + arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw GitFailure(arguments: arguments) }
    }

    private struct GitFailure: Error { let arguments: [String] }
}

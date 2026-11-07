import Foundation
import Testing
@testable import HeadroomCore

@Suite("Folder sizes")
struct FolderSizeTests {
    @Test func walkerCountsNestedFilesAndMarksNothingPartial() throws {
        let fx = try Fixture()
        for index in 0..<50 { try fx.file("tree/pkg\(index % 5)/lib/file\(index).js", bytes: 4_096) }
        let size = DirectorySizer.measure(fx.home.appending(path: "tree"))
        #expect(size.fileCount == 50)
        #expect(size.bytes >= 50 * 4_096)
        #expect(size.partial == false)
    }

    @Test func unreadableFolderIsMarkedPartial() throws {
        let fx = try Fixture()
        try fx.file("tree/ok", bytes: 1_000)
        let locked = try fx.folder("tree/locked")
        try fx.file("tree/locked/secret", bytes: 1_000)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        let size = DirectorySizer.measure(fx.home.appending(path: "tree"))
        #expect(size.partial)
        #expect(size.fileCount == 1)
    }

    @Test func measuresManyWorktreesInParallelAndKeepsOrder() async throws {
        let fx = try Fixture()
        var worktrees: [WorktreeInfo] = []
        for index in 0..<10 {
            let root = try fx.folder("wt\(index)")
            try fx.file("wt\(index)/node_modules/pkg/index.js", bytes: (index + 1) * 10_000)
            if index.isMultiple(of: 2) { try fx.file("wt\(index)/.nx/cache/out", bytes: 20_000) }
            worktrees.append(WorktreeInfo(repository: "repo", path: root.path, branch: "b\(index)", isDetached: false, isMainWorktree: index == 0,
                                          upstream: nil, unpushedCommits: 0, behind: 0, uncommittedChanges: 0, lastCommit: nil,
                                          isMissing: false, nodeModulesBytes: nil, nxCacheBytes: nil, error: nil))
        }

        let seen = Counter()
        let measured = await WorktreeScanner.withFolderSizes(worktrees) { _ in await seen.increment() }

        #expect(measured.map(\.path) == worktrees.map(\.path))
        #expect(await seen.value == worktrees.count)
        for (index, info) in measured.enumerated() {
            #expect((info.nodeModulesBytes ?? 0) >= Int64((index + 1) * 10_000))
            #expect((info.nxCacheBytes != nil) == index.isMultiple(of: 2))
        }
    }
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

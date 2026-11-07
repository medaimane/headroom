import Foundation
import Testing
@testable import HeadroomCore

@Suite("Path guard: what may be removed")
struct PathGuardTests {
    @Test func allowsItemsInsideAnAllowedRoot() throws {
        let fx = try Fixture()
        let root = try fx.folder("Library/Developer/Xcode/DerivedData")
        let item = try fx.folder("DerivedData/App-abc", in: root.deletingLastPathComponent())
        let pathGuard = PathGuard(paths: fx.paths, roots: [root])
        #expect(pathGuard.rejectedRoots.isEmpty)
        #expect(throws: Never.self) { try pathGuard.validate(item) }
    }

    @Test func allowsSpacesAndUnicodeInNames() throws {
        let fx = try Fixture()
        let root = try fx.folder("Library/Caches/Yarn")
        let item = try fx.file("Library/Caches/Yarn/v6/npm-émoji 😀 pkg/file.js")
        let pathGuard = PathGuard(paths: fx.paths, roots: [root])
        #expect(throws: Never.self) { try pathGuard.validate(item.deletingLastPathComponent()) }
    }

    @Test func rejectsTheRootItselfAndSiblings() throws {
        let fx = try Fixture()
        let root = try fx.folder("Library/Caches/Yarn")
        let sibling = try fx.folder("Library/Caches/Important")
        let pathGuard = PathGuard(paths: fx.paths, roots: [root])
        #expect(throws: GuardViolation.self) { try pathGuard.validate(root) }
        #expect(throws: GuardViolation.self) { try pathGuard.validate(sibling) }
        #expect(throws: GuardViolation.self) { try pathGuard.validate(fx.home) }
    }

    @Test func rejectsDotDotTraversal() throws {
        let fx = try Fixture()
        let root = try fx.folder("Library/Caches/Yarn")
        try fx.folder("Documents/thesis")
        let sneaky = root.appending(path: "../../../Documents/thesis")
        let pathGuard = PathGuard(paths: fx.paths, roots: [root])
        #expect(throws: GuardViolation.self) { try pathGuard.validate(sneaky) }
        #expect(throws: GuardViolation.self) { try pathGuard.validate(root.appending(path: "..")) }
    }

    @Test func rejectsARootRedirectedBySymlink() throws {
        let fx = try Fixture()
        let documents = try fx.folder("Documents")
        try fx.file("Documents/precious.txt")
        try fx.folder("Library/Caches")
        let root = try fx.symlink("Library/Caches/Yarn", to: documents)
        let pathGuard = PathGuard(paths: fx.paths, roots: [root])
        #expect(pathGuard.allowedRoots.isEmpty)
        #expect(pathGuard.rejectedRoots == [.rootIsSymlinked(root.path)])
        #expect(throws: GuardViolation.self) { try pathGuard.validate(root.appending(path: "precious.txt")) }
    }

    @Test func rejectsRootsOutsideHomeAndTemp() throws {
        let fx = try Fixture()
        let outside = fx.root.appending(path: "elsewhere", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let pathGuard = PathGuard(paths: fx.paths, roots: [outside, fx.home, fx.paths.temporary])
        #expect(pathGuard.allowedRoots.isEmpty)
        #expect(pathGuard.rejectedRoots.count == 3)
    }

    @Test func rejectsAnythingInsideAGitWorkingTree() throws {
        let fx = try Fixture()
        // A cache folder that happens to sit inside a repository.
        try fx.folder("project/.git")
        let root = try fx.folder("project/.cache")
        let item = try fx.file("project/.cache/blob")
        let pathGuard = PathGuard(paths: fx.paths, roots: [root])
        #expect(throws: GuardViolation.insideGitWorkingTree(Canonical.path(of: fx.home.appending(path: "project"))!)) {
            try pathGuard.validate(item)
        }
    }

    @Test func rejectsEnvLocalFiles() throws {
        let fx = try Fixture()
        let root = try fx.folder("Library/Caches/Yarn")
        let folder = try fx.folder("Library/Caches/Yarn/pkg")
        try fx.file("Library/Caches/Yarn/pkg/deep/.env.sandbox.local")
        let direct = try fx.file("Library/Caches/Yarn/.env.local")
        let pathGuard = PathGuard(paths: fx.paths, roots: [root])
        #expect(throws: GuardViolation.self) { try pathGuard.validate(folder) }
        #expect(throws: GuardViolation.self) { try pathGuard.validate(direct) }
        #expect(PathGuard.isEnvLocal(".env.development.local"))
        #expect(!PathGuard.isEnvLocal(".env"))
        #expect(!PathGuard.isEnvLocal(".env.example"))
    }

    @Test func temporaryItemsOnlyWithAKnownPrefix() throws {
        let fx = try Fixture()
        let metro = try fx.folder("metro-cache-1", in: fx.paths.temporary)
        let other = try fx.folder("some-app-state", in: fx.paths.temporary)
        let pathGuard = PathGuard(paths: fx.paths, roots: [], temporaryPrefixes: ["metro-"])
        #expect(throws: Never.self) { try pathGuard.validate(metro) }
        #expect(throws: GuardViolation.self) { try pathGuard.validate(other) }
    }

    @Test func aSymlinkedItemIsCheckedAsTheLinkNotItsTarget() throws {
        let fx = try Fixture()
        let root = try fx.folder("Library/Caches/Yarn")
        let documents = try fx.folder("Documents")
        let link = try fx.symlink("Library/Caches/Yarn/link-to-docs", to: documents)
        let pathGuard = PathGuard(paths: fx.paths, roots: [root])
        // Allowed: removing it removes only the link.
        #expect(throws: Never.self) { try pathGuard.validate(link) }
    }
}

@Suite("Clean-up planner and executor")
struct CleanupTests {
    func cacheFixture() throws -> Fixture {
        let fx = try Fixture()
        try fx.file("Library/Developer/Xcode/DerivedData/App-abc/Build/big.o", bytes: 200_000)
        try fx.file("Library/Developer/Xcode/DerivedData/Other-def/Index/data", bytes: 50_000)
        try fx.file(".npm/_cacache/content-v2/sha512/aa", bytes: 30_000)
        try fx.folder("metro-123", in: fx.paths.temporary)
        try fx.file("metro-123/cache", bytes: 10_000, in: fx.paths.temporary)
        try fx.file("unrelated/keep", bytes: 10_000, in: fx.paths.temporary)
        try fx.file("Library/Logs/app.log", bytes: 1000)
        return fx
    }

    @Test func plansTargetsWithSizes() throws {
        let fx = try cacheFixture()
        let plan = CleanupPlanner(paths: fx.paths).plan(entryIDs: ["xcode.derivedData", "npm.cache", "metro.cache"], running: RunningWork())
        #expect(plan.items.count == 3)
        #expect(plan.items.allSatisfy { $0.blockedReason == nil })
        let derived = try #require(plan.items.first { $0.id == "xcode.derivedData" })
        #expect(derived.targets.map(\.url.lastPathComponent) == ["App-abc", "Other-def"])
        #expect(derived.bytes >= 250_000)
        let metro = try #require(plan.items.first { $0.id == "metro.cache" })
        #expect(metro.targets.map(\.url.lastPathComponent) == ["metro-123"])
    }

    @Test func blocksWhileTheOwningToolRuns() throws {
        let fx = try cacheFixture()
        let running = RunningWork(categories: [.metro], processNames: ["xcodebuild"])
        let plan = CleanupPlanner(paths: fx.paths).plan(entryIDs: ["xcode.derivedData", "metro.cache", "npm.cache"], running: running)
        #expect(plan.items.first { $0.id == "xcode.derivedData" }?.blockedReason?.contains("xcodebuild") == true)
        #expect(plan.items.first { $0.id == "metro.cache" }?.blockedReason?.contains("Metro") == true)
        #expect(plan.items.first { $0.id == "npm.cache" }?.blockedReason == nil)
    }

    @Test func neverPlansInfoOnlyLocations() throws {
        let fx = try cacheFixture()
        let plan = CleanupPlanner(paths: fx.paths).plan(entryIDs: ["info.logs", "info.trash"], running: RunningWork())
        #expect(plan.runnable.isEmpty)
        #expect(plan.items.allSatisfy { $0.blockedReason != nil && $0.targets.isEmpty })
    }

    @Test func unknownIDsAreIgnored() throws {
        let fx = try cacheFixture()
        let plan = CleanupPlanner(paths: fx.paths).plan(entryIDs: ["../../Documents", "rm -rf"], running: RunningWork())
        #expect(plan.items.isEmpty)
    }

    @Test func dryRunRemovesNothing() throws {
        let fx = try cacheFixture()
        let planner = CleanupPlanner(paths: fx.paths)
        let plan = planner.plan(entryIDs: ["xcode.derivedData", "npm.cache"], running: RunningWork())
        let remover = RecordingRemover()
        let report = CleanupExecutor(pathGuard: planner.makeGuard(), mode: .dryRun, remover: remover).execute(plan)
        #expect(remover.removed.isEmpty)
        #expect(report.bytes == plan.bytes)
        #expect(fx.exists(fx.home.appending(path: "Library/Developer/Xcode/DerivedData/App-abc")))
    }

    @Test func liveRunRemovesOnlyPlannedItemsInTheFixture() throws {
        let fx = try cacheFixture()
        let planner = CleanupPlanner(paths: fx.paths)
        let plan = planner.plan(entryIDs: ["xcode.derivedData", "metro.cache"], running: RunningWork())
        let report = CleanupExecutor(pathGuard: planner.makeGuard(), mode: .live).execute(plan)
        #expect(report.results.allSatisfy { $0.failures.isEmpty })
        let derived = fx.home.appending(path: "Library/Developer/Xcode/DerivedData")
        #expect(fx.exists(derived)) // the cache folder itself stays
        #expect((try FileManager.default.contentsOfDirectory(atPath: derived.path)).isEmpty)
        #expect(!fx.exists(fx.paths.temporary.appending(path: "metro-123")))
        #expect(fx.exists(fx.paths.temporary.appending(path: "unrelated/keep")))
        #expect(fx.exists(fx.home.appending(path: ".npm/_cacache/content-v2/sha512/aa")))
        #expect(fx.exists(fx.home.appending(path: "Library/Logs/app.log")))
    }

    @Test func revalidatesBeforeRemoving() throws {
        let fx = try cacheFixture()
        let planner = CleanupPlanner(paths: fx.paths)
        let plan = planner.plan(entryIDs: ["npm.cache"], running: RunningWork())
        // After the preview, someone drops a .env.local into the planned folder.
        try fx.file(".npm/_cacache/content-v2/.env.local", bytes: 10)
        let report = CleanupExecutor(pathGuard: planner.makeGuard(), mode: .live).execute(plan)
        #expect(report.results.first?.failures.isEmpty == false)
        #expect(fx.exists(fx.home.appending(path: ".npm/_cacache/content-v2/.env.local")))
    }

    @Test func removingASymlinkLeavesItsTargetAlone() throws {
        let fx = try cacheFixture()
        let documents = try fx.folder("Documents")
        let precious = try fx.file("Documents/precious.txt")
        _ = try fx.symlink(".npm/_cacache/link", to: documents)
        let planner = CleanupPlanner(paths: fx.paths)
        let plan = planner.plan(entryIDs: ["npm.cache"], running: RunningWork())
        _ = CleanupExecutor(pathGuard: planner.makeGuard(), mode: .live).execute(plan)
        #expect(!fx.exists(fx.home.appending(path: ".npm/_cacache/link")))
        #expect(fx.exists(precious))
    }

    @Test func debugBuildsForceDryRunOnTheRealHome() {
        let real = HostPaths(home: FileManager.default.homeDirectoryForCurrentUser, temporary: URL(fileURLWithPath: NSTemporaryDirectory()))
        #expect(ExecutionPolicy.effectiveMode(requested: .live, paths: real) == .dryRun)
        let fakeFixture = HostPaths(home: FileManager.default.homeDirectoryForCurrentUser, temporary: URL(fileURLWithPath: NSTemporaryDirectory()), isFixture: true)
        #expect(ExecutionPolicy.effectiveMode(requested: .live, paths: fakeFixture) == .dryRun)
    }

    @Test func homeOverrideOnlyWorksInsideTemporaryFolders() {
        let unsafe = HostPaths.current(environment: ["HEADROOM_HOME": FileManager.default.homeDirectoryForCurrentUser.path])
        #expect(!unsafe.isFixture)
        let safe = HostPaths.current(environment: ["HEADROOM_HOME": NSTemporaryDirectory()])
        #expect(safe.isFixture)
    }
}

@Suite("Developer item removal")
struct DevItemRemovalTests {
    @Test func dryRunRunsNoCommand() async throws {
        let fx = try Fixture()
        let runner = FakeRunner()
        let item = DevItem(id: "runtime:0BA0FDBE-42EE-4187-9B0A-94704458B5CE", kind: .simulatorRuntime, name: "iOS 18.6", detail: "", bytes: 8_000_000_000)
        let result = await DevItemRemover(paths: fx.paths, mode: .dryRun, runner: runner).remove(item)
        #expect(result.succeeded)
        #expect(runner.calls.isEmpty)
        #expect(result.command == "xcrun simctl runtime delete 0BA0FDBE-42EE-4187-9B0A-94704458B5CE")
    }

    @Test func liveRunUsesSimctl() async throws {
        let fx = try Fixture()
        let runner = FakeRunner()
        let item = DevItem(id: "device:ABC-123", kind: .simulatorDevice, name: "iPhone", detail: "", bytes: 1)
        _ = await DevItemRemover(paths: fx.paths, mode: .live, runner: runner).remove(item)
        #expect(runner.calls == [["/usr/bin/xcrun", "simctl", "delete", "ABC-123"]])
    }

    @Test func rejectsOddIdentifiers() async throws {
        let fx = try Fixture()
        let runner = FakeRunner()
        for id in ["runtime:--all", "runtime:a b", "runtime:x;rm", "runtime:"] {
            let item = DevItem(id: id, kind: .simulatorRuntime, name: "x", detail: "", bytes: 1)
            let result = await DevItemRemover(paths: fx.paths, mode: .live, runner: runner).remove(item)
            #expect(!result.succeeded)
        }
        #expect(runner.calls.isEmpty)
    }

    @Test func blockedItemsAreNotRemoved() async throws {
        let fx = try Fixture()
        let runner = FakeRunner()
        let item = DevItem(id: "device:ABC", kind: .simulatorDevice, name: "iPhone", detail: "", bytes: 1, isInUse: true, blockedReason: "running")
        let result = await DevItemRemover(paths: fx.paths, mode: .live, runner: runner).remove(item)
        #expect(!result.succeeded)
        #expect(runner.calls.isEmpty)
    }

    @Test func avdGoesToTheTrashWithItsIniFile() async throws {
        let fx = try Fixture()
        let avd = try fx.folder(".android/avd/Pixel_9a.avd")
        try fx.file(".android/avd/Pixel_9a.ini", bytes: 10)
        let remover = RecordingRemover()
        let items = DevItemScanner(paths: fx.paths).androidAVDs(emulatorRunning: false)
        #expect(items.map(\.name) == ["Pixel 9a"])
        let result = await DevItemRemover(paths: fx.paths, mode: .live, remover: remover).remove(items[0])
        #expect(result.succeeded)
        #expect(remover.trashed.map(\.lastPathComponent).sorted() == ["Pixel_9a.avd", "Pixel_9a.ini"])
        #expect(fx.exists(avd))
    }

    @Test func trashMovesStayInsideTheirFolders() async throws {
        let fx = try Fixture()
        try fx.folder(".android/avd")
        let documents = try fx.folder("Documents")
        let remover = RecordingRemover()
        let item = DevItem(id: "avd:x", kind: .androidAVD, name: "x", detail: "", bytes: 1, location: documents)
        let result = await DevItemRemover(paths: fx.paths, mode: .live, remover: remover).remove(item)
        #expect(!result.succeeded)
        #expect(remover.trashed.isEmpty)
    }

    @Test func runningEmulatorBlocksAVDs() throws {
        let fx = try Fixture()
        try fx.folder(".android/avd/Pixel_9a.avd")
        let items = DevItemScanner(paths: fx.paths).androidAVDs(emulatorRunning: true)
        #expect(items.first?.blockedReason != nil)
    }
}

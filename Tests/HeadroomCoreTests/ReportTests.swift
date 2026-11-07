import Foundation
import Testing
@testable import HeadroomCore

@Suite("Git parsing and worktree scanning")
struct WorktreeTests {
    @Test func parsesWorktreeList() {
        let output = """
        worktree /Users/me/dev/app
        HEAD 1111111111111111111111111111111111111111
        branch refs/heads/development

        worktree /Users/me/dev/app/.claude/worktrees/feat
        HEAD 2222222222222222222222222222222222222222
        branch refs/heads/feature/login

        worktree /Users/me/dev/app-old
        HEAD 3333333333333333333333333333333333333333
        detached
        prunable gitdir file points to non-existent location

        """
        let entries = GitParsers.worktreeList(output)
        #expect(entries.count == 3)
        #expect(entries[0].branch == "development")
        #expect(entries[1].branch == "feature/login")
        #expect(entries[2].isDetached && entries[2].isPrunable)
    }

    @Test func parsesStatusWithoutKeepingFileNames() {
        let output = """
        # branch.oid abc
        # branch.head feature/login
        # branch.upstream origin/feature/login
        # branch.ab +2 -5
        1 .M N... 100644 100644 100644 aaa bbb src/app.ts
        ? notes.txt
        """
        let status = GitParsers.status(output)
        #expect(status.branch == "feature/login")
        #expect(status.upstream == "origin/feature/login")
        #expect(status.ahead == 2)
        #expect(status.behind == 5)
        #expect(status.changes == 2)
    }

    @Test func scansRealRepositoriesReadOnly() async throws {
        let fx = try Fixture()
        let dev = try fx.folder("Developer")
        let remote = try fx.folder("remote.git")
        let repo = dev.appending(path: "app")
        try git(["init", "-q", "--bare", "-b", "main", remote.path], in: fx.home)
        try git(["init", "-q", "-b", "main", repo.path], in: fx.home)
        try fx.file("README.md", bytes: 10, in: repo)
        try git(["add", "."], in: repo)
        try git(["commit", "-q", "-m", "init"], in: repo)
        try git(["remote", "add", "origin", remote.path], in: repo)
        try git(["push", "-q", "-u", "origin", "main"], in: repo)
        // A worktree with an unpushed commit, and uncommitted work in main.
        let worktree = dev.appending(path: "app-feature")
        try git(["worktree", "add", "-q", "-b", "feature", worktree.path], in: repo)
        try fx.file("feature.txt", bytes: 10, in: worktree)
        try git(["add", "."], in: worktree)
        try git(["commit", "-q", "-m", "feature"], in: worktree)
        try fx.file("scratch.txt", bytes: 10, in: repo)
        try fx.file("node_modules/pkg/index.js", bytes: 100_000, in: repo)
        let indexBefore = try Data(contentsOf: repo.appending(path: ".git/index"))

        let results = await WorktreeScanner(paths: fx.paths).scan(roots: [dev])
        #expect(results.count == 2)
        let main = try #require(results.first { $0.branch == "main" })
        #expect(main.isMainWorktree)
        #expect(main.upstream == "origin/main")
        #expect(main.unpushedCommits == 0)
        #expect((main.uncommittedChanges ?? 0) >= 1) // scratch.txt, plus node_modules (untracked here)
        #expect(main.status == .uncommitted)
        #expect((main.nodeModulesBytes ?? 0) >= 100_000)
        let feature = try #require(results.first { $0.branch == "feature" })
        #expect(feature.unpushedCommits == 1)
        #expect(feature.status == .unpushed)
        #expect(feature.upstream == nil)

        // Read-only: the index file is unchanged.
        #expect(try Data(contentsOf: repo.appending(path: ".git/index")) == indexBefore)
    }

    private func git(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"] + arguments
        process.currentDirectoryURL = directory
        process.environment = ["HOME": directory.path, "PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 { throw CommandError.launchFailed("git \(arguments.joined(separator: " "))") }
    }
}

@Suite("simctl and Docker parsing")
struct ParsingTests {
    @Test func parsesRuntimes() throws {
        let json = """
        {
          "0BA0FDBE-42EE-4187-9B0A-94704458B5CE" : {
            "build" : "24S118", "deletable" : true, "identifier" : "0BA0FDBE-42EE-4187-9B0A-94704458B5CE",
            "platformIdentifier" : "com.apple.platform.watchsimulator", "runtimeIdentifier" : "com.apple.CoreSimulator.SimRuntime.watchOS-27-2",
            "sizeBytes" : 3856669156, "state" : "Ready", "version" : "27.2", "unknownField": [1, 2]
          },
          "0DC515F1-E39F-4693-940E-2E32BC73FB22" : {
            "build" : "22G86", "deletable" : false, "identifier" : "0DC515F1-E39F-4693-940E-2E32BC73FB22", "lastUsedAt" : "2026-11-04T02:08:27Z",
            "platformIdentifier" : "com.apple.platform.iphonesimulator", "sizeBytes" : 8838255185, "state" : "Ready", "version" : "18.6"
          }
        }
        """
        let items = try SimctlParser.runtimes(from: json)
        #expect(items.map(\.name) == ["iOS 18.6", "watchOS 27.2"])
        #expect(items[0].bytes == 8_838_255_185)
        #expect(items[0].lastUsed != nil)
        #expect(items[0].blockedReason != nil)
        #expect(items[1].blockedReason == nil)
    }

    @Test func parsesDevices() throws {
        let json = """
        {"devices": {
          "com.apple.CoreSimulator.SimRuntime.iOS-27-2": [
            {"udid": "A", "name": "iPhone 18 Pro", "state": "Booted", "isAvailable": true, "dataPathSize": 5000000000, "dataPath": "/tmp/a", "deviceTypeIdentifier": "x", "logPath": "/tmp"},
            {"udid": "B", "name": "iPhone 18 Pro Max", "state": "Shutdown", "isAvailable": true, "dataPathSize": 2000000000}
          ],
          "com.apple.CoreSimulator.SimRuntime.iOS-18-6": [
            {"udid": "C", "name": "iPhone 16", "state": "Shutdown", "isAvailable": false}
          ]
        }}
        """
        let items = try SimctlParser.devices(from: json)
        #expect(items.map(\.name) == ["iPhone 18 Pro", "iPhone 18 Pro Max", "iPhone 16"])
        #expect(items[0].isInUse && items[0].blockedReason != nil)
        #expect(items[0].detail == "iOS 27.2")
        #expect(items[2].detail.contains("runtime missing"))
        #expect(SimctlParser.runtimeLabel("com.apple.CoreSimulator.SimRuntime.iOS-27-2-iPhone19-4") == "iOS 27.2")
    }

    @Test func parsesDockerSystemDF() {
        let output = """
        {"Active":"2","Reclaimable":"1.2GB (40%)","Size":"3GB","TotalCount":"5","Type":"Images"}
        {"Active":"1","Reclaimable":"0B (0%)","Size":"800MB","TotalCount":"1","Type":"Local Volumes"}
        """
        let rows = DockerUsage.parse(output)
        #expect(rows.map(\.type) == ["Images", "Local Volumes"])
        #expect(rows[0].reclaimable == "1.2GB (40%)")
    }
}

@Suite("Health, alerts, snapshots and records")
struct RecordsTests {
    func sample(at seconds: TimeInterval, diskFree: Int64 = 200 * Format.gigabyte, pressure: PressureLevel = .normal, swap: UInt64 = 0, thermal: ThermalLevel = .nominal, cpu: Double = 0.3, memory: UInt64 = 8_000_000_000) -> MetricsSample {
        MetricsSample(date: Date(timeIntervalSince1970: seconds), memoryTotal: 16_000_000_000, memoryUsed: memory, memoryCompressed: 0, memoryWired: 0,
                      pressure: pressure, swapUsed: swap, swapTotal: 0, cpuUsage: cpu, thermal: thermal,
                      diskTotal: 494 * Format.gigabyte, diskFree: diskFree, diskFreeIncludingPurgeable: diskFree)
    }

    @Test func assessesLevels() {
        let settings = HeadroomSettings()
        let lowDisk = HealthAssessment(sample: sample(at: 0, diskFree: 32 * Format.gigabyte), settings: settings)
        #expect(lowDisk.disk == .warning)
        #expect(lowDisk.overall == .warning)
        let critical = HealthAssessment(sample: sample(at: 0, diskFree: 10 * Format.gigabyte, pressure: .critical), settings: settings)
        #expect(critical.overall == .critical)
        let busyCPU = HealthAssessment(sample: sample(at: 0, cpu: 1.0), settings: settings)
        #expect(busyCPU.cpu == .warning)
        #expect(busyCPU.overall == .good)
    }

    @Test func alertsAreDebounced() {
        var evaluator = AlertEvaluator(cooldown: 1800)
        let settings = HeadroomSettings()
        #expect(evaluator.evaluate(sample(at: 0, diskFree: 40 * Format.gigabyte), settings: settings).map(\.kind) == [.lowDisk])
        #expect(evaluator.evaluate(sample(at: 60, diskFree: 40 * Format.gigabyte), settings: settings).isEmpty)
        // Getting worse breaks through the cooldown.
        #expect(evaluator.evaluate(sample(at: 120, diskFree: 10 * Format.gigabyte), settings: settings).map(\.kind) == [.lowDisk])
        #expect(evaluator.evaluate(sample(at: 2000, diskFree: 10 * Format.gigabyte), settings: settings).map(\.kind) == [.lowDisk])
    }

    @Test func memoryPressureMustLast() {
        var evaluator = AlertEvaluator()
        var settings = HeadroomSettings()
        settings.pressureSustainSeconds = 120
        #expect(evaluator.evaluate(sample(at: 0, pressure: .warning), settings: settings).isEmpty)
        #expect(evaluator.evaluate(sample(at: 60, pressure: .warning), settings: settings).isEmpty)
        #expect(evaluator.evaluate(sample(at: 130, pressure: .warning), settings: settings).map(\.kind) == [.memoryPressure])
        // A dip back to normal resets the timer.
        #expect(evaluator.evaluate(sample(at: 140, pressure: .normal), settings: settings).isEmpty)
        #expect(evaluator.evaluate(sample(at: 150, pressure: .critical), settings: settings).isEmpty)
    }

    @Test func snapshotVerdicts() throws {
        var calm = SnapshotAccumulator(label: "calm", start: Date(timeIntervalSince1970: 0))
        for t in stride(from: 0.0, to: 600, by: 5) { calm.add(sample(at: t)) }
        let calmSnapshot = try #require(calm.finish(end: Date(timeIntervalSince1970: 600)))
        #expect(calmSnapshot.verdict == .comfortable)
        #expect(calmSnapshot.sampleCount == 120)

        var heavy = SnapshotAccumulator(label: "heavy", start: Date(timeIntervalSince1970: 0))
        heavy.add(sample(at: 0, swap: 1_000_000_000), groups: [ProcessGroup(category: .iosSimulator, memory: 3_000_000_000, cpu: 1, processes: [], subgroups: [])], deviceCount: 3)
        heavy.add(sample(at: 60, pressure: .warning, swap: 2_000_000_000))
        heavy.add(sample(at: 120, pressure: .warning, swap: 4_000_000_000, thermal: .fair))
        let heavySnapshot = try #require(heavy.finish(end: Date(timeIntervalSince1970: 120)))
        #expect(heavySnapshot.verdict == .over)
        #expect(heavySnapshot.swapGrowth == 3_000_000_000)
        #expect(heavySnapshot.secondsUnderPressure == 120)
        #expect(heavySnapshot.testDevices == 3)
        #expect(heavySnapshot.categoryPeaks["iOS Simulator"] == 3_000_000_000)
    }

    @Test func historyRoundTripsAndExports() throws {
        let fx = try Fixture()
        let store = HistoryStore(directory: fx.paths.supportDirectory)
        try store.append(HistoryEntry(date: Date(timeIntervalSince1970: 0), action: "Clean npm cache", detail: "3 items", bytes: 1_000_000, dryRun: true, succeeded: true, undo: "Rebuilds | itself"))
        try store.append(HistoryEntry(date: Date(timeIntervalSince1970: 60), action: "Clean Gradle", detail: "", bytes: 0, dryRun: false, succeeded: false, undo: ""))
        let loaded = store.load()
        #expect(loaded.map(\.action) == ["Clean Gradle", "Clean npm cache"])
        let markdown = HistoryStore.markdown(loaded)
        #expect(markdown.contains("| Clean npm cache |"))
        #expect(markdown.contains("Rebuilds \\| itself"))
    }

    @Test func settingsToleratesMissingKeys() throws {
        let fx = try Fixture()
        let store = SettingsStore(directory: fx.paths.supportDirectory)
        try FileManager.default.createDirectory(at: fx.paths.supportDirectory, withIntermediateDirectories: true)
        try Data(#"{"dryRun": false, "worktreeRoots": ["Code"]}"#.utf8).write(to: store.fileURL)
        let settings = store.load()
        #expect(settings.dryRun == false)
        #expect(settings.worktreeRoots == ["Code"])
        #expect(settings.diskTargetBytes == 100 * Format.gigabyte)
        #expect(HeadroomSettings().dryRun == true)
    }

    @Test func snapshotsPersist() throws {
        let fx = try Fixture()
        let store = SnapshotStore(directory: fx.paths.supportDirectory)
        var acc = SnapshotAccumulator(label: "x", start: Date(timeIntervalSince1970: 0))
        acc.add(sample(at: 0))
        let snapshot = try #require(acc.finish(end: Date(timeIntervalSince1970: 5)))
        try store.save([snapshot])
        #expect(store.load() == [snapshot])
    }
}

@Suite("Sizes and metrics")
struct StorageTests {
    @Test func measuresFolders() throws {
        let fx = try Fixture()
        try fx.file("cache/a", bytes: 100_000)
        try fx.file("cache/sub/b", bytes: 50_000)
        let size = DirectorySizer.measure(fx.home.appending(path: "cache"))
        #expect(size.fileCount == 2)
        #expect(size.bytes >= 150_000)
        #expect(size.newestModification != nil)
        #expect(DirectorySizer.measure(fx.home.appending(path: "missing")) == .empty)
    }

    @Test func doesNotFollowSymlinkedFolders() throws {
        let fx = try Fixture()
        let big = try fx.folder("big")
        try fx.file("big/blob", bytes: 1_000_000)
        try fx.folder("cache")
        _ = try fx.symlink("cache/link", to: big)
        #expect(DirectorySizer.measure(fx.home.appending(path: "cache")).bytes < 100_000)
    }

    @Test func catalogIdsAreUniqueAndLocationsRelative() {
        let ids = StorageCatalog.entries.map(\.id)
        #expect(Set(ids).count == ids.count)
        for entry in StorageCatalog.entries {
            switch entry.location {
            case .home(let path), .androidSDK(let path):
                #expect(!path.hasPrefix("/") && !path.contains(".."))
            case .temporaryPrefix(let prefix):
                #expect(prefix.count >= 3 && !prefix.contains("/"))
            }
        }
    }

    @Test func readsLiveMetrics() async throws {
        var reader = SystemMetricsReader()
        _ = reader.sample()
        try await Task.sleep(for: .milliseconds(300))
        let sample = reader.sample()
        #expect(sample.memoryTotal > 0)
        #expect(sample.memoryUsed > 0 && sample.memoryUsed <= sample.memoryTotal + sample.memoryCompressed)
        #expect(sample.diskTotal > 0 && sample.diskFree > 0)
        #expect((0...1).contains(sample.cpuUsage))
    }
}

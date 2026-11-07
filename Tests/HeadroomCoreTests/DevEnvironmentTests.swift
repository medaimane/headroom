import Darwin
import Foundation
import Testing
@testable import HeadroomCore

@Suite("Dev environment")
struct DevEnvironmentTests {
    // MARK: Ports

    @Test func readsARealListeningPortOfThisProcess() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        try #require(fd >= 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        try #require(bound == 0)
        try #require(listen(fd, 1) == 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        let port = UInt16(bigEndian: address.sin_port)

        #expect(ListeningPorts.tcp(pid: getpid()).contains(port))
    }

    @Test func labelsWellKnownPorts() {
        #expect(ListeningPorts.label(for: 8081) == "Metro")
        #expect(ListeningPorts.label(for: 3000) == "web dev server")
        #expect(ListeningPorts.label(for: 5554) == "emulator console")
        #expect(ListeningPorts.label(for: 12345) == nil)
    }

    // MARK: Snapshot

    private func record(_ pid: pid_t, _ name: String, _ category: ProcessCategory, cwd: String? = nil, memory: UInt64 = 100) -> ProcessRecord {
        ProcessRecord(pid: pid, name: name, category: category, memory: memory, cpu: 0, workingDirectory: cwd, startTime: UInt64(pid) * 10)
    }

    @Test func groupsWhatIsRunning() {
        let records = [
            record(10, "node", .metro, cwd: "/Users/me/Developer/app-ec-1"),
            record(11, "next-server", .nextjs, cwd: "/Users/me/Developer/site"),
            record(12, "node", .nodeOther),                       // not listening: left out
            record(13, "Google Chrome Helper", .browser),         // listening, but not a dev server
            record(20, "qemu-system-aarch64", .androidEmulator, memory: 4_000),
            record(30, "claude", .claudeAgent, cwd: "/Users/me/Developer/app-ec-1", memory: 300),
            record(31, "claude", .claudeAgent, cwd: "/Users/me/Developer/app-ec-1", memory: 200),
            record(32, "claude", .claudeAgent, cwd: "/Users/me/Developer/app-ec-2", memory: 250),
            record(40, "launchd_sim", .iosSimulator, memory: 1_000),
            record(41, "SpringBoard", .iosSimulator, memory: 500),
        ]
        let ports: [pid_t: [UInt16]] = [10: [8081], 11: [3000], 13: [9222], 20: [5554, 5555]]
        let snapshot = DevEnvironment.snapshot(
            records: records,
            bootedSimulators: [(udid: "5C2C3A51-0000-4000-8000-000000000001", name: "iPhone 18 Pro", runtime: "iOS 27.0")],
            ports: { ports[$0] ?? [] },
            folder: { _ in nil })

        #expect(snapshot.simulators.map(\.name) == ["iPhone 18 Pro"])
        #expect(snapshot.simulatorMemory == 1_500)
        #expect(snapshot.emulators.count == 1)
        #expect(snapshot.emulators.first?.kind == .emulator(consolePort: 5554))
        #expect(snapshot.emulators.first?.detail == "emulator-5554")
        #expect(snapshot.servers.map(\.ports) == [[3000], [8081]])
        #expect(snapshot.servers.last?.detail == "Developer/app-ec-1")
        #expect(snapshot.agents.map(\.detail) == ["Developer/app-ec-1", "Developer/app-ec-2"])
        #expect(snapshot.agents.first?.memory == 500)
        #expect(snapshot.agents.allSatisfy { $0.stopBlockedReason != nil })
        #expect(snapshot.servers.allSatisfy { $0.stopBlockedReason == nil })
    }

    @Test func parsesBootedSimulatorsOnly() throws {
        let json = """
        {"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-27-0":[
          {"udid":"5C2C3A51-0000-4000-8000-000000000001","name":"iPhone 18 Pro","state":"Booted"},
          {"udid":"5C2C3A51-0000-4000-8000-000000000002","name":"iPhone 18 Pro Max","state":"Shutdown"}]}}
        """
        let booted = try DevEnvironment.bootedSimulators(from: json)
        #expect(booted.map(\.name) == ["iPhone 18 Pro"])
        #expect(booted.first?.runtime == "iOS 27.0")
    }

    // MARK: Stopping

    private let fx = try! Fixture()

    private func server(pid: pid_t = 4242, start: UInt64 = 99) -> RunningItem {
        RunningItem(id: "srv", kind: .server, name: "Metro · node", detail: "", pid: pid, startTime: start, ports: [8081], memory: 0, folder: nil)
    }

    @Test func stopsAServerWithAPoliteSignalAfterCheckingIdentity() async {
        let signals = SignalRecorder()
        let stopper = DevEnvironmentStopper(paths: fx.paths, mode: .live, runner: FakeRunner(),
                                            send: { signals.record($0, $1); return 0 }, startTime: { _ in 99 })
        let result = await stopper.stop(server())
        #expect(result.succeeded)
        #expect(signals.sent == [Sent(pid: 4242, signal: SIGTERM)])
    }

    @Test func neverSignalsAReusedPid() async {
        let signals = SignalRecorder()
        let stopper = DevEnvironmentStopper(paths: fx.paths, mode: .live, runner: FakeRunner(),
                                            send: { signals.record($0, $1); return 0 }, startTime: { _ in 12345 })
        let result = await stopper.stop(server())
        #expect(!result.succeeded)
        #expect(signals.sent.isEmpty)

        let gone = DevEnvironmentStopper(paths: fx.paths, mode: .live, runner: FakeRunner(),
                                         send: { signals.record($0, $1); return 0 }, startTime: { _ in nil })
        #expect(!(await gone.stop(server())).succeeded)
        #expect(signals.sent.isEmpty)
    }

    @Test func dryRunStopsNothing() async {
        let signals = SignalRecorder()
        let runner = FakeRunner()
        let stopper = DevEnvironmentStopper(paths: fx.paths, mode: .dryRun, runner: runner,
                                            send: { signals.record($0, $1); return 0 }, startTime: { _ in 99 })
        let serverResult = await stopper.stop(server())
        let simResult = await stopper.stop(RunningItem(id: "s", kind: .simulator(udid: "5C2C3A51-0000-4000-8000-000000000001"),
                                                       name: "iPhone 18 Pro", detail: "", pid: nil, startTime: nil, ports: [], memory: 0, folder: nil))
        #expect(serverResult.succeeded && simResult.succeeded)
        #expect(serverResult.message.contains("Dry run"))
        #expect(signals.sent.isEmpty)
        #expect(runner.calls.isEmpty)
    }

    @Test func shutsDownASimulatorWithSimctl() async {
        let runner = FakeRunner()
        let stopper = DevEnvironmentStopper(paths: fx.paths, mode: .live, runner: runner, send: { _, _ in 0 }, startTime: { _ in nil })
        let udid = "5C2C3A51-0000-4000-8000-000000000001"
        let result = await stopper.stop(RunningItem(id: "s", kind: .simulator(udid: udid), name: "iPhone 18 Pro", detail: "",
                                                    pid: nil, startTime: nil, ports: [], memory: 0, folder: nil))
        #expect(result.succeeded)
        #expect(runner.calls == [[ToolLocator.xcrun, "simctl", "shutdown", udid]])

        let bad = await stopper.stop(RunningItem(id: "x", kind: .simulator(udid: "all"), name: "x", detail: "",
                                                 pid: nil, startTime: nil, ports: [], memory: 0, folder: nil))
        #expect(!bad.succeeded)
        #expect(runner.calls.count == 1)
    }

    @Test func neverStopsAgentSessions() async {
        let signals = SignalRecorder()
        let runner = FakeRunner()
        let stopper = DevEnvironmentStopper(paths: fx.paths, mode: .live, runner: runner,
                                            send: { signals.record($0, $1); return 0 }, startTime: { _ in 1 })
        let agent = RunningItem(id: "a", kind: .agent, name: "Claude Code agent", detail: "", pid: 77, startTime: 1, ports: [], memory: 0, folder: nil)
        let result = await stopper.stop(agent)
        #expect(!result.succeeded)
        #expect(signals.sent.isEmpty && runner.calls.isEmpty)
    }

    @Test func emulatorWithoutAdbGetsAPoliteSignal() async {
        let signals = SignalRecorder()
        let stopper = DevEnvironmentStopper(paths: fx.paths, mode: .live, runner: FakeRunner(),
                                            send: { signals.record($0, $1); return 0 }, startTime: { _ in 5 })
        let emulator = RunningItem(id: "e", kind: .emulator(consolePort: 5554), name: "Android emulator", detail: "",
                                   pid: 900, startTime: 5, ports: [5554], memory: 0, folder: nil)
        let result = await stopper.stop(emulator)
        #expect(result.succeeded)
        #expect(signals.sent == [Sent(pid: 900, signal: SIGTERM)])
    }
}

struct Sent: Equatable { let pid: pid_t; let signal: Int32 }

final class SignalRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var sent: [Sent] = []
    func record(_ pid: pid_t, _ signal: Int32) { lock.withLock { sent.append(Sent(pid: pid, signal: signal)) } }
}

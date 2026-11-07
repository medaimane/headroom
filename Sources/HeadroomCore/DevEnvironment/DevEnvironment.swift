import Darwin
import Foundation

// MARK: - Listening ports

/// TCP ports a process is listening on, read from its open sockets with libproc.
/// Works for your own processes without admin rights; reads no traffic.
public enum ListeningPorts {
    public static func tcp(pid: pid_t) -> [UInt16] {
        let bufferSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bufferSize > 0 else { return [] }
        let count = Int(bufferSize) / MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: count)
        let filled = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, bufferSize) }
        guard filled > 0 else { return [] }

        var ports = Set<UInt16>()
        for fd in fds.prefix(Int(filled) / MemoryLayout<proc_fdinfo>.stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
                  info.psi.soi_kind == SOCKINFO_TCP,
                  info.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            let port = UInt16(bigEndian: UInt16(truncatingIfNeeded: info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport))
            if port > 0 { ports.insert(port) }
        }
        return ports.sorted()
    }

    /// What a well-known development port usually is.
    public static func label(for port: UInt16) -> String? {
        switch port {
        case 8081: "Metro"
        case 3000, 3001, 3002: "web dev server"
        case 4200: "Angular / Nx"
        case 5173: "Vite"
        case 6006: "Storybook"
        case 8080: "HTTP"
        case 9229: "Node inspector"
        case 5432: "PostgreSQL"
        case 3306: "MySQL"
        case 6379: "Redis"
        case 27017: "MongoDB"
        case 5554...5585: "emulator console"
        default: nil
        }
    }
}

// MARK: - What's running

/// One thing on the Dev environment page.
public struct RunningItem: Sendable, Identifiable, Hashable {
    public enum Kind: Sendable, Hashable {
        case simulator(udid: String)
        case emulator(consolePort: UInt16?)
        case server
        case agent
    }

    public var id: String
    public var kind: Kind
    public var name: String
    public var detail: String
    /// The process to stop (servers and emulators), with its start time to confirm identity.
    public var pid: pid_t?
    public var startTime: UInt64?
    public var ports: [UInt16]
    public var memory: UInt64
    public var folder: String?

    /// Why Headroom won't stop this, or nil if it can after confirmation.
    public var stopBlockedReason: String? {
        if case .agent = kind {
            return "Agent sessions are shown but not stopped from Headroom, so no work is lost. Stop one from its own terminal."
        }
        return nil
    }

    public var stopVerb: String {
        switch kind {
        case .simulator: "Shut down"
        case .emulator, .server, .agent: "Stop"
        }
    }

    /// How to start it again, shown before stopping and kept in History.
    public var restartHint: String {
        switch kind {
        case .simulator(let udid): return "Open it again from Xcode or the Simulator app, or run `xcrun simctl boot \(udid)`."
        case .emulator: return "Start it again from Android Studio's Device Manager, or with `emulator -avd <name>`."
        case .server:
            if ports.contains(8081) { return "Start Metro again the way you started it, for example `yarn start` or `npx react-native start`." }
            return "Start it again the way you started it, for example `npm run dev` in its project folder."
        case .agent: return "Not stopped by Headroom."
        }
    }
}

public struct DevEnvironmentSnapshot: Sendable {
    public var simulators: [RunningItem]
    public var emulators: [RunningItem]
    public var servers: [RunningItem]
    public var agents: [RunningItem]
    /// Memory of all iOS Simulator processes together (they can't be split per device).
    public var simulatorMemory: UInt64

    public static let empty = DevEnvironmentSnapshot(simulators: [], emulators: [], servers: [], agents: [], simulatorMemory: 0)
}

/// Builds the Dev environment page from a process sample and the booted simulators.
public enum DevEnvironment {
    /// Categories whose listening processes count as dev servers.
    static let serverCategories: Set<ProcessCategory> = [.metro, .nextjs, .nodeOther, .buildsAndTests, .watchman, .gradle, .containers, .other]

    public static func snapshot(records: [ProcessRecord], bootedSimulators: [(udid: String, name: String, runtime: String)],
                                ports: (pid_t) -> [UInt16] = ListeningPorts.tcp(pid:),
                                folder: (pid_t) -> String? = ProcessSampler.workingDirectory) -> DevEnvironmentSnapshot {
        let simulators = bootedSimulators.map { device in
            RunningItem(id: "sim:\(device.udid)", kind: .simulator(udid: device.udid), name: device.name, detail: device.runtime,
                        pid: nil, startTime: nil, ports: [], memory: 0, folder: nil)
        }
        let simulatorMemory = records.filter { $0.category == .iosSimulator }.reduce(UInt64(0)) { $0 + $1.memory }

        let emulators = records
            .filter { $0.category == .androidEmulator && $0.name.hasPrefix("qemu-system") }
            .map { record -> RunningItem in
                let listening = ports(record.pid)
                let console = listening.first { (5554...5585).contains($0) && $0 % 2 == 0 }
                return RunningItem(id: "emu:\(record.pid):\(record.startTime)", kind: .emulator(consolePort: console),
                                   name: "Android emulator", detail: console.map { "emulator-\($0)" } ?? "running",
                                   pid: record.pid, startTime: record.startTime, ports: listening, memory: record.memory, folder: nil)
            }

        let servers = records
            .filter { serverCategories.contains($0.category) && $0.pid != getpid() }
            .compactMap { record -> RunningItem? in
                let listening = ports(record.pid)
                guard !listening.isEmpty else { return nil }
                let where_ = record.workingDirectory ?? folder(record.pid)
                let title = record.category == .other ? record.name : "\(record.category.title) · \(record.name)"
                return RunningItem(id: "srv:\(record.pid):\(record.startTime)", kind: .server, name: title,
                                   detail: where_.map(ProcessGroup.shortFolder) ?? "",
                                   pid: record.pid, startTime: record.startTime, ports: listening, memory: record.memory, folder: where_)
            }
            .sorted { ($0.ports.first ?? 0) < ($1.ports.first ?? 0) }

        let agentRecords = records.filter { $0.category == .claudeAgent }
        let agents = Dictionary(grouping: agentRecords) { $0.workingDirectory ?? "" }
            .map { folder, items in
                RunningItem(id: "agent:\(folder)", kind: .agent, name: "Claude Code agent",
                            detail: folder.isEmpty ? "No project folder" : ProcessGroup.shortFolder(folder),
                            pid: nil, startTime: nil, ports: [], memory: items.reduce(0) { $0 + $1.memory },
                            folder: folder.isEmpty ? nil : folder)
            }
            .sorted { $0.detail < $1.detail }

        return DevEnvironmentSnapshot(simulators: simulators, emulators: emulators, servers: servers, agents: agents, simulatorMemory: simulatorMemory)
    }

    /// Booted simulators from `xcrun simctl list devices booted -j`.
    public static func bootedSimulators(from json: String) throws -> [(udid: String, name: String, runtime: String)] {
        let decoded = try JSONDecoder().decode(SimctlParser.DeviceListJSON.self, from: Data(json.utf8))
        return decoded.devices.flatMap { runtimeKey, devices in
            devices.filter { $0.state == "Booted" }.map { ($0.udid, $0.name, SimctlParser.runtimeLabel(runtimeKey)) }
        }
        .sorted { $0.name < $1.name }
    }
}

// MARK: - Stopping, after confirmation

/// Stops one simulator, emulator or dev server the user confirmed. Never force-kills, never stops
/// agent sessions, and checks right before stopping that the process is still the same one.
public struct DevEnvironmentStopper: Sendable {
    public struct Result: Sendable {
        public var item: RunningItem
        public var mode: ExecutionMode
        public var command: String
        public var error: String?
        public var succeeded: Bool { error == nil }
        public var message: String {
            if let error { return "Not stopped: \(error)" }
            return mode == .dryRun ? "Dry run: \(item.name) would be stopped (\(command)). Nothing was stopped." : "\(item.name) was asked to stop (\(command))."
        }
    }

    public var paths: HostPaths
    public var mode: ExecutionMode
    public var runner: CommandRunning
    /// Sends a signal; `Darwin.kill` in the app, a recorder in tests.
    public var send: @Sendable (pid_t, Int32) -> Int32
    /// The process's current start time, or nil if it's gone.
    public var startTime: @Sendable (pid_t) -> UInt64?

    public init(paths: HostPaths, mode: ExecutionMode, runner: CommandRunning = ProcessCommandRunner(),
                send: @escaping @Sendable (pid_t, Int32) -> Int32 = { Darwin.kill($0, $1) },
                startTime: @escaping @Sendable (pid_t) -> UInt64? = { ProcessSampler.startTime(of: $0) }) {
        self.paths = paths
        self.mode = mode
        self.runner = runner
        self.send = send
        self.startTime = startTime
    }

    public func stop(_ item: RunningItem) async -> Result {
        var result = Result(item: item, mode: mode, command: "")
        if let reason = item.stopBlockedReason {
            result.error = reason
            return result
        }
        switch item.kind {
        case .agent:
            result.error = item.stopBlockedReason
        case .simulator(let udid):
            guard udid.range(of: "^[0-9A-Fa-f-]{36}$", options: .regularExpression) != nil else {
                result.error = "That doesn't look like a simulator ID."
                return result
            }
            result.command = "xcrun simctl shutdown \(udid)"
            guard mode == .live else { return result }
            do {
                let output = try await runner.run(ToolLocator.xcrun, ["simctl", "shutdown", udid], timeout: 60)
                if !output.succeeded { result.error = output.stderr.isEmpty ? "simctl shutdown failed" : output.stderr.trimmingCharacters(in: .whitespacesAndNewlines) }
            } catch {
                result.error = String(describing: error)
            }
        case .emulator(let consolePort):
            let adb = paths.androidSDK.appending(path: "platform-tools/adb").path
            if let consolePort, FileManager.default.isExecutableFile(atPath: adb) {
                result.command = "adb -s emulator-\(consolePort) emu kill"
                guard checkIdentity(item, into: &result) else { return result }
                guard mode == .live else { return result }
                do {
                    let output = try await runner.run(adb, ["-s", "emulator-\(consolePort)", "emu", "kill"], timeout: 30)
                    if !output.succeeded { result.error = "adb couldn't stop the emulator" }
                } catch {
                    result.error = String(describing: error)
                }
            } else {
                terminate(item, into: &result)
            }
        case .server:
            terminate(item, into: &result)
        }
        return result
    }

    /// The process must still be running with the same start time, so a reused pid is never hit.
    private func checkIdentity(_ item: RunningItem, into result: inout Result) -> Bool {
        guard let pid = item.pid, pid > 1, pid != getpid(), let expected = item.startTime else {
            result.error = "Headroom can't identify that process."
            return false
        }
        guard let current = startTime(pid), current == expected else {
            result.error = "It already stopped, or a different process now has its ID."
            return false
        }
        return true
    }

    /// A polite SIGTERM, which lets the process clean up. Never SIGKILL.
    private func terminate(_ item: RunningItem, into result: inout Result) {
        result.command = "SIGTERM to process \(item.pid.map(String.init) ?? "?")"
        guard checkIdentity(item, into: &result), let pid = item.pid else { return }
        guard mode == .live else { return }
        if send(pid, SIGTERM) != 0 {
            result.error = errno == EPERM ? "That process belongs to another user or to macOS." : String(cString: strerror(errno))
        }
    }
}

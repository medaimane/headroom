import Darwin
import Foundation

/// One process as Headroom shows it. Command-line arguments are deliberately not kept.
public struct ProcessRecord: Sendable, Identifiable, Hashable {
    public var id: pid_t { pid }
    public var pid: pid_t
    public var name: String
    public var category: ProcessCategory
    /// Physical footprint ("Memory" in Activity Monitor), in bytes.
    public var memory: UInt64
    /// CPU usage since the previous sample, where 1.0 is one full core.
    public var cpu: Double
    /// Working folder, captured only for agents and dev servers to group them by worktree.
    public var workingDirectory: String?
    /// When the process started (mach absolute time). With the pid, it identifies this exact process,
    /// so a stop request can't hit a different process that later reuses the pid.
    public var startTime: UInt64

    public init(pid: pid_t, name: String, category: ProcessCategory, memory: UInt64, cpu: Double, workingDirectory: String? = nil, startTime: UInt64 = 0) {
        self.pid = pid
        self.startTime = startTime
        self.name = name
        self.category = category
        self.memory = memory
        self.cpu = cpu
        self.workingDirectory = workingDirectory
    }
}

/// Processes of one category, with sub-groups (for example one per worktree for agents).
public struct ProcessGroup: Sendable, Identifiable, Hashable {
    public var id: ProcessCategory { category }
    public var category: ProcessCategory
    public var memory: UInt64
    public var cpu: Double
    public var processes: [ProcessRecord]
    public var subgroups: [Subgroup]

    public struct Subgroup: Sendable, Identifiable, Hashable {
        public var id: String { title }
        public var title: String
        public var memory: UInt64
        public var cpu: Double
        public var count: Int
    }

    public static func group(_ records: [ProcessRecord]) -> [ProcessGroup] {
        Dictionary(grouping: records, by: \.category).map { category, items in
            let subgroups: [Subgroup]
            if category == .claudeAgent || category == .metro || category == .nextjs {
                subgroups = Dictionary(grouping: items) { $0.workingDirectory.map(Self.shortFolder) ?? "Unknown folder" }
                    .map { Subgroup(title: $0.key, memory: $0.value.reduce(0) { $0 + $1.memory }, cpu: $0.value.reduce(0) { $0 + $1.cpu }, count: $0.value.count) }
                    .sorted { $0.memory > $1.memory }
            } else {
                subgroups = Dictionary(grouping: items, by: \.name)
                    .map { Subgroup(title: $0.key, memory: $0.value.reduce(0) { $0 + $1.memory }, cpu: $0.value.reduce(0) { $0 + $1.cpu }, count: $0.value.count) }
                    .sorted { $0.memory > $1.memory }
            }
            return ProcessGroup(
                category: category,
                memory: items.reduce(0) { $0 + $1.memory },
                cpu: items.reduce(0) { $0 + $1.cpu },
                processes: items.sorted { $0.memory > $1.memory },
                subgroups: subgroups
            )
        }
        .sorted { $0.memory > $1.memory }
    }

    /// The last two path components, enough to tell worktrees apart without showing the whole path.
    static func shortFolder(_ path: String) -> String {
        let parts = path.split(separator: "/")
        return parts.isEmpty ? "No project folder" : parts.suffix(2).joined(separator: "/")
    }
}

public struct ProcessSnapshot: Sendable {
    public var records: [ProcessRecord]
    public var groups: [ProcessGroup]
    /// Processes owned by other users (root, system services) whose usage macOS doesn't share without admin rights.
    public var unreadableCount: Int
}

/// Samples all processes with libproc. Keeps a small cache so arguments are read only once per process.
public final class ProcessSampler: @unchecked Sendable {
    private struct CacheKey: Hashable { let pid: pid_t; let start: UInt64 }
    private struct CacheValue { let name: String; let category: ProcessCategory; let workingDirectory: String? }

    private var cache: [CacheKey: CacheValue] = [:]
    private var previousCPU: [pid_t: (time: UInt64, at: UInt64)] = [:]
    private let timebase: (numer: UInt64, denom: UInt64)
    private let lock = NSLock()

    public init() {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        timebase = (UInt64(info.numer), UInt64(max(info.denom, 1)))
    }

    public func sample() -> ProcessSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let now = mach_absolute_time()
        var records: [ProcessRecord] = []
        var unreadable = 0
        var seenKeys = Set<CacheKey>()
        var nextCPU: [pid_t: (time: UInt64, at: UInt64)] = [:]

        for pid in Self.allPIDs() {
            guard let usage = Self.rusage(pid) else {
                unreadable += 1
                continue
            }
            let key = CacheKey(pid: pid, start: usage.ri_proc_start_abstime)
            seenKeys.insert(key)
            let identity: CacheValue
            if let cached = cache[key] {
                identity = cached
            } else {
                let path = Self.path(pid) ?? ""
                let name = Self.name(pid) ?? (path as NSString).lastPathComponent
                let args = Self.arguments(pid)
                let category = ProcessCategorizer.categorize(ProcessIdentity(name: name, path: path, arguments: args))
                let wantsFolder = category == .claudeAgent || category == .metro || category == .nextjs
                identity = CacheValue(name: Self.displayName(name: name, path: path), category: category, workingDirectory: wantsFolder ? Self.workingDirectory(pid) : nil)
                cache[key] = identity
            }

            let cpuTime = usage.ri_user_time + usage.ri_system_time
            var cpu = 0.0
            if let previous = previousCPU[pid], cpuTime >= previous.time, now > previous.at {
                let cpuNanos = Double(cpuTime - previous.time) * Double(timebase.numer) / Double(timebase.denom)
                let wallNanos = Double(now - previous.at) * Double(timebase.numer) / Double(timebase.denom)
                cpu = wallNanos > 0 ? cpuNanos / wallNanos : 0
            }
            nextCPU[pid] = (cpuTime, now)

            records.append(ProcessRecord(pid: pid, name: identity.name, category: identity.category, memory: usage.ri_phys_footprint, cpu: cpu,
                                         workingDirectory: identity.workingDirectory, startTime: usage.ri_proc_start_abstime))
        }

        cache = cache.filter { seenKeys.contains($0.key) }
        previousCPU = nextCPU
        return ProcessSnapshot(records: records, groups: ProcessGroup.group(records), unreadableCount: unreadable)
    }

    /// Display name: the app bundle name for helpers inside an app, otherwise the executable name.
    static func displayName(name: String, path: String) -> String {
        if let range = path.range(of: ".app/") {
            let bundle = (String(path[..<range.lowerBound]) as NSString).lastPathComponent
            if !bundle.isEmpty, bundle != name { return name.hasPrefix(bundle) ? name : "\(bundle) (\(name))" }
        }
        return name
    }

    static func allPIDs() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 128)
        let count = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count * MemoryLayout<pid_t>.size))
        }
        guard count > 0 else { return [] }
        return pids.prefix(Int(count)).filter { $0 > 0 }
    }

    public static func startTime(of pid: pid_t) -> UInt64? { rusage(pid)?.ri_proc_start_abstime }

    static func rusage(_ pid: pid_t) -> rusage_info_v4? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? info : nil
    }

    static func path(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cBuffer: buffer)
    }

    static func name(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cBuffer: buffer)
    }

    /// argv via KERN_PROCARGS2. Used only to categorize; never stored.
    static func arguments(_ pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        // Skip the executable path and the NUL padding after it.
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var args: [String] = []
        var start = index
        while index < size, args.count < Int(argc) {
            if buffer[index] == 0 {
                args.append(String(decoding: buffer[start..<index], as: UTF8.self))
                start = index + 1
            }
            index += 1
        }
        return args
    }

    public static func workingDirectory(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return path.isEmpty ? nil : path
    }
}

extension ProcessSnapshot {
    /// Booted iOS simulators (one launchd_sim each) plus running Android emulators (one qemu each).
    public var testDeviceCount: Int {
        records.filter { record in
            (record.category == .iosSimulator && record.name == "launchd_sim")
                || (record.category == .androidEmulator && record.name.hasPrefix("qemu-system"))
        }.count
    }

    public var agentSessionCount: Int {
        Set(records.filter { $0.category == .claudeAgent }.compactMap(\.workingDirectory)).count
    }
}

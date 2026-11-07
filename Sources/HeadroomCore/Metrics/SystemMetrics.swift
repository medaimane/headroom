import Darwin
import Foundation

public enum PressureLevel: Int, Codable, Sendable, Comparable, CaseIterable {
    case normal = 1
    case warning = 2
    case critical = 4

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public var label: String {
        switch self {
        case .normal: "Normal"
        case .warning: "Warning"
        case .critical: "Critical"
        }
    }
}

public enum ThermalLevel: Int, Codable, Sendable, Comparable, CaseIterable {
    case nominal, fair, serious, critical

    public init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .serious
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public var label: String {
        switch self {
        case .nominal: "Nominal"
        case .fair: "Fair"
        case .serious: "Serious (throttling)"
        case .critical: "Critical (throttling)"
        }
    }
}

/// One reading of the machine's overall health.
public struct MetricsSample: Codable, Sendable, Equatable {
    public var date: Date
    public var memoryTotal: UInt64
    /// App memory + wired + compressed, like Activity Monitor's "Memory Used".
    public var memoryUsed: UInt64
    public var memoryCompressed: UInt64
    public var memoryWired: UInt64
    public var pressure: PressureLevel
    public var swapUsed: UInt64
    public var swapTotal: UInt64
    /// 0...1 across all cores.
    public var cpuUsage: Double
    public var thermal: ThermalLevel
    public var diskTotal: Int64
    /// Free space right now.
    public var diskFree: Int64
    /// Free space including what macOS can purge on demand.
    public var diskFreeIncludingPurgeable: Int64

    public init(date: Date, memoryTotal: UInt64, memoryUsed: UInt64, memoryCompressed: UInt64, memoryWired: UInt64, pressure: PressureLevel, swapUsed: UInt64, swapTotal: UInt64, cpuUsage: Double, thermal: ThermalLevel, diskTotal: Int64, diskFree: Int64, diskFreeIncludingPurgeable: Int64) {
        self.date = date
        self.memoryTotal = memoryTotal
        self.memoryUsed = memoryUsed
        self.memoryCompressed = memoryCompressed
        self.memoryWired = memoryWired
        self.pressure = pressure
        self.swapUsed = swapUsed
        self.swapTotal = swapTotal
        self.cpuUsage = cpuUsage
        self.thermal = thermal
        self.diskTotal = diskTotal
        self.diskFree = diskFree
        self.diskFreeIncludingPurgeable = diskFreeIncludingPurgeable
    }

    public var memoryUsedFraction: Double {
        memoryTotal == 0 ? 0 : Double(memoryUsed) / Double(memoryTotal)
    }
}

public struct HardwareInfo: Sendable, Codable {
    public var chip: String
    public var memory: UInt64
    public var performanceCores: Int
    public var efficiencyCores: Int
    public var osVersion: String

    public static func current() -> HardwareInfo {
        HardwareInfo(
            chip: SysctlReader.string("machdep.cpu.brand_string") ?? "Unknown chip",
            memory: SysctlReader.uint64("hw.memsize") ?? 0,
            performanceCores: Int(SysctlReader.int32("hw.perflevel0.physicalcpu") ?? 0),
            efficiencyCores: Int(SysctlReader.int32("hw.perflevel1.physicalcpu") ?? 0),
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString
        )
    }
}

public enum SysctlReader {
    public static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cBuffer: buffer)
    }

    public static func uint64(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    public static func int32(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }
}

/// Reads system-wide metrics. Keeps the previous CPU ticks to compute usage between calls,
/// so use one instance per sampling loop.
public struct SystemMetricsReader: Sendable {
    private var previousTicks: (busy: UInt64, total: UInt64)?
    private let volume: URL

    public init(volume: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.volume = volume
    }

    public mutating func sample(now: Date = Date()) -> MetricsSample {
        let memory = Self.memory()
        let swap = Self.swap()
        let disk = Self.disk(volume)
        return MetricsSample(
            date: now,
            memoryTotal: SysctlReader.uint64("hw.memsize") ?? 0,
            memoryUsed: memory.used,
            memoryCompressed: memory.compressed,
            memoryWired: memory.wired,
            pressure: Self.pressure(),
            swapUsed: swap.used,
            swapTotal: swap.total,
            cpuUsage: cpu(),
            thermal: ThermalLevel(ProcessInfo.processInfo.thermalState),
            diskTotal: disk.total,
            diskFree: disk.free,
            diskFreeIncludingPurgeable: disk.important
        )
    }

    static func pressure() -> PressureLevel {
        let raw = SysctlReader.int32("kern.memorystatus_vm_pressure_level") ?? 1
        return PressureLevel(rawValue: Int(raw)) ?? (raw > 2 ? .critical : .normal)
    }

    static func memory() -> (used: UInt64, compressed: UInt64, wired: UInt64) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0, 0) }
        let page = UInt64(SysctlReader.int32("hw.pagesize") ?? 16384)
        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        let wired = UInt64(stats.wire_count) * page
        let compressed = UInt64(stats.compressor_page_count) * page
        let app = (internalPages > purgeable ? internalPages - purgeable : 0) * page
        return (app + wired + compressed, compressed, wired)
    }

    static func swap() -> (used: UInt64, total: UInt64) {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return (0, 0) }
        return (usage.xsu_used, usage.xsu_total)
    }

    static func disk(_ url: URL) -> (total: Int64, free: Int64, important: Int64) {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return (0, 0, 0) }
        return (
            Int64(values.volumeTotalCapacity ?? 0),
            Int64(values.volumeAvailableCapacity ?? 0),
            values.volumeAvailableCapacityForImportantUsage ?? Int64(values.volumeAvailableCapacity ?? 0)
        )
    }

    private mutating func cpu() -> Double {
        var load = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &load) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let user = UInt64(load.cpu_ticks.0)
        let system = UInt64(load.cpu_ticks.1)
        let idle = UInt64(load.cpu_ticks.2)
        let nice = UInt64(load.cpu_ticks.3)
        let busy = user + system + nice
        let total = busy + idle
        defer { previousTicks = (busy, total) }
        guard let previous = previousTicks, total > previous.total else { return 0 }
        return Double(busy - previous.busy) / Double(total - previous.total)
    }
}

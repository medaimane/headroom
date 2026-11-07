import Foundation

// MARK: - History

/// One action Headroom took (or simulated), with how to undo it.
public struct HistoryEntry: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var date: Date
    public var action: String
    public var detail: String
    public var bytes: Int64
    public var dryRun: Bool
    public var succeeded: Bool
    public var undo: String

    public init(id: UUID = UUID(), date: Date = Date(), action: String, detail: String, bytes: Int64, dryRun: Bool, succeeded: Bool, undo: String) {
        self.id = id
        self.date = date
        self.action = action
        self.detail = detail
        self.bytes = bytes
        self.dryRun = dryRun
        self.succeeded = succeeded
        self.undo = undo
    }
}

/// Appends history as JSON lines in Application Support. Local only.
public struct HistoryStore: Sendable {
    public var fileURL: URL

    public init(directory: URL) {
        fileURL = directory.appending(path: "history.jsonl")
    }

    public func append(_ entry: HistoryEntry) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = try JSONCoding.encoder.encode(entry)
        data.append(0x0A)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: fileURL, options: .atomic)
        }
    }

    public func load() -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return data.split(separator: 0x0A).compactMap { try? JSONCoding.decoder.decode(HistoryEntry.self, from: Data($0)) }
            .sorted { $0.date > $1.date }
    }

    public static func markdown(_ entries: [HistoryEntry]) -> String {
        var lines = ["# Headroom change log", "", "| When | Action | Detail | Size | Mode | Result | Undo |", "|---|---|---|---|---|---|---|"]
        let formatter = ISO8601DateFormatter()
        for entry in entries {
            let cells = [formatter.string(from: entry.date), entry.action, entry.detail, Format.bytes(entry.bytes),
                         entry.dryRun ? "dry run" : "live", entry.succeeded ? "ok" : "failed", entry.undo]
            lines.append("| " + cells.map { $0.replacingOccurrences(of: "|", with: "\\|") }.joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

public enum JSONCoding {
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

// MARK: - Workload snapshots

/// The measured result of running a tagged workload for a while.
public struct WorkloadSnapshot: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var label: String
    public var start: Date
    public var end: Date
    public var sampleCount: Int
    public var averageCPU: Double
    public var peakCPU: Double
    public var worstPressure: PressureLevel
    /// Seconds spent with memory pressure at warning or critical.
    public var secondsUnderPressure: TimeInterval
    public var averageMemoryUsed: UInt64
    public var peakMemoryUsed: UInt64
    public var startSwap: UInt64
    public var peakSwap: UInt64
    public var worstThermal: ThermalLevel
    /// Peak memory per category name.
    public var categoryPeaks: [String: UInt64]
    public var testDevices: Int

    public var duration: TimeInterval { end.timeIntervalSince(start) }
    public var swapGrowth: Int64 { Int64(peakSwap) - Int64(startSwap) }

    /// Green when pressure stayed normal, no meaningful swap growth and no throttling.
    public var verdict: Verdict {
        if worstPressure == .critical || worstThermal >= .serious || swapGrowth > 2 * Format.gigabyte { return .over }
        if worstPressure == .warning || swapGrowth > 512_000_000 { return .atLimit }
        return .comfortable
    }

    public enum Verdict: String, Codable, Sendable {
        case comfortable, atLimit, over
        public var label: String {
            switch self {
            case .comfortable: "Comfortable"
            case .atLimit: "At the limit"
            case .over: "Too much"
            }
        }
    }
}

/// Collects samples while a workload snapshot is recording.
public struct SnapshotAccumulator: Sendable {
    public var label: String
    public private(set) var start: Date
    private var samples: [MetricsSample] = []
    private var categoryPeaks: [String: UInt64] = [:]
    private var peakDevices = 0
    private var pressureSeconds: TimeInterval = 0

    public init(label: String, start: Date = Date()) {
        self.label = label
        self.start = start
    }

    public mutating func add(_ sample: MetricsSample, groups: [ProcessGroup] = [], deviceCount: Int? = nil) {
        if let last = samples.last, last.pressure >= .warning || sample.pressure >= .warning {
            pressureSeconds += max(0, sample.date.timeIntervalSince(last.date))
        }
        samples.append(sample)
        for group in groups {
            categoryPeaks[group.category.title] = max(categoryPeaks[group.category.title] ?? 0, group.memory)
        }
        if let deviceCount { peakDevices = max(peakDevices, deviceCount) }
    }

    public var sampleCount: Int { samples.count }

    public func finish(end: Date = Date()) -> WorkloadSnapshot? {
        guard let first = samples.first else { return nil }
        let count = Double(samples.count)
        return WorkloadSnapshot(
            id: UUID(), label: label, start: start, end: end, sampleCount: samples.count,
            averageCPU: samples.reduce(0) { $0 + $1.cpuUsage } / count,
            peakCPU: samples.map(\.cpuUsage).max() ?? 0,
            worstPressure: samples.map(\.pressure).max() ?? .normal,
            secondsUnderPressure: pressureSeconds,
            averageMemoryUsed: UInt64(samples.reduce(0.0) { $0 + Double($1.memoryUsed) } / count),
            peakMemoryUsed: samples.map(\.memoryUsed).max() ?? 0,
            startSwap: first.swapUsed,
            peakSwap: samples.map(\.swapUsed).max() ?? 0,
            worstThermal: samples.map(\.thermal).max() ?? .nominal,
            categoryPeaks: categoryPeaks,
            testDevices: peakDevices
        )
    }
}

/// Saves snapshots as one JSON file.
public struct SnapshotStore: Sendable {
    public var fileURL: URL

    public init(directory: URL) {
        fileURL = directory.appending(path: "snapshots.json")
    }

    public func load() -> [WorkloadSnapshot] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONCoding.decoder.decode([WorkloadSnapshot].self, from: data)) ?? []
    }

    public func save(_ snapshots: [WorkloadSnapshot]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONCoding.encoder.encode(snapshots).write(to: fileURL, options: .atomic)
    }
}

// MARK: - Settings

public struct HeadroomSettings: Codable, Sendable, Equatable {
    /// Warn when free disk space drops below this.
    public var diskWarningBytes: Int64 = 60 * Format.gigabyte
    /// Critical below this.
    public var diskCriticalBytes: Int64 = 25 * Format.gigabyte
    /// The free-space goal shown on the storage bar.
    public var diskTargetBytes: Int64 = 100 * Format.gigabyte
    public var swapWarningBytes: Int64 = 4 * Format.gigabyte
    public var swapCriticalBytes: Int64 = 8 * Format.gigabyte
    /// Memory pressure must stay at warning or worse this long before a notification.
    public var pressureSustainSeconds: TimeInterval = 120
    public var sampleIntervalSeconds: Double = 5
    public var notificationsEnabled = true
    /// Clean-ups only simulate until this is turned off.
    public var dryRun = true
    /// Folders scanned for git repositories, relative to home unless absolute.
    public var worktreeRoots: [String] = ["Developer"]

    public init() {}

    /// Missing keys fall back to defaults, so settings files from older versions keep working.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = HeadroomSettings()
        diskWarningBytes = try c.decodeIfPresent(Int64.self, forKey: .diskWarningBytes) ?? d.diskWarningBytes
        diskCriticalBytes = try c.decodeIfPresent(Int64.self, forKey: .diskCriticalBytes) ?? d.diskCriticalBytes
        diskTargetBytes = try c.decodeIfPresent(Int64.self, forKey: .diskTargetBytes) ?? d.diskTargetBytes
        swapWarningBytes = try c.decodeIfPresent(Int64.self, forKey: .swapWarningBytes) ?? d.swapWarningBytes
        swapCriticalBytes = try c.decodeIfPresent(Int64.self, forKey: .swapCriticalBytes) ?? d.swapCriticalBytes
        pressureSustainSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .pressureSustainSeconds) ?? d.pressureSustainSeconds
        sampleIntervalSeconds = try c.decodeIfPresent(Double.self, forKey: .sampleIntervalSeconds) ?? d.sampleIntervalSeconds
        notificationsEnabled = try c.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? d.notificationsEnabled
        dryRun = try c.decodeIfPresent(Bool.self, forKey: .dryRun) ?? d.dryRun
        worktreeRoots = try c.decodeIfPresent([String].self, forKey: .worktreeRoots) ?? d.worktreeRoots
    }

    public func worktreeRootURLs(home: URL) -> [URL] {
        worktreeRoots.map { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : home.appending(path: $0, directoryHint: .isDirectory) }
    }
}

public struct SettingsStore: Sendable {
    public var fileURL: URL

    public init(directory: URL) {
        fileURL = directory.appending(path: "settings.json")
    }

    public func load() -> HeadroomSettings {
        guard let data = try? Data(contentsOf: fileURL) else { return HeadroomSettings() }
        return (try? JSONCoding.decoder.decode(HeadroomSettings.self, from: data)) ?? HeadroomSettings()
    }

    public func save(_ settings: HeadroomSettings) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONCoding.encoder
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(settings).write(to: fileURL, options: .atomic)
    }
}

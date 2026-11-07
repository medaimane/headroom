import Foundation

public enum HealthLevel: Int, Comparable, Sendable, Codable {
    case good, warning, critical

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Green, yellow or red for each part of a sample.
public struct HealthAssessment: Sendable, Equatable {
    public var disk: HealthLevel
    public var memory: HealthLevel
    public var swap: HealthLevel
    public var thermal: HealthLevel
    public var cpu: HealthLevel

    public var overall: HealthLevel { [disk, memory, swap, thermal].max() ?? .good }

    public init(sample: MetricsSample, settings: HeadroomSettings) {
        disk = sample.diskFree < settings.diskCriticalBytes ? .critical : sample.diskFree < settings.diskWarningBytes ? .warning : .good
        memory = switch sample.pressure {
        case .normal: .good
        case .warning: .warning
        case .critical: .critical
        }
        let swapUsed = Int64(sample.swapUsed)
        swap = swapUsed >= settings.swapCriticalBytes ? .critical : swapUsed >= settings.swapWarningBytes ? .warning : .good
        thermal = switch sample.thermal {
        case .nominal, .fair: .good
        case .serious: .warning
        case .critical: .critical
        }
        // CPU alone isn't a problem (builds should use it); it's shown but doesn't drive the overall status.
        cpu = sample.cpuUsage > 0.9 ? .warning : .good
    }
}

public struct HealthAlert: Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable {
        case lowDisk, memoryPressure, highSwap, thermal
    }

    public var kind: Kind
    public var level: HealthLevel
    public var title: String
    public var body: String
}

/// Decides when to notify. Debounced: one notification per kind per cooldown, and memory
/// pressure only after it has lasted a while.
public struct AlertEvaluator: Sendable {
    public var cooldown: TimeInterval
    private var lastSent: [HealthAlert.Kind: (date: Date, level: HealthLevel)] = [:]
    private var pressureSince: Date?

    public init(cooldown: TimeInterval = 30 * 60) {
        self.cooldown = cooldown
    }

    public mutating func evaluate(_ sample: MetricsSample, settings: HeadroomSettings) -> [HealthAlert] {
        let assessment = HealthAssessment(sample: sample, settings: settings)
        var candidates: [HealthAlert] = []

        if assessment.disk > .good {
            candidates.append(HealthAlert(kind: .lowDisk, level: assessment.disk, title: "Disk space is low",
                                          body: "\(Format.bytes(sample.diskFree)) free. Aim for \(Format.bytes(settings.diskTargetBytes)) or more to keep macOS fast."))
        }

        if sample.pressure >= .warning {
            pressureSince = pressureSince ?? sample.date
        } else {
            pressureSince = nil
        }
        if let since = pressureSince, sample.date.timeIntervalSince(since) >= settings.pressureSustainSeconds {
            candidates.append(HealthAlert(kind: .memoryPressure, level: assessment.memory, title: "Memory pressure is \(sample.pressure.label.lowercased())",
                                          body: "It has stayed high for \(Int(sample.date.timeIntervalSince(since) / 60)) min. Consider closing a simulator, an emulator or an agent session."))
        }

        if assessment.swap > .good {
            candidates.append(HealthAlert(kind: .highSwap, level: assessment.swap, title: "Heavy swapping",
                                          body: "\(Format.memory(sample.swapUsed)) of swap in use. The Mac is short of memory."))
        }

        if assessment.thermal > .good {
            candidates.append(HealthAlert(kind: .thermal, level: assessment.thermal, title: "The Mac is throttling",
                                          body: "Thermal state is \(sample.thermal.label.lowercased()). Builds and devices will run slower."))
        }

        return candidates.filter { alert in
            if let last = lastSent[alert.kind], sample.date.timeIntervalSince(last.date) < cooldown, alert.level <= last.level {
                return false
            }
            lastSent[alert.kind] = (sample.date, alert.level)
            return true
        }
    }
}

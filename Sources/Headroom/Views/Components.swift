import HeadroomCore
import SwiftUI

extension HealthLevel {
    var color: Color {
        switch self {
        case .good: .green
        case .warning: .yellow
        case .critical: .red
        }
    }

    var label: String {
        switch self {
        case .good: "All good"
        case .warning: "Needs attention"
        case .critical: "Critical"
        }
    }

    var menuSymbol: String {
        switch self {
        case .good: "gauge.with.dots.needle.33percent"
        case .warning: "exclamationmark.triangle"
        case .critical: "exclamationmark.octagon.fill"
        }
    }
}

struct StatusDot: View {
    let level: HealthLevel
    var body: some View {
        Circle().fill(level.color).frame(width: 9, height: 9)
            .accessibilityLabel(level.label)
    }
}

/// A compact metric: dot, title, value, caption.
struct MetricTile: View {
    let title: String
    let value: String
    var caption: String = ""
    var level: HealthLevel = .good

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                StatusDot(level: level)
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
            if !caption.isEmpty {
                Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Free space vs. the target, as a bar.
struct DiskBar: View {
    let sample: MetricsSample
    let settings: HeadroomSettings

    var body: some View {
        let total = max(Double(sample.diskTotal), 1)
        let used = Double(sample.diskTotal - sample.diskFree) / total
        let target = 1 - Double(settings.diskTargetBytes) / total
        let level = HealthAssessment(sample: sample, settings: settings).disk
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5).fill(.quaternary)
                    RoundedRectangle(cornerRadius: 5).fill(level.color.gradient)
                        .frame(width: proxy.size.width * used)
                    Rectangle().fill(.primary).frame(width: 2)
                        .offset(x: proxy.size.width * target)
                        .help("Target: keep \(Format.bytes(settings.diskTargetBytes)) free")
                }
            }
            .frame(height: 14)
            HStack {
                Text("\(Format.bytes(sample.diskFree)) free of \(Format.bytes(sample.diskTotal))")
                Spacer()
                let missing = settings.diskTargetBytes - sample.diskFree
                if missing > 0 {
                    Text("Free \(Format.bytes(missing)) more to reach the \(Format.bytes(settings.diskTargetBytes)) target")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Above the \(Format.bytes(settings.diskTargetBytes)) target").foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            if sample.diskFreeIncludingPurgeable > sample.diskFree + Format.gigabyte {
                Text("macOS can also reclaim about \(Format.bytes(sample.diskFreeIncludingPurgeable - sample.diskFree)) of purgeable space on its own when needed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct ModeBanner: View {
    let mode: ExecutionMode

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: mode == .dryRun ? "testtube.2" : "exclamationmark.triangle.fill")
            if mode == .dryRun {
                Text(ExecutionPolicy.isDebugBuild
                     ? "Dry run: this is a debug build, so nothing on this Mac is ever deleted."
                     : "Dry run: nothing will be deleted. Turn off dry run in Settings to clean for real.")
            } else {
                Text("Live: confirmed items will be deleted.")
            }
        }
        .font(.callout)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((mode == .dryRun ? Color.blue : Color.orange).opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

extension String {
    /// Replaces the home folder prefix with ~.
    func abbreviatingHome(_ home: URL) -> String {
        let homePath = home.path
        return hasPrefix(homePath) ? "~" + dropFirst(homePath.count) : self
    }
}

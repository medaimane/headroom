import Charts
import HeadroomCore
import SwiftUI

struct HealthView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let sample = model.latest, let assessment = model.assessment {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 5), spacing: 12) {
                        MetricTile(title: "Disk free", value: Format.bytes(sample.diskFree), caption: "Target \(Format.bytes(model.settings.diskTargetBytes))", level: assessment.disk)
                        MetricTile(title: "Memory pressure", value: sample.pressure.label,
                                   caption: "\(Format.memory(sample.memoryUsed)) used · \(Format.memory(sample.memoryCompressed)) compressed", level: assessment.memory)
                        MetricTile(title: "Swap", value: Format.memory(sample.swapUsed), caption: "Warn at \(Format.memory(model.settings.swapWarningBytes))", level: assessment.swap)
                        MetricTile(title: "CPU", value: Format.percent(sample.cpuUsage), caption: "All \(model.hardware.performanceCores + model.hardware.efficiencyCores) cores", level: assessment.cpu)
                        MetricTile(title: "Thermal", value: sample.thermal.label, caption: sample.thermal >= .serious ? "macOS is slowing the CPU" : "No throttling", level: assessment.thermal)
                    }
                    charts
                } else {
                    ProgressView("Reading the first sample…")
                }
                processes
            }
            .padding(20)
        }
        .navigationTitle("Health")
        .onAppear { model.detailViewers += 1 }
        .onDisappear { model.detailViewers -= 1 }
    }

    private var header: some View {
        let hw = model.hardware
        return Text("\(hw.chip) · \(Format.memory(hw.memory)) memory · \(hw.performanceCores) performance + \(hw.efficiencyCores) efficiency cores")
            .font(.callout).foregroundStyle(.secondary)
    }

    private var charts: some View {
        let samples = model.samples
        return Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                chartCard("Memory used", unit: "%") {
                    Chart(samples, id: \.date) { sample in
                        AreaMark(x: .value("Time", sample.date), y: .value("Used", sample.memoryUsedFraction * 100))
                            .foregroundStyle(pressureColor(sample.pressure).opacity(0.35))
                        LineMark(x: .value("Time", sample.date), y: .value("Used", sample.memoryUsedFraction * 100))
                            .foregroundStyle(pressureColor(sample.pressure))
                    }
                    .chartYScale(domain: 0...100)
                }
                chartCard("Swap used", unit: "GB") {
                    Chart(samples, id: \.date) { sample in
                        LineMark(x: .value("Time", sample.date), y: .value("Swap", Double(sample.swapUsed) / 1e9))
                    }
                }
                chartCard("CPU", unit: "%") {
                    Chart(samples, id: \.date) { sample in
                        LineMark(x: .value("Time", sample.date), y: .value("CPU", sample.cpuUsage * 100))
                    }
                    .chartYScale(domain: 0...100)
                }
            }
        }
    }

    private func pressureColor(_ level: PressureLevel) -> Color {
        switch level {
        case .normal: .green
        case .warning: .yellow
        case .critical: .red
        }
    }

    private func chartCard<C: View>(_ title: String, unit: String, @ViewBuilder chart: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(title) (\(unit)) · last hour").font(.caption).foregroundStyle(.secondary)
            chart().frame(height: 120)
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }

    private var processes: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("What's using memory and CPU").font(.headline)
                Spacer()
                if let snapshot = model.processes {
                    Text("\(snapshot.testDeviceCount) test devices · \(snapshot.agentSessionCount) agent sessions")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            if let snapshot = model.processes {
                VStack(spacing: 0) {
                    ForEach(snapshot.groups) { group in
                        ProcessGroupRow(group: group)
                        Divider()
                    }
                }
                .padding(.horizontal, 12)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
                if snapshot.unreadableCount > 0 {
                    Text("\(snapshot.unreadableCount) processes belong to macOS or other users. Their usage can't be read without admin rights, so they're not listed (they're still counted in the totals above).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct ProcessGroupRow: View {
    let group: ProcessGroup
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(spacing: 4) {
                ForEach(group.subgroups.prefix(25)) { sub in
                    HStack {
                        Text(sub.title).lineLimit(1).truncationMode(.middle)
                        if sub.count > 1 { Text("×\(sub.count)").foregroundStyle(.secondary) }
                        Spacer()
                        Text(Format.percent(sub.cpu)).frame(width: 60, alignment: .trailing).foregroundStyle(.secondary)
                        Text(Format.memory(sub.memory)).frame(width: 90, alignment: .trailing)
                    }
                    .font(.callout).monospacedDigit()
                }
            }
            .padding(.leading, 28)
            .padding(.bottom, 6)
        } label: {
            HStack {
                Image(systemName: group.category.symbol).frame(width: 20)
                Text(group.category.title)
                Text("\(group.processes.count)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(Format.percent(group.cpu)).frame(width: 60, alignment: .trailing).foregroundStyle(.secondary)
                Text(Format.memory(group.memory)).frame(width: 90, alignment: .trailing).fontWeight(.medium)
            }
            .monospacedDigit()
        }
        .padding(.vertical, 6)
    }
}

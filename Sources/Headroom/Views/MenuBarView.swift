import AppKit
import HeadroomCore
import SwiftUI

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Headroom").font(.headline)
                Spacer()
                if let level = model.assessment?.overall {
                    StatusDot(level: level)
                    Text(level.label).font(.caption).foregroundStyle(.secondary)
                }
            }

            if let sample = model.latest, let assessment = model.assessment {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                    row("Disk free", Format.bytes(sample.diskFree), assessment.disk)
                    row("Memory pressure", sample.pressure.label, assessment.memory)
                    row("Memory used", "\(Format.memory(sample.memoryUsed)) of \(Format.memory(sample.memoryTotal))", assessment.memory)
                    row("Swap", Format.memory(sample.swapUsed), assessment.swap)
                    row("CPU", Format.percent(sample.cpuUsage), assessment.cpu)
                    row("Thermal", sample.thermal.label, assessment.thermal)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }

            if let snapshot = model.processes {
                Divider()
                HStack {
                    Text("Top memory users").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(snapshot.testDeviceCount) devices · \(snapshot.agentSessionCount) agents").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(snapshot.groups.prefix(5)) { group in
                    HStack {
                        Image(systemName: group.category.symbol).frame(width: 18)
                        Text(group.category.title)
                        Spacer()
                        Text(Format.memory(group.memory)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }

            if let recording = model.recording {
                Divider()
                Label("Recording “\(recording.label)” · \(recording.sampleCount) samples", systemImage: "record.circle")
                    .foregroundStyle(.red).font(.callout)
            }

            Divider()
            HStack {
                Button("Open Headroom") {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                .keyboardShortcut("o")
                Spacer()
                Button { AppInfo.showAboutPanel() } label: { Image(systemName: "info.circle") }
                    .help("About Headroom")
                    .accessibilityLabel("About Headroom")
                Button {
                    openSettings()
                    NSApp.activate()
                } label: { Image(systemName: "gearshape") }
                .help("Settings")
                Button("Quit") {
                    model.flushSettingsHistory()
                    NSApp.terminate(nil)
                }
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    private func row(_ title: String, _ value: String, _ level: HealthLevel) -> some View {
        GridRow {
            StatusDot(level: level)
            Text(title).foregroundStyle(.secondary)
            Text(value).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.callout)
    }
}

import HeadroomCore
import ServiceManagement
import SwiftUI

struct SnapshotsView: View {
    @Environment(AppModel.self) private var model
    @State private var label = ""

    var body: some View {
        List {
            SwiftUI.Section {
                Text("Start your workload (for example 1 simulator, 1 emulator, Metro, Next.js, a browser and 2 agents), give it a name, and record for 10–15 minutes while you work normally. Headroom keeps the peaks so you can compare setups.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    if let recording = model.recording {
                        Image(systemName: "record.circle").foregroundStyle(.red)
                        Text("Recording “\(recording.label)” since \(recording.start.formatted(date: .omitted, time: .shortened)) · \(recording.sampleCount) samples")
                        Spacer()
                        Button("Stop and save") { model.stopRecording() }.buttonStyle(.borderedProminent)
                    } else {
                        TextField("Workload name, e.g. 1 sim + 1 emu + Metro + Next + 2 agents", text: $label)
                        Button("Start recording") { model.startRecording(label: label) }.buttonStyle(.borderedProminent)
                    }
                }
            }
            SwiftUI.Section("Saved") {
                if model.snapshots.isEmpty { Text("No snapshots yet").foregroundStyle(.secondary) }
                ForEach(model.snapshots) { snapshot in
                    SnapshotRow(snapshot: snapshot)
                        .contextMenu { Button("Delete snapshot", role: .destructive) { model.deleteSnapshot(snapshot) } }
                }
            }
        }
        .navigationTitle("Workload snapshots")
        .onAppear { model.detailViewers += 1 }
        .onDisappear { model.detailViewers -= 1 }
    }
}

struct SnapshotRow: View {
    let snapshot: WorkloadSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(snapshot.label).fontWeight(.medium)
                Text(verdictText).font(.caption).padding(.horizontal, 6).padding(.vertical, 2).background(verdictColor.opacity(0.2), in: Capsule())
                Spacer()
                Text("\(snapshot.start.formatted(date: .abbreviated, time: .shortened)) · \(Int(snapshot.duration / 60)) min").foregroundStyle(.secondary)
            }
            Text([
                "\(snapshot.testDevices) test devices",
                "memory peak \(Format.memory(snapshot.peakMemoryUsed))",
                "pressure worst \(snapshot.worstPressure.label.lowercased())" + (snapshot.secondsUnderPressure > 0 ? " for \(Int(snapshot.secondsUnderPressure / 60)) min" : ""),
                "swap +\(Format.memory(max(0, snapshot.swapGrowth)))",
                "CPU avg \(Format.percent(snapshot.averageCPU)), peak \(Format.percent(snapshot.peakCPU))",
                "thermal \(snapshot.worstThermal.label.lowercased())",
            ].joined(separator: " · "))
            .font(.callout).foregroundStyle(.secondary)
            let peaks = snapshot.categoryPeaks.sorted { $0.value > $1.value }.prefix(6)
            if !peaks.isEmpty {
                Text("Peaks: " + peaks.map { "\($0.key) \(Format.memory($0.value))" }.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var verdictText: String { snapshot.verdict.label }

    private var verdictColor: Color {
        switch snapshot.verdict {
        case .comfortable: .green
        case .atLimit: .yellow
        case .over: .red
        }
    }
}

struct HistoryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Table(model.history) {
            TableColumn("When") { entry in Text(entry.date.formatted(date: .abbreviated, time: .shortened)) }.width(140)
            TableColumn("Action") { entry in
                HStack(spacing: 4) {
                    Image(systemName: entry.succeeded ? "checkmark.circle" : "xmark.circle").foregroundStyle(entry.succeeded ? .green : .red)
                    Text(entry.action)
                }
            }
            TableColumn("Mode") { entry in Text(entry.dryRun ? "dry run" : "live").foregroundStyle(entry.dryRun ? .secondary : .primary) }.width(60)
            TableColumn("Size") { entry in Text(Format.bytes(entry.bytes)).monospacedDigit() }.width(80)
            TableColumn("Detail") { entry in Text(entry.detail).lineLimit(2).help(entry.detail) }
            TableColumn("How to undo") { entry in Text(entry.undo).lineLimit(2).help(entry.undo) }
        }
        .navigationTitle("History")
        .toolbar {
            ToolbarItem {
                Button { model.exportHistory() } label: { Label("Export as Markdown", systemImage: "square.and.arrow.up") }
                    .disabled(model.history.isEmpty)
            }
        }
        .overlay {
            if model.history.isEmpty {
                ContentUnavailableView("No actions yet", systemImage: "clock", description: Text("Every clean-up, removal and setting change is recorded here, with how to undo it."))
            }
        }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var rootsText = ""

    var body: some View {
        @Bindable var model = model
        Form {
            SwiftUI.Section("Disk") {
                gbStepper("Warn below", value: $model.settings.diskWarningBytes, range: 10...300)
                gbStepper("Critical below", value: $model.settings.diskCriticalBytes, range: 5...200)
                gbStepper("Free-space target", value: $model.settings.diskTargetBytes, range: 20...500)
            }
            SwiftUI.Section("Memory") {
                gbStepper("Swap warning at", value: $model.settings.swapWarningBytes, range: 1...32)
                gbStepper("Swap critical at", value: $model.settings.swapCriticalBytes, range: 2...64)
                Stepper("Notify after pressure lasts \(Int(model.settings.pressureSustainSeconds / 60)) min",
                        value: $model.settings.pressureSustainSeconds, in: 60...1800, step: 60)
                Stepper("Sample every \(Int(model.settings.sampleIntervalSeconds)) s", value: $model.settings.sampleIntervalSeconds, in: 2...60, step: 1)
                Toggle("Notifications", isOn: $model.settings.notificationsEnabled)
            }
            SwiftUI.Section("Clean-up") {
                Toggle("Dry run (simulate clean-ups, delete nothing)", isOn: $model.settings.dryRun)
                    .disabled(ExecutionPolicy.isDebugBuild)
                if ExecutionPolicy.isDebugBuild {
                    Text("This is a debug build: it is always a dry run on this Mac.").font(.caption).foregroundStyle(.secondary)
                }
            }
            SwiftUI.Section("Worktrees") {
                TextField("Folders to scan (comma-separated, relative to home)", text: $rootsText)
                    .onSubmit { saveRoots() }
                Text("Press Return to save. Default: Developer").font(.caption).foregroundStyle(.secondary)
            }
            SwiftUI.Section("System") {
                Toggle("Open Headroom at login", isOn: Binding(get: { model.launchesAtLogin }, set: { model.launchesAtLogin = $0 }))
                LabeledContent("Full Disk Access") {
                    Button("Open Privacy settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { NSWorkspace.shared.open(url) }
                    }
                }
                Text("Optional. Without it, a few protected folders show partial sizes (marked with a lock). Developer caches don't need it.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Data folder", value: model.paths.supportDirectory.path.abbreviatingHome(model.paths.home))
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 620)
        .onAppear { rootsText = model.settings.worktreeRoots.joined(separator: ", ") }
    }

    private func saveRoots() {
        let roots = rootsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !roots.isEmpty { model.settings.worktreeRoots = roots }
    }

    private func gbStepper(_ title: String, value: Binding<Int64>, range: ClosedRange<Int64>) -> some View {
        let gb = Binding<Int64>(get: { value.wrappedValue / Format.gigabyte }, set: { value.wrappedValue = $0 * Format.gigabyte })
        return Stepper("\(title): \(gb.wrappedValue) GB", value: gb, in: range, step: 5)
    }
}

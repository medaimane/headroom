import AppKit
import HeadroomCore
import SwiftUI

struct StorageView: View {
    @Environment(AppModel.self) private var model
    @State private var selected: Set<String> = []

    private var groups: [(String, [CatalogEntry])] {
        var order: [String] = []
        var byGroup: [String: [CatalogEntry]] = [:]
        for entry in StorageCatalog.entries {
            if byGroup[entry.group] == nil { order.append(entry.group) }
            byGroup[entry.group, default: []].append(entry)
        }
        return order.map { ($0, byGroup[$0]!) }
    }

    private var selectedBytes: Int64 {
        selected.compactMap { model.entrySizes[$0]?.bytes }.reduce(0, +)
    }

    var body: some View {
        VStack(spacing: 0) {
            List {
                if let sample = model.latest {
                    DiskBar(sample: sample, settings: model.settings).padding(.vertical, 6)
                }
                ForEach(groups, id: \.0) { group, entries in
                    SwiftUI.Section(group) {
                        ForEach(entries) { entry in
                            StorageRow(entry: entry, size: model.entrySizes[entry.id], home: model.paths.home, root: entry.root(in: model.paths),
                                       isSelected: Binding(get: { selected.contains(entry.id) }, set: { on in
                                           if on { selected.insert(entry.id) } else { selected.remove(entry.id) }
                                       }))
                        }
                    }
                }
                SwiftUI.Section("Docker") { DockerRows(status: model.docker) }
            }
            Divider()
            HStack(spacing: 12) {
                ModeBanner(mode: model.effectiveMode).frame(maxWidth: 520)
                Spacer()
                Text(selected.isEmpty ? "Select caches to clean" : "\(selected.count) selected · \(Format.bytes(selectedBytes))")
                    .foregroundStyle(.secondary).monospacedDigit()
                Button("Review clean-up…") { model.preparePlan(entryIDs: Array(selected)) }
                    .buttonStyle(.borderedProminent)
                    .disabled(selected.isEmpty || model.preparingPlan)
            }
            .padding(12)
        }
        .navigationTitle("Storage")
        .toolbar {
            ToolbarItem {
                Button {
                    model.scanStorage()
                } label: {
                    if model.scanningStorage { ProgressView().controlSize(.small) } else { Label("Rescan", systemImage: "arrow.clockwise") }
                }
                .help(model.lastStorageScan.map { "Last scanned \(Format.relative($0))" } ?? "Scan")
            }
        }
        .onAppear { if model.lastStorageScan == nil { model.scanStorage() } }
        .sheet(item: Binding(get: { model.pendingPlan.map(PlanBox.init) }, set: { if $0 == nil { model.pendingPlan = nil } })) { box in
            CleanupReviewSheet(plan: box.plan) {
                selected.subtract(box.plan.runnable.map(\.id))
            }
        }
    }
}

struct PlanBox: Identifiable {
    let plan: CleanupPlan
    var id: Date { plan.createdAt }
}

struct StorageRow: View {
    let entry: CatalogEntry
    let size: DirectorySize?
    let home: URL
    let root: URL
    @Binding var isSelected: Bool
    @State private var showInfo = false

    var body: some View {
        HStack(spacing: 10) {
            if entry.kind == .rebuildableCache {
                Toggle("", isOn: $isSelected).labelsHidden().disabled((size?.bytes ?? 0) == 0)
            } else {
                Image(systemName: "eye").foregroundStyle(.secondary).frame(width: 20).help("Shown only. Headroom never changes this.")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                Text(locationText).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if let modified = size?.newestModification {
                Text("changed \(Format.relative(modified))").font(.caption).foregroundStyle(.secondary)
            }
            if size?.partial == true {
                Image(systemName: "lock").foregroundStyle(.secondary).help("Some items couldn't be read. Full Disk Access would make this complete.")
            }
            Text(size.map { Format.bytes($0.bytes) } ?? "…").monospacedDigit().frame(width: 90, alignment: .trailing)
            Button { showInfo.toggle() } label: { Image(systemName: "info.circle") }
                .buttonStyle(.borderless)
                .popover(isPresented: $showInfo, arrowEdge: .trailing) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(entry.name).font(.headline)
                        Text(entry.rebuildNote).fixedSize(horizontal: false, vertical: true)
                        Text(locationText).font(.caption.monospaced()).textSelection(.enabled)
                        if !entry.blockingCategories.isEmpty || !entry.blockingProcessNames.isEmpty {
                            Text("Skipped while running: " + (entry.blockingCategories.map(\.title) + entry.blockingProcessNames).sorted().joined(separator: ", "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([root]) }
                            .disabled(!FileManager.default.fileExists(atPath: root.path))
                    }
                    .padding(14)
                    .frame(width: 340)
                }
        }
        .padding(.vertical, 2)
    }

    private var locationText: String {
        switch entry.location {
        case .temporaryPrefix(let prefix): "$TMPDIR/\(prefix)*"
        default: root.path.abbreviatingHome(home)
        }
    }
}

struct DockerRows: View {
    let status: DockerUsage.Status?

    var body: some View {
        switch status {
        case nil:
            Text("Not checked yet").foregroundStyle(.secondary)
        case .notInstalled:
            Text("Docker isn't installed.").foregroundStyle(.secondary)
        case .notRunning:
            Text("Docker is installed but not running. Start it to see image and volume sizes.").foregroundStyle(.secondary)
        case .rows(let rows):
            ForEach(rows) { row in
                HStack {
                    Text(row.type)
                    Text("\(row.total) total, \(row.active) active").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(row.size) · reclaimable \(row.reclaimable)").monospacedDigit()
                }
            }
            Text("Shown only in v1. Images and volumes can hold data (a local database lives in a volume), so pruning will need a per-item confirmation.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct CleanupReviewSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let plan: CleanupPlan
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.lastReport == nil ? "Review clean-up" : "Clean-up result").font(.title2.weight(.semibold))
            ModeBanner(mode: model.effectiveMode)

            if let report = model.lastReport {
                List(report.results) { result in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(result.name)
                            Spacer()
                            Text(report.mode == .dryRun ? "would free \(Format.bytes(result.bytes))" : "freed \(Format.bytes(result.bytes))").monospacedDigit()
                        }
                        if let reason = result.skippedReason { Text("Skipped: \(reason)").font(.caption).foregroundStyle(.orange) }
                        ForEach(result.failures.prefix(5), id: \.self) { Text($0).font(.caption).foregroundStyle(.red) }
                    }
                }
                HStack {
                    Text(report.mode == .dryRun ? "Simulated: \(Format.bytes(report.bytes)). Nothing was deleted." : "Freed \(Format.bytes(report.bytes)).")
                    Spacer()
                    Button("Done") {
                        onDone()
                        model.lastReport = nil
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            } else {
                List(plan.items) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(item.entry.name).fontWeight(.medium)
                            Spacer()
                            Text(item.blockedReason == nil ? "\(item.targets.count) items · \(Format.bytes(item.bytes))" : "skipped").monospacedDigit()
                        }
                        if let reason = item.blockedReason {
                            Label(reason, systemImage: "hand.raised").font(.caption).foregroundStyle(.orange)
                        } else {
                            Text(item.entry.rebuildNote).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
                Text("These are caches on Headroom's allow-list. Each item is checked again right before it's removed: it must still be inside the cache folder, not inside a git working tree, and not contain a .env*.local file.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Cancel", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(model.effectiveMode == .dryRun ? "Simulate cleaning \(Format.bytes(plan.bytes))" : "Delete \(Format.bytes(plan.bytes))") {
                        model.execute(plan)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(model.effectiveMode == .live ? .red : .accentColor)
                    .disabled(plan.runnable.isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 620, height: 520)
    }
}

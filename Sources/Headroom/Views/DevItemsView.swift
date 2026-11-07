import AppKit
import HeadroomCore
import SwiftUI

struct DevItemsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirming: DevItem?

    var body: some View {
        VStack(spacing: 0) {
            List {
                SwiftUI.Section {
                    ModeBanner(mode: model.effectiveMode)
                    Text("These aren't caches. Each one is removed only after its own confirmation.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(DevItemKind.allCases, id: \.self) { kind in
                    let items = model.devItems[kind] ?? []
                    SwiftUI.Section {
                        if let error = model.devItemErrors[kind] {
                            Text(error).foregroundStyle(.red)
                        } else if items.isEmpty {
                            Text(model.scanningDevItems ? "Scanning…" : "None found").foregroundStyle(.secondary)
                        }
                        ForEach(items) { item in
                            DevItemRow(item: item) { confirming = item }
                        }
                    } header: {
                        HStack {
                            Text(kind.title)
                            Spacer()
                            Text(Format.bytes(items.reduce(0) { $0 + $1.bytes })).monospacedDigit()
                        }
                    }
                }
            }
        }
        .navigationTitle("Simulators & devices")
        .toolbar {
            ToolbarItem {
                Button { model.scanDevItems() } label: {
                    if model.scanningDevItems { ProgressView().controlSize(.small) } else { Label("Rescan", systemImage: "arrow.clockwise") }
                }
            }
        }
        .onAppear { if model.devItems.isEmpty { model.scanDevItems() } }
        .confirmationDialog(confirming.map { "Remove \($0.name)?" } ?? "", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }), presenting: confirming) { item in
            Button(model.effectiveMode == .dryRun ? "Simulate removing \(Format.bytes(item.bytes))" : "Remove \(Format.bytes(item.bytes))", role: .destructive) {
                model.remove(item)
            }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text("\(item.kind.title): \(item.name) (\(item.detail)).\n\n\(item.kind.removalNote)")
        }
        .alert(model.lastDevItemResult?.succeeded == true ? "Done" : "Not removed",
               isPresented: Binding(get: { model.lastDevItemResult != nil }, set: { if !$0 { model.lastDevItemResult = nil } })) {
            Button("OK") { model.lastDevItemResult = nil }
        } message: {
            Text(model.lastDevItemResult?.message ?? "")
        }
    }
}

struct DevItemRow: View {
    let item: DevItem
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name)
                    if item.isInUse { Text("in use").font(.caption).padding(.horizontal, 5).background(.green.opacity(0.2), in: Capsule()) }
                }
                Text(item.detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let lastUsed = item.lastUsed {
                Text("used \(Format.relative(lastUsed))").font(.caption).foregroundStyle(.secondary)
            }
            Text(Format.bytes(item.bytes)).monospacedDigit().frame(width: 90, alignment: .trailing)
            if let location = item.location {
                Button { NSWorkspace.shared.activateFileViewerSelecting([location]) } label: { Image(systemName: "folder") }
                    .buttonStyle(.borderless).help("Show in Finder")
            }
            Button("Remove…", action: onRemove)
                .disabled(item.blockedReason != nil)
                .help(item.blockedReason ?? item.kind.removalNote)
        }
    }
}

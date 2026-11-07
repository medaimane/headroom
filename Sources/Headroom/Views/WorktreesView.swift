import AppKit
import HeadroomCore
import SwiftUI

struct WorktreesView: View {
    @Environment(AppModel.self) private var model
    @State private var sortOrder = [KeyPathComparator(\WorktreeRow.nodeModules, order: .reverse)]
    @State private var confirming: WorktreeInfo?

    private var rows: [WorktreeRow] {
        model.worktrees.map(WorktreeRow.init).sorted(using: sortOrder)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Push status is as of your last `git fetch`: Headroom never fetches, commits or changes a repository. The only thing it can remove is a worktree's node_modules, when the worktree is clean and pushed and nothing runs from it, after your confirmation. Scanned folders: \(model.settings.worktreeRoots.joined(separator: ", ")) (change in Settings).")
                .font(.callout).foregroundStyle(.secondary).padding(12)
            Table(rows, sortOrder: $sortOrder) {
                TableColumn("Repository", value: \.repository) { row in
                    VStack(alignment: .leading) {
                        Text(row.repository)
                        Text(row.info.path.abbreviatingHome(model.paths.home)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                .width(min: 200, ideal: 280)
                TableColumn("Branch", value: \.branch) { row in
                    Text(row.branch + (row.info.isMainWorktree ? "  (main)" : "")).lineLimit(1)
                }
                TableColumn("Status", value: \.statusOrder) { row in
                    StatusBadge(status: row.info.status)
                }
                .width(140)
                TableColumn("Unpushed", value: \.unpushed) { row in
                    Text(row.info.unpushedCommits.map(String.init) ?? "–").monospacedDigit()
                }
                .width(70)
                TableColumn("Changes", value: \.changes) { row in
                    Text(row.info.uncommittedChanges.map(String.init) ?? "–").monospacedDigit()
                }
                .width(70)
                TableColumn("Last commit", value: \.lastCommit) { row in
                    Text(row.info.lastCommit.map { Format.relative($0) } ?? "–")
                }
                .width(100)
                TableColumn("node_modules", value: \.nodeModules) { row in
                    Text(row.info.nodeModulesBytes.map { Format.bytes($0) } ?? "–").monospacedDigit()
                }
                .width(100)
                TableColumn("Nx cache", value: \.nxCache) { row in
                    Text(row.info.nxCacheBytes.map { Format.bytes($0) } ?? "–").monospacedDigit()
                }
                .width(80)
                TableColumn("") { row in
                    removeButton(for: row.info)
                }
                .width(110)
            }
            .contextMenu(forSelectionType: WorktreeRow.ID.self) { ids in
                if let id = ids.first {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: id)]) }
                    if let info = model.worktrees.first(where: { $0.path == id }), NodeModulesCleanup.quickBlocker(for: info) == nil {
                        Button("Remove node_modules…") { confirming = info }
                    }
                }
            }
            HStack {
                let total = model.worktrees.reduce(Int64(0)) { $0 + ($1.nodeModulesBytes ?? 0) + ($1.nxCacheBytes ?? 0) }
                let removable = model.worktrees.filter { NodeModulesCleanup.quickBlocker(for: $0) == nil }.reduce(Int64(0)) { $0 + ($1.nodeModulesBytes ?? 0) }
                Text("\(model.worktrees.count) worktrees · \(Format.bytes(total)) in node_modules and Nx caches · \(Format.bytes(removable)) of node_modules in clean, pushed worktrees")
                Spacer()
                if let date = model.lastWorktreeScan { Text("Scanned \(Format.relative(date))").foregroundStyle(.secondary) }
            }
            .font(.callout).padding(12)
        }
        .navigationTitle("Worktrees")
        .toolbar {
            ToolbarItem {
                Button { model.scanWorktrees() } label: {
                    if model.scanningWorktrees { ProgressView().controlSize(.small) } else { Label("Rescan", systemImage: "arrow.clockwise") }
                }
            }
        }
        .onAppear { if model.lastWorktreeScan == nil { model.scanWorktrees() } }
        .confirmationDialog(confirming.map { "Remove node_modules from \($0.repository) (\($0.branch ?? "detached"))?" } ?? "",
                            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                            presenting: confirming) { info in
            let size = Format.bytes(info.nodeModulesBytes ?? 0)
            Button(model.effectiveMode == .dryRun ? "Simulate removing \(size)" : "Remove \(size)", role: .destructive) {
                model.removeNodeModules(info)
            }
            Button("Cancel", role: .cancel) {}
        } message: { info in
            Text("""
            \(info.path.abbreviatingHome(model.paths.home))/node_modules

            Only this folder is removed. To bring it back, run `\(NodeModulesCleanup.reinstallCommand(in: info.path))` in the worktree.

            Right before removing, Headroom checks again that the worktree is clean and pushed, that git ignores node_modules, and that nothing is running from it.
            """)
        }
        .alert(model.lastNodeModulesResult?.succeeded == true ? "Done" : "Not removed",
               isPresented: Binding(get: { model.lastNodeModulesResult != nil }, set: { if !$0 { model.lastNodeModulesResult = nil } })) {
            Button("OK") { model.lastNodeModulesResult = nil }
        } message: {
            Text(model.lastNodeModulesResult?.message ?? "")
        }
    }

    @ViewBuilder
    private func removeButton(for info: WorktreeInfo) -> some View {
        if model.removingNodeModules.contains(info.path) {
            ProgressView().controlSize(.small)
        } else if let blocker = NodeModulesCleanup.quickBlocker(for: info) {
            if blocker != .noNodeModules {
                Text("Keep").font(.caption).foregroundStyle(.secondary).help(blocker.description)
            }
        } else {
            Button("Remove…") { confirming = info }
                .controlSize(.small)
                .help("Remove this worktree's node_modules (\(Format.bytes(info.nodeModulesBytes ?? 0))) after confirming.")
        }
    }
}

struct WorktreeRow: Identifiable {
    let info: WorktreeInfo
    var id: String { info.path }
    var repository: String { info.repository }
    var branch: String { info.branch ?? (info.isDetached ? "detached" : "–") }
    var unpushed: Int { info.unpushedCommits ?? -1 }
    var changes: Int { info.uncommittedChanges ?? -1 }
    var lastCommit: Date { info.lastCommit ?? .distantPast }
    var nodeModules: Int64 { info.nodeModulesBytes ?? 0 }
    var nxCache: Int64 { info.nxCacheBytes ?? 0 }
    var statusOrder: String { info.status.rawValue }
}

struct StatusBadge: View {
    let status: WorktreeInfo.Status

    var body: some View {
        Text(status.label)
            .font(.caption)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
    }

    private var color: Color {
        switch status {
        case .uncommitted, .unpushed: .orange
        case .noUpstream: .yellow
        case .clean: .green
        case .missing, .unknown: .gray
        }
    }
}

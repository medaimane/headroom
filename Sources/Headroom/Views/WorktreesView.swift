import AppKit
import HeadroomCore
import SwiftUI

struct WorktreesView: View {
    @Environment(AppModel.self) private var model
    @State private var sortOrder = [KeyPathComparator(\WorktreeRow.nodeModules, order: .reverse)]

    private var rows: [WorktreeRow] {
        model.worktrees.map(WorktreeRow.init).sorted(using: sortOrder)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Read-only. Push status is as of your last `git fetch`: Headroom never fetches, commits or changes a repository. Scanned folders: \(model.settings.worktreeRoots.joined(separator: ", ")) (change in Settings).")
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
            }
            .contextMenu(forSelectionType: WorktreeRow.ID.self) { ids in
                if let id = ids.first {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: id)]) }
                }
            }
            HStack {
                let total = model.worktrees.reduce(Int64(0)) { $0 + ($1.nodeModulesBytes ?? 0) + ($1.nxCacheBytes ?? 0) }
                Text("\(model.worktrees.count) worktrees · \(Format.bytes(total)) in node_modules and Nx caches")
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

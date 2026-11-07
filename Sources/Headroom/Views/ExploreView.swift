import AppKit
import HeadroomCore
import SwiftUI

/// Read-only drill-down: the biggest folders, one level at a time.
struct ExploreView: View {
    @Environment(AppModel.self) private var model
    @State private var stack: [URL] = []
    @State private var children: [(url: URL, size: DirectorySize)] = []
    @State private var loading = false

    private var current: URL { stack.last ?? model.paths.home }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button { stack.removeLast(); load() } label: { Image(systemName: "chevron.left") }
                    .disabled(stack.isEmpty)
                Text(current.path.abbreviatingHome(model.paths.home)).font(.callout.monospaced()).lineLimit(1).truncationMode(.head)
                Spacer()
                if loading { ProgressView().controlSize(.small) }
            }
            .padding(12)
            Divider()
            List {
                let total = children.reduce(0) { $0 + $1.size.bytes }
                ForEach(children, id: \.url) { child in
                    HStack {
                        Image(systemName: isDirectory(child.url) ? "folder" : "doc").foregroundStyle(.secondary)
                        Text(child.url.lastPathComponent).lineLimit(1)
                        Spacer()
                        if child.size.partial { Image(systemName: "lock").foregroundStyle(.secondary).help("Partly unreadable") }
                        if total > 0 {
                            ProgressView(value: Double(child.size.bytes), total: Double(total)).frame(width: 80)
                        }
                        Text(Format.bytes(child.size.bytes)).monospacedDigit().frame(width: 90, alignment: .trailing)
                        Button { NSWorkspace.shared.activateFileViewerSelecting([child.url]) } label: { Image(systemName: "magnifyingglass") }
                            .buttonStyle(.borderless).help("Show in Finder")
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        guard isDirectory(child.url) else { return }
                        stack.append(child.url)
                        load()
                    }
                }
            }
            Text("Double-click a folder to open it. Sizes only: Headroom never opens files here.")
                .font(.caption).foregroundStyle(.secondary).padding(10)
        }
        .navigationTitle("Explore disk")
        .onAppear { if children.isEmpty { load() } }
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func load() {
        let url = current
        loading = true
        children = []
        Task {
            let result = await model.children(of: url)
            if url == current {
                children = result
                loading = false
            }
        }
    }
}

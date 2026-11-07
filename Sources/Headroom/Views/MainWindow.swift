import HeadroomCore
import SwiftUI

enum Section: String, CaseIterable, Identifiable {
    case health, devEnvironment, storage, devices, explore, worktrees, snapshots, history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .health: "Health"
        case .devEnvironment: "Dev environment"
        case .storage: "Storage"
        case .devices: "Simulators & devices"
        case .explore: "Explore disk"
        case .worktrees: "Worktrees"
        case .snapshots: "Workload snapshots"
        case .history: "History"
        }
    }

    var symbol: String {
        switch self {
        case .health: "waveform.path.ecg"
        case .devEnvironment: "terminal"
        case .storage: "internaldrive"
        case .devices: "iphone.and.arrow.forward"
        case .explore: "folder"
        case .worktrees: "arrow.triangle.branch"
        case .snapshots: "camera.metering.matrix"
        case .history: "clock.arrow.circlepath"
        }
    }
}

struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Section? = .health

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.symbol).tag(section)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
            .safeAreaInset(edge: .bottom) {
                if let level = model.assessment?.overall {
                    HStack {
                        StatusDot(level: level)
                        Text(level.label).font(.caption)
                        Spacer()
                        SettingsLink { Image(systemName: "gearshape") }.buttonStyle(.borderless)
                    }
                    .padding(10)
                }
            }
        } detail: {
            switch selection ?? .health {
            case .health: HealthView()
            case .devEnvironment: DevEnvironmentView()
            case .storage: StorageView()
            case .devices: DevItemsView()
            case .explore: ExploreView()
            case .worktrees: WorktreesView()
            case .snapshots: SnapshotsView()
            case .history: HistoryView()
            }
        }
    }
}

import HeadroomCore
import SwiftUI

/// What's running for development right now, with a confirmed stop for simulators, emulators and dev servers.
struct DevEnvironmentView: View {
    @Environment(AppModel.self) private var model
    @State private var confirming: RunningItem?

    private var env: DevEnvironmentSnapshot { model.devEnvironment }

    var body: some View {
        List {
            Text("Simulators, emulators and dev servers can be stopped here, one at a time after you confirm. Headroom sends a normal stop request and never force-quits. Agent sessions are shown but not stopped from here.")
                .font(.callout).foregroundStyle(.secondary)
                .listRowSeparator(.hidden)

            SwiftUI.Section {
                if env.simulators.isEmpty { empty("No simulators running") }
                ForEach(env.simulators) { item in row(item, symbol: "iphone") }
            } header: {
                header("iOS simulators", memory: env.simulatorMemory, note: env.simulators.isEmpty ? nil : "all simulator processes together")
            }

            SwiftUI.Section {
                if env.emulators.isEmpty { empty("No emulators running") }
                ForEach(env.emulators) { item in row(item, symbol: "candybarphone") }
            } header: {
                header("Android emulators", memory: env.emulators.reduce(0) { $0 + $1.memory })
            }

            SwiftUI.Section {
                if env.servers.isEmpty { empty("No dev servers listening") }
                ForEach(env.servers) { item in row(item, symbol: "network") }
            } header: {
                header("Dev servers and ports", memory: env.servers.reduce(0) { $0 + $1.memory })
            }

            SwiftUI.Section {
                if env.agents.isEmpty { empty("No agent sessions") }
                ForEach(env.agents) { item in row(item, symbol: "sparkles") }
            } header: {
                header("Claude Code agent sessions", memory: env.agents.reduce(0) { $0 + $1.memory })
            }
        }
        .navigationTitle("Dev environment")
        .toolbar {
            ToolbarItem {
                Button { model.refreshDevEnvironment() } label: {
                    if model.refreshingDevEnvironment { ProgressView().controlSize(.small) } else { Label("Refresh", systemImage: "arrow.clockwise") }
                }
            }
        }
        .onAppear { model.detailViewers += 1 }
        .onDisappear { model.detailViewers -= 1 }
        .task {
            // Refresh while the page is visible.
            while !Task.isCancelled {
                model.refreshDevEnvironment()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .confirmationDialog(confirming.map { "\($0.stopVerb) \($0.name)?" } ?? "",
                            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                            presenting: confirming) { item in
            Button(model.effectiveMode == .dryRun ? "Simulate: \(item.stopVerb.lowercased())" : item.stopVerb, role: .destructive) {
                model.stop(item)
            }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text(confirmationText(item))
        }
        .alert(model.lastStopResult?.succeeded == true ? "Done" : "Not stopped",
               isPresented: Binding(get: { model.lastStopResult != nil }, set: { if !$0 { model.lastStopResult = nil } })) {
            Button("OK") { model.lastStopResult = nil }
        } message: {
            Text(model.lastStopResult?.message ?? "")
        }
    }

    private func row(_ item: RunningItem, symbol: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).frame(width: 18).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                HStack(spacing: 6) {
                    if !item.detail.isEmpty { Text(item.detail).foregroundStyle(.secondary) }
                    ForEach(item.ports, id: \.self) { port in
                        Text(ListeningPorts.label(for: port).map { "\(port) · \($0)" } ?? "\(port)")
                            .font(.caption.monospacedDigit())
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
                .font(.caption)
            }
            Spacer()
            if item.memory > 0 {
                Text(Format.memory(item.memory)).monospacedDigit().foregroundStyle(.secondary)
            }
            if model.stoppingItems.contains(item.id) {
                ProgressView().controlSize(.small)
            } else if let reason = item.stopBlockedReason {
                Text("Shown only").font(.caption).foregroundStyle(.secondary).help(reason)
            } else {
                Button("\(item.stopVerb)…") { confirming = item }.controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    private func header(_ title: String, memory: UInt64, note: String? = nil) -> some View {
        HStack {
            Text(title)
            Spacer()
            if memory > 0 {
                Text(Format.memory(memory) + (note.map { " (\($0))" } ?? "")).monospacedDigit()
            }
        }
    }

    private func empty(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary)
    }

    private func confirmationText(_ item: RunningItem) -> String {
        var lines: [String] = []
        if !item.detail.isEmpty { lines.append(item.detail) }
        if !item.ports.isEmpty { lines.append("Listening on " + item.ports.map(String.init).joined(separator: ", ")) }
        switch item.kind {
        case .simulator: lines.append("Headroom runs `xcrun simctl shutdown`, a normal shutdown. Apps in it close.")
        case .emulator: lines.append("Headroom asks the emulator to quit normally. It never force-quits.")
        case .server: lines.append("Headroom sends a normal stop request (SIGTERM), which lets it clean up. It never force-quits.")
        case .agent: break
        }
        lines.append("To start it again: \(item.restartHint)")
        return lines.joined(separator: "\n\n")
    }
}

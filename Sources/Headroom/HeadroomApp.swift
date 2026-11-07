import AppKit
import HeadroomCore
import SwiftUI

@main
struct HeadroomApp: App {
    @State private var model: AppModel

    init() {
        let model = AppModel()
        model.start()
        _model = State(initialValue: model)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("Headroom", id: "main") {
            MainWindow()
                .environment(model)
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1080, height: 720)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        let level = model.assessment?.overall ?? .good
        HStack(spacing: 4) {
            Image(systemName: level.menuSymbol)
            if let sample = model.latest, model.assessment?.disk ?? .good > .good {
                Text(Format.bytes(sample.diskFree))
            }
        }
        .accessibilityLabel("Headroom: \(level.label)")
    }
}

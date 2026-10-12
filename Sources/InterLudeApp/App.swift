import SwiftUI

@main
struct InterLudeApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model)
        } label: {
            Image(systemName: model.menuIcon)
        }
        .menuBarExtraStyle(.window)

        Window("InterLude Settings", id: "settings") {
            SettingsView(model: model)
        }
        .windowResizability(.contentSize)
    }
}

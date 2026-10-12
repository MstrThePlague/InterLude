import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The first launch shows the panel in a window as well, so it is clear the app is running.
        if !UserDefaults.standard.bool(forKey: "shownWelcomeWindow") {
            UserDefaults.standard.set(true, forKey: "shownWelcomeWindow")
            showWindow()
        }
    }

    /// Opening the app again (Finder, Spotlight) shows the panel in a window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow(); return true
    }

    func showWindow() {
        if window == nil {
            let demoSettings = CommandLine.arguments.contains("--demo=settings")
            let w = NSWindow(contentViewController: demoSettings
                             ? NSHostingController(rootView: SettingsView(model: AppModel.shared))
                             : NSHostingController(rootView: PanelView(model: AppModel.shared)))
            w.title = "InterLude"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct InterLudeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let model = AppModel.shared

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

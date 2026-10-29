import SwiftUI
import AppKit
import InterLudeCore
import InterLudeApple

/// InterLude has no Dock icon, so a menu bar icon is easy to miss. The delegate shows the panel in a window on first
/// launch, and whenever the app is opened again from Finder or Spotlight.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains(where: { $0.hasPrefix("--demo=") }) { showWindow(); return }
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
        if let path = CommandLine.arguments.first(where: { $0.hasPrefix("--snapshot=") })?.dropFirst(11) { snapshot(to: String(path)) }
    }

    /// For README screenshots with `--demo=`: saves the window's content as a PNG once it has settled, then quits.
    private func snapshot(to path: String) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            if let view = window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            NSApp.terminate(nil)
        }
    }
}

@main
struct InterLudeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let model: AppModel

    init() {
        Platform.install(.apple)
        model = AppModel.shared
    }

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

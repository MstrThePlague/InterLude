import SwiftUI
import AppKit
import WebKit
import InterLudeCore
import InterLudeApple

/// InterLude has no Dock icon, so a menu bar icon is easy to miss. The delegate shows the app in a window on first
/// launch, and whenever the app is opened again from Finder or Spotlight.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains(where: { $0.hasPrefix("--demo=") }) { showWindow(); return }
        // The first launch shows the app in a window as well, so it is clear it is running.
        if !UserDefaults.standard.bool(forKey: "shownWelcomeWindow") {
            UserDefaults.standard.set(true, forKey: "shownWelcomeWindow")
            showWindow()
        }
    }

    /// Opening the app again (Finder, Spotlight) shows it in a window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow(); return true
    }

    /// The same web app as the menu bar panel, in a window that can be widened to show Earlier beside the player.
    func showWindow() {
        if window == nil {
            let fragment = CommandLine.arguments.first { $0.hasPrefix("--demo=settings") }.map { String($0.dropFirst(7)) }
            let w = NSWindow(contentViewController: NSHostingController(rootView: WebPanel(model: AppModel.shared, fragment: fragment)))
            w.title = "InterLude"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.setContentSize(NSSize(width: 400, height: 760))
            w.contentMinSize = NSSize(width: 340, height: 520)
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let path = CommandLine.arguments.first(where: { $0.hasPrefix("--snapshot=") })?.dropFirst(11) { snapshot(to: String(path)) }
    }

    /// For README screenshots with `--demo=`: saves the window's web view as a PNG once it has settled, then quits.
    private func snapshot(to path: String) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard let web = window?.contentView?.firstSubview(of: WKWebView.self),
                  let image = try? await web.takeSnapshot(configuration: nil), let tiff = image.tiffRepresentation else { NSApp.terminate(nil); return }
            try? NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            NSApp.terminate(nil)
        }
    }
}

extension NSView {
    func firstSubview<T: NSView>(of type: T.Type) -> T? {
        for v in subviews { if let t = v as? T ?? v.firstSubview(of: type) { return t } }
        return nil
    }
}

/// The web app from the Mac's own server, the same page phones and the Linux server show.
struct WebPanel: View {
    let model: AppModel
    /// Opens straight to part of the page, such as "settings".
    var fragment: String?

    var body: some View {
        if let base = model.panelURL { WebView(url: fragment.flatMap { URL(string: "#\($0)", relativeTo: base)?.absoluteURL } ?? base) }
        else {
            ContentUnavailableView("InterLude can't show its panel", systemImage: "exclamationmark.triangle",
                                   description: Text(model.serverError ?? "Its local server isn't running."))
        }
    }
}

private struct WebView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let web = WKWebView(frame: .zero, configuration: config)
        web.setValue(false, forKey: "drawsBackground")      // no white flash before the page paints
        web.allowsMagnification = false
        web.load(URLRequest(url: url))
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        if web.url == nil { web.load(URLRequest(url: url)) }
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
            WebPanel(model: model).frame(width: 380, height: 720)
        } label: {
            Image(systemName: model.menuIcon)
        }
        .menuBarExtraStyle(.window)
    }
}

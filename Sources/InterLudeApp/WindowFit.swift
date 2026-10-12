import SwiftUI
import AppKit

/// Keeps the hosting window exactly as tall as the SwiftUI content, with its top edge fixed.
/// MenuBarExtra windows do not shrink by themselves when content is removed, which left empty space
/// (for example after closing the welcome note).
struct FitHostWindow: ViewModifier {
    @State private var window: NSWindow?

    func body(content: Content) -> some View {
        content
            .background(WindowReader { window = $0 })
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fit(height: $0) }
            .onChange(of: window) { fit(height: nil) }
    }

    private func fit(height: CGFloat?) {
        guard let w = window, let view = w.contentView else { return }
        let target = height ?? view.fittingSize.height
        let current = w.contentRect(forFrameRect: w.frame).height
        guard target > 0, abs(target - current) > 0.5 else { return }
        var f = w.frame
        let top = f.maxY
        f.size.height += target - current
        f.origin.y = top - f.size.height
        w.setFrame(f, display: true, animate: false)
    }
}

private struct WindowReader: NSViewRepresentable {
    let found: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { found(v.window) }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async { found(v.window) }
    }
}

extension View {
    func fitsHostWindow() -> some View { modifier(FitHostWindow()) }
}

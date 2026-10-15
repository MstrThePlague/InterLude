import SwiftUI

/// A faint, Winamp-style bar spectrum that drifts behind the panel while audio plays.
/// It is decorative: the heights come from layered sines, not from the audio.
struct SpectrumBackdrop: View {
    var active: Bool
    var muted: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let bars = 28
    private let fps = 1.0 / 24.0

    var body: some View {
        TimelineView(.animation(minimumInterval: fps, paused: !active || reduceMotion)) { timeline in
            Canvas { ctx, size in
                draw(&ctx, size: size, t: reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate)
            }
        }
        .mask(LinearGradient(colors: [.clear, .black.opacity(0.9)], startPoint: .top, endPoint: .bottom))
        .opacity(active ? (muted ? 0.04 : 0.09) : 0)
        .animation(.easeInOut(duration: 0.6), value: active)
        .animation(.easeInOut(duration: 0.6), value: muted)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func draw(_ ctx: inout GraphicsContext, size: CGSize, t: Double) {
        let gap: CGFloat = 3
        let barW = (size.width - gap * CGFloat(bars - 1)) / CGFloat(bars)
        let segH: CGFloat = 4
        let segGap: CGFloat = 2
        let rows = Int(size.height / (segH + segGap))
        for i in 0..<bars {
            let x = CGFloat(i) * (barW + gap)
            let level = height(bar: i, t: t)
            let lit = Int((level * Double(rows) * 0.75).rounded())
            for r in 0..<lit {
                let y = size.height - CGFloat(r + 1) * (segH + segGap)
                ctx.fill(Path(CGRect(x: x, y: y, width: barW, height: segH)), with: .color(.accentColor))
            }
            // Peak cap that hangs just above the bar, as on the original.
            let cap = min(rows - 1, lit + 1 + Int(1.5 + 1.5 * sin(t * 1.3 + Double(i))))
            let y = size.height - CGFloat(cap + 1) * (segH + segGap)
            ctx.fill(Path(CGRect(x: x, y: y, width: barW, height: segH)), with: .color(.primary))
        }
    }

    /// 0...1, a lively but smooth blend of sines with a gentle bass-heavy tilt.
    private func height(bar i: Int, t: Double) -> Double {
        let f = Double(i)
        let a = sin(t * 2.1 + f * 0.7)
        let b = sin(t * 3.4 + f * 1.9 + 1.3)
        let c = sin(t * 0.8 + f * 0.31)
        let v = 0.5 + 0.28 * a + 0.17 * b + 0.2 * c
        let tilt = 1.0 - 0.45 * f / Double(bars)
        return max(0.04, min(1, v * tilt))
    }
}

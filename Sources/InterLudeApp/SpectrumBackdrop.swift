import SwiftUI
import InterLudeCore

/// A faint, Winamp-style bar spectrum that drifts behind the panel while audio plays.
/// When a `sampler` is given the bars follow the audio being heard; without one (Cast) they drift on layered sines.
struct SpectrumBackdrop: View {
    var active: Bool
    var muted: Bool
    var sampler: (@MainActor () -> [Float]?)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var motion = Ballistics()

    private let bars = Spectrum.bands
    private var fps: Double { sampler == nil ? 24 : Spectrum.fps }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / fps, paused: !active || reduceMotion)) { timeline in
            let now = timeline.date.timeIntervalSinceReferenceDate
            let _ = motion.step(now: now, target: targets(now))
            Canvas { ctx, size in draw(&ctx, size: size) }
        }
        .mask(LinearGradient(colors: [.clear, .black.opacity(0.9)], startPoint: .top, endPoint: .bottom))
        .opacity(active ? (muted ? 0.05 : 0.1) : 0)
        .animation(.easeInOut(duration: 0.6), value: active)
        .animation(.easeInOut(duration: 0.6), value: muted)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Where each bar wants to be right now.
    private func targets(_ t: Double) -> [Float] {
        if reduceMotion { return (0..<bars).map { Float(decorative(bar: $0, t: 0)) } }
        if let sampler { return sampler() ?? [Float](repeating: 0, count: bars) }
        return (0..<bars).map { Float(decorative(bar: $0, t: t)) }
    }

    private func draw(_ ctx: inout GraphicsContext, size: CGSize) {
        let gap: CGFloat = 3
        let barW = (size.width - gap * CGFloat(bars - 1)) / CGFloat(bars)
        let segH: CGFloat = 4
        let segGap: CGFloat = 2
        let rows = Int(size.height / (segH + segGap))
        func rect(_ x: CGFloat, _ row: Int) -> CGRect {
            CGRect(x: x, y: size.height - CGFloat(row + 1) * (segH + segGap), width: barW, height: segH)
        }
        for i in 0..<bars {
            let x = CGFloat(i) * (barW + gap)
            let lit = Int((Double(motion.levels[i]) * Double(rows) * 0.8).rounded())
            for r in 0..<lit { ctx.fill(Path(rect(x, r)), with: .color(.accentColor)) }
            // Peak cap that hangs above the bar and falls under gravity, as on the original.
            let cap = min(rows - 1, Int((Double(motion.peaks[i]) * Double(rows) * 0.8).rounded()))
            if cap > lit { ctx.fill(Path(rect(x, cap)), with: .color(.primary)) }
        }
    }

    /// 0...1, with a gentle bass-heavy tilt. Every bar bounces at its own rate and phase, so nothing travels
    /// along the row: each stays in its column, as on a hardware analyser.
    private func decorative(bar i: Int, t: Double) -> Double {
        func unit(_ k: Double) -> Double { let x = sin(Double(i + 1) * k) * 43758.5453; return x - x.rounded(.down) }
        let v = 0.5 + 0.3 * sin(t * (1.6 + 2.2 * unit(12.9898)) + 6.28 * unit(78.233))
                    + 0.2 * sin(t * (3.1 + 3.0 * unit(39.346)) + 6.28 * unit(11.135))
        return max(0.04, min(1, v * (1.0 - 0.45 * Double(i) / Double(bars))))
    }
}

/// Winamp-style bar behaviour: bars jump up quickly and fall at a steady rate; peak caps hold, then drop faster.
private final class Ballistics {
    var levels = [Float](repeating: 0, count: Spectrum.bands)
    var peaks = [Float](repeating: 0, count: Spectrum.bands)
    private var hold = [Double](repeating: 0, count: Spectrum.bands)
    private var fall = [Float](repeating: 0, count: Spectrum.bands)
    private var last: Double?

    func step(now: Double, target: [Float]) {
        let dt = Float(min(0.1, max(0, now - (last ?? now)))); last = now
        for i in levels.indices {
            let t = i < target.count ? target[i] : 0
            if t > levels[i] { levels[i] += (t - levels[i]) * min(1, dt * 30) }
            else { levels[i] = max(t, levels[i] - dt * 1.1) }
            if levels[i] >= peaks[i] { peaks[i] = levels[i]; hold[i] = 0.4; fall[i] = 0 }
            else if hold[i] > 0 { hold[i] -= Double(dt) }
            else { fall[i] += dt * 2.5; peaks[i] = max(levels[i], peaks[i] - fall[i] * dt) }
        }
    }
}

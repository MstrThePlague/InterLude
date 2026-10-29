import SwiftUI

/// The panel's palette, from the Aurora UI style. The saturated colours are for fills and glows; the lighter tints
/// are for text and glyphs, which always sit on darkened glass and never directly on the gradient.
enum Aurora {
    static let blue = Color(red: 0, green: 0.5, blue: 1)
    static let pink = Color(red: 1, green: 0.078, blue: 0.576)
    static let cyan = Color(red: 0, green: 1, blue: 1)
    static let violet = Color(red: 0.545, green: 0, blue: 1)
    static let teal = Color(red: 0.125, green: 0.698, blue: 0.667)

    static let liveText = Color(red: 0.37, green: 0.89, blue: 0.85)
    static let mutedText = Color(red: 1, green: 0.49, blue: 0.75)
    static let earlierText = Color(red: 0.73, green: 0.55, blue: 1)
    /// Text on a pink fill: white on pink is under 4:1, this is well over 5:1.
    static let onPink = Color(red: 0.11, green: 0, blue: 0.07)
    static let base = Color(red: 0.03, green: 0.04, blue: 0.12)

    /// What the background is doing: blue and violet while listening, pink through a bulletin, violet for a programme.
    enum Mood: Equatable {
        case live, muted, earlier

        var blobs: [Color] {
            switch self {
            case .live: [Aurora.blue, Aurora.violet, Aurora.teal]
            case .muted: [Aurora.pink, Aurora.violet, Aurora.blue]
            case .earlier: [Aurora.violet, Aurora.blue, Aurora.teal]
            }
        }
        var glow: Color { blobs[0] }
    }
}

/// Three soft colour fields that drift on 9 to 12 second loops, under a veil that keeps text readable.
/// It stands still when nothing is playing and under Reduce Motion, and the colours change slowly with the mood.
struct AuroraBackdrop: View {
    var mood: Aurora.Mood
    var active: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: !active || reduceMotion)) { timeline in
            let t = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            GeometryReader { g in
                let w = g.size.width, h = g.size.height
                ZStack {
                    Aurora.base
                    blob(mood.blobs[0], size: w * 1.15).position(x: w * (0.15 + 0.12 * wave(t, 11, 0)), y: h * (0.10 + 0.08 * wave(t, 9, 1)))
                    blob(mood.blobs[1], size: w * 1.1).position(x: w * (0.90 + 0.10 * wave(t, 9, 2)), y: h * (0.48 + 0.10 * wave(t, 12, 3)))
                    blob(mood.blobs[2], size: w * 1.0).position(x: w * (0.30 + 0.12 * wave(t, 12, 4)), y: h * (0.95 + 0.06 * wave(t, 10, 5)))
                    LinearGradient(colors: [.black.opacity(0.2), .black.opacity(0.45)], startPoint: .top, endPoint: .bottom)
                }
                .frame(width: w, height: h)
                .animation(.easeInOut(duration: 1.4), value: mood)
            }
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func blob(_ colour: Color, size: CGFloat) -> some View {
        Circle()
            .fill(RadialGradient(colors: [colour.opacity(0.85), colour.opacity(0)], center: .center, startRadius: 0, endRadius: size / 2))
            .frame(width: size, height: size)
    }

    private func wave(_ t: Double, _ period: Double, _ phase: Double) -> Double { sin(t / period * 2 * .pi + phase) }
}

extension View {
    /// A darkened, blurred pane with a hairline edge, for the cards that sit over the gradient.
    func glassCard(radius: CGFloat = 12) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return self
            .background(Aurora.base.opacity(0.55), in: shape)
            .background(.ultraThinMaterial, in: shape)
            .overlay(shape.strokeBorder(.white.opacity(0.14), lineWidth: 1))
            .clipShape(shape)
    }
}

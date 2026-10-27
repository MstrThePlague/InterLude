import Foundation
import InterLudeCore

/// Speech and music scores from Google's YAMNet (an AudioSet classifier, Apache 2.0), run with ONNX Runtime.
/// YAMNet scores 0.96 s frames every 0.48 s; these are averaged into the 3 s windows with a 1.5 s hop that Apple's
/// classifier reports, then mapped onto Apple's scale (`YAMNetCalibration`), so the detector's thresholds hold for both.
public final class YAMNetClassifier: SoundClassifying, @unchecked Sendable {
    private let model: ONNXModel
    private let speechClass: Int
    private let musicClass: Int
    private let calibrated: Bool
    public static let classes = 521
    static let frameHop = 0.48, frameLength = 0.96
    static let windowLength = 3.0, windowHop = 1.5

    /// Loads `yamnet.onnx` and `yamnet_class_map.csv` from `directory`, as scripts/yamnet/convert.sh makes them.
    public init(directory: URL, calibrated: Bool = true) throws {
        self.calibrated = calibrated
        model = try ONNXModel(path: directory.appendingPathComponent("yamnet.onnx").path, input: "waveform:0", output: "Identity:0")
        let map = try String(contentsOf: directory.appendingPathComponent("yamnet_class_map.csv"), encoding: .utf8)
        func index(_ name: String) throws -> Int {
            // The file has CRLF line ends, which Swift counts as one character, so split on newlines of any kind.
            guard let line = map.components(separatedBy: .newlines).first(where: { $0.hasSuffix(",\(name)") }),
                  let i = Int(line.split(separator: ",")[0]) else {
                throw ONNXModel.Failure(message: "yamnet_class_map.csv has no \(name) class")
            }
            return i
        }
        speechClass = try index("Speech"); musicClass = try index("Music")
    }

    public func classify(_ clips: [PCMAudio]) throws -> [SoundScore] {
        guard let rate = clips.first?.sampleRate else { return [] }
        var mono: [Float] = []
        for c in clips { mono += Self.mono(c) }
        let raw = try frames(Resample.to16k(mono, from: rate))
        return Self.windows(raw, duration: Double(mono.count) / rate).map {
            calibrated ? SoundScore(time: $0.time, duration: Self.windowLength,
                                    speech: YAMNetCalibration.speech.map($0.speech), music: YAMNetCalibration.music.map($0.music))
                       : SoundScore(time: $0.time, duration: Self.windowLength, speech: $0.speech, music: $0.music)
        }
    }

    /// YAMNet's speech and music probabilities for each frame of 16 kHz audio, uncalibrated.
    public func frames(_ samples16k: [Float]) throws -> [(speech: Double, music: Double)] {
        guard samples16k.count >= 16000 else { return [] }
        let out = try model.run(samples16k)
        guard out.shape.count == 2, out.shape[1] == Self.classes else { throw ONNXModel.Failure(message: "unexpected output shape \(out.shape)") }
        return (0..<out.shape[0]).map { f in
            (Double(out.values[f * Self.classes + speechClass]), Double(out.values[f * Self.classes + musicClass]))
        }
    }

    /// Averages frames into Apple-style windows: those starting every 1.5 s that fit in `duration`, each taking the
    /// frames that lie wholly inside it.
    static func windows(_ frames: [(speech: Double, music: Double)], duration: Double) -> [(time: Double, speech: Double, music: Double)] {
        var out: [(time: Double, speech: Double, music: Double)] = []
        var start = 0.0
        while start + windowLength <= duration + 1e-6 {
            let inside = frames.indices.filter {
                let t = Double($0) * frameHop
                return t >= start - 1e-6 && t + frameLength <= start + windowLength + 1e-6
            }
            if !inside.isEmpty {
                let n = Double(inside.count)
                out.append((start, inside.reduce(0) { $0 + frames[$1].speech } / n, inside.reduce(0) { $0 + frames[$1].music } / n))
            }
            start += windowHop
        }
        return out
    }

    static func mono(_ a: PCMAudio) -> [Float] {
        guard let l = a.channels.first else { return [] }
        guard a.channels.count > 1 else { return l }
        let r = a.channels[1]
        return (0..<min(l.count, r.count)).map { (l[$0] + r[$0]) * 0.5 }
    }
}

/// Piecewise-linear maps from YAMNet's scores to Apple's classifier's, fitted by matching quantiles of the two over the
/// same hours of 6 Music (scripts/yamnet/calibrate.py). Inputs between knots are interpolated; outside, clamped.
public struct ScoreMap: Sendable, Equatable {
    public var knots: [(x: Double, y: Double)]
    public init(_ knots: [(x: Double, y: Double)]) { self.knots = knots }
    public static let identity = ScoreMap([(0, 0), (1, 1)])

    public func map(_ x: Double) -> Double {
        guard let first = knots.first, let last = knots.last else { return x }
        if x <= first.x { return first.y }
        if x >= last.x { return last.y }
        let i = knots.firstIndex { $0.x >= x }!
        let a = knots[i - 1], b = knots[i]
        return b.x == a.x ? b.y : a.y + (b.y - a.y) * (x - a.x) / (b.x - a.x)
    }

    public static func == (a: ScoreMap, b: ScoreMap) -> Bool { a.knots.elementsEqual(b.knots) { $0.x == $1.x && $0.y == $1.y } }
}

/// Resampling to YAMNet's 16 kHz.
enum Resample {
    /// A 63-tap Blackman-windowed sinc low-pass at 7.2 kHz for 48 kHz input, then every third sample.
    static let taps: [Float] = {
        let n = 63, fc = 7200.0 / 48000.0, mid = Double(n - 1) / 2
        var h = (0..<n).map { i -> Double in
            let x = Double(i) - mid
            let sinc = x == 0 ? 2 * fc : sin(2 * .pi * fc * x) / (.pi * x)
            let w = 0.42 - 0.5 * cos(2 * .pi * Double(i) / Double(n - 1)) + 0.08 * cos(4 * .pi * Double(i) / Double(n - 1))
            return sinc * w
        }
        let sum = h.reduce(0, +)
        h = h.map { $0 / sum }
        return h.map(Float.init)
    }()

    static func to16k(_ x: [Float], from rate: Double) -> [Float] {
        if rate == 16000 { return x }
        precondition(rate == 48000, "YAMNet input must be 48 kHz or 16 kHz")
        let h = taps, half = h.count / 2
        var out = [Float](repeating: 0, count: x.count / 3)
        x.withUnsafeBufferPointer { src in
            h.withUnsafeBufferPointer { k in
                for o in 0..<out.count {
                    let c = o * 3
                    var acc: Float = 0
                    let lo = max(0, c - half), hi = min(src.count - 1, c + half)
                    for i in lo...hi { acc += src[i] * k[i - c + half] }
                    out[o] = acc
                }
            }
        }
        return out
    }
}

/// Fitted by scripts/yamnet/calibrate.py on 5¾ hours of 6 Music (27 October 2026, 12:24 to 18:09 UTC): 13,652 windows.
/// Mapped, YAMNet agrees with Apple's classifier on 94.5% of windows at speech 0.5, 96.1% at 0.6 and 94.5% at music 0.5.
public enum YAMNetCalibration {
    public static let speech = ScoreMap([(0.0000, 0.0970), (0.0010, 0.2350), (0.0020, 0.3280), (0.0030, 0.3944), (0.0050, 0.4737), (0.0130, 0.5680), (0.0583, 0.6640), (0.1880, 0.7530), (0.3420, 0.8080), (0.5030, 0.8380), (0.6840, 0.8600), (0.8270, 0.8760), (0.9240, 0.8890), (0.9710, 0.9020), (0.9910, 0.9150), (0.9980, 0.9280), (1.0000, 0.9730)])
    public static let music = ScoreMap([(0.0000, 0.1690), (0.0020, 0.2430), (0.0100, 0.3400), (0.0600, 0.4324), (0.1900, 0.4970), (0.3349, 0.5450), (0.4730, 0.5842), (0.5770, 0.6165), (0.6560, 0.6440), (0.7100, 0.6660), (0.7560, 0.6850), (0.7870, 0.7000), (0.8090, 0.7120), (0.8290, 0.7240), (0.8460, 0.7350), (0.8590, 0.7470), (0.8710, 0.7560), (0.8820, 0.7650), (0.8910, 0.7730), (0.8990, 0.7820), (0.9070, 0.7900), (0.9140, 0.7980), (0.9220, 0.8070), (0.9280, 0.8140), (0.9340, 0.8210), (0.9400, 0.8280), (0.9450, 0.8350), (0.9500, 0.8430), (0.9540, 0.8500), (0.9590, 0.8560), (0.9630, 0.8640), (0.9680, 0.8720), (0.9710, 0.8790), (0.9750, 0.8870), (0.9800, 0.8950), (0.9840, 0.9040), (0.9890, 0.9150), (0.9940, 0.9310), (1.0000, 0.9890)])
}

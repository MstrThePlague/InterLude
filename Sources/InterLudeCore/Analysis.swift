import Foundation
import AVFoundation
import SoundAnalysis

/// One classifier result: a window of audio with speech and music scores.
public struct SoundScore: Sendable, Codable {
    public var time: Double      // seconds from the start of the stream (window start)
    public var duration: Double
    public var speech: Double
    public var music: Double
}

/// Decodes ADTS AAC frames to PCM by round-tripping through a temporary file.
public enum Decode {
    public static func pcm(frames: [Data]) throws -> AVAudioPCMBuffer? {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("il-\(UUID().uuidString).aac")
        var d = Data(); for f in frames { d.append(f) }
        try d.write(to: tmp); defer { try? FileManager.default.removeItem(at: tmp) }
        let file = try AVAudioFile(forReading: tmp)
        guard file.length > 0, let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { return nil }
        try file.read(into: buf)
        return buf
    }
}

/// Runs Apple's built-in sound classifier over a short clip. Windows are 3 s with a 1.5 s hop.
/// (The stream analyzer silently drops buffers when fed faster than real time, so clips go through a file.)
public final class ClipClassifier: NSObject, SNResultsObserving, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [SoundScore] = []

    public override init() { super.init() }

    /// Scores `buffers` as one continuous clip. Times are seconds from the start of the clip.
    public func classify(_ buffers: [AVAudioPCMBuffer]) throws -> [SoundScore] {
        guard let first = buffers.first else { return [] }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("il-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: first.format.sampleRate,
                                           AVNumberOfChannelsKey: first.format.channelCount, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true]
            let out = try AVAudioFile(forWriting: tmp, settings: settings, commonFormat: first.format.commonFormat, interleaved: false)
            for b in buffers { try out.write(from: b) }
        }
        lock.lock(); results = []; lock.unlock()
        let analyzer = try SNAudioFileAnalyzer(url: tmp)
        try analyzer.add(try SNClassifySoundRequest(classifierIdentifier: .version1), withObserver: self)
        analyzer.analyze()
        lock.lock(); defer { lock.unlock() }
        return results
    }

    public func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let r = result as? SNClassificationResult else { return }
        let speech = r.classification(forIdentifier: "speech")?.confidence ?? 0
        let music = r.classification(forIdentifier: "music")?.confidence ?? 0
        lock.lock()
        results.append(SoundScore(time: r.timeRange.start.seconds, duration: r.timeRange.duration.seconds, speech: speech, music: music))
        lock.unlock()
    }
}

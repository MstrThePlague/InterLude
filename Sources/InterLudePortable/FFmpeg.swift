import Foundation
import InterLudeCore

/// Decodes audio by running ffmpeg, so no codec has to be linked in. Each call starts one short-lived process:
/// a 6.4 s segment decodes in a few tens of milliseconds, well inside the time the session has for it.
public struct FFmpegDecoder: AudioDecoding {
    public let executable: URL
    public let sampleRate: Double

    public init(executable: URL, sampleRate: Double = 48000) {
        self.executable = executable; self.sampleRate = sampleRate
    }

    /// The first ffmpeg found in `PATH` or the usual install locations, or nil when there isn't one.
    public static func find(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let path = (environment["PATH"] ?? "").split(separator: pathSeparator).map(String.init)
        let dirs = path + ["/usr/bin", "/usr/local/bin", "/opt/homebrew/bin"]
        return dirs.lazy.map { URL(fileURLWithPath: $0).appendingPathComponent(executableName) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    #if os(Windows)
    private static let pathSeparator: Character = ";", executableName = "ffmpeg.exe"
    #else
    private static let pathSeparator: Character = ":", executableName = "ffmpeg"
    #endif

    public func decode(adts frames: [Data]) throws -> PCMAudio? {
        guard !frames.isEmpty else { return nil }
        let pcm = try run(["-f", "aac", "-i", "pipe:0"], input: frames.reduce(into: Data()) { $0.append($1) })
        return pcm.frameCount > 0 ? pcm : nil
    }

    public func read(contentsOf url: URL) throws -> PCMAudio {
        try run(["-i", url.path], input: nil)
    }

    /// Runs ffmpeg with `inputArgs`, asking for 32-bit float stereo at `sampleRate`, and splits the result into channels.
    private func run(_ inputArgs: [String], input: Data?) throws -> PCMAudio {
        let out = try FFmpeg.run(executable, inputArgs + ["-f", "f32le", "-ac", "2", "-ar", String(Int(sampleRate)), "pipe:1"], input: input)
        return PCMAudio(interleavedStereo: out, sampleRate: sampleRate)
    }

}

/// Encodes AAC-LC with ffmpeg's own encoder, for silent frames and the ambience played over muted bulletins.
public struct FFmpegAACEncoder: AACEncoding {
    public let executable: URL
    public init(executable: URL) { self.executable = executable }

    /// ffmpeg's AAC encoder starts with one frame of priming, and ADTS has nowhere to say so.
    public static let priming = 1024

    public func encode(_ pcm: [Float], bitrate: UInt32) throws -> (frames: [Data], delay: Int) {
        let input = pcm.withUnsafeBufferPointer { Data(buffer: $0) }
        let adts = try FFmpeg.run(executable, ["-f", "f32le", "-ar", "48000", "-ac", "2", "-i", "pipe:0",
                                               "-c:a", "aac", "-b:a", String(bitrate), "-f", "adts", "pipe:1"], input: input)
        return (FFmpeg.rawFrames(adts), Self.priming)
    }
}

/// Running ffmpeg as a filter from stdin to stdout.
public enum FFmpeg {
    public struct Failure: Error, LocalizedError {
        public let status: Int32
        public let message: String
        public var errorDescription: String? { "ffmpeg exited with \(status)\(message.isEmpty ? "" : ": \(message)")" }
    }

    static func run(_ executable: URL, _ args: [String], input: Data?) throws -> Data {
        let p = Process()
        p.executableURL = executable
        p.arguments = (input == nil ? ["-nostdin"] : []) + ["-hide_banner", "-loglevel", "error"] + args
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        p.standardInput = input == nil ? FileHandle.nullDevice : stdin
        p.standardOutput = stdout; p.standardError = stderr
        try p.run()
        // Feed stdin on another thread: ffmpeg writes output while it reads, and both pipes have small buffers.
        if let input {
            let writer = stdin.fileHandleForWriting
            DispatchQueue.global(qos: .utility).async {
                try? writer.write(contentsOf: input)
                try? writer.close()
            }
        }
        let errors = Data.Collector(stderr.fileHandleForReading)
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let message = String(decoding: errors.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(status: p.terminationStatus, message: message)
        }
        return out
    }

    /// The AAC payloads of an ADTS stream, without their headers.
    static func rawFrames(_ adts: Data) -> [Data] {
        var frames: [Data] = [], i = adts.startIndex
        while i + 7 <= adts.endIndex, adts[i] == 0xFF, adts[i + 1] & 0xF0 == 0xF0 {
            let length = (Int(adts[i + 3] & 0x03) << 11) | (Int(adts[i + 4]) << 3) | (Int(adts[i + 5]) >> 5)
            let header = adts[i + 1] & 0x01 == 1 ? 7 : 9             // 9 when a CRC follows the header
            guard length > header, i + length <= adts.endIndex else { break }
            frames.append(Data(adts[(i + header)..<(i + length)]))
            i += length
        }
        return frames
    }
}

extension PCMAudio {
    /// Splits little-endian interleaved stereo Float32 into two channels. A trailing partial frame is dropped.
    init(interleavedStereo data: Data, sampleRate: Double) {
        let n = data.count / 8
        var left = [Float](repeating: 0, count: n), right = [Float](repeating: 0, count: n)
        data.withUnsafeBytes { raw in
            for i in 0..<n {
                left[i] = Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: i * 8, as: UInt32.self)))
                right[i] = Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: i * 8 + 4, as: UInt32.self)))
            }
        }
        self.init(channels: [left, right], sampleRate: sampleRate)
    }
}

extension Data {
    /// Reads a pipe to its end on a background thread, so a chatty stderr can't fill up and stall the process.
    final class Collector: @unchecked Sendable {
        private let done = DispatchSemaphore(value: 0)
        private var result = Data()
        init(_ handle: FileHandle) {
            DispatchQueue.global(qos: .utility).async { [self] in
                result = handle.readDataToEndOfFile()
                done.signal()
            }
        }
        var data: Data { done.wait(); return result }
    }
}

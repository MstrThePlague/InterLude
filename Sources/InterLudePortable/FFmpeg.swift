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
        let p = Process()
        p.executableURL = executable
        p.arguments = (input == nil ? ["-nostdin"] : []) + ["-hide_banner", "-loglevel", "error"]
            + inputArgs + ["-f", "f32le", "-ac", "2", "-ar", String(Int(sampleRate)), "pipe:1"]
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
            throw DecodeError.ffmpeg(status: p.terminationStatus, message: message)
        }
        return PCMAudio(interleavedStereo: out, sampleRate: sampleRate)
    }

    public enum DecodeError: Error, LocalizedError {
        case ffmpeg(status: Int32, message: String)
        public var errorDescription: String? {
            switch self { case .ffmpeg(let s, let m): "ffmpeg exited with \(s)\(m.isEmpty ? "" : ": \(m)")" }
        }
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

import Foundation
import InterLudeCore
import InterLudePortable
import InterLudeHTTP

// interlude-server: InterLude without a Mac. It plays one station a fixed time behind live to any browser, starting a
// session on the first request for the stream and stopping it when nobody has asked for 10 minutes.
//
//   interlude-server [--port 8642] [--data DIR] [--stations FILE] [--web DIR] [--station ID] [--delay SECONDS] [--ffmpeg PATH]

/// Writes a line straight to stdout, unbuffered, so `docker logs` keeps up.
func log(_ line: String) { FileHandle.standardOutput.write(Data((line + "\n").utf8)) }

struct Options {
    var port = 8642
    var data = URL(fileURLWithPath: "/var/lib/interlude", isDirectory: true)
    var stations = URL(fileURLWithPath: "/usr/share/interlude/stations.json")
    var web = URL(fileURLWithPath: "/usr/share/interlude/web", isDirectory: true)
    var station = "bbc_6music"
    var delay = 60.0
    var ffmpeg: URL?

    init(_ args: [String]) throws {
        var i = 1
        func value() throws -> String {
            i += 1
            guard i < args.count else { throw UsageError("\(args[i - 1]) needs a value") }
            return args[i]
        }
        while i < args.count {
            switch args[i] {
            case "--port": guard let p = Int(try value()), (1024...65535).contains(p) else { throw UsageError("--port must be 1024 to 65535") }; port = p
            case "--data": data = URL(fileURLWithPath: try value(), isDirectory: true)
            case "--stations": stations = URL(fileURLWithPath: try value())
            case "--web": web = URL(fileURLWithPath: try value(), isDirectory: true)
            case "--station": station = try value()
            case "--delay": guard let d = Double(try value()), (20...600).contains(d) else { throw UsageError("--delay must be 20 to 600 seconds") }; delay = d
            case "--ffmpeg": ffmpeg = URL(fileURLWithPath: try value())
            default: throw UsageError("unknown option \(args[i])")
            }
            i += 1
        }
    }
}

struct UsageError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

/// Owns the one shared session, as the Mac app's Model does.
actor Controller {
    private let catalogue: Catalogue
    private let station: Station
    private let delay: Double
    private var session: PlayerSession?
    private var starting: Task<PlayerSession, Error>?
    private var lastRequest = Date()

    init(catalogue: Catalogue, station: Station, delay: Double) {
        self.catalogue = catalogue; self.station = station; self.delay = delay
    }

    /// Answers a request under /stream/, starting the session if it isn't running.
    func stream(_ relative: String) async -> HTTPResponse {
        lastRequest = Date()
        do { return try await running().respond(to: relative) }
        catch { return HTTPResponse(status: 503, contentType: "text/plain", body: Data("\(error.localizedDescription)\n".utf8), noCache: true) }
    }

    private func running() async throws -> PlayerSession {
        if let session { return session }
        if let starting { return try await starting.value }
        let (catalogue, station, delay) = (catalogue, station, delay)
        let t = Task {
            var settings = SessionSettings(station: station, profile: StationProfile.load(station))
            settings.delaySeconds = delay
            // No detection on the server yet: the classifier, encoder and transcriber arrive in later milestones.
            settings.muteNews = false
            let s = PlayerSession(catalogue: catalogue, settings: settings, token: "stream",
                                  cacheRoot: try AppPaths.cacheDirectory(),
                                  eventLog: try AppPaths.supportDirectory().appendingPathComponent("events.jsonl"))
            try await s.start()
            return s
        }
        starting = t
        defer { starting = nil }
        log("starting \(station.name), \(Int(delay)) s behind live")
        let s = try await t.value
        session = s
        log("session running")
        return s
    }

    func stopIfIdle(after limit: TimeInterval) async {
        guard let s = session, Date().timeIntervalSince(lastRequest) > limit else { return }
        await s.stop()
        session = nil
        log("stopped \(station.name): no requests for \(Int(limit / 60)) minutes")
    }
}

/// Files from the web directory. Only names in it are served, never paths.
func staticFile(_ name: String, in dir: URL) -> HTTPResponse {
    let types = ["html": "text/html; charset=utf-8", "js": "text/javascript", "css": "text/css", "png": "image/png", "svg": "image/svg+xml"]
    guard !name.contains("/"), !name.hasPrefix("."), let type = types[(name as NSString).pathExtension],
          let body = try? Data(contentsOf: dir.appendingPathComponent(name)) else { return .notFound }
    return HTTPResponse(contentType: type, body: body)
}

do {
    let opt = try Options(CommandLine.arguments)
    guard let ffmpeg = opt.ffmpeg ?? FFmpegDecoder.find() else { throw UsageError("ffmpeg not found; install it or pass --ffmpeg") }
    Platform.install(.portable(ffmpeg: ffmpeg))
    AppPaths.root = opt.data
    let catalogue = try Catalogue.load(from: Catalogue.editableURL(bundled: opt.stations))
    guard let station = catalogue.station(opt.station) else { throw UsageError("no station \(opt.station) in stations.json") }
    let controller = Controller(catalogue: catalogue, station: station, delay: opt.delay)

    Task {
        while true {
            try? await Task.sleep(for: .seconds(60))
            await controller.stopIfIdle(after: 600)
        }
    }

    let web = opt.web
    let server = HTTPServer(port: opt.port) { req in
        switch req.path {
        case "/": return staticFile("index.html", in: web)
        case "/healthz": return HTTPResponse(contentType: "text/plain", body: Data("ok\n".utf8), noCache: true)
        case let p where p.hasPrefix("/stream/"): return await controller.stream(String(p.dropFirst("/stream/".count)))
        default: return staticFile(String(req.path.dropFirst()), in: web)
        }
    }
    try await server.run { log("InterLude listening on port \(opt.port), data in \(opt.data.path)") }
} catch let e as UsageError {
    FileHandle.standardError.write(Data("interlude-server: \(e)\n".utf8))
    exit(2)
} catch {
    FileHandle.standardError.write(Data("interlude-server: \(error.localizedDescription)\n".utf8))
    exit(1)
}

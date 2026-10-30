import Foundation
import InterLudeCore
import InterLudePortable
import InterLudeHTTP
import InterLudeML
import InterLudeCast

// interlude-server: InterLude without a Mac. The web app at /app/<token>/ plays, controls and configures one shared
// session, which starts when a browser asks for the stream and stops when nobody has for 10 minutes.
//
//   interlude-server [--port 8642] [--data DIR] [--config DIR] [--stations FILE] [--web DIR] [--models DIR] [--ambience DIR]
//                    [--ffmpeg PATH] [--keep-running] [--cast-host ADDRESS]
//   interlude-server --check AUDIOFILE [--models DIR]     runs both models on a file, prints what they hear, and exits
//
// --keep-running (or INTERLUDE_KEEP_RUNNING=1) runs the live session all the time, for comparing with the Mac.
// --cast-host is the address Cast speakers fetch the stream from; by default, this machine's LAN address.
//
// --config (default /etc/interlude) holds what can change while the server runs, all optional: stations.json, used in
// place of the list kept in --data, and web/ with index.html, app.css or app.js to use in place of the built-in ones.
// Both are read again when they change (scripts/push-config.sh puts them there), and open pages reload themselves.
//
// --models holds yamnet.onnx and its class map (scripts/yamnet/convert.sh), and whisper.cpp's ggml-base.en.bin for the
// newsreader's opening and sign-off. Without YAMNet the server plays but can't recognise bulletins.

/// Writes a line straight to stdout, unbuffered, so `docker logs` keeps up.
func log(_ line: String) { FileHandle.standardOutput.write(Data((line + "\n").utf8)) }

struct Options {
    var port = 8642
    var data = URL(fileURLWithPath: "/var/lib/interlude", isDirectory: true)
    var config = URL(fileURLWithPath: "/etc/interlude", isDirectory: true)
    var stations = URL(fileURLWithPath: "/usr/share/interlude/stations.json")
    var web = URL(fileURLWithPath: "/usr/share/interlude/web", isDirectory: true)
    var models = URL(fileURLWithPath: "/usr/share/interlude/models", isDirectory: true)
    var ambience = URL(fileURLWithPath: "/usr/share/interlude/ambience", isDirectory: true)
    var ffmpeg: URL?
    var keepRunning = ProcessInfo.processInfo.environment["INTERLUDE_KEEP_RUNNING"] == "1"
    var castHost = ProcessInfo.processInfo.environment["INTERLUDE_CAST_HOST"]
    var check: URL?

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
            case "--config": config = URL(fileURLWithPath: try value(), isDirectory: true)
            case "--stations": stations = URL(fileURLWithPath: try value())
            case "--web": web = URL(fileURLWithPath: try value(), isDirectory: true)
            case "--models": models = URL(fileURLWithPath: try value(), isDirectory: true)
            case "--ambience": ambience = URL(fileURLWithPath: try value(), isDirectory: true)
            case "--ffmpeg": ffmpeg = URL(fileURLWithPath: try value())
            case "--keep-running": keepRunning = true
            case "--cast-host": castHost = try value()
            case "--check": check = URL(fileURLWithPath: try value())
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

/// Files from the web directory: hls.js, the QR code library and the icons. Only names in it are served, never paths.
func staticFile(_ name: String, in dir: URL) -> HTTPResponse {
    let types = ["js": "text/javascript", "png": "image/png", "css": "text/css"]
    guard !name.contains("/"), !name.hasPrefix("."), let type = types[(name as NSString).pathExtension],
          let body = try? Data(contentsOf: dir.appendingPathComponent(name)) else { return .notFound }
    return HTTPResponse(contentType: type, body: body)
}

/// Whether a command comes from the app's own page. Browsers send Origin with a cross-site POST, so a page elsewhere
/// can't press the buttons; a client that sends no Origin, like curl, has to know the token anyway.
func sameOrigin(_ req: HTTPRequest) -> Bool {
    guard let origin = req.headers["origin"] else { return true }
    guard let u = URLComponents(string: origin), let host = u.host else { return false }
    let authority = u.port.map { "\(host):\($0)" } ?? host
    return [req.headers["host"], req.headers["x-forwarded-host"]].contains(authority)
}

/// The station list: the config folder's if it has one, otherwise the one kept in the data folder, with stations new
/// to the bundled list added either way.
func loadStations(bundled: URL, config: URL) throws -> Catalogue {
    let editable = FileManager.default.fileExists(atPath: config.path) ? config : nil
    let c = try Catalogue.loadEditable(bundled: bundled, editable: editable)
    log("\(c.stations.count) stations from \(try (editable ?? Catalogue.editableURL(bundled: bundled)).path)")
    return c
}

/// Reads the station list again whenever it changes, or one appears in or goes from the config folder, and hands it to
/// the controller.
func watchStations(bundled: URL, config: URL, controller: Controller) throws {
    let files = [config, try Catalogue.editableURL(bundled: bundled), bundled]
    Task {
        var last = FileStamp.of(files)
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3))
            let now = FileStamp.of(files)
            guard now != last else { continue }
            last = now
            do { await controller.use(try loadStations(bundled: bundled, config: config)) }
            catch { log("couldn't read the changed station list, so the old one stays: \(error)") }
        }
    }
}

func text(_ status: Int, _ s: String) -> HTTPResponse {
    HTTPResponse(status: status, contentType: "text/plain; charset=utf-8", body: Data(s.utf8), noCache: true)
}

do {
    let opt = try Options(CommandLine.arguments)
    guard let ffmpeg = opt.ffmpeg ?? FFmpegDecoder.find() else { throw UsageError("ffmpeg not found; install it or pass --ffmpeg") }
    var platform = Platform.portable(ffmpeg: ffmpeg)
    var detects = false
    do {
        // One model for every session: loading takes a moment, and ONNX Runtime sessions can be shared.
        let yamnet = try YAMNetClassifier(directory: opt.models)
        platform.makeClassifier = { yamnet }
        detects = true
        log("YAMNet loaded from \(opt.models.path)")
    } catch {
        log("no sound classifier (\(error.localizedDescription)); news won't be recognised")
    }
    let whisperModel = opt.models.appendingPathComponent("ggml-base.en.bin")
    if FileManager.default.fileExists(atPath: whisperModel.path) {
        // One transcriber, so the model loads once; it runs one bulletin at a time.
        let whisper = WhisperTranscriber(model: whisperModel)
        platform.makeTranscriber = { whisper }
        log("whisper model at \(whisperModel.path)")
    }
    Platform.install(platform)
    if let file = opt.check {
        let audio = try platform.decoder.read(contentsOf: file)
        log(String(format: "%@: %.1f s at %.0f Hz", file.lastPathComponent, audio.duration, audio.sampleRate))
        if detects {
            for sc in try platform.makeClassifier().classify([audio]) {
                log(String(format: "  %5.1f s  speech %.2f  music %.2f", sc.time, sc.speech, sc.music))
            }
        }
        if let stt = platform.makeTranscriber?() {
            guard await stt.prepare(install: false) else { throw UsageError("the whisper model didn't load") }
            let phrases = try await stt.transcribe(samples: audio.channels[0], sampleRate: audio.sampleRate)
            for p in phrases { log(String(format: "  %5.1f s  %@", p.start, p.text)) }
            log("sign-off: \(NewsPhrases.signOff(in: phrases, after: 0).map { String(format: "at %.1f s", $0) } ?? "not heard")")
        }
        exit(0)
    }
    AppPaths.root = opt.data
    // A station list in the config folder replaces the one kept in the data folder, and new bundled stations join it.
    let configStations = opt.config.appendingPathComponent("stations.json")
    let catalogue = try loadStations(bundled: opt.stations, config: configStations)
    let controller = Controller(catalogue: catalogue, settingsURL: try AppPaths.supportDirectory().appendingPathComponent("settings.json"),
                                detects: detects, ambienceDirectory: opt.ambience, keepRunning: opt.keepRunning,
                                castBase: (opt.castHost ?? LocalAddress.lan()).map { "http://\($0):\(opt.port)" })
    if opt.keepRunning { log("keeping the live session running") }
    let web = opt.web
    let icon = (try? Data(contentsOf: web.appendingPathComponent("icon.png"))) ?? Data()
    let touchIcon = (try? Data(contentsOf: web.appendingPathComponent("touch-icon.png"))) ?? Data()
    let prefix = RemoteRoutes.appPrefix
    let files = WebFiles(folders: [opt.config.appendingPathComponent("web", isDirectory: true), web])
    await controller.setPageVersion { files.version }
    for name in WebFiles.names where files.url(name)?.deletingLastPathComponent().standardizedFileURL != web.standardizedFileURL {
        log("\(name) from \(files.url(name)?.path ?? "nowhere")")
    }
    let oldPage = opt.data.appendingPathComponent("web/index.html")
    if FileManager.default.fileExists(atPath: oldPage.path) {
        log("ignoring \(oldPage.path), from an older push-web.sh: pages now come from \(opt.config.path)/web")
    }
    try watchStations(bundled: opt.stations, config: configStations, controller: controller)

    let server = HTTPServer(port: opt.port, events: { req in
        guard RemoteRoutes.route(req, token: await controller.token, prefix: prefix) == .events else { return nil }
        return controller.events()
    }) { req in
        if req.path == "/healthz" { return text(200, "ok\n") }
        if req.path.hasPrefix("/static/") { return staticFile(String(req.path.dropFirst("/static/".count)), in: web) }
        if req.path.hasPrefix("/stream/") { return await controller.stream(String(req.path.dropFirst("/stream/".count))) }
        let token = await controller.token
        guard let route = RemoteRoutes.route(req, token: token, prefix: prefix) else {
            return req.path == "/" ? text(404, "InterLude: open the link shown in the server's log.\n") : .notFound
        }
        switch route {
        case .page: return RemoteRoutes.page(token: token, touchIcon: touchIcon, prefix: prefix, files: files)
        case .asset(let name): return RemoteRoutes.asset(name, files: files)
        case .manifest: return RemoteRoutes.manifest
        case .icon: return HTTPResponse(contentType: "image/png", body: icon)
        case .qr: return .notFound      // the page draws its own
        case .state, .events: return RemoteRoutes.json(await controller.state())
        case .command(let c):
            guard !c.macOnly else { return .notFound }
            guard sameOrigin(req) else { return text(403, "Commands must come from InterLude's own page.\n") }
            await controller.perform(c)
            return RemoteRoutes.json(await controller.state())
        }
    }
    let link = RemoteRoutes.pagePath(token: await controller.token, prefix: prefix)
    try await server.run {
        log("InterLude listening on port \(opt.port), data in \(opt.data.path)")
        log("Open the app at http://\(ProcessInfo.processInfo.hostName):\(opt.port)\(link) (or this host's address)")
    }
} catch let e as UsageError {
    FileHandle.standardError.write(Data("interlude-server: \(e)\n".utf8))
    exit(2)
} catch {
    FileHandle.standardError.write(Data("interlude-server: \(error.localizedDescription)\n".utf8))
    exit(1)
}

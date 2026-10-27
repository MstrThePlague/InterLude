import Foundation
import InterLudeCore
import InterLudePortable
import InterLudeHTTP
import InterLudeML

// interlude-server: InterLude without a Mac. The web app at /app/<token>/ plays, controls and configures one shared
// session, which starts when a browser asks for the stream and stops when nobody has for 10 minutes.
//
//   interlude-server [--port 8642] [--data DIR] [--stations FILE] [--web DIR] [--models DIR] [--ambience DIR] [--ffmpeg PATH]
//
// --models holds yamnet.onnx and its class map (scripts/yamnet/convert.sh), and whisper.cpp's ggml-base.en.bin for the
// newsreader's opening and sign-off. Without YAMNet the server plays but can't recognise bulletins.

/// Writes a line straight to stdout, unbuffered, so `docker logs` keeps up.
func log(_ line: String) { FileHandle.standardOutput.write(Data((line + "\n").utf8)) }

struct Options {
    var port = 8642
    var data = URL(fileURLWithPath: "/var/lib/interlude", isDirectory: true)
    var stations = URL(fileURLWithPath: "/usr/share/interlude/stations.json")
    var web = URL(fileURLWithPath: "/usr/share/interlude/web", isDirectory: true)
    var models = URL(fileURLWithPath: "/usr/share/interlude/models", isDirectory: true)
    var ambience = URL(fileURLWithPath: "/usr/share/interlude/ambience", isDirectory: true)
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
            case "--models": models = URL(fileURLWithPath: try value(), isDirectory: true)
            case "--ambience": ambience = URL(fileURLWithPath: try value(), isDirectory: true)
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
    AppPaths.root = opt.data
    let catalogue = try Catalogue.load(from: Catalogue.editableURL(bundled: opt.stations))
    let controller = Controller(catalogue: catalogue, settingsURL: try AppPaths.supportDirectory().appendingPathComponent("settings.json"),
                                detects: detects, ambienceDirectory: opt.ambience)
    let web = opt.web
    let icon = (try? Data(contentsOf: web.appendingPathComponent("icon.png"))) ?? Data()
    let touchIcon = (try? Data(contentsOf: web.appendingPathComponent("touch-icon.png"))) ?? Data()
    let prefix = RemoteRoutes.appPrefix

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
        case .page: return RemoteRoutes.page(token: token, touchIcon: touchIcon, prefix: prefix)
        case .manifest: return RemoteRoutes.manifest
        case .icon: return HTTPResponse(contentType: "image/png", body: icon)
        case .state, .events: return RemoteRoutes.json(await controller.state())
        case .command(let c):
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

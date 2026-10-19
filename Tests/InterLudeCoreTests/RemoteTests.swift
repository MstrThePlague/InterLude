import Testing
import Foundation
@testable import InterLudeCore

@Suite struct RemoteTests {
    let token = "abc123"
    private func route(_ method: String, _ target: String) -> RemoteRoute? {
        RemoteRoutes.route(HTTPRequest(requestLine: "\(method) \(target) HTTP/1.1")!, token: token)
    }

    @Test func parsesRequestLine() {
        let r = HTTPRequest(requestLine: "POST /remote/x/api/volume?v=0.4&x=a%20b HTTP/1.1")
        #expect(r?.method == "POST")
        #expect(r?.path == "/remote/x/api/volume")
        #expect(r?.query == ["v": "0.4", "x": "a b"])
        #expect(HTTPRequest(requestLine: "DELETE /x HTTP/1.1") == nil)
        #expect(HTTPRequest(requestLine: "GET") == nil)
    }

    @Test func pageAndFiles() {
        #expect(route("GET", "/remote/abc123/") == .page)
        #expect(route("GET", "/remote/abc123") == .page)
        #expect(route("GET", "/remote/abc123/manifest.webmanifest") == .manifest)
        #expect(route("GET", "/remote/abc123/icon.png") == .icon)
        #expect(route("GET", "/remote/abc123/api/state") == .state)
    }

    @Test func needsTheToken() {
        #expect(route("GET", "/remote/wrong/") == nil)
        #expect(route("GET", "/remote/abc1234/") == nil)
        #expect(route("GET", "/remote/") == nil)
        #expect(RemoteRoutes.route(HTTPRequest(path: "/remote//"), token: "") == nil)
    }

    @Test func commandsOnlyByPost() {
        #expect(route("GET", "/remote/abc123/api/toggle") == nil)
        #expect(route("POST", "/remote/abc123/api/toggle") == .command(.toggle))
        #expect(route("POST", "/remote/abc123/api/station?id=bbc_6music") == .command(.station("bbc_6music")))
        #expect(route("POST", "/remote/abc123/api/station") == nil)
        #expect(route("POST", "/remote/abc123/api/speaker?id=cast:Kitchen") == .command(.speaker("cast:Kitchen")))
        #expect(route("POST", "/remote/abc123/api/notnews") == .command(.notNews))
        #expect(route("POST", "/remote/abc123/api/gotthrough") == .command(.newsGotThrough))
        #expect(route("POST", "/remote/abc123/api/reboot") == nil)
        #expect(route("POST", "/remote/abc123/") == nil)
    }

    @Test func volumeIsClamped() {
        #expect(route("POST", "/remote/abc123/api/volume?v=0.25") == .command(.volume(0.25)))
        #expect(route("POST", "/remote/abc123/api/volume?v=7") == .command(.volume(1)))
        #expect(route("POST", "/remote/abc123/api/volume?v=-1") == .command(.volume(0)))
        #expect(route("POST", "/remote/abc123/api/volume?v=nan") == nil)
        #expect(route("POST", "/remote/abc123/api/volume") == nil)
    }

    @Test func earlierCommands() {
        #expect(route("POST", "/remote/abc123/api/mode?m=earlier") == .command(.earlier(true)))
        #expect(route("POST", "/remote/abc123/api/mode?m=live") == .command(.earlier(false)))
        #expect(route("POST", "/remote/abc123/api/mode?m=later") == nil)
        #expect(route("POST", "/remote/abc123/api/mode") == nil)
        #expect(route("GET", "/remote/abc123/api/mode?m=earlier") == nil)
        #expect(route("POST", "/remote/abc123/api/schedule") == .command(.reloadSchedule))
        #expect(route("GET", "/remote/abc123/api/schedule") == nil)
    }

    @Test func daysStayWithinTheLastMonth() {
        #expect(route("POST", "/remote/abc123/api/day?d=0") == .command(.day(0)))
        #expect(route("POST", "/remote/abc123/api/day?d=\(OnDemand.days - 1)") == .command(.day(OnDemand.days - 1)))
        #expect(route("POST", "/remote/abc123/api/day?d=\(OnDemand.days)") == nil)
        #expect(route("POST", "/remote/abc123/api/day?d=-1") == nil)
        #expect(route("POST", "/remote/abc123/api/day?d=1.5") == nil)
        #expect(route("POST", "/remote/abc123/api/day") == nil)
        #expect(route("GET", "/remote/abc123/api/day?d=1") == nil)
    }

    @Test func programmesNeedAPlainID() {
        #expect(route("POST", "/remote/abc123/api/programme?id=p0lxz91z") == .command(.programme("p0lxz91z")))
        #expect(route("GET", "/remote/abc123/api/programme?id=p0lxz91z") == nil)
        #expect(route("POST", "/remote/abc123/api/programme") == nil)
        #expect(route("POST", "/remote/abc123/api/programme?id=") == nil)
        #expect(route("POST", "/remote/abc123/api/programme?id=a%2Fb") == nil)
        #expect(route("POST", "/remote/abc123/api/programme?id=%3Cb%3E") == nil)
        #expect(route("POST", "/remote/abc123/api/programme?id=\(String(repeating: "a", count: 33))") == nil)
    }

    @Test func stateCarriesEarlier() throws {
        var s = RemoteState()
        s.mode = "earlier"
        var e = RemoteState.EarlierItem()
        e.programmes = [.init(id: "p1", title: "T", detail: "2 h 0 min", time: "10:00", image: nil, playable: true, onNow: false, chosen: true, playing: false)]
        s.earlier = e
        s.replay = .init(heard: 0.3, analysed: 0.4, news: [[0, 0.02]], position: "36:00 of 2 h 0 min", skipped: nil)
        let back = try JSONDecoder().decode(RemoteState.self, from: RemoteRoutes.json(s).body)
        #expect(back == s)
        #expect(back.earlier?.lastDay == OnDemand.days - 1)
    }

    @Test func pageCarriesItsBase() {
        let html = String(decoding: RemoteRoutes.page(token: token).body, as: UTF8.self)
        #expect(html.contains(#"<base href="/remote/abc123/">"#))
        #expect(!html.contains("__BASE__"))
    }

    @Test func tokensAreLongAndFresh() {
        let a = RemoteRoutes.newToken(), b = RemoteRoutes.newToken()
        #expect(a.count == 32 && a != b)
    }

    /// The real server, over loopback: a POST reaches the handler with its query, and other methods are refused.
    @Test func serverAcceptsPost() async throws {
        let port = UInt16.random(in: 40000...60000)
        let server = LocalServer(port: port) { req in
            HTTPResponse(contentType: "text/plain", body: Data("\(req.method) \(req.path) \(req.query["v"] ?? "-")".utf8))
        }
        try server.start()
        defer { server.stop() }
        try await Task.sleep(for: .milliseconds(200))
        var post = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/remote/t/api/volume?v=0.5")!)
        post.httpMethod = "POST"
        let (body, _) = try await URLSession.shared.data(for: post)
        #expect(String(decoding: body, as: UTF8.self) == "POST /remote/t/api/volume 0.5")
        var put = post; put.httpMethod = "PUT"
        let (_, r) = try await URLSession.shared.data(for: put)
        #expect((r as? HTTPURLResponse)?.statusCode == 405)
    }
}

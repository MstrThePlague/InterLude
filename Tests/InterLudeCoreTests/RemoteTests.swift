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

    @Test func recognisesTailscaleAddresses() {
        #expect(Tailnet.isTailscale("100.100.1.2"))
        #expect(Tailnet.isTailscale("100.64.0.1"))
        #expect(Tailnet.isTailscale("100.127.255.254"))
        #expect(!Tailnet.isTailscale("100.128.0.1"))
        #expect(!Tailnet.isTailscale("100.63.0.1"))
        #expect(!Tailnet.isTailscale("192.168.1.20"))
        #expect(!Tailnet.isTailscale("100.100.1"))
    }

    @Test func recognisesMagicDNSNames() {
        #expect(Tailnet.magicDNSName("my-mac.tailnet-1234.ts.net.") == "my-mac.tailnet-1234.ts.net")
        #expect(Tailnet.magicDNSName("My-Mac.Tailnet-1234.TS.NET") == "my-mac.tailnet-1234.ts.net")
        #expect(Tailnet.magicDNSName("2.1.100.100.in-addr.arpa") == nil)
        #expect(Tailnet.magicDNSName("tailnet-1234.ts.net") == nil)
        #expect(Tailnet.magicDNSName("a.b.tailnet-1234.ts.net") == nil)
        #expect(Tailnet.magicDNSName("mac..ts.net") == nil)
        #expect(Tailnet.magicDNSName("mac.local") == nil)
    }

    @Test func readsTheNameFromTailscaleStatus() {
        let json = #"{"BackendState":"Running","Self":{"HostName":"my-mac","DNSName":"my-mac.tailnet-1234.ts.net.","TailscaleIPs":["100.100.1.2"]}}"#
        #expect(Tailnet.magicDNSName(statusJSON: Data(json.utf8)) == "my-mac.tailnet-1234.ts.net")
        #expect(Tailnet.magicDNSName(statusJSON: Data(#"{"BackendState":"Stopped","Self":{"DNSName":""}}"#.utf8)) == nil)
        #expect(Tailnet.magicDNSName(statusJSON: Data(#"{"BackendState":"NoState"}"#.utf8)) == nil)
        #expect(Tailnet.magicDNSName(statusJSON: Data("not json".utf8)) == nil)
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

    @Test func serverRoutesLiveUnderApp() {
        let app = { (method: String, target: String) in
            RemoteRoutes.route(HTTPRequest(requestLine: "\(method) \(target) HTTP/1.1")!, token: self.token, prefix: RemoteRoutes.appPrefix)
        }
        #expect(app("GET", "/app/abc123/") == .page)
        #expect(app("GET", "/app/abc123/api/events") == .events)
        #expect(app("POST", "/app/abc123/api/events") == nil)
        #expect(app("POST", "/app/abc123/api/play") == .command(.play))
        #expect(app("GET", "/remote/abc123/") == nil)
        #expect(route("GET", "/app/abc123/") == nil)
        let html = String(decoding: RemoteRoutes.page(token: token, prefix: RemoteRoutes.appPrefix).body, as: UTF8.self)
        #expect(html.contains(#"<base href="/app/abc123/">"#))
    }

    @Test func settingsAreChecked() {
        #expect(route("POST", "/remote/abc123/api/setting?k=delay&v=90") == .command(.setting(.delay(90))))
        #expect(route("POST", "/remote/abc123/api/setting?k=delay&v=47") == .command(.setting(.delay(45))))
        #expect(route("POST", "/remote/abc123/api/setting?k=delay&v=20") == nil)
        #expect(route("POST", "/remote/abc123/api/setting?k=delay&v=601") == nil)
        #expect(route("POST", "/remote/abc123/api/setting?k=delay&v=nan") == nil)
        #expect(route("POST", "/remote/abc123/api/setting?k=muteNews&v=0") == .command(.setting(.muteNews(false))))
        #expect(route("POST", "/remote/abc123/api/setting?k=shadowMode&v=yes") == nil)
        #expect(route("POST", "/remote/abc123/api/setting?k=jingleOnly&v=1") == .command(.setting(.jingleOnly(true))))
        #expect(route("POST", "/remote/abc123/api/setting?k=forgetJingle") == .command(.setting(.forgetJingle)))
        #expect(route("POST", "/remote/abc123/api/setting?k=bitrate&v=128") == .command(.setting(.bitrate(128_000))))
        #expect(route("POST", "/remote/abc123/api/setting?k=bitrate&v=96") == nil)
        #expect(route("POST", "/remote/abc123/api/setting?k=ambience&v=ocean") == .command(.setting(.ambience("ocean"))))
        #expect(route("POST", "/remote/abc123/api/setting?k=ambience&v=..%2Fetc") == nil)
        #expect(route("POST", "/remote/abc123/api/setting?k=port&v=80") == nil)
        #expect(route("GET", "/remote/abc123/api/setting?k=muteNews&v=0") == nil)
        #expect(route("POST", "/remote/abc123/api/resetlink") == .command(.resetLink))
        #expect(route("GET", "/remote/abc123/api/resetlink") == nil)
    }

    @Test func pageCarriesItsBase() {
        let html = String(decoding: RemoteRoutes.page(token: token).body, as: UTF8.self)
        #expect(html.contains(#"<base href="/remote/abc123/">"#))
        #expect(!html.contains("__BASE__"))
    }

    /// iOS 27 shows a letter tile for a fetched apple-touch-icon, so the page carries it inline.
    @Test func pageCarriesItsTouchIcon() {
        let html = String(decoding: RemoteRoutes.page(token: token, touchIcon: Data([1, 2, 3])).body, as: UTF8.self)
        #expect(html.contains(#"<link rel="apple-touch-icon" sizes="180x180" href="data:image/png;base64,AQID">"#))
        #expect(html.contains(#"<link rel="icon" href="icon.png">"#))
        #expect(!html.contains("__TOUCH_ICON__"))
        let plain = String(decoding: RemoteRoutes.page(token: token).body, as: UTF8.self)
        #expect(plain.contains(#"<link rel="apple-touch-icon" sizes="180x180" href="icon.png">"#))
    }

    @Test func tokensAreLongAndFresh() {
        let a = RemoteRoutes.newToken(), b = RemoteRoutes.newToken()
        #expect(a.count == 32 && a != b)
    }
}

import Testing
import Foundation
import InterLudeCore
import InterLudeApple

@Suite struct LocalServerTests {
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

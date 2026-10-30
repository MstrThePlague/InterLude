import Foundation

public struct HTTPResponse: Sendable {
    public var status: Int
    public var contentType: String
    public var body: Data
    public var noCache = false
    public init(status: Int = 200, contentType: String, body: Data, noCache: Bool = false) {
        self.status = status; self.contentType = contentType; self.body = body; self.noCache = noCache
    }
    public static let notFound = HTTPResponse(status: 404, contentType: "text/plain", body: Data("not found".utf8))
}

public struct HTTPRequest: Sendable {
    public var method: String
    public var path: String
    public var query: [String: String]
    /// Header fields with lowercased names. The Mac's server leaves them empty.
    public var headers: [String: String] = [:]
    /// Whether it came from this machine. The Mac's server sets it from the connection, so a page can't claim it.
    public var fromLoopback = false
    public init(method: String = "GET", path: String, query: [String: String] = [:], headers: [String: String] = [:]) {
        self.method = method; self.path = path; self.query = query; self.headers = headers
    }
    /// Parses the request line, such as `POST /a/b?x=1 HTTP/1.1`. Only GET, HEAD and POST are accepted.
    public init?(requestLine: String) {
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, ["GET", "HEAD", "POST"].contains(parts[0]),
              let c = URLComponents(string: String(parts[1])) else { return nil }
        method = String(parts[0]); path = c.path
        query = Dictionary((c.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, b in b })
    }
}

//  HTTP.swift
//  InterLudeCore
//
//  The request and response types every web server in InterLude speaks: the Mac's LocalServer and the Linux
//  server's Hummingbird bridge both translate to and from these, so the routes are written once.

import Foundation

/// An answer to an HTTP request.
public struct HTTPResponse: Sendable {
    public var status: Int
    public var contentType: String
    public var body: Data
    /// Whether to send `Cache-Control: no-cache`, for anything that changes from one request to the next.
    public var noCache = false
    /// A body with no end, sent as it arrives in place of `body`, such as the AAC stream a Sonos speaker plays.
    public var stream: AsyncStream<Data>?

    public init(status: Int = 200, contentType: String, body: Data, noCache: Bool = false) {
        self.status = status; self.contentType = contentType; self.body = body; self.noCache = noCache
    }

    /// A streaming answer, never cached.
    public init(contentType: String, stream: AsyncStream<Data>) {
        status = 200; self.contentType = contentType; body = Data(); noCache = true; self.stream = stream
    }

    public static let notFound = HTTPResponse(status: 404, contentType: "text/plain", body: Data("not found".utf8))
}

/// The parts of an HTTP request that InterLude's routes look at. Requests carry no body: commands put their
/// arguments in the query string.
public struct HTTPRequest: Sendable {
    public var method: String
    public var path: String
    public var query: [String: String]
    /// Header fields, keyed by lower-case name. The Mac's server leaves this empty.
    public var headers: [String: String] = [:]
    /// Whether the request came from this machine. Servers set it from the connection, never from anything the
    /// client sends, so a page can't claim it.
    public var fromLoopback = false

    public init(method: String = "GET", path: String, query: [String: String] = [:], headers: [String: String] = [:]) {
        self.method = method; self.path = path; self.query = query; self.headers = headers
    }

    /// Parses a request line such as `POST /a/b?x=1 HTTP/1.1`.
    ///
    /// - Returns: Nil for a malformed line, or a method other than GET, HEAD and POST.
    public init?(requestLine: String) {
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, ["GET", "HEAD", "POST"].contains(parts[0]),
              let target = URLComponents(string: String(parts[1])) else { return nil }
        method = String(parts[0]); path = target.path
        // A repeated parameter keeps its last value.
        query = Dictionary((target.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
    }
}

import Foundation
import Network
import InterLudeCore

/// Finds Sonos speakers by their Bonjour service and yields their addresses. Any one of them describes the
/// household's rooms and groups (`Sonos.groups`), so these are only where to ask.
public final class SonosDiscovery: @unchecked Sendable {
    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "interlude.sonos.discovery")
    public let updates: AsyncStream<[String]>
    private let cont: AsyncStream<[String]>.Continuation
    /// Counts browse changes, so the addresses for an older one, still being looked up, are thrown away.
    private var change = 0      // only touched on `queue`

    public init() {
        (updates, cont) = AsyncStream.makeStream(of: [String].self, bufferingPolicy: .bufferingNewest(1))
    }

    public func start() {
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: Sonos.service, domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            change += 1
            let mine = change
            Task {
                var hosts: [String] = []
                for r in results {
                    // Speakers put their description's address in the TXT record; look the service up if one doesn't.
                    if case .bonjour(let txt) = r.metadata, let loc = txt["location"], let h = URLComponents(string: loc)?.host { hosts.append(h) }
                    else if let h = await Self.resolve(r.endpoint) { hosts.append(h) }
                }
                let latest = Array(Set(hosts)).sorted()
                self.queue.async { if mine == self.change { self.cont.yield(latest) } }
            }
        }
        b.start(queue: queue)
        browser = b
    }

    public func stop() { browser?.cancel(); browser = nil }

    /// The IPv4 address behind a Bonjour service, found by connecting to it. Nil if that takes more than 4 seconds.
    static func resolve(_ endpoint: NWEndpoint) async -> String? {
        let params = NWParameters.tcp
        (params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        let c = NWConnection(to: endpoint, using: params)
        let queue = DispatchQueue(label: "interlude.sonos.resolve")
        return await withCheckedContinuation { (k: CheckedContinuation<String?, Never>) in
            final class Once: @unchecked Sendable { var done = false }
            let once = Once()      // only touched on `queue`
            @Sendable func finish(_ host: String?) {
                guard !once.done else { return }
                once.done = true; c.cancel(); k.resume(returning: host)
            }
            c.stateUpdateHandler = { st in
                switch st {
                case .ready:
                    if case .hostPort(let host, _) = c.currentPath?.remoteEndpoint { finish("\(host)".components(separatedBy: "%")[0]) } else { finish(nil) }
                case .failed, .cancelled: finish(nil)
                default: break
                }
            }
            c.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 4) { finish(nil) }
        }
    }
}

//  SonosDiscovery.swift
//  InterLudeApple
//
//  Finds Sonos speakers on the Mac with Bonjour. The Linux server does the same with its own multicast DNS watcher
//  (InterLudeCast/MDNS.swift).

import Foundation
import Network
import InterLudeCore

/// Finds Sonos speakers by their Bonjour service and yields their addresses. Any one of them describes the
/// household's rooms and groups (`Sonos.groups`), so these are only where to ask.
public final class SonosDiscovery: @unchecked Sendable {
    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "interlude.sonos.discovery")
    /// The speakers' addresses, sorted, each time the browse results change.
    public let updates: AsyncStream<[String]>
    private let continuation: AsyncStream<[String]>.Continuation
    /// Counts browse changes, so the addresses for an older one, still being looked up, are thrown away.
    private var change = 0      // only touched on `queue`

    public init() {
        (updates, continuation) = AsyncStream.makeStream(of: [String].self, bufferingPolicy: .bufferingNewest(1))
    }

    public func start() {
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Sonos.service, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            change += 1
            let mine = change
            Task {
                var hosts: [String] = []
                for result in results {
                    // Speakers put their description's address in the TXT record; look the service up if one doesn't.
                    if case .bonjour(let txt) = result.metadata, let location = txt["location"], let host = URLComponents(string: location)?.host {
                        hosts.append(host)
                    } else if let host = await Self.resolve(result.endpoint) { hosts.append(host) }
                }
                let latest = Array(Set(hosts)).sorted()
                self.queue.async { if mine == self.change { self.continuation.yield(latest) } }
            }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    public func stop() { browser?.cancel(); browser = nil }

    /// The IPv4 address behind a Bonjour service, found by connecting to it. Nil if that takes more than 4 seconds.
    static func resolve(_ endpoint: NWEndpoint) async -> String? {
        let params = NWParameters.tcp
        (params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        let connection = NWConnection(to: endpoint, using: params)
        let queue = DispatchQueue(label: "interlude.sonos.resolve")
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            final class Once: @unchecked Sendable { var done = false }
            let once = Once()      // only touched on `queue`
            @Sendable func finish(_ host: String?) {
                guard !once.done else { return }
                once.done = true; connection.cancel(); continuation.resume(returning: host)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    // Drop any interface suffix, such as %en0.
                    if case .hostPort(let host, _) = connection.currentPath?.remoteEndpoint { finish("\(host)".components(separatedBy: "%")[0]) } else { finish(nil) }
                case .failed, .cancelled: finish(nil)
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 4) { finish(nil) }
        }
    }
}

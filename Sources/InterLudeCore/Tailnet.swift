import Foundation

/// Recognising Tailscale addresses and MagicDNS names.
public enum Tailnet {
    /// Tailscale hands out addresses from the carrier-grade NAT range, 100.64.0.0/10.
    public static func isTailscale(_ addr: String) -> Bool {
        let o = addr.split(separator: ".").compactMap { UInt8($0) }
        return o.count == 4 && o[0] == 100 && (64...127).contains(o[1])
    }

    /// `name` as a MagicDNS name without its trailing dot, or nil if it isn't one.
    public static func magicDNSName(_ name: String) -> String? {
        let n = (name.hasSuffix(".") ? String(name.dropLast()) : name).lowercased()
        let labels = n.split(separator: ".", omittingEmptySubsequences: false)
        return n.hasSuffix(".ts.net") && labels.count == 4 && !labels.contains("") ? n : nil
    }

    /// The MagicDNS name in the output of `tailscale status --json`.
    public static func magicDNSName(statusJSON: Data) -> String? {
        struct Status: Decodable {
            struct Node: Decodable { var DNSName: String? }
            var me: Node?
            enum CodingKeys: String, CodingKey { case me = "Self" }
        }
        return (try? JSONDecoder().decode(Status.self, from: statusJSON))?.me?.DNSName.flatMap(magicDNSName)
    }
}

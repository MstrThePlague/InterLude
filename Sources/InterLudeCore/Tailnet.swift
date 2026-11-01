//  Tailnet.swift
//  InterLudeCore
//
//  Recognises Tailscale addresses and MagicDNS names, so the phone remote can hand out a link that works anywhere
//  on the user's tailnet rather than only on the home Wi-Fi.

import Foundation

/// Helpers for Tailscale's addressing scheme.
public enum Tailnet {
    /// Whether `address` is a Tailscale IPv4 address.
    ///
    /// Tailscale hands out addresses from the carrier-grade NAT range, 100.64.0.0/10, so the first octet is 100
    /// and the second lies between 64 and 127.
    public static func isTailscale(_ address: String) -> Bool {
        let octets = address.split(separator: ".").compactMap { UInt8($0) }
        return octets.count == 4 && octets[0] == 100 && (64...127).contains(octets[1])
    }

    /// Normalises a MagicDNS name.
    ///
    /// - Parameter name: A host name, possibly fully qualified with a trailing dot.
    /// - Returns: The name in lower case without its trailing dot, such as `my-mac.tailnet-1234.ts.net`, or nil if
    ///   it is not a machine's MagicDNS name (exactly four labels ending in `.ts.net`).
    public static func magicDNSName(_ name: String) -> String? {
        let trimmed = (name.hasSuffix(".") ? String(name.dropLast()) : name).lowercased()
        let labels = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        return trimmed.hasSuffix(".ts.net") && labels.count == 4 && !labels.contains("") ? trimmed : nil
    }

    /// Finds this machine's MagicDNS name in the output of `tailscale status --json`.
    ///
    /// - Parameter statusJSON: The command's standard output.
    /// - Returns: The normalised name, or nil if the output can't be read or has no usable name.
    public static func magicDNSName(statusJSON: Data) -> String? {
        struct Status: Decodable {
            struct Node: Decodable { var DNSName: String? }
            /// Tailscale calls this machine's entry `Self`, which is a keyword in Swift.
            var me: Node?
            enum CodingKeys: String, CodingKey { case me = "Self" }
        }
        return (try? JSONDecoder().decode(Status.self, from: statusJSON))?.me?.DNSName.flatMap(magicDNSName)
    }
}

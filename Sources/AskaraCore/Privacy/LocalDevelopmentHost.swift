import Foundation

/// Hosts that local development servers use. Only these may skip certificate validation
/// (after the user agrees), so a self-signed or mkcert certificate works without weakening
/// HTTPS on public sites.
public enum LocalDevelopmentHost {
    public static func isLocal(_ rawHost: String) -> Bool {
        var host = rawHost.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else { return false }
        if host == "localhost" || host == "::1" { return true }
        if [".localhost", ".test", ".local", ".internal"].contains(where: { host.hasSuffix($0) }) { return true }
        guard let octets = ipv4(host) else { return false }
        // Loopback and private (RFC 1918) addresses: dev servers reached over the LAN.
        return octets[0] == 127 || octets[0] == 10
            || (octets[0] == 172 && (16...31).contains(octets[1]))
            || (octets[0] == 192 && octets[1] == 168)
    }

    /// Hosts that only resolve to this Mac. A phone needs the Mac's network address instead.
    public static func isLoopback(_ rawHost: String) -> Bool {
        var host = rawHost.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host == "localhost" || host == "::1" || host.hasSuffix(".localhost") { return true }
        return ipv4(host)?.first == 127
    }

    /// The URL with a loopback host replaced by `address`, so another device on the network can open it.
    public static func reachableURL(_ url: URL, lanAddress address: String?) -> URL {
        guard let address, let host = url.host, isLoopback(host),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.host = address
        return components.url ?? url
    }

    private static func ipv4(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let octets = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber),
                  let value = Int(part), value <= 255 else { return nil }
            return value
        }
        return octets.count == 4 ? octets : nil
    }
}

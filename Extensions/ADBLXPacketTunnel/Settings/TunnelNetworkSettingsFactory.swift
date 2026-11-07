import NetworkExtension

/// The tunnel's network settings, built apart from `startTunnel` so a test can pin them.
/// Only `fakeDNSServer` is routed into the tunnel; everything else keeps using the normal
/// route. A default route here would put every app's traffic through a tunnel that only
/// understands DNS (docs/gotchas.md, "DNS Protection breaks app connectivity").
public enum TunnelNetworkSettingsFactory {
    /// A TEST-NET-2 address: never a real host, so nothing else shares the route.
    public static let fakeDNSServer = "198.51.100.1"
    static let quad9IPv4 = "9.9.9.9"

    public static func make(
        upstreamIPv4: String, upstreamIPv6: String?, upstreamIPv4Fallback: String? = nil
    ) -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")

        let dnsSettings = NEDNSSettings(servers: [fakeDNSServer])
        dnsSettings.matchDomains = [""]
        settings.dnsSettings = dnsSettings

        // IPv4: the fake DNS server is the only route, and the upstream is excluded so the
        // forwarder's own socket doesn't loop back into the tunnel.
        let ipv4Settings = NEIPv4Settings(addresses: ["192.0.2.2"], subnetMasks: ["255.255.255.255"])
        ipv4Settings.includedRoutes = [
            NEIPv4Route(destinationAddress: fakeDNSServer, subnetMask: "255.255.255.255")
        ]
        var excludedV4Routes = [
            NEIPv4Route(destinationAddress: upstreamIPv4, subnetMask: "255.255.255.255")
        ]
        if upstreamIPv4 != quad9IPv4 {
            excludedV4Routes.append(NEIPv4Route(destinationAddress: quad9IPv4, subnetMask: "255.255.255.255"))
        }
        if let upstreamIPv4Fallback {
            excludedV4Routes.append(NEIPv4Route(destinationAddress: upstreamIPv4Fallback, subnetMask: "255.255.255.255"))
        }
        ipv4Settings.excludedRoutes = excludedV4Routes
        settings.ipv4Settings = ipv4Settings

        // IPv6: no DNS server and no included route; only the upstream is excluded.
        if let upstreamIPv6 {
            let ipv6Settings = NEIPv6Settings(addresses: ["fd00::2"], networkPrefixLengths: [128])
            ipv6Settings.excludedRoutes = [
                NEIPv6Route(destinationAddress: upstreamIPv6, networkPrefixLength: 128)
            ]
            settings.ipv6Settings = ipv6Settings
        }
        return settings
    }
}

import Testing
import NetworkExtension
@testable import ADBLX

/// Only the tunnel's own DNS address may be routed into it. A default route would send every
/// app's traffic through a tunnel that only understands DNS, which is what "DNS Protection
/// breaks app connectivity" in docs/gotchas.md first suspected. Expected values are literals,
/// not read from the factory's constants.
@Suite("Tunnel network settings")
struct TunnelNetworkSettingsTests {
    private func v4(_ settings: NEPacketTunnelNetworkSettings) throws -> NEIPv4Settings {
        try #require(settings.ipv4Settings)
    }

    @Test("DNS goes to the one fake server, for every domain")
    func dnsServer() {
        let s = TunnelNetworkSettingsFactory.make(upstreamIPv4: "9.9.9.9", upstreamIPv6: "2620:fe::fe")
        #expect(s.dnsSettings?.servers == ["198.51.100.1"])
        #expect(s.dnsSettings?.matchDomains == [""])
    }

    @Test("IPv4: the only routed destination is the DNS address")
    func ipv4OnlyDNSRouted() throws {
        let s = TunnelNetworkSettingsFactory.make(upstreamIPv4: "9.9.9.9", upstreamIPv6: "2620:fe::fe")
        let routes = try #require(try v4(s).includedRoutes)
        #expect(routes.map(\.destinationAddress) == ["198.51.100.1"])
        #expect(routes.map(\.destinationSubnetMask) == ["255.255.255.255"])
    }

    @Test("IPv4: no default route, however the upstream is configured")
    func ipv4NoDefaultRoute() throws {
        for (up4, up6) in [("9.9.9.9", "2620:fe::fe"), ("1.1.1.1", nil), ("8.8.8.8", "2001:4860:4860::8888")] as [(String, String?)] {
            let s = TunnelNetworkSettingsFactory.make(upstreamIPv4: up4, upstreamIPv6: up6)
            for route in try v4(s).includedRoutes ?? [] {
                #expect(route.destinationSubnetMask != "0.0.0.0")
                #expect(route.destinationAddress != "0.0.0.0")
            }
        }
    }

    @Test("IPv4: the upstream is excluded so the forwarder's own socket never loops into the tunnel")
    func ipv4UpstreamExcluded() throws {
        let quad9 = try v4(TunnelNetworkSettingsFactory.make(upstreamIPv4: "9.9.9.9", upstreamIPv6: nil))
        #expect(quad9.excludedRoutes?.map(\.destinationAddress) == ["9.9.9.9"])
        let custom = try v4(TunnelNetworkSettingsFactory.make(upstreamIPv4: "1.1.1.1", upstreamIPv6: nil))
        #expect(custom.excludedRoutes?.map(\.destinationAddress) == ["1.1.1.1", "9.9.9.9"])
    }

    @Test("IPv6: nothing is routed into the tunnel, and the upstream is excluded")
    func ipv6NothingRouted() throws {
        let s = TunnelNetworkSettingsFactory.make(upstreamIPv4: "9.9.9.9", upstreamIPv6: "2620:fe::fe")
        let v6 = try #require(s.ipv6Settings)
        #expect((v6.includedRoutes ?? []).isEmpty)
        #expect(v6.excludedRoutes?.map(\.destinationAddress) == ["2620:fe::fe"])
        #expect(v6.excludedRoutes?.map(\.destinationNetworkPrefixLength) == [128])
    }

    @Test("IPv6: no IPv6 settings at all without an IPv6 upstream")
    func noIPv6WithoutUpstream() {
        #expect(TunnelNetworkSettingsFactory.make(upstreamIPv4: "9.9.9.9", upstreamIPv6: nil).ipv6Settings == nil)
    }

    @Test("the tunnel's own addresses are single hosts, not subnets that attract traffic")
    func ownAddresses() throws {
        let s = TunnelNetworkSettingsFactory.make(upstreamIPv4: "9.9.9.9", upstreamIPv6: "2620:fe::fe")
        #expect(try v4(s).addresses == ["192.0.2.2"])
        #expect(try v4(s).subnetMasks == ["255.255.255.255"])
        #expect(s.ipv6Settings?.addresses == ["fd00::2"])
        #expect(s.ipv6Settings?.networkPrefixLengths == [128])
    }

    @Test("a fallback upstream is excluded too, after the primary")
    func fallbackExcluded() throws {
        let s = TunnelNetworkSettingsFactory.make(upstreamIPv4: "9.9.9.9", upstreamIPv6: nil, upstreamIPv4Fallback: "149.112.112.112")
        #expect(try v4(s).excludedRoutes?.map(\.destinationAddress) == ["9.9.9.9", "149.112.112.112"])
        for route in try v4(s).includedRoutes ?? [] { #expect(route.destinationAddress == "198.51.100.1") }
    }
}

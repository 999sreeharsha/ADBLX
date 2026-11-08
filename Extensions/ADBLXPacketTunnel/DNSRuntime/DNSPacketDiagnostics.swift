import Foundation
import ADBLXShared

/// What an unparsable packet was, for the DEBUG counters. Counts only: no address leaves here
/// except as "is it the DNS address or not".
public struct UnparsablePacketTraits: Equatable, Sendable {
    public enum Transport: Equatable, Sendable { case tcp, udp, icmp, other }
    public enum Size: Equatable, Sendable { case small, medium, large }

    public let ipVersion: IPVersion?
    public let transport: Transport
    public let toDNSAddress: Bool
    public let size: Size
}

public enum UnparsablePacketClassifier {
    public static func traits(of packet: Data, dnsAddress: UInt32) -> UnparsablePacketTraits {
        let p = [UInt8](packet)
        let size: UnparsablePacketTraits.Size = p.count <= 64 ? .small : (p.count <= 576 ? .medium : .large)
        func transport(_ number: UInt8) -> UnparsablePacketTraits.Transport {
            switch number {
            case 6: return .tcp
            case 17: return .udp
            case 1, 58: return .icmp
            default: return .other
            }
        }
        guard let first = p.first else { return UnparsablePacketTraits(ipVersion: nil, transport: .other, toDNSAddress: false, size: size) }
        switch first >> 4 {
        case 4 where p.count >= 20:
            let dst = UInt32(p[16]) << 24 | UInt32(p[17]) << 16 | UInt32(p[18]) << 8 | UInt32(p[19])
            return UnparsablePacketTraits(ipVersion: .v4, transport: transport(p[9]), toDNSAddress: dst == dnsAddress, size: size)
        case 6 where p.count >= 40:
            // The tunnel has no IPv6 DNS address, so no IPv6 packet is ever addressed to it.
            return UnparsablePacketTraits(ipVersion: .v6, transport: transport(p[6]), toDNSAddress: false, size: size)
        default:
            return UnparsablePacketTraits(ipVersion: nil, transport: .other, toDNSAddress: false, size: size)
        }
    }

    public static func record(_ traits: UnparsablePacketTraits, in counters: DNSTunnelCounters) {
        switch traits.ipVersion {
        case .v4: counters.increment(\.unparsableIPv4)
        case .v6: counters.increment(\.unparsableIPv6)
        case nil: break
        }
        switch traits.transport {
        case .tcp: counters.increment(\.unparsableTCP)
        case .udp: counters.increment(\.unparsableUDP)
        case .icmp: counters.increment(\.unparsableICMP)
        case .other: counters.increment(\.unparsableOtherProtocol)
        }
        if traits.toDNSAddress { counters.increment(\.unparsableToDNSAddress) }
        switch traits.size {
        case .small: counters.increment(\.unparsableSmall)
        case .medium: counters.increment(\.unparsableMedium)
        case .large: counters.increment(\.unparsableLarge)
        }
    }
}

public enum DNSQueryTypeBucket {
    public static func counter(for qtype: UInt16) -> WritableKeyPath<DNSTunnelCountersSnapshot, UInt64> {
        switch qtype {
        case 1: return \.queriesA
        case 28: return \.queriesAAAA
        case 65: return \.queriesHTTPS
        default: return \.queriesOther
        }
    }
}

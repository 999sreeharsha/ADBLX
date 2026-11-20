import Foundation
import ADBLXShared

/// What an unparsable packet was, for the DEBUG counters. Counts only: no address leaves here
/// except as "is it the DNS address or not".
public struct UnparsablePacketTraits: Equatable, Sendable {
    public enum Transport: Equatable, Sendable { case tcp, udp, icmp, other }
    public enum Size: Equatable, Sendable { case small, medium, large }
    /// What an ICMP packet is: a ping, an error saying a reply could not be delivered, or other.
    public enum ICMPKind: Equatable, Sendable { case echoRequest, unreachable, other }

    public let ipVersion: IPVersion?
    public let transport: Transport
    public let toDNSAddress: Bool
    public let size: Size
    /// Set for ICMP and ICMPv6 only.
    public var icmpKind: ICMPKind? = nil
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
            let icmp = p[9] == 1 ? icmpKind(at: Int(p[0] & 0x0F) * 4, in: p, echo: 8, unreachable: 3) : nil
            return UnparsablePacketTraits(ipVersion: .v4, transport: transport(p[9]), toDNSAddress: dst == dnsAddress, size: size, icmpKind: icmp)
        case 6 where p.count >= 40:
            // The tunnel has no IPv6 DNS address, so no IPv6 packet is ever addressed to it.
            let icmp = p[6] == 58 ? icmpKind(at: 40, in: p, echo: 128, unreachable: 1) : nil
            return UnparsablePacketTraits(ipVersion: .v6, transport: transport(p[6]), toDNSAddress: false, size: size, icmpKind: icmp)
        default:
            return UnparsablePacketTraits(ipVersion: nil, transport: .other, toDNSAddress: false, size: size)
        }
    }

    /// The kind of the ICMP message starting at `offset`; `other` if the header isn't there.
    private static func icmpKind(at offset: Int, in p: [UInt8], echo: UInt8, unreachable: UInt8) -> UnparsablePacketTraits.ICMPKind {
        guard offset < p.count else { return .other }
        switch p[offset] {
        case echo: return .echoRequest
        case unreachable: return .unreachable
        default: return .other
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
        switch traits.icmpKind {
        case .echoRequest: counters.increment(\.unparsableICMPEchoRequest)
        case .unreachable: counters.increment(\.unparsableICMPUnreachable)
        case .other: counters.increment(\.unparsableICMPOther)
        case nil: break
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

/// How long a query's first answer took, as one of a few buckets (each bound inclusive).
public enum DNSAnswerLatencyBucket {
    public static func counter(forSeconds seconds: TimeInterval) -> WritableKeyPath<DNSTunnelCountersSnapshot, UInt64> {
        switch seconds {
        case ...0.05: return \.firstAnswerUnder50ms
        case ...0.1: return \.firstAnswerUnder100ms
        case ...0.25: return \.firstAnswerUnder250ms
        case ...0.5: return \.firstAnswerUnder500ms
        case ...1.0: return \.firstAnswerUnder1s
        default: return \.firstAnswerOver1s
        }
    }
}

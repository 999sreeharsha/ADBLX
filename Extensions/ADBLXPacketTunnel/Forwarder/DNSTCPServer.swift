import Foundation
import os

public struct DNSTCPConnectionKey: Hashable, Sendable {
    public let clientIP: UInt32
    public let clientPort: UInt16
}

public struct DNSTCPQuery: Sendable {
    public let key: DNSTCPConnectionKey
    public let message: Data
}

public struct DNSTCPOutput: Sendable {
    public var packets: [Data] = []
    public var queries: [DNSTCPQuery] = []
}

/// A small TCP server for DNS on the tunnel's fake DNS address (port 53), for the clients that
/// retry over TCP after a truncated UDP answer. It speaks just enough TCP for that: handshake,
/// in-order data, one or more length-prefixed queries, answers, and close. The tunnel is a
/// lossless local link, so there are no retransmission timers; nothing here sleeps or schedules.
///
/// Synchronous on purpose: `receive` returns the packets to send now and the queries to resolve,
/// the caller resolves them (asynchronously) and passes each answer to `respond`. Segments are
/// therefore handled strictly in the order they arrive.
public final class DNSTCPServer: @unchecked Sendable {
    private struct Connection {
        var established = false
        var iss: UInt32
        var rcvNext: UInt32
        var sndNext: UInt32
        var reader = DNSTCPFrameReader()
        var outstanding = 0
        var finReceived = false
        var lastActivity: TimeInterval
    }

    private static let maxSegmentPayload = 1200
    private static let port: UInt16 = 53

    private let serverIP: UInt32
    private let clock: DNSClock
    private let maxConnections: Int
    private let idleTimeout: TimeInterval
    private let initialSequence: @Sendable () -> UInt32
    private let connections = OSAllocatedUnfairLock(initialState: [DNSTCPConnectionKey: Connection]())

    public init(
        serverIP: UInt32,
        clock: DNSClock,
        maxConnections: Int = 32,
        idleTimeout: TimeInterval = 30,
        initialSequence: @escaping @Sendable () -> UInt32 = { UInt32.random(in: 1...UInt32.max / 2) }
    ) {
        self.serverIP = serverIP
        self.clock = clock
        self.maxConnections = maxConnections
        self.idleTimeout = idleTimeout
        self.initialSequence = initialSequence
    }

    public var connectionCount: Int { connections.withLock { $0.count } }

    // MARK: - Segments in

    public func receive(_ seg: ParsedTCPSegment) -> DNSTCPOutput {
        let now = clock.now
        return connections.withLock { (table: inout [DNSTCPConnectionKey: Connection]) -> DNSTCPOutput in
            var out = DNSTCPOutput()
            // Idle connections are dropped lazily, so an idle server has no timer to wake the radio or CPU.
            table = table.filter { now - $0.value.lastActivity <= idleTimeout }

            guard seg.dstPort == Self.port else {
                reset(for: seg, into: &out)
                return out
            }
            let key = DNSTCPConnectionKey(clientIP: seg.srcIP, clientPort: seg.srcPort)

            if seg.flags.contains(.syn), !seg.flags.contains(.ack) {
                if let existing = table[key], !existing.established, existing.rcvNext == seg.seq &+ 1 {
                    out.packets.append(packet(seg: seg, seq: existing.iss, ack: existing.rcvNext, flags: [.syn, .ack]))
                    return out
                }
                table[key] = nil
                if table.count >= maxConnections, let oldest = table.min(by: { $0.value.lastActivity < $1.value.lastActivity }) {
                    out.packets.append(rawReset(to: oldest.key, conn: oldest.value))
                    table[oldest.key] = nil
                }
                let iss = initialSequence()
                table[key] = Connection(iss: iss, rcvNext: seg.seq &+ 1, sndNext: iss &+ 1, lastActivity: now)
                out.packets.append(packet(seg: seg, seq: iss, ack: seg.seq &+ 1, flags: [.syn, .ack]))
                return out
            }

            guard var conn = table[key] else {
                reset(for: seg, into: &out)
                return out
            }
            if seg.flags.contains(.rst) {
                table[key] = nil
                return out
            }
            conn.lastActivity = now
            if !conn.established, seg.flags.contains(.ack), seg.ack == conn.sndNext { conn.established = true }

            var needsAck = false
            var data = seg.payload
            if !data.isEmpty {
                let behind = Int32(bitPattern: conn.rcvNext &- seg.seq)     // > 0: part or all already received
                if behind >= 0, Int(behind) < data.count {
                    data = data.dropFirst(Int(behind))
                    if let messages = conn.reader.append(data) {
                        conn.rcvNext = conn.rcvNext &+ UInt32(data.count)
                        conn.outstanding += messages.count
                        out.queries.append(contentsOf: messages.map { DNSTCPQuery(key: key, message: $0) })
                    } else {
                        out.packets.append(rawReset(to: key, conn: conn, seg: seg))
                        table[key] = nil
                        return out
                    }
                }
                needsAck = true     // new, old or out of order: always say where we are
            }
            if seg.flags.contains(.fin), seg.seq &+ UInt32(seg.payload.count) == conn.rcvNext {
                conn.rcvNext = conn.rcvNext &+ 1
                conn.finReceived = true
                needsAck = true
            }
            if conn.finReceived, conn.outstanding == 0 {
                out.packets.append(packet(seg: seg, seq: conn.sndNext, ack: conn.rcvNext, flags: [.fin, .ack]))
                table[key] = nil
                return out
            }
            if needsAck {
                out.packets.append(packet(seg: seg, seq: conn.sndNext, ack: conn.rcvNext, flags: [.ack]))
            }
            table[key] = conn
            return out
        }
    }

    // MARK: - Answers out

    /// The packets that deliver `message` as the answer to a query from `key`; empty if the
    /// connection has gone.
    public func respond(to key: DNSTCPConnectionKey, with message: Data) -> [Data] {
        let now = clock.now
        return connections.withLock { (table: inout [DNSTCPConnectionKey: Connection]) -> [Data] in
            guard var conn = table[key] else { return [] }
            conn.lastActivity = now
            conn.outstanding = max(0, conn.outstanding - 1)

            var packets: [Data] = []
            let framed = DNSTCPFraming.frame(message)
            var offset = 0
            while offset < framed.count {
                let end = min(offset + Self.maxSegmentPayload, framed.count)
                packets.append(TCPSegmentBuilder.buildIPv4(
                    srcIP: serverIP, dstIP: key.clientIP, srcPort: Self.port, dstPort: key.clientPort,
                    seq: conn.sndNext, ack: conn.rcvNext, flags: [.psh, .ack],
                    payload: framed.subdata(in: offset..<end)
                ))
                conn.sndNext = conn.sndNext &+ UInt32(end - offset)
                offset = end
            }
            if conn.finReceived, conn.outstanding == 0 {
                packets.append(TCPSegmentBuilder.buildIPv4(
                    srcIP: serverIP, dstIP: key.clientIP, srcPort: Self.port, dstPort: key.clientPort,
                    seq: conn.sndNext, ack: conn.rcvNext, flags: [.fin, .ack], payload: Data()
                ))
                table[key] = nil
            } else {
                table[key] = conn
            }
            return packets
        }
    }

    // MARK: - Packet helpers

    /// A segment from us to the sender of `seg`.
    private func packet(seg: ParsedTCPSegment, seq: UInt32, ack: UInt32, flags: TCPFlags) -> Data {
        TCPSegmentBuilder.buildIPv4(
            srcIP: serverIP, dstIP: seg.srcIP, srcPort: Self.port, dstPort: seg.srcPort,
            seq: seq, ack: ack, flags: flags, payload: Data()
        )
    }

    private func rawReset(to key: DNSTCPConnectionKey, conn: Connection, seg: ParsedTCPSegment? = nil) -> Data {
        TCPSegmentBuilder.buildIPv4(
            srcIP: serverIP, dstIP: key.clientIP, srcPort: Self.port, dstPort: key.clientPort,
            seq: conn.sndNext, ack: 0, flags: [.rst], payload: Data()
        )
    }

    /// RFC 793: the reset for a segment that belongs to no connection.
    private func reset(for seg: ParsedTCPSegment, into out: inout DNSTCPOutput) {
        guard !seg.flags.contains(.rst) else { return }
        if seg.flags.contains(.ack) {
            out.packets.append(packet(seg: seg, seq: seg.ack, ack: 0, flags: [.rst]))
        } else {
            let length = UInt32(seg.payload.count) + (seg.flags.contains(.syn) ? 1 : 0) + (seg.flags.contains(.fin) ? 1 : 0)
            out.packets.append(packet(seg: seg, seq: 0, ack: seg.seq &+ length, flags: [.rst, .ack]))
        }
    }
}

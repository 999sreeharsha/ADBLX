import Foundation
import os
@testable import ADBLX

// Shared doubles and builders for the DNS transport tests. Nothing here sleeps on the wall
// clock: time is `ManualDNSClock`, and waiting is on a condition, never on a duration.

/// A clock that only moves when a test says so.
nonisolated final class ManualDNSClock: @unchecked Sendable {
    private struct Sleeper {
        let id: Int
        let deadline: TimeInterval
        let continuation: CheckedContinuation<Void, Error>
    }
    private struct State {
        var now: TimeInterval = 0
        var nextID = 0
        var sleepers: [Sleeper] = []
        var watchers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    var now: TimeInterval { state.withLock { $0.now } }
    var sleeperCount: Int { state.withLock { $0.sleepers.count } }

    func advance(by seconds: TimeInterval) {
        let due: [Sleeper] = state.withLock { s in
            s.now += seconds
            let due = s.sleepers.filter { $0.deadline <= s.now }
            s.sleepers.removeAll { $0.deadline <= s.now }
            return due
        }
        for sleeper in due { sleeper.continuation.resume() }
    }

    /// Returns once at least `count` tasks are sleeping on this clock.
    func waitForSleepers(_ count: Int) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let ready = state.withLock { s -> Bool in
                if s.sleepers.count >= count { return true }
                s.watchers.append((count, c))
                return false
            }
            if ready { c.resume() }
        }
    }

    func sleep(seconds: TimeInterval) async throws {
        let id = state.withLock { s -> Int in s.nextID += 1; return s.nextID }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                let (cancelled, watchers) = state.withLock { s -> (Bool, [CheckedContinuation<Void, Never>]) in
                    s.sleepers.append(Sleeper(id: id, deadline: s.now + seconds, continuation: c))
                    let ready = s.watchers.filter { s.sleepers.count >= $0.count }
                    s.watchers.removeAll { w in s.sleepers.count >= w.count }
                    return (false, ready.map(\.continuation))
                }
                _ = cancelled
                for w in watchers { w.resume() }
            }
        } onCancel: {
            let sleeper = state.withLock { s -> Sleeper? in
                guard let i = s.sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return s.sleepers.remove(at: i)
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }
}
extension ManualDNSClock: DNSClock {}

/// Collects packets a component writes and lets a test wait for the n-th.
nonisolated final class PacketSink: @unchecked Sendable {
    private struct State {
        var packets: [Data] = []
        var watchers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    var packets: [Data] { state.withLock { $0.packets } }
    var count: Int { state.withLock { $0.packets.count } }

    func append(_ packet: Data) {
        let ready = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            s.packets.append(packet)
            let ready = s.watchers.filter { s.packets.count >= $0.count }
            s.watchers.removeAll { s.packets.count >= $0.count }
            return ready.map(\.continuation)
        }
        for c in ready { c.resume() }
    }

    func waitForCount(_ count: Int) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let ready = state.withLock { s -> Bool in
                if s.packets.count >= count { return true }
                s.watchers.append((count, c))
                return false
            }
            if ready { c.resume() }
        }
    }
}

/// An upstream UDP socket that answers each query synchronously through a closure.
nonisolated final class ScriptedUpstreamSocket: @unchecked Sendable {
    private let handler = OSAllocatedUnfairLock<(@Sendable (Data, String, UInt16) -> Void)?>(initialState: nil)
    private let reply: @Sendable (Data) -> Data?
    private let failure: Error?
    let sent = OSAllocatedUnfairLock(initialState: [Data]())

    init(failure: Error? = nil, reply: @escaping @Sendable (Data) -> Data? = { _ in nil }) {
        self.reply = reply
        self.failure = failure
    }

    func send(payload: Data) async throws {
        if let failure { throw failure }
        sent.withLock { $0.append(payload) }
        if let response = reply(payload) { handler.withLock { $0 }?(response, "9.9.9.9", 53) }
    }
    func setResponseHandler(_ h: @escaping @Sendable (Data, String, UInt16) -> Void) { handler.withLock { $0 = h } }
    func close() {}
}
extension ScriptedUpstreamSocket: DNSUpstreamSocketProtocol {}

nonisolated struct SendFailure: Error {}

/// Upstream-over-TCP double: records queries, answers with a canned message or throws.
nonisolated final class ScriptedTCPTransport: @unchecked Sendable {
    let queries = OSAllocatedUnfairLock(initialState: [Data]())
    private let result: Result<Data, Error>
    init(_ result: Result<Data, Error>) { self.result = result }

    func exchange(query: Data, host: String, port: UInt16) async throws -> Data {
        queries.withLock { $0.append(query) }
        return try result.get()
    }
}
extension ScriptedTCPTransport: DNSUpstreamTCPTransport {}

// MARK: - Wire builders (independent of the code under test)

nonisolated enum TestDNS {
    /// A DNS query message. `udpSize` adds an EDNS0 OPT record advertising that size.
    static func query(_ domain: String, txID: UInt16 = 0x1234, udpSize: UInt16? = nil) -> Data {
        var d = Data([UInt8(txID >> 8), UInt8(txID & 0xFF), 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, udpSize == nil ? 0x00 : 0x01])
        for label in domain.split(separator: ".") { d.append(UInt8(label.utf8.count)); d.append(contentsOf: label.utf8) }
        d.append(contentsOf: [0x00, 0x00, 0x01, 0x00, 0x01])
        if let udpSize {
            d.append(contentsOf: [0x00, 0x00, 0x29, UInt8(udpSize >> 8), UInt8(udpSize & 0xFF), 0, 0, 0, 0, 0, 0])
        }
        return d
    }

    /// A response to `query`, optionally truncated, with `answerBytes` bytes of answer data.
    static func response(to query: Data, truncated: Bool = false, answerBytes: Int = 0, rcode: UInt8 = 0) -> Data {
        var d = Data(query.prefix(12))
        d[2] = 0x81 | (truncated ? 0x02 : 0x00)
        d[3] = 0x80 | rcode
        d[6] = 0; d[7] = answerBytes > 0 ? 1 : 0; d[8] = 0; d[9] = 0; d[10] = 0; d[11] = 0
        d.append(question(of: query))
        if answerBytes > 0 {
            d.append(contentsOf: [0xC0, 0x0C, 0x00, 0x10, 0x00, 0x01, 0, 0, 0, 60, UInt8(answerBytes >> 8), UInt8(answerBytes & 0xFF)])
            d.append(Data(repeating: 0x41, count: answerBytes))
        }
        return d
    }

    /// The question section (name + type + class) of a query.
    static func question(of query: Data) -> Data {
        var i = 12
        while query[i] != 0 { i += Int(query[i]) + 1 }
        return query.subdata(in: 12..<(i + 5))
    }

    static func txID(_ message: Data) -> UInt16 { UInt16(message[0]) << 8 | UInt16(message[1]) }
    static func rcode(_ message: Data) -> UInt8 { message[3] & 0x0F }
    static func isTruncated(_ message: Data) -> Bool { message[2] & 0x02 != 0 }
    static func answerCount(_ message: Data) -> Int { Int(message[6]) << 8 | Int(message[7]) }

    /// A client-to-fake-server IPv4/UDP packet carrying `dns`.
    static func udpPacket(dns: Data, srcPort: UInt16 = 54321, src: [UInt8] = [192, 0, 2, 2], dst: [UInt8] = [198, 51, 100, 1]) -> Data {
        let udpLen = 8 + dns.count
        let total = 20 + udpLen
        var p = Data(count: total)
        p[0] = 0x45; p[2] = UInt8(total >> 8); p[3] = UInt8(total & 0xFF); p[6] = 0x40; p[8] = 64; p[9] = 17
        p.replaceSubrange(12..<16, with: src); p.replaceSubrange(16..<20, with: dst)
        p[20] = UInt8(srcPort >> 8); p[21] = UInt8(srcPort & 0xFF); p[22] = 0; p[23] = 53
        p[24] = UInt8(udpLen >> 8); p[25] = UInt8(udpLen & 0xFF)
        p.replaceSubrange(28..<total, with: dns)
        return p
    }

    /// DNS payload of a UDP packet the forwarder wrote.
    static func dnsPayload(ofUDPPacket p: Data) -> Data { p.subdata(in: 28..<p.count) }
}

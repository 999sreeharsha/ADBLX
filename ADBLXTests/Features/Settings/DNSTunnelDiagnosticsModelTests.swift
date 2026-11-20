#if DEBUG
import Testing
import Foundation
import os
import ADBLXShared
@testable import ADBLX

private nonisolated final class ScriptedDiagnosticsTransport: @unchecked Sendable {
    let sent = OSAllocatedUnfairLock(initialState: [DNSTunnelDiagnosticsMessage]())
    private let reply: @Sendable (DNSTunnelDiagnosticsMessage) throws -> Data?
    init(reply: @escaping @Sendable (DNSTunnelDiagnosticsMessage) throws -> Data?) { self.reply = reply }
    func send(_ message: DNSTunnelDiagnosticsMessage) async throws -> Data? {
        sent.withLock { $0.append(message) }
        return try reply(message)
    }
}
extension ScriptedDiagnosticsTransport: DNSTunnelDiagnosticsTransport {}

private nonisolated func encoded(_ edit: (inout DNSTunnelCountersSnapshot) -> Void) -> Data {
    var s = DNSTunnelCountersSnapshot(); edit(&s)
    return try! JSONEncoder().encode(s)
}

private struct TunnelDown: LocalizedError {
    var errorDescription: String? { "Tunnel is not running" }
}

@Suite("Developer screen: DNS tunnel section")
@MainActor
struct DNSTunnelDiagnosticsModelTests {
    @Test("refresh shows the tunnel's counts")
    func refresh() async {
        let reply = encoded { $0.blockedQueries = 7; $0.upstreamTimeouts = 2 }
        let transport = ScriptedDiagnosticsTransport { _ in reply }
        let model = DNSTunnelDiagnosticsModel(transport: transport)
        await model.refresh()
        #expect(model.counters?.blockedQueries == 7)
        #expect(model.counters?.upstreamTimeouts == 2)
        #expect(model.status == nil)
        #expect(transport.sent.withLock { $0 } == [.readCounters])
    }

    @Test("a tunnel that isn't running is reported, not hidden")
    func tunnelDown() async {
        let model = DNSTunnelDiagnosticsModel(transport: ScriptedDiagnosticsTransport { _ in throw TunnelDown() })
        await model.refresh()
        #expect(model.counters == nil)
        #expect(model.status == "Tunnel is not running")
    }

    @Test("a tunnel build that doesn't answer is reported")
    func noReply() async {
        let model = DNSTunnelDiagnosticsModel(transport: ScriptedDiagnosticsTransport { _ in nil })
        await model.refresh()
        #expect(model.status == "The tunnel did not reply")
    }

    @Test("turning pass-through on sends it and shows what the tunnel says")
    func passthroughOn() async {
        let transport = ScriptedDiagnosticsTransport { message in
            message == .setPassthrough(true) ? encoded { $0.passthrough = true } : nil
        }
        let model = DNSTunnelDiagnosticsModel(transport: transport)
        await model.setPassthrough(true)
        #expect(transport.sent.withLock { $0 } == [.setPassthrough(true)])
        #expect(model.passthrough)
    }

    @Test("reset sends resetCounters")
    func reset() async {
        let transport = ScriptedDiagnosticsTransport { _ in encoded { _ in } }
        let model = DNSTunnelDiagnosticsModel(transport: transport)
        await model.reset()
        #expect(transport.sent.withLock { $0 } == [.resetCounters])
    }

    @Test("every row is a label and a number; nothing can show a domain")
    func rowsAreCountsOnly() async {
        let reply = encoded { $0.ingressPackets = 12; $0.tcpQueries = 3 }
        let model = DNSTunnelDiagnosticsModel(transport: ScriptedDiagnosticsTransport { _ in reply })
        await model.refresh()
        #expect(model.rows.map(\.label) == [
            "Packets in", "Blocked", "Forwarded", "Responses written", "No answer in 2 s",
            "Upstream send errors", "Second upstream asked", "SERVFAIL sent", "Truncated upstream answers",
            "TCP segments", "TCP queries", "Unparsable packets", "Socket resets",
            "Answered by IPv4 primary", "Answered by IPv6", "Answered by IPv4 fallback",
            "Late from IPv4 primary", "Late from IPv6", "Late from IPv4 fallback",
            "Duplicate client queries", "Replies from unexpected sender", "Upstream TCP OK", "Upstream TCP failed", "Cut to fit, TC to client",
            "Queries A", "Queries AAAA", "Queries HTTPS", "Queries other",
            "Unparsable IPv4", "Unparsable IPv6", "Unparsable TCP", "Unparsable UDP", "Unparsable ICMP",
            "ICMP echo request", "ICMP unreachable", "ICMP other type", "Unparsable other protocol", "Unparsable to DNS address",
            "Unparsable ≤64 B", "Unparsable ≤576 B", "Unparsable >576 B",
            "First answer ≤50 ms", "First answer ≤100 ms", "First answer ≤250 ms", "First answer ≤500 ms",
            "First answer ≤1 s", "First answer >1 s",
            "Path updates", "Resets: interface change", "Resets: reconnect", "Resets: virtual interfaces only"
        ])
        #expect(model.rows.allSatisfy { UInt64($0.value) != nil })
        #expect(model.rows.first { $0.label == "Packets in" }?.value == "12")
    }
}
#endif

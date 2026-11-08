#if DEBUG
import Foundation
import NetworkExtension
import Observation
import ADBLXShared

nonisolated protocol DNSTunnelDiagnosticsTransport: Sendable {
    /// Sends one message to the running packet tunnel and returns its reply, if any.
    func send(_ message: DNSTunnelDiagnosticsMessage) async throws -> Data?
}

nonisolated enum DNSTunnelDiagnosticsError: LocalizedError {
    case tunnelNotRunning

    var errorDescription: String? { "Tunnel is not running" }
}

/// Talks to the real tunnel through its `NETunnelProviderSession`.
nonisolated struct SystemDNSTunnelDiagnosticsTransport: DNSTunnelDiagnosticsTransport {
    func send(_ message: DNSTunnelDiagnosticsMessage) async throws -> Data? {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        let session = managers
            .first { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == "com.ADBLX.ADBLX.PacketTunnel" }?
            .connection as? NETunnelProviderSession
        guard let session, session.status == .connected else { throw DNSTunnelDiagnosticsError.tunnelNotRunning }
        let payload = try JSONEncoder().encode(message)
        return try await withCheckedThrowingContinuation { continuation in
            do {
                try session.sendProviderMessage(payload) { continuation.resume(returning: $0) }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

/// The Developer screen's DNS tunnel section. Shows counts only.
@MainActor
@Observable
final class DNSTunnelDiagnosticsModel {
    struct Row: Equatable {
        let label: String
        let value: String
    }

    private(set) var counters: DNSTunnelCountersSnapshot?
    private(set) var status: String?

    @ObservationIgnored private let transport: DNSTunnelDiagnosticsTransport

    init(transport: DNSTunnelDiagnosticsTransport) {
        self.transport = transport
    }

    var passthrough: Bool { counters?.passthrough ?? false }

    var rows: [Row] {
        guard let c = counters else { return [] }
        return [
            Row(label: "Packets in", value: "\(c.ingressPackets)"),
            Row(label: "Blocked", value: "\(c.blockedQueries)"),
            Row(label: "Forwarded", value: "\(c.forwardedQueries)"),
            Row(label: "Responses written", value: "\(c.responsesWritten)"),
            Row(label: "No answer in 2 s", value: "\(c.upstreamTimeouts)"),
            Row(label: "Upstream send errors", value: "\(c.upstreamSendErrors)"),
            Row(label: "Second upstream asked", value: "\(c.upstreamRetries)"),
            Row(label: "SERVFAIL sent", value: "\(c.servfailsSent)"),
            Row(label: "Truncated upstream answers", value: "\(c.truncatedUpstreamAnswers)"),
            Row(label: "TCP segments", value: "\(c.tcpSegments)"),
            Row(label: "TCP queries", value: "\(c.tcpQueries)"),
            Row(label: "Unparsable packets", value: "\(c.unparsablePackets)"),
            Row(label: "Socket resets", value: "\(c.socketResets)"),
            Row(label: "Answered by IPv4 primary", value: "\(c.answersFromPrimaryIPv4)"),
            Row(label: "Answered by IPv6", value: "\(c.answersFromIPv6)"),
            Row(label: "Answered by IPv4 fallback", value: "\(c.answersFromFallbackIPv4)"),
            Row(label: "Late from IPv4 primary", value: "\(c.lateAnswersFromPrimaryIPv4)"),
            Row(label: "Late from IPv6", value: "\(c.lateAnswersFromIPv6)"),
            Row(label: "Late from IPv4 fallback", value: "\(c.lateAnswersFromFallbackIPv4)"),
            Row(label: "Duplicate client queries", value: "\(c.duplicateClientQueries)"),
            Row(label: "Upstream TCP OK", value: "\(c.upstreamTCPSucceeded)"),
            Row(label: "Upstream TCP failed", value: "\(c.upstreamTCPFailed)"),
            Row(label: "Cut to fit, TC to client", value: "\(c.truncatedToClient)"),
            Row(label: "Queries A", value: "\(c.queriesA)"),
            Row(label: "Queries AAAA", value: "\(c.queriesAAAA)"),
            Row(label: "Queries HTTPS", value: "\(c.queriesHTTPS)"),
            Row(label: "Queries other", value: "\(c.queriesOther)"),
            Row(label: "Unparsable IPv4", value: "\(c.unparsableIPv4)"),
            Row(label: "Unparsable IPv6", value: "\(c.unparsableIPv6)"),
            Row(label: "Unparsable TCP", value: "\(c.unparsableTCP)"),
            Row(label: "Unparsable UDP", value: "\(c.unparsableUDP)"),
            Row(label: "Unparsable ICMP", value: "\(c.unparsableICMP)"),
            Row(label: "Unparsable other protocol", value: "\(c.unparsableOtherProtocol)"),
            Row(label: "Unparsable to DNS address", value: "\(c.unparsableToDNSAddress)"),
            Row(label: "Unparsable ≤64 B", value: "\(c.unparsableSmall)"),
            Row(label: "Unparsable ≤576 B", value: "\(c.unparsableMedium)"),
            Row(label: "Unparsable >576 B", value: "\(c.unparsableLarge)"),
            Row(label: "Path updates", value: "\(c.pathUpdates)"),
            Row(label: "Resets: interface change", value: "\(c.resetsInterfaceChange)"),
            Row(label: "Resets: reconnect", value: "\(c.resetsReconnect)"),
            Row(label: "Resets: virtual interfaces only", value: "\(c.resetsVirtualInterfacesOnly)")
        ]
    }

    func refresh() async { await send(.readCounters) }
    func reset() async { await send(.resetCounters) }
    func setPassthrough(_ on: Bool) async { await send(.setPassthrough(on)) }

    private func send(_ message: DNSTunnelDiagnosticsMessage) async {
        do {
            guard let reply = try await transport.send(message),
                  let snapshot = try? JSONDecoder().decode(DNSTunnelCountersSnapshot.self, from: reply) else {
                status = "The tunnel did not reply"
                return
            }
            counters = snapshot
            status = nil
        } catch {
            counters = nil
            status = error.localizedDescription
        }
    }
}
#endif

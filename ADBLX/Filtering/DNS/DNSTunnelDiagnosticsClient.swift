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
            Row(label: "Upstream timeouts", value: "\(c.upstreamTimeouts)"),
            Row(label: "Upstream send errors", value: "\(c.upstreamSendErrors)"),
            Row(label: "Upstream retries", value: "\(c.upstreamRetries)"),
            Row(label: "SERVFAIL sent", value: "\(c.servfailsSent)"),
            Row(label: "Truncated upstream answers", value: "\(c.truncatedUpstreamAnswers)"),
            Row(label: "TCP segments", value: "\(c.tcpSegments)"),
            Row(label: "TCP queries", value: "\(c.tcpQueries)"),
            Row(label: "Unparsable packets", value: "\(c.unparsablePackets)"),
            Row(label: "Socket resets", value: "\(c.socketResets)")
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

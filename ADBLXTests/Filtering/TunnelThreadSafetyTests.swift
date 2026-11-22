import Foundation
import Testing
@testable import ADBLX

/// SEC-15: the tunnel's counters change from the packet-flow callback, the forwarder's queue and
/// TCP answer tasks at once, and the upstream socket is closed from outside its queue. These tests
/// pin the fix; races themselves are caught by running the tunnel tests under Thread Sanitizer
/// (`docs/Security/Findings.md`, SEC-15).
@Suite("Tunnel thread safety")
struct TunnelThreadSafetyTests {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test("concurrent increments are all counted, and each caller sees its own new value")
    func countersCountEveryConcurrentIncrement() async {
        let counters = DNSTunnelCounters()
        let values = await withTaskGroup(of: [UInt64].self) { group in
            for _ in 0..<8 {
                group.addTask {
                    (0..<1000).map { _ in counters.incrementReturningValue(\.ingressPackets) }
                }
            }
            return await group.reduce(into: [UInt64]()) { $0 += $1 }
        }
        #expect(counters.snapshot.ingressPackets == 8000)
        #expect(Set(values) == Set(1...8000))
    }

    @Test("the packet tunnel keeps no counters of its own outside the locked DNSTunnelCounters")
    func providerHasNoUnlockedCounters() throws {
        let source = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("Extensions/ADBLXPacketTunnel/PacketTunnelProvider.swift"),
            encoding: .utf8
        )
        #expect(!source.contains("&+="), "a plain counter in the provider is raced by the forwarder's queue")
    }

    @Test("closing the socket from another thread while answers arrive stops delivery once close returns",
          .timeLimit(.minutes(1)))
    func closeWhileReceivingStopsDelivery() async throws {
        let responder = try LocalUDPResponder()
        defer { responder.stop() }
        let socket = try BSDUDPUpstreamSocket(host: "127.0.0.1", port: responder.port, isIPv6: false)
        let delivered = Counter()
        socket.setResponseHandler { _, _, _ in delivered.add() }

        let query = Data(repeating: 0xAB, count: 32)
        for _ in 0..<200 { try await socket.send(payload: query) }
        while delivered.value == 0 { await Task.yield() }

        let sender = Task.detached { for _ in 0..<200 { try? await socket.send(payload: query) } }
        await Task.detached { socket.close() }.value
        let atClose = delivered.value
        _ = await sender.value
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(delivered.value == atClose, "an answer was delivered after close returned")
        await #expect(throws: (any Error).self) { try await socket.send(payload: query) }
    }
}

private nonisolated final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

/// Echoes every datagram it receives on 127.0.0.1, from a thread of its own.
private nonisolated final class LocalUDPResponder: @unchecked Sendable {
    private let fd: Int32
    let port: UInt16
    private let stopped = NSLock()
    private var isStopped = false

    init() throws {
        let descriptor = socket(AF_INET, SOCK_DGRAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, length) }
        }
        guard bound == 0 else { Darwin.close(descriptor); throw POSIXError(.EADDRINUSE) }
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        var timeout = timeval(tv_sec: 0, tv_usec: 50_000)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        fd = descriptor
        port = UInt16(bigEndian: addr.sin_port)
        let thread = Thread { [self] in run() }
        thread.start()
    }

    private func run() {
        var buffer = [UInt8](repeating: 0, count: 512)
        while !stopped.withLock({ isStopped }) {
            var from = sockaddr_storage()
            var fromLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let count = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &fromLength) }
            }
            guard count > 0 else { continue }
            _ = withUnsafePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, buffer, count, 0, $0, fromLength) }
            }
        }
        Darwin.close(fd)
    }

    func stop() { stopped.withLock { isStopped = true } }
}

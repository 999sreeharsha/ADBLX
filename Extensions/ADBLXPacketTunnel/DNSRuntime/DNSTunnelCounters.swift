import Foundation
import os
import ADBLXShared

/// Aggregate counts for the DEBUG Developer screen. Counts only: nothing here accepts, stores
/// or returns a domain (docs/Architecture/Logging.md). Held in memory, never written to disk,
/// read only when the app asks; it has no timers and does no I/O.
public final class DNSTunnelCounters: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: DNSTunnelCountersSnapshot())

    public init() {}

    public var snapshot: DNSTunnelCountersSnapshot { state.withLock { $0 } }

    public func increment(_ counter: WritableKeyPath<DNSTunnelCountersSnapshot, UInt64>, by amount: UInt64 = 1) {
        state.withLock { $0[keyPath: counter] &+= amount }
    }

    public func reset() {
        state.withLock { current in
            var fresh = DNSTunnelCountersSnapshot()
            fresh.passthrough = current.passthrough
            current = fresh
        }
    }
}

/// Answers the Developer screen's provider messages.
public struct DNSTunnelDiagnosticsHandler: @unchecked Sendable {
    private let counters: DNSTunnelCounters
    private let engine: DNSLookupEngine

    public init(counters: DNSTunnelCounters, engine: DNSLookupEngine) {
        self.counters = counters
        self.engine = engine
    }

    /// The reply for `data`, or nil if it isn't a diagnostics message.
    public func handle(_ data: Data) -> Data? {
        guard let message = try? JSONDecoder().decode(DNSTunnelDiagnosticsMessage.self, from: data) else { return nil }
        switch message {
        case .readCounters: break
        case .resetCounters: counters.reset()
        case .setPassthrough(let on): engine.isPassthrough = on
        }
        var snapshot = counters.snapshot
        snapshot.passthrough = engine.isPassthrough
        return try? JSONEncoder().encode(snapshot)
    }
}

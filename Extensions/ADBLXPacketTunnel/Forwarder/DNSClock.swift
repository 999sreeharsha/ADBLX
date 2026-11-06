import Foundation

/// Time as the forwarder and TCP server see it, so tests move it by hand instead of sleeping.
public protocol DNSClock: Sendable {
    /// Seconds since an arbitrary fixed point; only differences matter.
    var now: TimeInterval { get }
    func sleep(seconds: TimeInterval) async throws
}

public struct SystemDNSClock: DNSClock {
    public init() {}
    public var now: TimeInterval { Date().timeIntervalSince1970 }
    public func sleep(seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}

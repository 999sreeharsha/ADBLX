import Foundation
import os
import Network
import ADBLXShared

/// What matters about the current network: whether there is one, and which interfaces it has.
public struct NetworkPathSnapshot: Equatable, Sendable {
    public let isSatisfied: Bool
    public let interfaces: [String]

    public init(isSatisfied: Bool, interfaces: [String]) {
        self.isSatisfied = isSatisfied
        self.interfaces = interfaces
    }

    var key: String { interfaces.sorted().joined(separator: ",") }
}

/// Source of network path updates. A protocol so tests drive it by hand.
public protocol NetworkPathObserver: Sendable {
    func start(_ handler: @escaping @Sendable (NetworkPathSnapshot) -> Void)
    func stop()
}

/// Decides when a path update means the upstream sockets should be replaced: the first update is
/// only a baseline, a repeat is nothing, going offline is nothing (there is no network to use),
/// and coming back, or any change of interfaces, is a reset.
public struct PathChangeFilter {
    public enum Change: Equatable {
        case none
        /// Back online after being offline.
        case reconnect
        /// The set of interfaces changed. `virtualOnly`: every interface that came or went is a
        /// virtual one (utun, ipsec, ppp, llw, awdl), not Wi-Fi, cellular or wired.
        case interfaceChange(virtualOnly: Bool)
    }

    private static let virtualPrefixes = ["utun", "ipsec", "ppp", "llw", "awdl"]

    private var last: (isSatisfied: Bool, interfaces: Set<String>)?

    public init() {}

    public mutating func shouldReset(for snapshot: NetworkPathSnapshot) -> Bool {
        evaluate(snapshot) != .none
    }

    public mutating func evaluate(_ snapshot: NetworkPathSnapshot) -> Change {
        let previous = last
        let interfaces = Set(snapshot.interfaces)
        last = (snapshot.isSatisfied, interfaces)
        guard let previous, snapshot.isSatisfied else { return .none }
        guard previous.isSatisfied else { return .reconnect }
        let changed = previous.interfaces.symmetricDifference(interfaces)
        guard !changed.isEmpty else { return .none }
        let virtualOnly = changed.allSatisfy { name in Self.virtualPrefixes.contains { name.hasPrefix($0) } }
        return .interfaceChange(virtualOnly: virtualOnly)
    }
}

/// Production observer, on `NWPathMonitor`.
public final class SystemNetworkPathObserver: NetworkPathObserver, @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.ADBLX.ADBLX.PathMonitorQueue", qos: .utility)

    public init() {}

    public func start(_ handler: @escaping @Sendable (NetworkPathSnapshot) -> Void) {
        monitor.pathUpdateHandler = { path in
            handler(NetworkPathSnapshot(isSatisfied: path.status == .satisfied, interfaces: path.availableInterfaces.map(\.name)))
        }
        monitor.start(queue: queue)
    }

    public func stop() { monitor.cancel() }
}

/// Replaces the forwarder's upstream sockets when the network changes, marking the tunnel
/// `reasserting` while it does. Event-driven: no timer, no polling.
public final class DNSNetworkMonitor: @unchecked Sendable {
    private let observer: NetworkPathObserver
    private let forwarder: DNSUpstreamForwarder
    private let setReasserting: @Sendable (Bool) -> Void
    private let counters: DNSTunnelCounters?
    private let filter = OSAllocatedUnfairLock(initialState: PathChangeFilter())
    private let running = OSAllocatedUnfairLock<(stream: AsyncStream<NetworkPathSnapshot>.Continuation, task: Task<Void, Never>)?>(initialState: nil)

    public init(
        observer: NetworkPathObserver, forwarder: DNSUpstreamForwarder,
        setReasserting: @escaping @Sendable (Bool) -> Void, counters: DNSTunnelCounters? = nil
    ) {
        self.observer = observer
        self.forwarder = forwarder
        self.setReasserting = setReasserting
        self.counters = counters
    }

    /// Updates are handled one at a time, in the order they arrive.
    public func start() {
        let (stream, continuation) = AsyncStream.makeStream(of: NetworkPathSnapshot.self)
        let task = Task { [weak self] in
            for await snapshot in stream { await self?.handle(snapshot) }
        }
        running.withLock { $0 = (continuation, task) }
        observer.start { continuation.yield($0) }
    }

    public func stop() {
        observer.stop()
        running.withLock { state in
            state?.stream.finish()
            state?.task.cancel()
            state = nil
        }
    }

    public func handle(_ snapshot: NetworkPathSnapshot) async {
        counters?.increment(\.pathUpdates)
        let change = filter.withLock { $0.evaluate(snapshot) }
        switch change {
        case .none: return
        case .reconnect: counters?.increment(\.resetsReconnect)
        case .interfaceChange(let virtualOnly):
            counters?.increment(virtualOnly ? \.resetsVirtualInterfacesOnly : \.resetsInterfaceChange)
        }
        setReasserting(true)
        try? await forwarder.resetSockets()
        setReasserting(false)
    }
}

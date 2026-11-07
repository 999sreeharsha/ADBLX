import Foundation
import os
import Network

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
    private var last: (isSatisfied: Bool, key: String)?

    public init() {}

    public mutating func shouldReset(for snapshot: NetworkPathSnapshot) -> Bool {
        let previous = last
        last = (snapshot.isSatisfied, snapshot.key)
        guard let previous, snapshot.isSatisfied else { return false }
        return !(previous.isSatisfied && previous.key == snapshot.key)
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
    private let filter = OSAllocatedUnfairLock(initialState: PathChangeFilter())
    private let running = OSAllocatedUnfairLock<(stream: AsyncStream<NetworkPathSnapshot>.Continuation, task: Task<Void, Never>)?>(initialState: nil)

    public init(observer: NetworkPathObserver, forwarder: DNSUpstreamForwarder, setReasserting: @escaping @Sendable (Bool) -> Void) {
        self.observer = observer
        self.forwarder = forwarder
        self.setReasserting = setReasserting
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
        guard filter.withLock({ $0.shouldReset(for: snapshot) }) else { return }
        setReasserting(true)
        try? await forwarder.resetSockets()
        setReasserting(false)
    }
}

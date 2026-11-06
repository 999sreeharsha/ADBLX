import Foundation
import Network

/// One DNS exchange with the upstream over TCP: the message in, the answer out, both without
/// the two-byte length prefix. Injected so tests never touch the network.
public protocol DNSUpstreamTCPTransport: Sendable {
    func exchange(query: Data, host: String, port: UInt16) async throws -> Data
}

public enum DNSUpstreamTCPError: Error, Equatable {
    case timedOut
    case closed
    case badResponse
}

/// Production transport: a short-lived `NWConnection` per exchange. Used only when the upstream
/// truncated a UDP answer, so the extra handshake is rare.
public final class NWDNSUpstreamTCPTransport: DNSUpstreamTCPTransport, @unchecked Sendable {
    private let timeout: TimeInterval
    private let queue = DispatchQueue(label: "com.ADBLX.ADBLX.UpstreamTCPQueue", qos: .userInitiated)

    public init(timeout: TimeInterval = 3) {
        self.timeout = timeout
    }

    public func exchange(query: Data, host: String, port: UInt16) async throws -> Data {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw DNSUpstreamTCPError.badResponse }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let once = OnceFlag()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                func finish(_ result: Result<Data, Error>) {
                    guard once.claim() else { return }
                    connection.cancel()
                    continuation.resume(with: result)
                }
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        connection.send(content: DNSTCPFraming.frame(query), completion: .contentProcessed { error in
                            if let error { finish(.failure(error)); return }
                            Self.readMessage(from: connection, finish: finish)
                        })
                    case .failed(let error): finish(.failure(error))
                    case .cancelled: finish(.failure(DNSUpstreamTCPError.closed))
                    default: break
                    }
                }
                queue.asyncAfter(deadline: .now() + timeout) { finish(.failure(DNSUpstreamTCPError.timedOut)) }
                connection.start(queue: queue)
            }
        } onCancel: {
            connection.cancel()
        }
    }

    private static func readMessage(from connection: NWConnection, finish: @escaping (Result<Data, Error>) -> Void) {
        connection.receive(minimumIncompleteLength: 2, maximumLength: 2) { header, _, _, error in
            guard error == nil, let header, header.count == 2 else { finish(.failure(error ?? DNSUpstreamTCPError.closed)); return }
            let length = Int(header[header.startIndex]) << 8 | Int(header[header.startIndex + 1])
            guard length >= 12 else { finish(.failure(DNSUpstreamTCPError.badResponse)); return }
            connection.receive(minimumIncompleteLength: length, maximumLength: length) { body, _, _, error in
                guard error == nil, let body, body.count == length else { finish(.failure(error ?? DNSUpstreamTCPError.closed)); return }
                finish(.success(body))
            }
        }
    }

    private final class OnceFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if claimed { return false }
            claimed = true
            return true
        }
    }
}

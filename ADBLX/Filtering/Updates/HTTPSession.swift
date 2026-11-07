import Foundation

/// Thin seam over `URLSession.data(for:)` so `ManifestClient`/`FilterDownloadClient`
/// can be unit-tested with canned responses — no real network, no `URLProtocol` stubbing.
protocol HTTPSession: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
    /// Throws `HTTPSessionError.tooLarge` for a body over `maxBytes`.
    func data(for request: URLRequest, maxBytes: Int) async throws -> (Data, URLResponse)
    /// Writes the body to `destination`. Throws `HTTPSessionError.tooLarge` past `maxBytes`,
    /// leaving nothing at `destination`.
    func download(for request: URLRequest, maxBytes: Int, to destination: URL) async throws -> URLResponse
}

enum HTTPSessionError: Error, Equatable {
    case tooLarge
}

extension HTTPSession {
    /// For test sessions, which hold the whole body anyway: checks the declared length, then
    /// the received byte count.
    func data(for request: URLRequest, maxBytes: Int) async throws -> (Data, URLResponse) {
        let (data, response) = try await data(for: request)
        guard response.expectedContentLength <= maxBytes, data.count <= maxBytes else { throw HTTPSessionError.tooLarge }
        return (data, response)
    }

    /// For test sessions: the same checks as `data(for:maxBytes:)`, then the body is written.
    func download(for request: URLRequest, maxBytes: Int, to destination: URL) async throws -> URLResponse {
        let (data, response) = try await data(for: request, maxBytes: maxBytes)
        try data.write(to: destination, options: .atomic)
        return response
    }
}

extension URLSession: HTTPSession {
    /// Stops reading as soon as the declared length or the bytes received pass `maxBytes`, so an
    /// oversized body is never held in memory. Byte by byte, so only for small bodies.
    func data(for request: URLRequest, maxBytes: Int) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await bytes(for: request)
        guard response.expectedContentLength <= maxBytes else {
            bytes.task.cancel()
            throw HTTPSessionError.tooLarge
        }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > maxBytes {
                bytes.task.cancel()
                throw HTTPSessionError.tooLarge
            }
        }
        return (data, response)
    }

    /// A download task streaming to disk, cancelled by `CappedDownloadDelegate` as soon as the
    /// declared length or the bytes written pass `maxBytes`. Not the async
    /// `download(for:delegate:)`: it never calls the delegate's `didWriteData` (gotchas.md).
    func download(for request: URLRequest, maxBytes: Int, to destination: URL) async throws -> URLResponse {
        let delegate = CappedDownloadDelegate(maxBytes: maxBytes, destination: destination)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = downloadTask(with: request)
                delegate.start(task, continuation: continuation)
            }
        } onCancel: {
            delegate.cancel()
        }
    }
}

/// One capped download. Resumes its continuation exactly once, from `didCompleteWithError`, and
/// leaves nothing at the destination unless the whole body arrived within the cap.
nonisolated final class CappedDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let maxBytes: Int64
    private let destination: URL
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var continuation: CheckedContinuation<URLResponse, Error>?
    private var tooLarge = false
    private var moveError: Error?

    init(maxBytes: Int, destination: URL) {
        self.maxBytes = Int64(maxBytes)
        self.destination = destination
    }

    func start(_ task: URLSessionDownloadTask, continuation: CheckedContinuation<URLResponse, Error>) {
        lock.withLock {
            self.task = task
            self.continuation = continuation
        }
        task.delegate = self
        task.resume()
    }

    func cancel() {
        lock.withLock { task }?.cancel()
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        // The declared length arrives with the first chunk; the count is checked on every one,
        // since a server can omit the length or understate it.
        guard totalBytesWritten > maxBytes || totalBytesExpectedToWrite > maxBytes else { return }
        lock.withLock { tooLarge = true }
        downloadTask.cancel()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The system deletes `location` when this returns, so the file moves now.
        do {
            let size = (try FileManager.default.attributesOfItem(atPath: location.path)[.size] as? NSNumber)?.int64Value ?? 0
            guard size <= maxBytes else {
                lock.withLock { tooLarge = true }
                return
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            lock.withLock { moveError = error }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (continuation, tooLarge, moveError) = lock.withLock { () -> (CheckedContinuation<URLResponse, Error>?, Bool, Error?) in
            defer { self.continuation = nil }
            return (self.continuation, self.tooLarge, self.moveError)
        }
        guard let continuation else { return }
        if tooLarge || error != nil || moveError != nil {
            try? FileManager.default.removeItem(at: destination)
        }
        if tooLarge {
            continuation.resume(throwing: HTTPSessionError.tooLarge)
        } else if let failure = error ?? moveError {
            continuation.resume(throwing: failure)
        } else if let response = task.response {
            continuation.resume(returning: response)
        } else {
            continuation.resume(throwing: URLError(.badServerResponse))
        }
    }
}

/// Test/debug helper: returns a canned `Result` keyed by exact request URL.
/// Lives in the main target (not the test target) so it's reusable across every
/// `Updates/` test suite via `@testable import ADBLX`, matching how production types
/// in this module are structured.
final class MockHTTPSession: HTTPSession, @unchecked Sendable {
    struct UnregisteredURL: Error {
        var url: URL
    }

    private var responses: [URL: Result<(Data, URLResponse), Error>]
    // Optional artificial delay before returning, in nanoseconds — additive, defaults
    // to 0 so every existing call site is unaffected. Lets tests force genuinely
    // overlapping concurrent requests (e.g. 3+ concurrent UpdateCoordinator.run()
    // callers) instead of relying on incidental async-let scheduling, which can't
    // reliably prove a fix for a race that only manifests under staggered completion.
    private var delayNanoseconds: UInt64

    init(responses: [URL: Result<(Data, URLResponse), Error>], delayNanoseconds: UInt64 = 0) {
        self.responses = responses
        self.delayNanoseconds = delayNanoseconds
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url, let result = responses[url] else {
            throw UnregisteredURL(url: request.url ?? URL(string: "about:blank")!)
        }
        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }
        return try result.get()
    }
}

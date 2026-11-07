import Foundation

/// Follows a redirect only to the original request's host, over HTTPS. The manifest pins
/// where each list comes from (docs/Security/ManifestTrust.md, sourceURL), and `URLSession`
/// otherwise follows any redirect. A refused redirect hands back the 3xx response itself,
/// which the clients already reject as an unexpected status.
nonisolated final class RedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(Self.allows(from: task.originalRequest?.url, to: request.url) ? request : nil)
    }

    /// Every hop is compared with the original request, so a chain can't drift host by host.
    static func allows(from original: URL?, to target: URL?) -> Bool {
        guard let originalHost = original?.host()?.lowercased(), let target,
              target.scheme?.lowercased() == "https", let targetHost = target.host()?.lowercased() else { return false }
        return targetHost == originalHost
    }
}

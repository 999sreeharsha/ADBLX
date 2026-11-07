import Foundation
import Testing
@testable import ADBLX

/// The manifest pins where lists come from, so a redirect mustn't take a download somewhere
/// else, or off HTTPS (docs/Security/ManifestTrust.md, sourceURL).
@Suite("RedirectGuard")
struct RedirectGuardTests {
    private let original = URL(string: "https://999sreeharsha.github.io/ADBLX/filters/ads/easylist.txt")!

    /// What the guard answers for a redirect from `original` to `target`.
    private func followed(_ target: String) async -> URL? {
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: original)
        defer { session.invalidateAndCancel() }
        let response = HTTPURLResponse(url: original, statusCode: 301, httpVersion: nil, headerFields: ["Location": target])!
        return await withCheckedContinuation { continuation in
            RedirectGuard().urlSession(
                session, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: URL(string: target)!)
            ) { continuation.resume(returning: $0?.url) }
        }
    }

    @Test("A redirect on the same host over HTTPS is followed")
    func sameHostIsFollowed() async {
        let target = "https://999sreeharsha.github.io/ADBLX/filters/ads/easylist-2.txt"
        #expect(await followed(target) == URL(string: target))
    }

    @Test("A redirect to another host is refused")
    func otherHostIsRefused() async {
        for target in ["https://evil.example/easylist.txt", "https://sreeharsha.github.io.evil.example/x.txt", "https://github.io/x.txt"] {
            #expect(await followed(target) == nil, "\(target)")
        }
    }

    @Test("A redirect that downgrades to http is refused, even on the same host")
    func downgradeIsRefused() async {
        #expect(await followed("http://999sreeharsha.github.io/ADBLX/filters/ads/easylist.txt") == nil)
    }

    @Test("The host compares without regard to case")
    func hostCaseIsIgnored() async {
        let target = "https://999SreeHarsha.GitHub.io/ADBLX/filters/ads/easylist.txt"
        #expect(await followed(target) == URL(string: target))
    }

    @Test("The app's session applies the guard to every request, lists and manifest alike")
    func appSessionUsesTheGuard() {
        let session = AppCompositionRoot.makeHTTPSession() as? URLSession
        #expect(session?.delegate is RedirectGuard)
    }
}

import Foundation
import Testing
@testable import ADBLX

/// `SFContentBlockerManager.getStateOfContentBlocker` can drop its completion without calling it
/// (seen on the iOS 27.1 simulator, 2026-11-20: a whole test run hung on it). The provider must
/// answer "state unknown" after its timeout instead of waiting for ever.
@Suite("SystemContentBlockerStateProvider")
struct SystemContentBlockerStateProviderTests {
    private final class CompletionBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: (@Sendable (Bool?, Error?) -> Void)?
        func set(_ completion: @escaping @Sendable (Bool?, Error?) -> Void) {
            lock.lock(); stored = completion; lock.unlock()
        }
        var completion: (@Sendable (Bool?, Error?) -> Void)? {
            lock.lock(); defer { lock.unlock() }; return stored
        }
    }

    private func isUnavailable(_ state: ContentBlockerSettingsState) -> Bool {
        if case .unavailable = state { return true }
        return false
    }

    @Test("a state query whose completion never fires returns unavailable after the timeout",
          .timeLimit(.minutes(1)))
    func neverAnsweredTimesOut() async {
        let provider = SystemContentBlockerStateProvider(timeoutSeconds: 1) { _, _ in }
        let state = await provider.state(of: "com.ADBLX.ADBLX.ContentBlocker.Ads")
        #expect(isUnavailable(state))
    }

    @Test("a completion that arrives after the timeout is ignored", .timeLimit(.minutes(1)))
    func lateAnswerIgnored() async throws {
        let box = CompletionBox()
        let provider = SystemContentBlockerStateProvider(timeoutSeconds: 1) { _, completion in box.set(completion) }
        let state = await provider.state(of: "com.ADBLX.ADBLX.ContentBlocker.Ads")
        #expect(isUnavailable(state))
        // Resuming the continuation a second time would crash the test process.
        let lateCompletion = try #require(box.completion)
        lateCompletion(true, nil)
    }

    @Test("an answer before the timeout is returned", arguments: [true, false])
    func answerReturned(isEnabled: Bool) async {
        let provider = SystemContentBlockerStateProvider(timeoutSeconds: 10) { _, completion in completion(isEnabled, nil) }
        let state = await provider.state(of: "com.ADBLX.ADBLX.ContentBlocker.Ads")
        #expect(state == (isEnabled ? .enabled : .disabled))
    }

    @Test("an error or a missing state is unavailable")
    func errorOrMissingStateIsUnavailable() async {
        let failing = SystemContentBlockerStateProvider(timeoutSeconds: 10) { _, completion in
            completion(nil, CocoaError(.fileReadUnknown))
        }
        let empty = SystemContentBlockerStateProvider(timeoutSeconds: 10) { _, completion in completion(nil, nil) }
        #expect(isUnavailable(await failing.state(of: "x")))
        #expect(isUnavailable(await empty.state(of: "x")))
    }
}

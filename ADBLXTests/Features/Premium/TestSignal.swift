import Foundation
import ADBLXShared
@testable import ADBLX

/// Values a production callback reports, for a test to wait on instead of sleeping for a guessed
/// time. Values sent before anyone waits are kept, so none is missed. One waiter at a time.
nonisolated final class TestSignal<Value: Sendable>: @unchecked Sendable {
    private let stream: AsyncStream<Value>
    private let continuation: AsyncStream<Value>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream(of: Value.self)
    }

    func send(_ value: Value) {
        continuation.yield(value)
    }

    /// Suspends until a value for which `condition` holds arrives, skipping earlier ones. Bound
    /// the test with a `.timeLimit` trait.
    func wait(until condition: (Value) -> Bool) async {
        for await value in stream where condition(value) {
            return
        }
    }
}

/// Reports every `entitlement.json` the web extension publisher writes, as written.
nonisolated final class SignalingFileManager: FileManager, @unchecked Sendable {
    let written = TestSignal<WebExtensionPersistedEntitlement>()

    // The Objective-C method that Swift's `replaceItemAt(_:withItemAt:...)` calls; that one is
    // an overlay extension and can't be overridden.
    override func replaceItem(
        at originalItemURL: URL, withItemAt newItemURL: URL, backupItemName: String?,
        options: FileManager.ItemReplacementOptions = [], resultingItemURL resultingURL: AutoreleasingUnsafeMutablePointer<NSURL?>?
    ) throws {
        try super.replaceItem(
            at: originalItemURL, withItemAt: newItemURL, backupItemName: backupItemName, options: options, resultingItemURL: resultingURL
        )
        report(originalItemURL)
    }

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        try super.moveItem(at: srcURL, to: dstURL)
        report(dstURL)
    }

    private func report(_ url: URL) {
        guard let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(WebExtensionPersistedEntitlement.self, from: data) else { return }
        written.send(record)
    }
}

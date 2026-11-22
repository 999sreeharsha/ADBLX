import Foundation
import Testing
@testable import ADBLX

/// `SFContentBlockerManager` sets up its connection to Safari lazily on the first call, and that
/// setup is not thread-safe: two first calls at once resume the same XPC connection twice and iOS
/// kills the app (`BUG IN CLIENT OF LIBDISPATCH: Over-resume of an object`, iPhone 14 crash log
/// `ADBLX-2026-11-22-115708.ips`, three threads inside `_contentBlockerLoaderConnection`). Every
/// state check and reload therefore goes through one app-wide `ContentBlockerCallGate`.
@Suite("ContentBlockerCallGate")
struct ContentBlockerCallGateTests {
    /// Stands in for `SFContentBlockerManager`. Records how many calls are in flight at once.
    /// Answers arrive shortly after the call, on another thread, as the real one does, so calls
    /// that aren't serialized overlap.
    nonisolated final class FakeContentBlockerManager: @unchecked Sendable {
        private let lock = NSLock()
        private var inFlight = 0
        private var maxInFlight = 0
        private var recordedCalls: [String] = []
        private var heldCompletions: [String: @Sendable (Bool?, Error?) -> Void] = [:]
        private var timeoutReleasesAtCall: [String: Int] = [:]

        /// Identifiers whose completion never fires. Not counted as in flight.
        private let hung: Set<String>
        /// Identifiers whose completion fires only when the test calls `release(_:)`.
        private let held: Set<String>
        private let gate: ContentBlockerCallGate?

        /// Each identifier, as the manager receives a call for it.
        let invoked = TestSignal<String>()

        init(hung: Set<String> = [], held: Set<String> = [], gate: ContentBlockerCallGate? = nil) {
            self.hung = hung
            self.held = held
            self.gate = gate
        }

        var maxConcurrentCalls: Int { lock.withLock { maxInFlight } }
        var calls: [String] { lock.withLock { recordedCalls } }
        /// The gate's timeout-release count at the moment the call for `identifier` arrived.
        func timeoutReleases(seenBy identifier: String) -> Int? { lock.withLock { timeoutReleasesAtCall[identifier] } }

        var stateOperation: SystemContentBlockerStateProvider.StateOperation {
            { [self] identifier, completion in
                answer(identifier) { completion(true, nil) } hold: { completion($0, nil) }
            }
        }

        var reloadOperation: ReloadCoordinator.ReloadOperation {
            { [self] identifier, completion in
                answer(identifier) { completion(nil) } hold: { _ in completion(nil) }
            }
        }

        func release(_ identifier: String, isEnabled: Bool) {
            let completion = lock.withLock { heldCompletions.removeValue(forKey: identifier) }
            completion?(isEnabled, nil)
        }

        private func answer(_ identifier: String, reply: @escaping @Sendable () -> Void, hold: @escaping @Sendable (Bool?) -> Void) {
            let releases = gate?.timeoutReleases
            let counted = !hung.contains(identifier)
            lock.withLock {
                recordedCalls.append(identifier)
                timeoutReleasesAtCall[identifier] = releases
                if counted {
                    inFlight += 1
                    maxInFlight = max(maxInFlight, inFlight)
                }
                if held.contains(identifier) {
                    heldCompletions[identifier] = { [self] isEnabled, _ in
                        lock.withLock { inFlight -= 1 }
                        hold(isEnabled)
                    }
                }
            }
            invoked.send(identifier)
            guard counted, !held.contains(identifier) else { return }
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(2)) { [self] in
                lock.withLock { inFlight -= 1 }
                reply()
            }
        }
    }

    private func isUnavailable(_ state: ContentBlockerSettingsState) -> Bool {
        if case .unavailable = state { return true }
        return false
    }

    @Test("the manager never sees two calls at once, across many parallel callers and several instances",
          .timeLimit(.minutes(1)))
    func neverTwoCallsAtOnce() async {
        let gate = ContentBlockerCallGate()
        let manager = FakeContentBlockerManager()
        let providers = (0..<3).map { _ in
            SystemContentBlockerStateProvider(timeoutSeconds: 10, gate: gate, stateOperation: manager.stateOperation)
        }
        let reloaders = (0..<3).map { _ in
            ReloadCoordinator(timeoutSeconds: 10, gate: gate, reloadOperation: manager.reloadOperation)
        }

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<60 {
                // Distinct identifiers, so no two state checks share a call.
                let identifier = "blocker-\(index)"
                if index.isMultiple(of: 2) {
                    let provider = providers[index % providers.count]
                    group.addTask { _ = await provider.state(of: identifier) }
                } else {
                    let reloader = reloaders[index % reloaders.count]
                    group.addTask { _ = await reloader.reload(extensionIdentifier: identifier) }
                }
            }
        }

        #expect(manager.calls.count == 60)
        #expect(manager.maxConcurrentCalls == 1)
    }

    @Test("a call that never answers holds the gate only until its timeout, then later calls run",
          .timeLimit(.minutes(1)))
    func hungCallReleasesAtTimeout() async {
        let gate = ContentBlockerCallGate()
        let manager = FakeContentBlockerManager(hung: ["hung"], gate: gate)
        let provider = SystemContentBlockerStateProvider(timeoutSeconds: 1, gate: gate, stateOperation: manager.stateOperation)
        let reloader = ReloadCoordinator(timeoutSeconds: 10, gate: gate, reloadOperation: manager.reloadOperation)

        let hung = Task { await provider.state(of: "hung") }
        await manager.invoked.wait { $0 == "hung" }

        let checked = await provider.state(of: "after-state")
        let reloaded = await reloader.reload(extensionIdentifier: "after-reload")

        #expect(isUnavailable(await hung.value))
        #expect(checked == .enabled)
        #expect(reloaded.success)
        #expect(gate.timeoutReleases == 1)
        // The later calls reached the manager only after the hung call's hold had ended.
        #expect(manager.timeoutReleases(seenBy: "after-state") == 1)
    }

    @Test("concurrent checks of the same blocker share one call; a check after it makes a new one",
          .timeLimit(.minutes(1)))
    func concurrentChecksShareOneCall() async {
        let gate = ContentBlockerCallGate()
        let manager = FakeContentBlockerManager(held: ["ads"])
        let provider = SystemContentBlockerStateProvider(timeoutSeconds: 10, gate: gate, stateOperation: manager.stateOperation)

        let checks = (0..<10).map { _ in Task { await provider.state(of: "ads") } }
        await manager.invoked.wait { $0 == "ads" }
        for _ in 0..<100_000 where provider.callers(waitingOn: "ads") < 10 { await Task.yield() }
        #expect(provider.callers(waitingOn: "ads") == 10)

        manager.release("ads", isEnabled: true)
        for check in checks {
            #expect(await check.value == .enabled)
        }
        #expect(manager.calls == ["ads"])

        let later = Task { await provider.state(of: "ads") }
        await manager.invoked.wait { $0 == "ads" }
        manager.release("ads", isEnabled: false)
        #expect(await later.value == .disabled)
        #expect(manager.calls == ["ads", "ads"])
    }
}

/// One state provider and one reload coordinator for the whole app, both from
/// `AppCompositionRoot`. The gate keeps calls apart however many there are; one instance keeps
/// state-check sharing effective.
@Suite("Content blocker manager instances")
struct ContentBlockerManagerInstanceTests {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test("the composition root hands out one state provider and one reload coordinator")
    func compositionRootSharesOneInstanceEach() {
        #expect(AppCompositionRoot.makeContentBlockerStateProvider() === AppCompositionRoot.makeContentBlockerStateProvider())
        #expect(AppCompositionRoot.makeReloadCoordinator() === AppCompositionRoot.makeReloadCoordinator())
    }

    @Test("no app source outside AppCompositionRoot constructs a state provider or reload coordinator")
    func onlyTheCompositionRootConstructs() throws {
        let appFolder = Self.repoRoot.appendingPathComponent("ADBLX")
        let enumerator = try #require(FileManager.default.enumerator(at: appFolder, includingPropertiesForKeys: nil))
        // A constructor call, not a longer name ending the same way (`makeReloadCoordinator(`).
        let constructor = /(?:^|[^A-Za-z0-9_])(SystemContentBlockerStateProvider|ReloadCoordinator)\(/
        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" && url.lastPathComponent != "AppCompositionRoot.swift" {
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines)
            for (number, line) in lines.enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//") else { continue }
                if code.contains(constructor) {
                    offenders.append("\(url.lastPathComponent):\(number + 1)")
                }
            }
        }
        #expect(offenders.isEmpty, "construct these through AppCompositionRoot: \(offenders)")
    }
}

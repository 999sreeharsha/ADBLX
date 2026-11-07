import Testing
import Foundation
import WebKit
@testable import ADBLX

/// WebKit reports a failed rule compile as WKErrorDomain code 6, which a full disk can cause.
/// Neither place it can surface may read as a successful update.
@Suite("Compile and reload failures reach the user", .serialized)
struct ReloadFailureSurfacingTests {
    private let manifestEndpoint = URL(string: "https://example.com/manifest.json")!
    private let filterURL = URL(string: "https://example.com/filters/ads/easylist.txt")!
    private let ids = GroupExtensionIdentifiers(
        ads: "com.ADBLX.ADBLX.AdsBlocker", privacy: "com.ADBLX.ADBLX.PrivacyBlocker",
        annoyances: "com.ADBLX.ADBLX.AnnoyancesBlocker", regional: "com.ADBLX.ADBLX.RegionalBlocker"
    )
    private let goodRules = Data("[{\"trigger\":{\"url-filter\":\"good\"},\"action\":{\"type\":\"block\"}}]".utf8)
    private let compileError = NSError(domain: WKErrorDomain, code: WKError.Code.contentRuleListStoreCompileFailed.rawValue)

    private func makeCoordinator(
        store: FilterStore,
        reloads: ReloadRecorder,
        rules: Data? = nil,
        notModified: Bool = false,
        unsigned: Bool = false,
        blockerState: ContentBlockerSettingsState = .enabled
    ) throws -> UpdateCoordinator {
        let reloader = ReloadCoordinator(timeoutSeconds: 3, reloadOperation: reloads.operation)
        var responses: [URL: Result<(Data, URLResponse), Error>] = [:]
        if notModified {
            let response = HTTPURLResponse(url: manifestEndpoint, statusCode: 304, httpVersion: nil, headerFields: nil)!
            responses[manifestEndpoint] = .success((Data(), response))
        } else {
            let rules = rules ?? goodRules
            let entry = FilterManifest.Entry(
                id: "easylist", name: "EasyList", group: .ads, sourceURL: filterURL,
                version: Checksum.sha256Hex(of: rules), checksumSHA256: Checksum.sha256Hex(of: rules), ruleCount: 1,
                enabledByDefault: true, premium: false
            )
            let manifest = try JSONEncoder().encode(FilterManifest(manifestVersion: SignedManifests.version, entries: [entry]))
            let ok = HTTPURLResponse(url: manifestEndpoint, statusCode: 200, httpVersion: nil, headerFields: ["ETag": "\"v1\""])!
            let filterOK = HTTPURLResponse(url: filterURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
            responses[manifestEndpoint] = .success((manifest, ok))
            responses[filterURL] = .success((rules, filterOK))
        }
        let session = MockHTTPSession(responses: responses)
        let pipeline = FilterPipeline(
            validator: FilterValidator(), compiler: PassthroughRuleCompiler(),
            compositionService: JSONArrayCompositionService(),
            partitioner: GroupPartitioner(extensionIdentifiers: ids),
            store: store, writer: AtomicRuleWriter(), reloader: reloader, gate: FilterTransactionGate()
        )
        return UpdateCoordinator(
            manifestClient: unsigned
                ? SignedManifests.client(session: session, endpoint: manifestEndpoint)
                : SignedManifests.signingClient(session: session, endpoint: manifestEndpoint),
            manifestStore: ManifestStore(filterStore: store),
            downloadClient: FilterDownloadClient(session: session),
            pipeline: pipeline, store: store, reloader: reloader, extensionIdentifiers: ids,
            entitlementService: StubEntitlementService(isPremiumEntitled: false), gate: FilterTransactionGate(),
            stateProvider: FixedBlockerState(blockerState)
        )
    }

    private var reloadFailedMessage: UpdatePhase { .failed(String(localized: "updateprogress.status.reloadFailed")) }

    @Test("a reload's compile error stays in the per-extension status")
    func reloadKeepsCompileError() async throws {
        let reloads = ReloadRecorder(failure: compileError)
        let identifier = "test.\(UUID().uuidString)"

        let result = await ReloadCoordinator(timeoutSeconds: 3, reloadOperation: reloads.operation)
            .reload(extensionIdentifier: identifier)

        #expect(!result.success)
        let error = try #require(result.error) as NSError
        #expect(error.domain == WKErrorDomain)
        #expect(error.code == 6)
        #expect(ReloadResultLog.shared.entries().first { $0.extensionIdentifier == identifier }?.outcome == "failed WKErrorDomain#6")
    }

    @Test("an update Safari couldn't apply is not reported as complete")
    @MainActor
    func failedReloadIsNotComplete() async throws {
        let reloads = ReloadRecorder(failure: compileError)
        let coordinator = try makeCoordinator(store: .temporary(), reloads: reloads)
        let model = UpdateProgressModel(stateProvider: FixedBlockerState(.enabled))

        await model.start(coordinator: coordinator)

        #expect(model.phase == reloadFailedMessage)
    }

    // The user turned this blocker off. That isn't a failure they can do anything about.
    @Test("a failed reload of a disabled blocker still completes")
    @MainActor
    func disabledBlockerCompletes() async throws {
        let reloads = ReloadRecorder(failure: compileError)
        let store = FilterStore.temporary()
        let coordinator = try makeCoordinator(store: store, reloads: reloads, blockerState: .disabled)
        let model = UpdateProgressModel(stateProvider: FixedBlockerState(.disabled))

        await model.start(coordinator: coordinator)

        #expect(model.phase == .complete)

        // And it isn't retried, so later updates still report up to date.
        let attempts = reloads.calls.count
        let second = try await makeCoordinator(store: store, reloads: reloads, notModified: true, blockerState: .disabled).run()
        guard case .upToDate = second else { Issue.record("expected .upToDate, got \(second)"); return }
        #expect(reloads.calls.count == attempts)
    }

    // Otherwise "try again" gets a 304, reloads nothing and claims success.
    @Test("trying again after a failed reload retries it, even on a 304")
    @MainActor
    func retryAfterFailedReload() async throws {
        let store = FilterStore.temporary()
        let reloads = ReloadRecorder(failure: compileError)
        let enabled = FixedBlockerState(.enabled)

        await UpdateProgressModel(stateProvider: enabled).start(coordinator: try makeCoordinator(store: store, reloads: reloads))
        let attemptsAfterUpdate = reloads.calls.count

        let stillFailing = UpdateProgressModel(stateProvider: enabled)
        await stillFailing.start(coordinator: try makeCoordinator(store: store, reloads: reloads, notModified: true))
        #expect(stillFailing.phase == reloadFailedMessage)
        #expect(reloads.calls.count == attemptsAfterUpdate + 1)

        reloads.failure = nil
        let recovered = UpdateProgressModel(stateProvider: enabled)
        await recovered.start(coordinator: try makeCoordinator(store: store, reloads: reloads, notModified: true))
        #expect(recovered.phase == .complete)
        #expect(reloads.calls.count == attemptsAfterUpdate + 2)

        // Applied now, so nothing is left to retry.
        await UpdateProgressModel(stateProvider: enabled).start(coordinator: try makeCoordinator(store: store, reloads: reloads, notModified: true))
        #expect(reloads.calls.count == attemptsAfterUpdate + 2)
    }

    // Retrying a reload doesn't depend on the manifest, so a rejected one mustn't skip it.
    @Test("a rejected manifest still retries a pending reload")
    @MainActor
    func rejectedManifestRetriesPendingReload() async throws {
        let store = FilterStore.temporary()
        let reloads = ReloadRecorder(failure: compileError)
        let enabled = FixedBlockerState(.enabled)
        await UpdateProgressModel(stateProvider: enabled).start(coordinator: try makeCoordinator(store: store, reloads: reloads))
        let attemptsAfterUpdate = reloads.calls.count

        reloads.failure = nil
        let rejected = UpdateProgressModel(stateProvider: enabled)
        await rejected.start(coordinator: try makeCoordinator(store: store, reloads: reloads, rules: Data("[]".utf8), unsigned: true))

        #expect(reloads.calls.count == attemptsAfterUpdate + 1)
        #expect(rejected.phase == .failed(String(localized: "updateprogress.status.failed")))
        // Applied by that retry, so nothing is left pending.
        await UpdateProgressModel(stateProvider: enabled).start(coordinator: try makeCoordinator(store: store, reloads: reloads, notModified: true))
        #expect(reloads.calls.count == attemptsAfterUpdate + 1)
    }

    private let unknown = ContentBlockerSettingsState.unavailable("state unreadable")

    // The user may well be using it, so "try again" must reload it. But they can't act on an
    // unknown state, so a retry that fails again still reports up to date.
    @Test("a failed reload whose blocker state is unknown is retried, and the retry still reports up to date")
    func unknownStateIsRetried() async throws {
        let store = FilterStore.temporary()
        let reloads = ReloadRecorder(failure: compileError)
        _ = try await makeCoordinator(store: store, reloads: reloads, blockerState: unknown).run()
        let attempts = reloads.calls.count

        let retry = try await makeCoordinator(store: store, reloads: reloads, notModified: true, blockerState: unknown).run()

        guard case .upToDate = retry else { Issue.record("expected .upToDate, got \(retry)"); return }
        #expect(reloads.calls.count == attempts + 1)
    }

    @Test("a blocker whose state stays unknown is retried three times, then left alone")
    func unknownStateRetriesAreCapped() async throws {
        let store = FilterStore.temporary()
        let reloads = ReloadRecorder(failure: compileError)
        _ = try await makeCoordinator(store: store, reloads: reloads, blockerState: unknown).run()
        let attempts = reloads.calls.count

        for _ in 0..<5 {
            _ = try await makeCoordinator(store: store, reloads: reloads, notModified: true, blockerState: unknown).run()
        }

        #expect(reloads.calls.count == attempts + 3)
    }

    // Written by the previous build, before entries carried a retry count.
    @Test("a pending list in the old format is still retried")
    func oldFormatIsRead() async throws {
        let store = FilterStore.temporary()
        try await store.writeMetadata(try JSONEncoder().encode([ids.ads]), filename: "pending_reloads.json")
        let reloads = ReloadRecorder(failure: nil)

        _ = try await makeCoordinator(store: store, reloads: reloads, notModified: true).run()

        #expect(reloads.calls == [ids.ads])
    }

    // Real WebKit, real code 6: this url-filter isn't a regex it can compile.
    @Test("rules WebKit won't compile roll back, leave the installed rules alone and report failure")
    @MainActor
    func webKitRejectionKeepsLastGoodRules() async throws {
        let store = FilterStore.temporary()
        let reloads = ReloadRecorder(failure: nil)
        let first = try await makeCoordinator(store: store, reloads: reloads).run()
        guard case .updated = first else { Issue.record("expected the first update to install, got \(first)"); return }
        let rulesBefore = try await store.read("Ads.json", in: .compiled)
        try await ManifestStore(filterStore: store).save(FilterManifest(manifestVersion: "2026-11-06T00:00:00Z", entries: []), etag: nil)

        let rejected = Data("[{\"trigger\":{\"url-filter\":\"(\"},\"action\":{\"type\":\"block\"}}]".utf8)
        let direct = try await makeCoordinator(store: store, reloads: reloads, rules: rejected).run()
        guard case .rolledBack(let reason) = direct, case .webKitCompilationRejected = reason as? FilterPipelineError else {
            Issue.record("expected a WebKit rejection, got \(direct)"); return
        }

        let model = UpdateProgressModel(stateProvider: FixedBlockerState(.enabled))
        await model.start(coordinator: try makeCoordinator(store: store, reloads: reloads, rules: rejected))

        #expect(model.phase == .failed(String(localized: "updateprogress.status.failed")))
        #expect(try await store.read("Ads.json", in: .compiled) == rulesBefore)
    }

    @Test("a snapshot that fails on a full disk leaves nothing behind")
    func failedSnapshotCleansUp() async throws {
        let store = FilterStore.temporary(fileManager: OutOfSpaceFileManager())
        let compiled = try await store.directoryURL(.compiled)
        try goodRules.write(to: compiled.appendingPathComponent("Ads.json"))

        await #expect(throws: (any Error).self) { try await store.snapshotForRollback() }

        let previous = compiled.deletingLastPathComponent().appendingPathComponent("Previous")
        #expect(!FileManager.default.fileExists(atPath: previous.path))
    }
}

private nonisolated final class ReloadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private var storedFailure: Error?

    init(failure: Error?) { storedFailure = failure }

    var calls: [String] { lock.withLock { recorded } }
    var failure: Error? {
        get { lock.withLock { storedFailure } }
        set { lock.withLock { storedFailure = newValue } }
    }

    var operation: ReloadCoordinator.ReloadOperation {
        { [self] identifier, completion in
            let failure = lock.withLock {
                recorded.append(identifier)
                return storedFailure
            }
            completion(failure)
        }
    }
}

private nonisolated struct FixedBlockerState {
    let value: ContentBlockerSettingsState
    init(_ value: ContentBlockerSettingsState) { self.value = value }
    func state(of extensionIdentifier: String) async -> ContentBlockerSettingsState { value }
}

extension FixedBlockerState: ContentBlockerStateProviding {}

private nonisolated final class OutOfSpaceFileManager: FileManager, @unchecked Sendable {
    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        throw CocoaError(.fileWriteOutOfSpace)
    }
}

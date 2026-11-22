import Foundation
import Testing
@testable import ADBLX

/// Blocker Settings checks wait their turn in `ContentBlockerCallGate`, so the Protection tab
/// shows its content at once, marks each blocker "checking", and fills in each blocker's state
/// as its own check returns.
@MainActor
@Suite("Protection tab while blocker checks are pending", .timeLimit(.minutes(1)))
struct ProtectionCheckingStateTests {
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<100_000 where !condition() { await Task.yield() }
    }

    private func category(_ id: FilterCategoryID, in viewModel: ProtectionViewModel) -> ProtectionCategory? {
        viewModel.status?.categories.first { $0.id == id }
    }

    @Test("a check held in the gate doesn't hold back the screen: content shows, that blocker is checking")
    func heldCheckStillShowsContent() async throws {
        let privacy = try #require(RealProtectionService.defaultDescriptors.first { $0.category == .privacy }).extensionIdentifier
        let gate = ContentBlockerCallGate()
        let manager = ContentBlockerCallGateTests.FakeContentBlockerManager(held: [privacy])
        let filterStore = FilterStore.temporary()
        let service = RealProtectionService(
            store: filterStore,
            preferencesStore: FilterPreferencesStore(store: filterStore),
            stateProvider: SystemContentBlockerStateProvider(timeoutSeconds: 30, gate: gate, stateOperation: manager.stateOperation)
        )
        let viewModel = ProtectionViewModel(service: service)

        let refresh = Task { await viewModel.refreshProtectionStatus(reason: .initialLoad) }
        await manager.invoked.wait { $0 == privacy }
        await waitUntil { viewModel.status != nil }

        #expect(viewModel.status?.categories.map(\.id) == FilterCategoryID.allCases)
        #expect(category(.privacy, in: viewModel)?.status == .checking)
        #expect(viewModel.status?.masterState == .checking)

        manager.release(privacy, isEnabled: true)
        _ = await refresh.value
        #expect(viewModel.status?.categories.allSatisfy { $0.status == .active } == true)
        #expect(viewModel.status?.masterState == .active)
    }

    @Test("every blocker starts as checking, and each fills in as its own check returns")
    func eachBlockerFillsInOnItsOwn() async {
        let service = DrivenProtectionService()
        let viewModel = ProtectionViewModel(service: service)

        let refresh = Task { await viewModel.refreshProtectionStatus(reason: .initialLoad) }
        await waitUntil { viewModel.status != nil }
        #expect(viewModel.status?.categories.map(\.status) == [.checking, .checking, .checking, .checking])
        #expect(viewModel.status?.masterState == .checking)

        service.answer(.ads, .enabled)
        await waitUntil { category(.ads, in: viewModel)?.status == .active }
        #expect(category(.ads, in: viewModel)?.status == .active)
        #expect(category(.privacy, in: viewModel)?.status == .checking)
        #expect(viewModel.status?.masterState == .checking)

        service.answer(.privacy, .disabled)
        await waitUntil { category(.privacy, in: viewModel)?.status == .disabledInSettings }
        #expect(category(.privacy, in: viewModel)?.status == .disabledInSettings)
        #expect(category(.annoyances, in: viewModel)?.status == .checking)

        service.answer(.annoyances, .enabled)
        service.answer(.regional, .enabled)
        service.finishChecks()
        _ = await refresh.value
        #expect(viewModel.status?.masterState == .partiallyActive)
    }

    @Test("a later refresh shows each blocker's last known state while it is checked again")
    func refreshKeepsLastKnownStates() async {
        let service = DrivenProtectionService()
        let viewModel = ProtectionViewModel(service: service)

        let first = Task { await viewModel.refreshProtectionStatus(reason: .initialLoad) }
        await waitUntil { viewModel.status != nil }
        for id in FilterCategoryID.allCases { service.answer(id, id == .privacy ? .disabled : .enabled) }
        service.finishChecks()
        _ = await first.value

        let second = Task { await viewModel.refreshProtectionStatus(reason: .foreground) }
        await waitUntil { service.checkRuns == 2 }
        // An answer from the second run shows that run's starting status has been applied.
        service.answer(.regional, .disabled)
        await waitUntil { category(.regional, in: viewModel)?.status == .disabledInSettings }
        #expect(category(.regional, in: viewModel)?.status == .disabledInSettings)
        #expect(category(.privacy, in: viewModel)?.status == .disabledInSettings)
        #expect(viewModel.status?.masterState == .partiallyActive)

        service.finishChecks()
        _ = await second.value
    }

    @Test("turning off a blocker that is still checking turns it off, with no Settings prompt")
    func toggleWhileChecking() async {
        let service = DrivenProtectionService()
        let viewModel = ProtectionViewModel(service: service)

        let refresh = Task { await viewModel.refreshProtectionStatus(reason: .initialLoad) }
        await waitUntil { viewModel.status != nil }

        await viewModel.toggleCategory(.ads)

        #expect(category(.ads, in: viewModel)?.isEnabled == false)
        #expect(category(.ads, in: viewModel)?.status == .disabledByUser)
        #expect(viewModel.showSettingsPrompt == false)
        #expect(service.lastSetCategory?.0 == .ads)
        #expect(service.lastSetCategory?.1 == false)

        service.finishChecks()
        _ = await refresh.value
    }

    @Test("a category turned on while its blocker is checking prompts once the check says it's off in Settings")
    func turnedOnWhileCheckingThenOffInSettingsPrompts() async {
        let service = DrivenProtectionService(initiallyEnabled: false)
        let viewModel = ProtectionViewModel(service: service)

        let refresh = Task { await viewModel.refreshProtectionStatus(reason: .initialLoad) }
        await waitUntil { viewModel.status != nil }

        await viewModel.toggleCategory(.ads)
        #expect(category(.ads, in: viewModel)?.isEnabled == true)
        #expect(viewModel.showSettingsPrompt == false)

        service.answer(.ads, .disabled)
        await waitUntil { category(.ads, in: viewModel)?.status == .disabledInSettings }
        #expect(viewModel.showSettingsPrompt == true)
        #expect(viewModel.pendingSettingsCategory?.id == .ads)

        service.finishChecks()
        _ = await refresh.value
    }

    @Test("no prompt when the check for a category turned on while checking says it's on, or it was turned off again")
    func turnedOnWhileCheckingWithoutPrompt() async {
        let service = DrivenProtectionService(initiallyEnabled: false)
        let viewModel = ProtectionViewModel(service: service)

        let refresh = Task { await viewModel.refreshProtectionStatus(reason: .initialLoad) }
        await waitUntil { viewModel.status != nil }

        await viewModel.toggleCategory(.ads)
        await viewModel.toggleCategory(.privacy)
        await viewModel.toggleCategory(.privacy)
        service.answer(.ads, .enabled)
        service.answer(.privacy, .disabled)
        service.finishChecks()
        _ = await refresh.value

        #expect(category(.ads, in: viewModel)?.status == .active)
        #expect(category(.privacy, in: viewModel)?.status == .disabledByUser)
        #expect(viewModel.showSettingsPrompt == false)
    }

    @Test("a category whose blocker is still checking")
    func checkingCategoryModel() {
        let checking = ProtectionCategory(id: .ads, name: "Ads", description: "", isEnabled: true, ruleCount: 0, extensionSettingsState: nil)
        let turnedOff = ProtectionCategory(id: .privacy, name: "Privacy", description: "", isEnabled: false, ruleCount: 0, extensionSettingsState: nil)

        #expect(checking.status == .checking)
        // The toggle shows the user's choice until the check says otherwise.
        #expect(checking.isEffectivelyActive)
        #expect(turnedOff.status == .disabledByUser)
        #expect(RealProtectionService.computeMasterState(from: [checking, turnedOff]) == .checking)
    }
}

/// A Protection service whose blocker checks answer only when the test says so.
nonisolated final class DrivenProtectionService: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [AsyncStream<CategorySettingsState>.Continuation] = []
    private var setCalls: [(FilterCategoryID, Bool)] = []
    private let initiallyEnabled: Bool

    /// `initiallyEnabled` is the user's choice for every category before any toggle.
    init(initiallyEnabled: Bool = true) {
        self.initiallyEnabled = initiallyEnabled
    }

    var checkRuns: Int { lock.withLock { continuations.count } }
    var lastSetCategory: (FilterCategoryID, Bool)? { lock.withLock { setCalls.last } }

    /// Answers the latest run of checks.
    func answer(_ category: FilterCategoryID, _ state: ContentBlockerSettingsState) {
        lock.withLock { continuations.last }?.yield(CategorySettingsState(category: category, state: state))
    }

    func finishChecks() {
        lock.withLock { continuations.last }?.finish()
    }
}

extension DrivenProtectionService: ProtectionService {
    func fetchStatusBeforeChecks() async -> ProtectionStatus {
        let categories = FilterCategoryID.allCases.map {
            ProtectionCategory(
                id: $0, name: $0.rawValue, description: "", isEnabled: initiallyEnabled, ruleCount: 0, extensionSettingsState: nil
            )
        }
        return ProtectionStatus(masterState: RealProtectionService.computeMasterState(from: categories), categories: categories)
    }

    func extensionSettingsStates() -> AsyncStream<CategorySettingsState> {
        let (stream, continuation) = AsyncStream.makeStream(of: CategorySettingsState.self)
        lock.withLock { continuations.append(continuation) }
        return stream
    }

    func setCategory(_ id: FilterCategoryID, enabled: Bool) async {
        lock.withLock { setCalls.append((id, enabled)) }
    }

    func setFilterList(_ id: String, enabled: Bool) async {}
}

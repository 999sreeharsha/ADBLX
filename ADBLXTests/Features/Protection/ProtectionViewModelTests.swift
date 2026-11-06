// ADBLXTests/Features/Protection/ProtectionViewModelTests.swift
import Testing
@testable import ADBLX

@Suite("ProtectionViewModel")
struct ProtectionViewModelTests {
    @Test("load() populates status from the injected service")
    func loadPopulatesStatus() async {
        let expected = ProtectionStatus(
            masterState: .active,
            categories: [
                ProtectionCategory(id: .ads, name: "Ads", description: "Blocks display and video ads", isEnabled: true, ruleCount: 62_000),
            ]
        )
        let viewModel = ProtectionViewModel(service: StubProtectionService(statusToReturn: expected))

        await viewModel.load()

        #expect(viewModel.status == expected)
    }

    @Test("toggleCategory flips the category's isEnabled and calls the service")
    func toggleCategoryFlipsState() async {
        let initial = ProtectionStatus(
            masterState: .active,
            categories: [
                ProtectionCategory(id: .ads, name: "Ads", description: "Blocks display and video ads", isEnabled: true, ruleCount: 62_000),
            ]
        )
        let service = StubProtectionService(statusToReturn: initial)
        let viewModel = ProtectionViewModel(service: service)
        await viewModel.load()

        await viewModel.toggleCategory(.ads)

        #expect(viewModel.status?.categories.first?.isEnabled == false)
        let lastSetCall = await service.lastSetCall
        #expect(lastSetCall?.0 == .ads)
        #expect(lastSetCall?.1 == false)
    }

    @Test("toggleCategory turning ON when disabled in Settings shows prompt")
    func toggleCategoryShowsPromptWhenDisabledInSettings() async {
        let initial = ProtectionStatus(
            masterState: .disabledInSettings,
            categories: [
                ProtectionCategory(
                    id: .ads,
                    name: "Ads",
                    description: "Blocks ads",
                    isEnabled: false,
                    ruleCount: 10_000,
                    extensionSettingsState: .disabled,
                    participatesInProtectionStatus: true
                )
            ]
        )
        let service = StubProtectionService(statusToReturn: initial)
        let viewModel = ProtectionViewModel(service: service)
        await viewModel.load()

        #expect(viewModel.showSettingsPrompt == false)

        await viewModel.toggleCategory(.ads)

        #expect(viewModel.status?.categories.first?.isEnabled == true)
        #expect(viewModel.showSettingsPrompt == true)
        #expect(viewModel.pendingSettingsCategory?.id == .ads)
    }

    @Test("toggleCategory turning OFF when active does not show prompt")
    func toggleCategoryTurningOffDoesNotShowPrompt() async {
        let initial = ProtectionStatus(
            masterState: .active,
            categories: [
                ProtectionCategory(
                    id: .ads,
                    name: "Ads",
                    description: "Blocks ads",
                    isEnabled: true,
                    ruleCount: 10_000,
                    extensionSettingsState: .enabled,
                    participatesInProtectionStatus: true
                )
            ]
        )
        let service = StubProtectionService(statusToReturn: initial)
        let viewModel = ProtectionViewModel(service: service)
        await viewModel.load()

        await viewModel.toggleCategory(.ads)

        #expect(viewModel.status?.categories.first?.isEnabled == false)
        #expect(viewModel.showSettingsPrompt == false)
    }

    @Test("refreshProtectionStatus coalesces concurrent calls")
    func refreshProtectionStatusCoalesces() async {
        let expected = ProtectionStatus(
            masterState: .active,
            categories: []
        )
        let slowService = SlowStubProtectionService(statusToReturn: expected)
        let viewModel = ProtectionViewModel(service: slowService)

        async let r1 = viewModel.refreshProtectionStatus(reason: .initialLoad)
        async let r2 = viewModel.refreshProtectionStatus(reason: .foreground)

        let (res1, res2) = await (r1, r2)
        #expect(res1 == expected)
        #expect(res2 == expected)
        let fetchCount = await slowService.fetchCount
        #expect(fetchCount == 1)
    }
}

private actor StubProtectionService {
    let statusToReturn: ProtectionStatus
    private(set) var lastSetCall: (FilterCategoryID, Bool)?

    init(statusToReturn: ProtectionStatus) {
        self.statusToReturn = statusToReturn
    }

    func fetchStatus() async -> ProtectionStatus { statusToReturn }

    func setCategory(_ id: FilterCategoryID, enabled: Bool) async {
        lastSetCall = (id, enabled)
    }

    func setFilterList(_ id: String, enabled: Bool) async {}
}

extension StubProtectionService: ProtectionService {}

private actor SlowStubProtectionService {
    let statusToReturn: ProtectionStatus
    private(set) var fetchCount = 0

    init(statusToReturn: ProtectionStatus) {
        self.statusToReturn = statusToReturn
    }

    func fetchStatus() async -> ProtectionStatus {
        fetchCount += 1
        try? await Task.sleep(for: .milliseconds(50))
        return statusToReturn
    }

    func setCategory(_ id: FilterCategoryID, enabled: Bool) async {}
    func setFilterList(_ id: String, enabled: Bool) async {}
}

extension SlowStubProtectionService: ProtectionService {}

@Suite("ProtectionViewModel filter lists")
struct ProtectionViewModelFilterListTests {
    @Test("load() populates filterLists alongside categories")
    func loadPopulatesFilterLists() async {
        let expected = ProtectionStatus(
            masterState: .active,
            categories: [],
            filterLists: [
                FilterListEntry(id: "easylist", name: "EasyList", category: .ads, version: "2026-07-15", isEnabled: true, isPremium: false),
            ]
        )
        let viewModel = ProtectionViewModel(service: StubFilterListService(statusToReturn: expected))

        await viewModel.load()

        #expect(viewModel.status?.filterLists == expected.filterLists)
    }

    @Test("toggleFilterList flips the list's isEnabled and calls the service")
    func toggleFilterListFlipsState() async {
        let initial = ProtectionStatus(
            masterState: .active,
            categories: [],
            filterLists: [
                FilterListEntry(id: "easylist", name: "EasyList", category: .ads, version: "2026-07-15", isEnabled: true, isPremium: false),
            ]
        )
        let service = StubFilterListService(statusToReturn: initial)
        let viewModel = ProtectionViewModel(service: service)
        await viewModel.load()

        await viewModel.toggleFilterList("easylist")

        #expect(viewModel.status?.filterLists.first?.isEnabled == false)
    }
}

private struct StubFilterListService {
    let statusToReturn: ProtectionStatus
    func fetchStatus() async -> ProtectionStatus { statusToReturn }
    func setCategory(_ id: FilterCategoryID, enabled: Bool) async {}
    func setFilterList(_ id: String, enabled: Bool) async {}
}

extension StubFilterListService: ProtectionService {}

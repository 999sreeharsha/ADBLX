// ADBLXTests/Features/Protection/ProtectionViewModelTests.swift
import Testing
@testable import ADBLX

@Suite("ProtectionViewModel")
struct ProtectionViewModelTests {
    @Test("load() populates status from the injected service")
    func loadPopulatesStatus() async {
        let expected = ProtectionStatus(
            isSafariExtensionEnabled: true,
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
            isSafariExtensionEnabled: true,
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
}

private actor StubProtectionService: ProtectionService {
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

@Suite("ProtectionViewModel filter lists")
struct ProtectionViewModelFilterListTests {
    @Test("load() populates filterLists alongside categories")
    func loadPopulatesFilterLists() async {
        let expected = ProtectionStatus(
            isSafariExtensionEnabled: true,
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
            isSafariExtensionEnabled: true,
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

private struct StubFilterListService: ProtectionService {
    let statusToReturn: ProtectionStatus
    func fetchStatus() async -> ProtectionStatus { statusToReturn }
    func setCategory(_ id: FilterCategoryID, enabled: Bool) async {}
    func setFilterList(_ id: String, enabled: Bool) async {}
}

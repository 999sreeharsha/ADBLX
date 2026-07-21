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
}

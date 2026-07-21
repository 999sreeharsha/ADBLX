// ADBLXTests/Features/Home/HomeViewModelTests.swift
import Testing
@testable import ADBLX

@Suite("HomeViewModel")
struct HomeViewModelTests {
    @Test("load() populates status from the injected service")
    func loadPopulatesStatus() async {
        let expected = HomeStatus(
            isProtectionEnabled: true,
            dnsProviderName: "NextDNS",
            lastUpdateDescription: "2m ago",
            ruleCount: 142_042,
            blockedPercentage: 99.2,
            recentActivity: []
        )
        let viewModel = HomeViewModel(service: StubHomeService(statusToReturn: expected))

        await viewModel.load()

        #expect(viewModel.status == expected)
        #expect(viewModel.isLoading == false)
    }
}

private struct StubHomeService: HomeService {
    let statusToReturn: HomeStatus
    func fetchStatus() async -> HomeStatus { statusToReturn }
}

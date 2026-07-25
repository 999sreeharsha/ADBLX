// ADBLXTests/Features/Home/HomeViewModelTests.swift
import Testing
@testable import ADBLX

@Suite("HomeViewModel")
struct HomeViewModelTests {
    @Test("load() populates status from the injected service")
    func loadPopulatesStatus() async {
        let expected = HomeStatus(
            isProtectionEnabled: true,
            safariProtectionStatus: .active,
            lastUpdateDescription: "2m ago",
            ruleCount: 142_042,
            recentActivity: []
        )
        let viewModel = HomeViewModel(service: StubHomeService(statusToReturn: expected))

        await viewModel.load()

        #expect(viewModel.status == expected)
        #expect(viewModel.isLoading == false)
    }

    @Test("loadWithBootstrapRetry retries until isProtectionEnabled becomes true, then stops")
    func retriesUntilProtectionEnabled() async {
        let service = SequencedStubHomeService(statusesToReturn: [
            HomeStatus(
                isProtectionEnabled: false, safariProtectionStatus: .active,
                lastUpdateDescription: "Never", ruleCount: 0, recentActivity: []
            ),
            HomeStatus(
                isProtectionEnabled: true, safariProtectionStatus: .active,
                lastUpdateDescription: "just now", ruleCount: 62_000, recentActivity: []
            ),
        ])
        let viewModel = HomeViewModel(service: service)

        await viewModel.loadWithBootstrapRetry(maxAttempts: 3, retryDelay: .milliseconds(1))

        #expect(viewModel.status?.isProtectionEnabled == true)
        #expect(await service.callCount == 2)
    }

    @Test("loadWithBootstrapRetry gives up after maxAttempts and leaves the last (empty) status")
    func givesUpAfterMaxAttempts() async {
        let service = SequencedStubHomeService(statusesToReturn: [
            HomeStatus(
                isProtectionEnabled: false, safariProtectionStatus: .active,
                lastUpdateDescription: "Never", ruleCount: 0, recentActivity: []
            ),
        ])
        let viewModel = HomeViewModel(service: service)

        await viewModel.loadWithBootstrapRetry(maxAttempts: 2, retryDelay: .milliseconds(1))

        #expect(viewModel.status?.isProtectionEnabled == false)
        #expect(await service.callCount == 2)
    }
}

private struct StubHomeService: HomeService {
    let statusToReturn: HomeStatus
    func fetchStatus() async -> HomeStatus { statusToReturn }
}

private actor SequencedStubHomeService: HomeService {
    private var statuses: [HomeStatus]
    private(set) var callCount = 0

    init(statusesToReturn: [HomeStatus]) {
        self.statuses = statusesToReturn
    }

    func fetchStatus() async -> HomeStatus {
        callCount += 1
        if statuses.count > 1 {
            return statuses.removeFirst()
        }
        return statuses[0]
    }
}

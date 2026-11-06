// ADBLXTests/Features/Settings/SettingsViewModelTests.swift
import Testing
@testable import ADBLX

@Suite("SettingsViewModel")
struct SettingsViewModelTests {
    @Test("load() populates snapshot from the injected service")
    func loadPopulatesSnapshot() async {
        let expected = SettingsSnapshot(iCloudSyncEnabled: false, allowlist: [AllowlistEntry(id: "1", domain: "example.com")])
        let viewModel = SettingsViewModel(service: StubSettingsService(snapshotToReturn: expected))

        await viewModel.load()

        #expect(viewModel.snapshot == expected)
    }

    @Test("addAllowlistEntry appends a new entry and reloads")
    func addAllowlistEntryAppends() async {
        let service = StubSettingsService(snapshotToReturn: SettingsSnapshot(iCloudSyncEnabled: false, allowlist: []))
        let viewModel = SettingsViewModel(service: service)
        await viewModel.load()

        await viewModel.addAllowlistEntry(domain: "example.com")

        #expect(await service.addedDomains == ["example.com"])
    }
}

private actor StubSettingsService: SettingsService {
    let snapshotToReturn: SettingsSnapshot
    private(set) var addedDomains: [String] = []

    init(snapshotToReturn: SettingsSnapshot) {
        self.snapshotToReturn = snapshotToReturn
    }

    func fetchSnapshot() async -> SettingsSnapshot { snapshotToReturn }
    func addAllowlistEntry(domain: String) async -> AllowlistEditOutcome {
        addedDomains.append(domain)
        return .applied
    }
    func removeAllowlistEntry(id: String) async -> AllowlistEditOutcome { .applied }
}

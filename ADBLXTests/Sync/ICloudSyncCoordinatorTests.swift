// ADBLXTests/Sync/ICloudSyncCoordinatorTests.swift
import XCTest
@testable import ADBLX
import ADBLXShared

final class ICloudSyncCoordinatorTests: XCTestCase {
    private var tempDirectory: URL!
    private var filterStore: FilterStore!
    private var allowlistStore: AllowlistStore!
    private var mockKVS: MockUbiquitousKeyValueStore!

    override func setUp() async throws {
        try await super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        filterStore = FilterStore(overrideBaseURL: tempDirectory)
        allowlistStore = AllowlistStore(store: filterStore)
        mockKVS = MockUbiquitousKeyValueStore()
    }

    override func tearDown() async throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        try await super.tearDown()
    }

    // -------------------------------------------------------------
    // Test 1: Remote changes merge into local allowlist
    // -------------------------------------------------------------
    func testRemoteChangesMergeIntoLocalAllowlist() async throws {
        // Pre-populate local
        _ = try await allowlistStore.add(domain: "local-first.com")

        // Pre-populate remote records
        let remoteRecords = [
            SyncedAllowlistRecord(domain: "remote-alpha.com", isDeleted: false),
            SyncedAllowlistRecord(domain: "remote-beta.com", isDeleted: false),
            SyncedAllowlistRecord(domain: "local-first.com", isDeleted: false)
        ]
        let data = try JSONEncoder().encode(remoteRecords)
        mockKVS.set(data, forKey: "ADBLX_ICLOUD_ALLOWLIST_RECORDS_DATA")

        let coordinator = ICloudSyncCoordinator(
            store: mockKVS,
            allowlistStore: allowlistStore,
            entitlementService: StubEntitlementService(isPremiumEntitled: true)
        )

        await coordinator.handleExternalChange()

        let localDomains = await allowlistStore.loadDomains()
        XCTAssertTrue(localDomains.contains("local-first.com"))
        XCTAssertTrue(localDomains.contains("remote-alpha.com"))
        XCTAssertTrue(localDomains.contains("remote-beta.com"))
        XCTAssertEqual(localDomains.count, 3, "Merge-union must deduplicate existing domains")
    }

    // -------------------------------------------------------------
    // Test 2: Local allowlist pushes to remote KVS
    // -------------------------------------------------------------
    func testPushLocalAllowlistUpstream() async throws {
        _ = try await allowlistStore.add(domain: "client-custom.org")
        _ = try await allowlistStore.add(domain: "client-portal.io")

        let coordinator = ICloudSyncCoordinator(
            store: mockKVS,
            allowlistStore: allowlistStore,
            entitlementService: StubEntitlementService(isPremiumEntitled: true)
        )

        await coordinator.recordLocalAddition(domain: "client-custom.org")
        await coordinator.recordLocalAddition(domain: "client-portal.io")

        let records = await coordinator.loadRemoteRecords()
        let domains = records.filter { !$0.isDeleted }.map(\.domain)
        XCTAssertEqual(Set(domains), Set(["client-custom.org", "client-portal.io"]))
    }

    // -------------------------------------------------------------
    // Test 3: Remote deletion tombstone removes local domain & prevents resurrection
    // -------------------------------------------------------------
    func testRemoteDeletionRemovesLocalDomainAndPreventsResurrection() async throws {
        // Local device has two domains
        _ = try await allowlistStore.add(domain: "keep-me.com")
        _ = try await allowlistStore.add(domain: "delete-me.com")

        // Remote device deleted "delete-me.com" (tombstone set)
        let remoteRecords = [
            SyncedAllowlistRecord(domain: "keep-me.com", isDeleted: false),
            SyncedAllowlistRecord(domain: "delete-me.com", isDeleted: true)
        ]
        let data = try JSONEncoder().encode(remoteRecords)
        mockKVS.set(data, forKey: "ADBLX_ICLOUD_ALLOWLIST_RECORDS_DATA")

        let coordinator = ICloudSyncCoordinator(
            store: mockKVS,
            allowlistStore: allowlistStore,
            entitlementService: StubEntitlementService(isPremiumEntitled: true)
        )

        await coordinator.handleExternalChange()

        let localDomains = await allowlistStore.loadDomains()
        XCTAssertTrue(localDomains.contains("keep-me.com"), "Retained domain must stay in allowlist")
        XCTAssertFalse(localDomains.contains("delete-me.com"), "Tombstoned domain must be removed from local store")
        XCTAssertEqual(localDomains.count, 1)

        // Ensure subsequent sync pass does NOT resurrect the deleted domain
        await coordinator.handleExternalChange()
        let localDomainsSecondPass = await allowlistStore.loadDomains()
        XCTAssertFalse(localDomainsSecondPass.contains("delete-me.com"), "Deleted domain must never resurrect")
    }

    // -------------------------------------------------------------
    // Test 4: Unentitled users do not sync
    // -------------------------------------------------------------
    func testUnentitledUserBypassesSync() async throws {
        _ = try await allowlistStore.add(domain: "free-user-site.com")
        let remoteRecords = [SyncedAllowlistRecord(domain: "premium-site.com", isDeleted: false)]
        let data = try JSONEncoder().encode(remoteRecords)
        mockKVS.set(data, forKey: "ADBLX_ICLOUD_ALLOWLIST_RECORDS_DATA")

        let coordinator = ICloudSyncCoordinator(
            store: mockKVS,
            allowlistStore: allowlistStore,
            entitlementService: StubEntitlementService(isPremiumEntitled: false)
        )

        await coordinator.handleExternalChange()

        let localDomains = await allowlistStore.loadDomains()
        XCTAssertFalse(localDomains.contains("premium-site.com"), "Free user must not sync remote allowlist")

        let isActive = await coordinator.isSyncActive()
        XCTAssertFalse(isActive)
    }
}

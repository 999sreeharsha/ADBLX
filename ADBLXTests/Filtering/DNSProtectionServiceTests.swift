import XCTest
import os
@testable import ADBLX
import ADBLXShared

final class MockDNSProtectionService: DNSProtectionServiceProtocol, @unchecked Sendable {
    private let settingsStore: DNSProtectionSettingsStore
    private var status: DNSConnectionStatus = .disconnected
    private var statusHandler: (@Sendable (DNSConnectionStatus) -> Void)?
    private let lock = NSLock()
    private let baseDirectory: URL
    private let entitlementService: EntitlementService?
    
    public init(
        settingsStore: DNSProtectionSettingsStore,
        baseDirectory: URL,
        entitlementService: EntitlementService? = nil
    ) {
        self.settingsStore = settingsStore
        self.baseDirectory = baseDirectory
        self.entitlementService = entitlementService
    }
    
    public func setStatusChangeHandler(_ handler: @escaping @Sendable (DNSConnectionStatus) -> Void) {
        lock.lock()
        self.statusHandler = handler
        lock.unlock()
    }
    
    public func loadStatus() async -> (DNSProtectionSettings, DNSConnectionStatus) {
        if let entitlement = entitlementService, !(await entitlement.isPremiumEntitled()) {
            lock.lock()
            if status == .connected {
                status = .disconnected
                settingsStore.setEnabled(false)
                let handler = statusHandler
                lock.unlock()
                handler?(.disconnected)
                return (settingsStore.loadSettings(), .disconnected)
            }
            lock.unlock()
        }
        lock.lock()
        defer { lock.unlock() }
        return (settingsStore.loadSettings(), status)
    }
    
    public func startProtection() async throws {
        if let entitlement = entitlementService, !(await entitlement.isPremiumEntitled()) {
            throw NSError(
                domain: "DNSProtectionService",
                code: -403,
                userInfo: [NSLocalizedDescriptionKey: "DNS Protection requires an active Premium subscription."]
            )
        }
        lock.lock()
        status = .connected
        settingsStore.setEnabled(true)
        let handler = statusHandler
        lock.unlock()
        handler?(.connected)
    }
    
    public func stopProtection() async throws {
        lock.lock()
        status = .disconnected
        settingsStore.setEnabled(false)
        let handler = statusHandler
        lock.unlock()
        handler?(.disconnected)
    }
    
    public func updateResolver(option: UpstreamResolverOption, customIPv4: String, customIPv6: String?) async throws {
        if option == .custom {
            guard DNSProtectionSettingsStore.validateIPv4(customIPv4) else {
                throw NSError(domain: "DNSProtectionService", code: -2, userInfo: [NSLocalizedDescriptionKey: "Invalid IPv4 address format"])
            }
            if let v6 = customIPv6, !v6.isEmpty {
                guard DNSProtectionSettingsStore.validateIPv6(v6) else {
                    throw NSError(domain: "DNSProtectionService", code: -3, userInfo: [NSLocalizedDescriptionKey: "Invalid IPv6 address format"])
                }
            }
        }
        settingsStore.updateResolver(option: option, customIPv4: customIPv4, customIPv6: customIPv6)
    }
    
    public func addAllowlistDomain(_ rawDomain: String) async throws -> [String] {
        guard let validated = DNSProtectionSettingsStore.validateDomain(rawDomain) else {
            throw NSError(domain: "DNSProtectionService", code: -4, userInfo: [NSLocalizedDescriptionKey: "Invalid domain name format"])
        }
        var current = settingsStore.loadSettings().allowlistDomains
        if !current.contains(validated) {
            current.append(validated)
            current.sort()
            settingsStore.saveAllowlist(current)
            
            // Compile and publish generation (Zero Tunnel Restart)
            _ = try DNSArtifactPublisher().publish(
                blocklistSources: [],
                allowlistRules: current,
                baseAppGroupURL: baseDirectory
            )
        }
        return current
    }
    
    public func removeAllowlistDomain(_ domain: String) async throws -> [String] {
        var current = settingsStore.loadSettings().allowlistDomains
        current.removeAll(where: { $0 == domain })
        settingsStore.saveAllowlist(current)
        
        // Compile and publish generation (Zero Tunnel Restart)
        _ = try DNSArtifactPublisher().publish(
            blocklistSources: [],
            allowlistRules: current,
            baseAppGroupURL: baseDirectory
        )
        return current
    }
}

final class DNSProtectionServiceTests: XCTestCase {
    private var tempDirectory: URL!
    private var testUserDefaults: UserDefaults!
    private var store: DNSProtectionSettingsStore!
    private var service: MockDNSProtectionService!
    
    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("DNSProtectionServiceTests_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        
        testUserDefaults = UserDefaults(suiteName: "TestServiceDefaults_\(UUID().uuidString)")!
        store = DNSProtectionSettingsStore(userDefaults: testUserDefaults)
        service = MockDNSProtectionService(settingsStore: store, baseDirectory: tempDirectory)
    }
    
    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        testUserDefaults = nil
        store = nil
        service = nil
        super.tearDown()
    }
    
    func testAllowlistEditingPipelineAndGenerationPublication() async throws {
        // 1. Add first allowlist domain
        let list1 = try await service.addAllowlistDomain("apple.com")
        XCTAssertEqual(list1, ["apple.com"])
        
        // Verify generation 1 was published and current.json updated
        let manifest1 = try DNSGenerationManifest.readCurrentManifest(appGroupBaseDirectory: tempDirectory)
        XCTAssertEqual(manifest1.generation, 1)
        XCTAssertEqual(manifest1.allowlistCount, 1)
        
        // 2. Add second allowlist domain
        let list2 = try await service.addAllowlistDomain("google.com")
        XCTAssertEqual(list2, ["apple.com", "google.com"])
        
        // Verify generation 2 was published atomically
        let manifest2 = try DNSGenerationManifest.readCurrentManifest(appGroupBaseDirectory: tempDirectory)
        XCTAssertEqual(manifest2.generation, 2)
        XCTAssertEqual(manifest2.allowlistCount, 2)
        
        // 3. Remove domain
        let list3 = try await service.removeAllowlistDomain("apple.com")
        XCTAssertEqual(list3, ["google.com"])
        
        // Verify generation 3 was published atomically
        let manifest3 = try DNSGenerationManifest.readCurrentManifest(appGroupBaseDirectory: tempDirectory)
        XCTAssertEqual(manifest3.generation, 3)
        XCTAssertEqual(manifest3.allowlistCount, 1)
    }
    
    func testInvalidDomainRejection() async throws {
        do {
            _ = try await service.addAllowlistDomain("invalid domain with spaces")
            XCTFail("Should reject invalid domain")
        } catch {
            XCTAssertNotNil(error)
        }
    }
    
    func testResolverUpdateValidation() async throws {
        // Valid custom resolver
        try await service.updateResolver(option: .custom, customIPv4: "1.1.1.1", customIPv6: "2606:4700::1111")
        let (settings, _) = await service.loadStatus()
        XCTAssertEqual(settings.resolverOption, .custom)
        XCTAssertEqual(settings.customIPv4, "1.1.1.1")
        XCTAssertEqual(settings.customIPv6, "2606:4700::1111")
        
        // Invalid IPv4 rejected
        do {
            try await service.updateResolver(option: .custom, customIPv4: "999.999.1.1", customIPv6: nil)
            XCTFail("Should reject invalid IPv4")
        } catch {
            XCTAssertNotNil(error)
        }
    }
    
    func testLifecycleStateTransitions() async throws {
        let statusLock = OSAllocatedUnfairLock(initialState: [DNSConnectionStatus]())
        service.setStatusChangeHandler { newStatus in
            statusLock.withLock { $0.append(newStatus) }
        }
        
        try await service.startProtection()
        let (_, status1) = await service.loadStatus()
        XCTAssertEqual(status1, .connected)
        
        try await service.stopProtection()
        let (_, status2) = await service.loadStatus()
        XCTAssertEqual(status2, .disconnected)
        
        let statuses = statusLock.withLock { $0 }
        XCTAssertEqual(statuses, [.connected, .disconnected])
    }
    
    func testLoaderBoundaryOnlyLoadsDNSFilterSources() {
        // Assert DNSFilterSource contains strictly the approved DNS feeds
        let allSources = DNSFilterSource.allCases
        XCTAssertEqual(allSources, [.oisd, .peterLowe])
        
        // Assert Content Blocker lists are NEVER part of the DNS enum
        let sourceStrings = Set(allSources.map(\.rawValue))
        XCTAssertFalse(sourceStrings.contains("easylist"))
        XCTAssertFalse(sourceStrings.contains("easyprivacy"))
        XCTAssertFalse(sourceStrings.contains("fanboy-annoyances"))
    }
}

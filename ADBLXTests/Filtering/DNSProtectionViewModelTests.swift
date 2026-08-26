import XCTest
@testable import ADBLX
import ADBLXShared

struct MockTestEntitlementService: EntitlementService, @unchecked Sendable {
    var isEntitled: Bool
    func isPremiumEntitled() async -> Bool { isEntitled }
}

final class DNSProtectionViewModelTests: XCTestCase {
    private var tempDirectory: URL!
    private var testUserDefaults: UserDefaults!
    private var store: DNSProtectionSettingsStore!
    
    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("DNSProtectionVMTests_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        testUserDefaults = UserDefaults(suiteName: "TestVMDefaults_\(UUID().uuidString)")!
        store = DNSProtectionSettingsStore(userDefaults: testUserDefaults)
    }
    
    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        testUserDefaults = nil
        store = nil
        super.tearDown()
    }
    
    @MainActor
    func testFreeUserCannotStartDNSProtectionAndTriggersPaywall() async {
        let freeEntitlement = MockTestEntitlementService(isEntitled: false)
        let mockService = MockDNSProtectionService(
            settingsStore: store,
            baseDirectory: tempDirectory,
            entitlementService: freeEntitlement
        )
        let vm = DNSProtectionViewModel(service: mockService, entitlementService: freeEntitlement)
        
        await vm.load()
        XCTAssertFalse(vm.isPremium)
        XCTAssertFalse(vm.isEnabled)
        XCTAssertFalse(vm.showPaywallSheet)
        
        // Attempt to enable protection as a free user
        await vm.toggleProtection()
        
        // Protection MUST NOT be enabled, and paywall sheet MUST be presented
        XCTAssertFalse(vm.isEnabled)
        XCTAssertEqual(vm.connectionStatus, .disconnected)
        XCTAssertTrue(vm.showPaywallSheet)
    }
    
    @MainActor
    func testPremiumUserCanStartDNSProtectionSuccessfully() async {
        let premiumEntitlement = MockTestEntitlementService(isEntitled: true)
        let mockService = MockDNSProtectionService(
            settingsStore: store,
            baseDirectory: tempDirectory,
            entitlementService: premiumEntitlement
        )
        let vm = DNSProtectionViewModel(service: mockService, entitlementService: premiumEntitlement)
        
        await vm.load()
        XCTAssertTrue(vm.isPremium)
        XCTAssertFalse(vm.isEnabled)
        XCTAssertFalse(vm.showPaywallSheet)
        
        // Enable protection as a premium user
        await vm.toggleProtection()
        
        XCTAssertTrue(vm.isEnabled)
        XCTAssertEqual(vm.connectionStatus, .connected)
        XCTAssertFalse(vm.showPaywallSheet)
    }
    
    @MainActor
    func testRunningTunnelTornDownWhenEntitlementLapses() async {
        // Start out with a connected mock service
        var dynamicEntitlement = MockTestEntitlementService(isEntitled: true)
        let mockService = MockDNSProtectionService(
            settingsStore: store,
            baseDirectory: tempDirectory,
            entitlementService: dynamicEntitlement
        )
        try? await mockService.startProtection()
        
        // Entitlement lapses
        dynamicEntitlement.isEntitled = false
        let vm = DNSProtectionViewModel(service: mockService, entitlementService: dynamicEntitlement)
        
        await vm.load()
        
        // Must automatically stop protection and report disconnected
        XCTAssertFalse(vm.isPremium)
        XCTAssertFalse(vm.isEnabled)
        XCTAssertEqual(vm.connectionStatus, .disconnected)
    }
}

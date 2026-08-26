import XCTest
@testable import ADBLX
import ADBLXShared

final class DNSProtectionSettingsStoreTests: XCTestCase {
    private var testUserDefaults: UserDefaults!
    private var store: DNSProtectionSettingsStore!
    
    override func setUp() {
        super.setUp()
        testUserDefaults = UserDefaults(suiteName: "TestDNSProtectionSettingsStore_\(UUID().uuidString)")!
        store = DNSProtectionSettingsStore(userDefaults: testUserDefaults)
    }
    
    override func tearDown() {
        testUserDefaults.removePersistentDomain(forName: testUserDefaults.description)
        testUserDefaults = nil
        store = nil
        super.tearDown()
    }
    
    func testDefaultSettings() {
        let settings = store.loadSettings()
        XCTAssertFalse(settings.isEnabled)
        XCTAssertEqual(settings.resolverOption, .quad9Default)
        XCTAssertEqual(settings.customIPv4, "9.9.9.9")
        XCTAssertEqual(settings.customIPv6, "2620:fe::fe")
        XCTAssertTrue(settings.allowlistDomains.isEmpty)
    }
    
    func testSaveAndLoadSettings() {
        var settings = DNSProtectionSettings(
            isEnabled: true,
            resolverOption: .custom,
            customIPv4: "1.1.1.1",
            customIPv6: "2606:4700::1111",
            allowlistDomains: ["apple.com", "google.com"]
        )
        store.saveSettings(settings)
        
        let loaded = store.loadSettings()
        XCTAssertTrue(loaded.isEnabled)
        XCTAssertEqual(loaded.resolverOption, .custom)
        XCTAssertEqual(loaded.customIPv4, "1.1.1.1")
        XCTAssertEqual(loaded.customIPv6, "2606:4700::1111")
        XCTAssertEqual(loaded.allowlistDomains, ["apple.com", "google.com"])
        
        store.setEnabled(false)
        XCTAssertFalse(store.loadSettings().isEnabled)
    }
    
    func testIPv4Validation() {
        XCTAssertTrue(DNSProtectionSettingsStore.validateIPv4("9.9.9.9"))
        XCTAssertTrue(DNSProtectionSettingsStore.validateIPv4("1.1.1.1"))
        XCTAssertTrue(DNSProtectionSettingsStore.validateIPv4("192.168.1.1"))
        
        XCTAssertFalse(DNSProtectionSettingsStore.validateIPv4("999.9.9.9"))
        XCTAssertFalse(DNSProtectionSettingsStore.validateIPv4("invalid.ip"))
        XCTAssertFalse(DNSProtectionSettingsStore.validateIPv4("1.1.1"))
        XCTAssertFalse(DNSProtectionSettingsStore.validateIPv4(""))
    }
    
    func testIPv6Validation() {
        XCTAssertTrue(DNSProtectionSettingsStore.validateIPv6("2620:fe::fe"))
        XCTAssertTrue(DNSProtectionSettingsStore.validateIPv6("2606:4700::1111"))
        XCTAssertTrue(DNSProtectionSettingsStore.validateIPv6("::1"))
        
        XCTAssertFalse(DNSProtectionSettingsStore.validateIPv6("2620:fe::fe::1"))
        XCTAssertFalse(DNSProtectionSettingsStore.validateIPv6("invalid.ip6"))
        XCTAssertFalse(DNSProtectionSettingsStore.validateIPv6(""))
    }
    
    func testDomainValidationAndNormalization() {
        // Valid domains
        XCTAssertEqual(DNSProtectionSettingsStore.validateDomain("example.com"), "example.com")
        XCTAssertEqual(DNSProtectionSettingsStore.validateDomain("sub.domain.co.uk"), "sub.domain.co.uk")
        XCTAssertEqual(DNSProtectionSettingsStore.validateDomain("||tracker.ad.net^"), "tracker.ad.net")
        XCTAssertEqual(DNSProtectionSettingsStore.validateDomain("https://my-domain.org/path?q=1"), "my-domain.org")
        XCTAssertEqual(DNSProtectionSettingsStore.validateDomain("*.wildcard.io"), "wildcard.io")
        XCTAssertEqual(DNSProtectionSettingsStore.validateDomain("CAPITAL.COM"), "capital.com")
        
        // Invalid domains
        XCTAssertNil(DNSProtectionSettingsStore.validateDomain(""))
        XCTAssertNil(DNSProtectionSettingsStore.validateDomain("singlelabel"))
        XCTAssertNil(DNSProtectionSettingsStore.validateDomain("-invalid.com"))
        XCTAssertNil(DNSProtectionSettingsStore.validateDomain("invalid-.com"))
        XCTAssertNil(DNSProtectionSettingsStore.validateDomain("bad domain.com"))
        XCTAssertNil(DNSProtectionSettingsStore.validateDomain("bad_domain.com"))
    }
}

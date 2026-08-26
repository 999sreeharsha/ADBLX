import Foundation
import ADBLXShared

public struct DNSProtectionSettings: Equatable, Sendable {
    public var isEnabled: Bool
    public var resolverOption: UpstreamResolverOption
    public var customIPv4: String
    public var customIPv6: String?
    public var allowlistDomains: [String]
    
    public init(
        isEnabled: Bool = false,
        resolverOption: UpstreamResolverOption = .quad9Default,
        customIPv4: String = "9.9.9.9",
        customIPv6: String? = "2620:fe::fe",
        allowlistDomains: [String] = []
    ) {
        self.isEnabled = isEnabled
        self.resolverOption = resolverOption
        self.customIPv4 = customIPv4
        self.customIPv6 = customIPv6
        self.allowlistDomains = allowlistDomains
    }
}

public final class DNSProtectionSettingsStore: @unchecked Sendable {
    private let userDefaults: UserDefaults
    private let lock = NSLock()
    
    private let keyEnabled = "ADBLX_DNS_PROTECTION_ENABLED"
    private let keyResolverOption = "ADBLX_DNS_RESOLVER_OPTION"
    private let keyCustomIPv4 = "ADBLX_DNS_CUSTOM_IPV4"
    private let keyCustomIPv6 = "ADBLX_DNS_CUSTOM_IPV6"
    private let keyAllowlist = "ADBLX_DNS_ALLOWLIST_DOMAINS"
    
    public init(userDefaults: UserDefaults = UserDefaults(suiteName: "group.com.ADBLX.ADBLX") ?? .standard) {
        self.userDefaults = userDefaults
    }
    
    public func loadSettings() -> DNSProtectionSettings {
        lock.lock()
        defer { lock.unlock() }
        
        let isEnabled = userDefaults.bool(forKey: keyEnabled)
        let rawOption = userDefaults.string(forKey: keyResolverOption) ?? UpstreamResolverOption.quad9Default.rawValue
        let option = UpstreamResolverOption(rawValue: rawOption) ?? .quad9Default
        let customIPv4 = userDefaults.string(forKey: keyCustomIPv4) ?? "9.9.9.9"
        let customIPv6 = userDefaults.string(forKey: keyCustomIPv6) ?? "2620:fe::fe"
        let allowlist = userDefaults.stringArray(forKey: keyAllowlist) ?? []
        
        return DNSProtectionSettings(
            isEnabled: isEnabled,
            resolverOption: option,
            customIPv4: customIPv4,
            customIPv6: customIPv6,
            allowlistDomains: allowlist
        )
    }
    
    public func saveSettings(_ settings: DNSProtectionSettings) {
        lock.lock()
        defer { lock.unlock() }
        
        userDefaults.set(settings.isEnabled, forKey: keyEnabled)
        userDefaults.set(settings.resolverOption.rawValue, forKey: keyResolverOption)
        userDefaults.set(settings.customIPv4, forKey: keyCustomIPv4)
        userDefaults.set(settings.customIPv6, forKey: keyCustomIPv6)
        userDefaults.set(settings.allowlistDomains, forKey: keyAllowlist)
    }
    
    public func setEnabled(_ isEnabled: Bool) {
        lock.lock()
        defer { lock.unlock() }
        userDefaults.set(isEnabled, forKey: keyEnabled)
    }
    
    public func updateResolver(option: UpstreamResolverOption, customIPv4: String, customIPv6: String?) {
        lock.lock()
        defer { lock.unlock() }
        userDefaults.set(option.rawValue, forKey: keyResolverOption)
        userDefaults.set(customIPv4, forKey: keyCustomIPv4)
        userDefaults.set(customIPv6, forKey: keyCustomIPv6)
    }
    
    public func saveAllowlist(_ domains: [String]) {
        lock.lock()
        defer { lock.unlock() }
        userDefaults.set(domains, forKey: keyAllowlist)
    }
    
    // MARK: - Validation
    
    public static func validateIPv4(_ address: String) -> Bool {
        var sin = sockaddr_in()
        return address.withCString { inet_pton(AF_INET, $0, &sin.sin_addr) } == 1
    }
    
    public static func validateIPv6(_ address: String) -> Bool {
        var sin6 = sockaddr_in6()
        return address.withCString { inet_pton(AF_INET6, $0, &sin6.sin6_addr) } == 1
    }
    
    public static func validateDomain(_ rawInput: String) -> String? {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty, trimmed.count <= 253 else { return nil }
        
        // Disallow wildcard prefix or protocols
        var clean = trimmed
        if clean.hasPrefix("https://") {
            clean = String(clean.dropFirst(8))
        } else if clean.hasPrefix("http://") {
            clean = String(clean.dropFirst(7))
        }
        if clean.hasPrefix("||") {
            clean = String(clean.dropFirst(2))
        }
        if clean.hasSuffix("^") {
            clean = String(clean.dropLast(1))
        }
        if clean.hasPrefix("*.") {
            clean = String(clean.dropFirst(2))
        }
        
        // Remove path or trailing slash if user pasted a URL
        if let slashIdx = clean.firstIndex(of: "/") {
            clean = String(clean[..<slashIdx])
        }
        if let colonIdx = clean.firstIndex(of: ":") {
            clean = String(clean[..<colonIdx])
        }
        
        // Verify label format
        let labels = clean.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return nil }
        
        for label in labels {
            guard !label.isEmpty, label.count <= 63 else { return nil }
            guard !label.hasPrefix("-"), !label.hasSuffix("-") else { return nil }
            for char in label {
                guard char.isASCII, (char.isLetter || char.isNumber || char == "-") else {
                    return nil
                }
            }
        }
        
        return clean
    }
}

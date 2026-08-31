import Foundation
import NetworkExtension
import os
import ADBLXShared

public enum DNSConnectionStatus: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case reasserting
    case disconnecting
    case vpnConflict(String)
    case error(String)
    
    public var title: String {
        switch self {
        case .disconnected: return "Inactive"
        case .connecting: return "Connecting..."
        case .connected: return "Protected"
        case .reasserting: return "Reconnecting..."
        case .disconnecting: return "Disconnecting..."
        case .vpnConflict: return "VPN Conflict"
        case .error: return "Configuration Error"
        }
    }
}

/// Explicit allowlisted DNS-layer source enum preventing Layer 1 CB list contamination
public enum DNSFilterSource: String, CaseIterable, Sendable {
    case oisd = "oisd"
    case peterLowe = "peter-lowe"
}

public protocol DNSProtectionServiceProtocol: AnyObject, Sendable {
    func loadStatus() async -> (DNSProtectionSettings, DNSConnectionStatus)
    func startProtection() async throws
    func stopProtection() async throws
    func updateResolver(option: UpstreamResolverOption, customIPv4: String, customIPv6: String?) async throws
    func addAllowlistDomain(_ rawDomain: String) async throws -> [String]
    func removeAllowlistDomain(_ domain: String) async throws -> [String]
    func setStatusChangeHandler(_ handler: @escaping @Sendable (DNSConnectionStatus) -> Void)
}

public final class RealDNSProtectionService: DNSProtectionServiceProtocol, @unchecked Sendable {
    private let settingsStore: DNSProtectionSettingsStore
    private let entitlementService: EntitlementService
    private let logger = Logger(subsystem: "com.ADBLX.ADBLX", category: "DNSProtectionService")
    private static let signposter = OSSignposter(subsystem: "com.ADBLX.ADBLX", category: "DNSProtectionService")
    private let stateLock = OSAllocatedUnfairLock(initialState: (
        tunnelManager: NETunnelProviderManager?.none,
        statusHandler: (@Sendable (DNSConnectionStatus) -> Void)?.none
    ))
    private var notificationObserver: AnyObject?
    private var entitlementTask: Task<Void, Never>?
    
    public init(
        settingsStore: DNSProtectionSettingsStore = DNSProtectionSettingsStore(),
        entitlementService: EntitlementService = AppCompositionRoot.makeSubscriptionService()
    ) {
        self.settingsStore = settingsStore
        self.entitlementService = entitlementService
        setupStatusObserver()
        setupEntitlementObserver()
    }
    
    deinit {
        entitlementTask?.cancel()
        if let observer = notificationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    public func setStatusChangeHandler(_ handler: @escaping @Sendable (DNSConnectionStatus) -> Void) {
        stateLock.withLock { $0.statusHandler = handler }
    }
    
    private func setupEntitlementObserver() {
        entitlementTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            for await state in await self.entitlementService.stateUpdates() {
                if !state.hasPremiumAccess {
                    await self.handleEntitlementLoss()
                }
            }
        }
    }

    private func handleEntitlementLoss() async {
        let settings = settingsStore.loadSettings()
        let manager = await getOrLoadManager()

        // Idempotency: if already disconnected/disabled and settings already disabled, do nothing
        if let manager, manager.connection.status == .disconnected && !manager.isEnabled && !settings.isEnabled {
            return
        }

        let spID = Self.signposter.makeSignpostID()
        let teardownInterval = Self.signposter.beginInterval("dns.entitlementTeardown", id: spID)
        defer { Self.signposter.endInterval("dns.entitlementTeardown", teardownInterval) }

        logger.info("Entitlement lost (.free) — executing idempotent DNS teardown")

        if let manager {
            if manager.connection.status != .disconnected && manager.connection.status != .invalid {
                manager.connection.stopVPNTunnel()
            }
            if manager.isEnabled {
                manager.isEnabled = false
                try? await saveManager(manager)
            }
        }
        if settings.isEnabled {
            settingsStore.setEnabled(false)
        }
        notifyStatusChange(.disconnected)
    }

    // MARK: - Status Loading
    
    public func loadStatus() async -> (DNSProtectionSettings, DNSConnectionStatus) {
        var settings = settingsStore.loadSettings()
        let manager = await getOrLoadManager()
        
        guard let mgr = manager else {
            return (settings, .disconnected)
        }
        
        let entitled = await entitlementService.isPremiumEntitled()
        if mgr.connection.status == .connected && !entitled {
            await handleEntitlementLoss()
            return (settingsStore.loadSettings(), .disconnected)
        }
        
        let status = mapVPNStatus(mgr.connection.status)
        if mgr.connection.status == .disconnected && !mgr.isEnabled && settings.isEnabled {
            settingsStore.setEnabled(false)
            settings.isEnabled = false
        }
        return (settings, status)
    }
    
    // MARK: - Lifecycle Management
    
    public func startProtection() async throws {
        guard await entitlementService.isPremiumEntitled() else {
            throw NSError(
                domain: "DNSProtectionService",
                code: -403,
                userInfo: [NSLocalizedDescriptionKey: "DNS Protection requires an active Premium subscription."]
            )
        }
        let settings = settingsStore.loadSettings()
        try await publishAllowlistGeneration(settings.allowlistDomains)
        guard let manager = await getOrLoadManager() else {
            throw NSError(
                domain: "DNSProtectionService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to load VPN manager"]
            )
        }
        
        let pProtocol = (manager.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
        pProtocol.providerBundleIdentifier = "com.ADBLX.ADBLX.PacketTunnel"
        pProtocol.serverAddress = "127.0.0.1"
        
        var providerConfig: [String: Any] = [
            "resolverOption": settings.resolverOption.rawValue,
            "ipv4Address": settings.customIPv4
        ]
        if let v6 = settings.customIPv6 {
            providerConfig["ipv6Address"] = v6
        }
        pProtocol.providerConfiguration = providerConfig
        
        manager.protocolConfiguration = pProtocol
        manager.localizedDescription = "ADBLX DNS Protection"
        manager.isEnabled = true
        
        do {
            try await saveManager(manager)
            try await reloadManager(manager)
            
            if manager.connection.status == .invalid {
                notifyStatusChange(.vpnConflict("Another VPN profile may be conflicting with ADBLX."))
                return
            }
            
            try manager.connection.startVPNTunnel()
            settingsStore.setEnabled(true)
            logger.info("DNS Protection VPN tunnel started")
        } catch {
            logger.error("Failed to start DNS Protection: \(error.localizedDescription)")
            notifyStatusChange(.error(error.localizedDescription))
            throw error
        }
    }
    
    public func stopProtection() async throws {
        guard let manager = await getOrLoadManager() else { return }
        
        manager.connection.stopVPNTunnel()
        manager.isEnabled = false
        try await saveManager(manager)
        settingsStore.setEnabled(false)
        logger.info("DNS Protection VPN tunnel stopped")
    }
    
    public func updateResolver(
        option: UpstreamResolverOption,
        customIPv4: String,
        customIPv6: String?
    ) async throws {
        if option == .custom {
            guard DNSProtectionSettingsStore.validateIPv4(customIPv4) else {
                throw NSError(
                    domain: "DNSProtectionService",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid IPv4 address format"]
                )
            }
            if let v6 = customIPv6, !v6.isEmpty {
                guard DNSProtectionSettingsStore.validateIPv6(v6) else {
                    throw NSError(
                        domain: "DNSProtectionService",
                        code: -3,
                        userInfo: [NSLocalizedDescriptionKey: "Invalid IPv6 address format"]
                    )
                }
            }
        }
        
        settingsStore.updateResolver(option: option, customIPv4: customIPv4, customIPv6: customIPv6)
        
        let settings = settingsStore.loadSettings()
        if settings.isEnabled, let manager = await getOrLoadManager() {
            if let pProtocol = manager.protocolConfiguration as? NETunnelProviderProtocol {
                var providerConfig = pProtocol.providerConfiguration ?? [:]
                providerConfig["resolverOption"] = option.rawValue
                providerConfig["ipv4Address"] = customIPv4
                if let v6 = customIPv6 {
                    providerConfig["ipv6Address"] = v6
                } else {
                    providerConfig.removeValue(forKey: "ipv6Address")
                }
                pProtocol.providerConfiguration = providerConfig
                manager.protocolConfiguration = pProtocol
                try await saveManager(manager)
                
                manager.connection.stopVPNTunnel()
                try? await Task.sleep(nanoseconds: 200_000_000)
                try manager.connection.startVPNTunnel()
            }
        }
    }
    
    // MARK: - Allowlist Editing Pipeline (Off-Main, Zero Tunnel Restart)
    
    public func addAllowlistDomain(_ rawDomain: String) async throws -> [String] {
        guard let validated = DNSProtectionSettingsStore.validateDomain(rawDomain) else {
            throw NSError(
                domain: "DNSProtectionService",
                code: -4,
                userInfo: [NSLocalizedDescriptionKey: "Invalid domain name format. Example: example.com"]
            )
        }
        
        var currentAllowlist = settingsStore.loadSettings().allowlistDomains
        guard !currentAllowlist.contains(validated) else {
            return currentAllowlist
        }
        
        currentAllowlist.append(validated)
        currentAllowlist.sort()
        settingsStore.saveAllowlist(currentAllowlist)
        
        try await publishAllowlistGeneration(currentAllowlist)
        return currentAllowlist
    }
    
    public func removeAllowlistDomain(_ domain: String) async throws -> [String] {
        var currentAllowlist = settingsStore.loadSettings().allowlistDomains
        currentAllowlist.removeAll(where: { $0 == domain })
        settingsStore.saveAllowlist(currentAllowlist)
        
        try await publishAllowlistGeneration(currentAllowlist)
        return currentAllowlist
    }
    
    private func loadBlocklistSources() -> [String] {
        var sources: [String] = []
        for source in DNSFilterSource.allCases {
            if let url = Bundle.main.url(forResource: source.rawValue, withExtension: "txt", subdirectory: "Filters/DNS") ??
                         Bundle.main.url(forResource: source.rawValue, withExtension: "txt"),
               let text = try? String(contentsOf: url, encoding: .utf8) {
                sources.append(text)
            }
        }
        return sources
    }

    private func publishAllowlistGeneration(_ allowlist: [String]) async throws {
        let blocklistSources = loadBlocklistSources()
        try await Task.detached(priority: .userInitiated) {
            let appGroupBase = DNSAppGroupPaths.appGroupContainerURL() ?? FileManager.default.temporaryDirectory
            _ = try DNSArtifactPublisher().publish(
                blocklistSources: blocklistSources,
                allowlistRules: allowlist,
                baseAppGroupURL: appGroupBase
            )
        }.value
    }
    
    // MARK: - Helpers & Observers
    
    private func setupStatusObserver() {
        notificationObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let connection = notification.object as? NEVPNConnection else { return }
            let status = self.mapVPNStatus(connection.status)
            self.notifyStatusChange(status)
        }
    }
    
    private func notifyStatusChange(_ status: DNSConnectionStatus) {
        let handler = stateLock.withLock { $0.statusHandler }
        handler?(status)
    }
    
    private func mapVPNStatus(_ status: NEVPNStatus) -> DNSConnectionStatus {
        switch status {
        case .invalid: return .disconnected
        case .disconnected: return .disconnected
        case .connecting: return .connecting
        case .connected: return .connected
        case .reasserting: return .reasserting
        case .disconnecting: return .disconnecting
        @unknown default: return .disconnected
        }
    }
    
    private func getOrLoadManager() async -> NETunnelProviderManager? {
        let existing = stateLock.withLock { $0.tunnelManager }
        if let existing = existing {
            return existing
        }
        
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            let manager = managers.first ?? NETunnelProviderManager()
            stateLock.withLock { $0.tunnelManager = manager }
            return manager
        } catch {
            logger.error("Failed to load NETunnelProviderManager: \(error.localizedDescription)")
            return nil
        }
    }
    
    private func saveManager(_ manager: NETunnelProviderManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.saveToPreferences { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
    
    private func reloadManager(_ manager: NETunnelProviderManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.loadFromPreferences { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

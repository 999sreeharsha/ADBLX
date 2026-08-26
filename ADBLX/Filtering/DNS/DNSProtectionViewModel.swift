import Foundation
import Observation
import ADBLXShared

@Observable
public final class DNSProtectionViewModel {
    private let service: DNSProtectionServiceProtocol
    private let entitlementService: EntitlementService
    private var entitlementObservationTask: Task<Void, Never>?
    
    public var isEnabled: Bool = false
    public var isPremium: Bool = false
    public var showPaywallSheet: Bool = false
    public var connectionStatus: DNSConnectionStatus = .disconnected
    public var resolverOption: UpstreamResolverOption = .quad9Default
    public var customIPv4: String = "9.9.9.9"
    public var customIPv6: String = "2620:fe::fe"
    public var allowlistDomains: [String] = []
    
    public var newDomainInput: String = ""
    public var errorMessage: String?
    public var showErrorAlert: Bool = false
    public var isProcessing: Bool = false
    public var isPublishingAllowlist: Bool = false
    
    public init(
        service: DNSProtectionServiceProtocol = RealDNSProtectionService(),
        entitlementService: EntitlementService = AppCompositionRoot.makeSubscriptionService()
    ) {
        self.service = service
        self.entitlementService = entitlementService
        self.service.setStatusChangeHandler { [weak self] newStatus in
            Task { @MainActor [weak self] in
                self?.connectionStatus = newStatus
                if case .connected = newStatus {
                    self?.isEnabled = true
                } else if case .disconnected = newStatus {
                    self?.isEnabled = false
                }
            }
        }
        setupEntitlementObserver()
    }

    deinit {
        entitlementObservationTask?.cancel()
    }

    private func setupEntitlementObserver() {
        entitlementObservationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await state in await self.entitlementService.stateUpdates() {
                self.isPremium = state.hasPremiumAccess
                if !state.hasPremiumAccess && self.isEnabled {
                    self.isEnabled = false
                    self.connectionStatus = .disconnected
                }
            }
        }
    }
    
    @MainActor
    public func load() async {
        let entitled = await entitlementService.isPremiumEntitled()
        self.isPremium = entitled
        
        let (settings, status) = await service.loadStatus()
        
        // If tunnel is active but entitlement has lapsed, enforce immediate teardown
        if status == .connected && !entitled {
            try? await service.stopProtection()
            self.isEnabled = false
            self.connectionStatus = .disconnected
        } else {
            self.isEnabled = (status == .connected || status == .connecting) && settings.isEnabled
            self.connectionStatus = status
        }
        
        self.resolverOption = settings.resolverOption
        self.customIPv4 = settings.customIPv4
        self.customIPv6 = settings.customIPv6 ?? ""
        self.allowlistDomains = settings.allowlistDomains
    }
    
    @MainActor
    public func toggleProtection() async {
        isProcessing = true
        defer { isProcessing = false }
        
        do {
            if isEnabled {
                try await service.stopProtection()
                isEnabled = false
                connectionStatus = .disconnected
            } else {
                let entitled = await entitlementService.isPremiumEntitled()
                guard entitled else {
                    showPaywallSheet = true
                    isEnabled = false
                    return
                }
                try await service.startProtection()
                isEnabled = true
                connectionStatus = .connecting
            }
        } catch {
            errorMessage = error.localizedDescription
            showErrorAlert = true
            isEnabled = false
        }
    }
    
    @MainActor
    public func saveResolver() async {
        do {
            let v6 = customIPv6.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : customIPv6
            try await service.updateResolver(
                option: resolverOption,
                customIPv4: customIPv4.trimmingCharacters(in: .whitespacesAndNewlines),
                customIPv6: v6
            )
        } catch {
            errorMessage = error.localizedDescription
            showErrorAlert = true
        }
    }
    
    @MainActor
    public func addAllowlistDomain() async {
        let input = newDomainInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        
        isPublishingAllowlist = true
        defer { isPublishingAllowlist = false }
        
        do {
            let updated = try await service.addAllowlistDomain(input)
            allowlistDomains = updated
            newDomainInput = ""
        } catch {
            errorMessage = error.localizedDescription
            showErrorAlert = true
        }
    }
    
    @MainActor
    public func removeAllowlistDomain(at offsets: IndexSet) async {
        isPublishingAllowlist = true
        defer { isPublishingAllowlist = false }
        
        for index in offsets {
            guard index < allowlistDomains.count else { continue }
            let domain = allowlistDomains[index]
            do {
                let updated = try await service.removeAllowlistDomain(domain)
                allowlistDomains = updated
            } catch {
                errorMessage = error.localizedDescription
                showErrorAlert = true
            }
        }
    }
}

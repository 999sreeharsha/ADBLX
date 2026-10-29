// ADBLX/Filtering/WebExtension/WebExtensionEntitlementCoordinator.swift
import Foundation
import ADBLXShared
import os

/// Observes the authoritative EntitlementService and atomically synchronizes
/// `entitlement.json` in the App Group container for the Safari Web Extension.
/// Deduplicates state transitions so disk I/O occurs only on effective capability changes.
public actor WebExtensionEntitlementCoordinator {
    private let entitlementService: EntitlementService
    private let publisher: WebExtensionEntitlementPublisher
    private let baseAppGroupURL: URL?
    private var lastPublishedCapability: Bool?
    private var lastPublishedValidUntil: Date?
    private var observationTask: Task<Void, Never>?
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.ADBLX.ADBLX",
        category: "WebExtensionEntitlementCoordinator"
    )
    private static let signposter = OSSignposter(
        subsystem: "com.ADBLX.ADBLX",
        category: "WebExtensionEntitlementCoordinator"
    )

    public init(
        entitlementService: EntitlementService,
        publisher: WebExtensionEntitlementPublisher = WebExtensionEntitlementPublisher(),
        baseAppGroupURL: URL? = WebExtensionAppGroupPaths.appGroupContainerURL()
    ) {
        self.entitlementService = entitlementService
        self.publisher = publisher
        self.baseAppGroupURL = baseAppGroupURL
    }

    deinit {
        observationTask?.cancel()
    }

    public func startObserving() {
        guard observationTask == nil else { return }

        observationTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            for await state in await self.entitlementService.stateUpdates() {
                await self.handleEntitlementChange(state)
            }
        }
    }

    public func syncCurrentState() async {
        let state = await entitlementService.currentState
        await handleEntitlementChange(state)
    }

    private func handleEntitlementChange(_ state: EntitlementState) async {
        let isPremium = state.hasPremiumAccess

        let validUntil = isPremium ? state.validUntil : nil

        // Deduplication: only write when the effective capability or its expiry changes
        if lastPublishedCapability == isPremium && lastPublishedValidUntil == validUntil {
            return
        }

        let spID = Self.signposter.makeSignpostID()
        let interval = Self.signposter.beginInterval("webExtension.entitlementSync", id: spID)
        defer { Self.signposter.endInterval("webExtension.entitlementSync", interval) }

        do {
            try publisher.publish(isPremium: isPremium, validUntil: validUntil, baseAppGroupURL: baseAppGroupURL)
            lastPublishedCapability = isPremium
            lastPublishedValidUntil = validUntil
            Self.logger.info(
                "Synchronized WebExtension entitlement: isPremium=\(isPremium) hasExpiry=\(validUntil != nil)"
            )
        } catch {
            Self.logger.error("Failed to publish Web Extension entitlement: \(error.localizedDescription)")
        }
    }

    public func currentPublishedCapability() -> Bool? {
        lastPublishedCapability
    }
}

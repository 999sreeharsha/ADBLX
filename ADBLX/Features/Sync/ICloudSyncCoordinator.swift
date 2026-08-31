// ADBLX/Features/Sync/ICloudSyncCoordinator.swift
import Foundation

/// Seam for NSUbiquitousKeyValueStore enabling isolated unit testing.
public protocol UbiquitousKeyValueStoreProtocol: AnyObject, Sendable {
    func array(forKey aKey: String) -> [Any]?
    func set(_ anArray: [Any]?, forKey aKey: String)
    func data(forKey aKey: String) -> Data?
    func set(_ aData: Data?, forKey aKey: String)
    func bool(forKey aKey: String) -> Bool
    func set(_ value: Bool, forKey aKey: String)
    @discardableResult func synchronize() -> Bool
}

extension NSUbiquitousKeyValueStore: @unchecked Sendable, UbiquitousKeyValueStoreProtocol {}

/// Mock implementation for unit tests.
public final class MockUbiquitousKeyValueStore: @unchecked Sendable, UbiquitousKeyValueStoreProtocol {
    private var storage: [String: Any] = [:]
    private let lock = NSLock()

    public init(initialStorage: [String: Any] = [:]) {
        self.storage = initialStorage
    }

    public func array(forKey aKey: String) -> [Any]? {
        lock.lock()
        defer { lock.unlock() }
        return storage[aKey] as? [Any]
    }

    public func set(_ anArray: [Any]?, forKey aKey: String) {
        lock.lock()
        defer { lock.unlock() }
        storage[aKey] = anArray
    }

    public func data(forKey aKey: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return storage[aKey] as? Data
    }

    public func set(_ aData: Data?, forKey aKey: String) {
        lock.lock()
        defer { lock.unlock() }
        storage[aKey] = aData
    }

    public func bool(forKey aKey: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return (storage[aKey] as? Bool) ?? false
    }

    public func set(_ value: Bool, forKey aKey: String) {
        lock.lock()
        defer { lock.unlock() }
        storage[aKey] = value
    }

    public func synchronize() -> Bool {
        true
    }
}

/// A synced allowlist record with timestamp and deletion tombstone.
public struct SyncedAllowlistRecord: Codable, Equatable, Sendable {
    public let domain: String
    public let updatedAt: Date
    public let isDeleted: Bool

    public init(domain: String, updatedAt: Date = Date(), isDeleted: Bool = false) {
        self.domain = domain
        self.updatedAt = updatedAt
        self.isDeleted = isDeleted
    }
}

/// Coordinates multi-device synchronization for custom allowlists with tombstone-based deletion propagation.
public actor ICloudSyncCoordinator {
    private let store: UbiquitousKeyValueStoreProtocol
    private let allowlistStore: AllowlistStore
    private let pipeline: FilterPipeline?
    private let entitlementService: EntitlementService
    private let notificationCenter: NotificationCenter
    private var isObserving = false

    private static let keyAllowlistData = "ADBLX_ICLOUD_ALLOWLIST_RECORDS_DATA"
    private static let keyAllowlistLegacyArray = "ADBLX_ICLOUD_ALLOWLIST_DOMAINS"

    init(
        store: UbiquitousKeyValueStoreProtocol = NSUbiquitousKeyValueStore.default,
        allowlistStore: AllowlistStore,
        pipeline: FilterPipeline? = nil,
        entitlementService: EntitlementService,
        notificationCenter: NotificationCenter = .default
    ) {
        self.store = store
        self.allowlistStore = allowlistStore
        self.pipeline = pipeline
        self.entitlementService = entitlementService
        self.notificationCenter = notificationCenter
    }

    /// Starts observing remote iCloud changes if entitled.
    public func startObserving() async {
        guard !isObserving else { return }
        isObserving = true

        notificationCenter.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store as? NSUbiquitousKeyValueStore,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task {
                await self.handleExternalChange()
            }
        }

        // Initial synchronization pass
        await handleExternalChange()
    }

    /// Handles changes pushed down from another device via iCloud, respecting tombstones and additions.
    public func handleExternalChange() async {
        guard await entitlementService.isPremiumEntitled() else { return }

        let remoteRecords = loadRemoteRecords()
        let localEntries = await allowlistStore.load()
        var localMap: [String: AllowlistEntry] = [:]
        for entry in localEntries {
            localMap[entry.domain] = entry
        }

        var didChange = false

        for remote in remoteRecords {
            if remote.isDeleted {
                // Deletion tombstone: if present locally, remove it
                if let entry = localMap[remote.domain] {
                    try? await allowlistStore.remove(id: entry.id)
                    localMap.removeValue(forKey: remote.domain)
                    didChange = true
                }
            } else {
                // Active addition: if missing locally, add it
                if localMap[remote.domain] == nil {
                    do {
                        _ = try await allowlistStore.add(domain: remote.domain)
                        didChange = true
                    } catch {
                        // Ignore invalid domain entries
                    }
                }
            }
        }

        if didChange {
            _ = try? await pipeline?.syncAllowlist()
        }
    }

    /// Records a local domain addition and synchronizes upstream.
    public func recordLocalAddition(domain: String) async {
        guard await entitlementService.isPremiumEntitled() else { return }

        var records = loadRemoteRecords()
        records.removeAll { $0.domain == domain }
        records.append(SyncedAllowlistRecord(domain: domain, updatedAt: Date(), isDeleted: false))
        saveRecords(records)
    }

    /// Records a local domain deletion with a tombstone and synchronizes upstream.
    public func recordLocalDeletion(domain: String) async {
        guard await entitlementService.isPremiumEntitled() else { return }

        var records = loadRemoteRecords()
        records.removeAll { $0.domain == domain }
        records.append(SyncedAllowlistRecord(domain: domain, updatedAt: Date(), isDeleted: true))
        saveRecords(records)
    }

    /// Helper to read records from KVS with legacy array fallback.
    public func loadRemoteRecords() -> [SyncedAllowlistRecord] {
        if let data = store.data(forKey: Self.keyAllowlistData),
           let records = try? JSONDecoder().decode([SyncedAllowlistRecord].self, from: data) {
            return records
        }

        // Fallback to legacy string array if present
        if let array = store.array(forKey: Self.keyAllowlistLegacyArray) as? [String] {
            return array.map { SyncedAllowlistRecord(domain: $0, updatedAt: Date(), isDeleted: false) }
        }

        return []
    }

    private func saveRecords(_ records: [SyncedAllowlistRecord]) {
        if let data = try? JSONEncoder().encode(records) {
            store.set(data, forKey: Self.keyAllowlistData)
        }
        // Mirror active domains to legacy array for backward compatibility
        let active = records.filter { !$0.isDeleted }.map(\.domain)
        store.set(active, forKey: Self.keyAllowlistLegacyArray)
        store.synchronize()
    }

    /// Returns whether iCloud sync is active and entitled.
    public func isSyncActive() async -> Bool {
        await entitlementService.isPremiumEntitled()
    }
}

// ADBLX/Features/Premium/Trial/TrialKeychainStore.swift
import Foundation
import Security
import os

public protocol TrialStoreProtocol: Sendable {
    func loadRecord() -> TrialRecord?
    func saveRecord(_ record: TrialRecord) throws
    func deleteRecord()
}

public final class TrialKeychainStore: TrialStoreProtocol, @unchecked Sendable {
    private let service: String
    private let account: String
    private static let logger = Logger(subsystem: "com.ADBLX.ADBLX", category: "TrialKeychainStore")
    private static let signposter = OSSignposter(subsystem: "com.ADBLX.ADBLX", category: "TrialKeychainStore")

    public init(
        service: String = "com.ADBLX.ADBLX.trial",
        account: String = "trial_record"
    ) {
        self.service = service
        self.account = account
    }

    public func loadRecord() -> TrialRecord? {
        let spID = Self.signposter.makeSignpostID()
        let interval = Self.signposter.beginInterval("trial.keychainRead", id: spID)
        defer { Self.signposter.endInterval("trial.keychainRead", interval) }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }

        do {
            let decoder = JSONDecoder()
            return try decoder.decode(TrialRecord.self, from: data)
        } catch {
            Self.logger.error("Failed to decode TrialRecord from Keychain: \(error.localizedDescription)")
            return nil
        }
    }

    public func saveRecord(_ record: TrialRecord) throws {
        let spID = Self.signposter.makeSignpostID()
        let interval = Self.signposter.beginInterval("trial.keychainWrite", id: spID)
        defer { Self.signposter.endInterval("trial.keychainWrite", interval) }

        let encoder = JSONEncoder()
        let data = try encoder.encode(record)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let attributesToUpdate: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary)

        if updateStatus == errSecItemNotFound {
            var newItem = query
            newItem[kSecValueData as String] = data
            newItem[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

            let addStatus = SecItemAdd(newItem as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                Self.logger.error("SecItemAdd failed with status: \(addStatus)")
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(addStatus), userInfo: nil)
            }
        } else if updateStatus != errSecSuccess {
            Self.logger.error("SecItemUpdate failed with status: \(updateStatus)")
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(updateStatus), userInfo: nil)
        }
    }

    public func deleteRecord() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

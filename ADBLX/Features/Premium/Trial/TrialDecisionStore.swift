// ADBLX/Features/Premium/Trial/TrialDecisionStore.swift
import Foundation
import Security
import os

public protocol TrialDecisionStoreProtocol: Sendable {
    func hasChosenFreeTier() async -> Bool
    func setChosenFreeTier(_ value: Bool) async throws
}

public final class TrialKeychainDecisionStore: TrialDecisionStoreProtocol, Sendable {
    private let service: String
    private let account: String
    private static let logger = Logger(subsystem: "com.ADBLX.ADBLX", category: "TrialKeychainDecisionStore")

    public init(
        service: String = "com.ADBLX.ADBLX.trial",
        account: String = "userChoseFreeTier"
    ) {
        self.service = service
        self.account = account
    }

    public func hasChosenFreeTier() async -> Bool {
        await Task.detached(priority: .userInitiated) { [service, account] in
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
                return false
            }

            guard let value = try? JSONDecoder().decode(Bool.self, from: data) else {
                return false
            }
            return value
        }.value
    }

    public func setChosenFreeTier(_ value: Bool) async throws {
        try await Task.detached(priority: .userInitiated) { [service, account] in
            let data = try JSONEncoder().encode(value)

            let deleteQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            SecItemDelete(deleteQuery as CFDictionary)

            let addQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
            ]

            let status = SecItemAdd(addQuery as CFDictionary, nil)
            guard status == errSecSuccess else {
                Self.logger.error("Failed to write userChoseFreeTier to Keychain: \(status)")
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: nil)
            }
            Self.logger.info("Persisted userChoseFreeTier=\(value) to Keychain")
        }.value
    }
}

public actor InMemoryTrialDecisionStore: TrialDecisionStoreProtocol {
    private var chosen: Bool

    public init(chosen: Bool = false) {
        self.chosen = chosen
    }

    public func hasChosenFreeTier() -> Bool {
        chosen
    }

    public func setChosenFreeTier(_ value: Bool) {
        self.chosen = value
    }
}

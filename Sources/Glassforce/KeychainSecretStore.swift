import Foundation
import Security
import GlassforceCore

/// Refresh tokens in the login Keychain: one generic-password item per org, this device only,
/// never synced to iCloud.
struct KeychainSecretStore: SecretStore {
    let service: String

    private func baseQuery(account: String? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kCFBooleanFalse!,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }

    func read(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return result as? Data
    }

    func write(_ data: Data, account: String) throws {
        let update = SecItemUpdate(baseQuery(account: account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainError(status: update) }
        var add = baseQuery(account: account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrLabel as String] = "Glassforce (Salesforce sign-in)"
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    /// Removes every item for this service (mock reset only).
    func deleteAll() {
        SecItemDelete(baseQuery() as CFDictionary)
    }
}

struct KeychainError: LocalizedError, CustomStringConvertible {
    let status: OSStatus
    var description: String { (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)" }
    var errorDescription: String? {
        let description = self.description.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return status == errSecUserCanceled || status == errSecAuthFailed
            ? "the Mac Keychain didn't hand over your saved sign-in (\(description)). Click Always Allow when macOS asks about Glassforce"
            : "the Mac Keychain refused your saved sign-in (\(description))"
    }
}

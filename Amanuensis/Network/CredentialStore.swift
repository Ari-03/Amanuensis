import Foundation
import Security

/// API credentials live in the login Keychain, never in saved app configuration.
enum CredentialStore {
    private static let service = "dev.amanuensis.api-credentials"

    static func set(_ value: String, for provider: ModelFamily) throws {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains(where: { $0.isWhitespace }) else {
            throw CredentialError.invalidValue
        }
        let query = try query(for: provider)
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8)]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item.merge(attributes) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw CredentialError.keychain(addStatus) }
        } else if status != errSecSuccess {
            throw CredentialError.keychain(status)
        }
    }

    static func get(for provider: ModelFamily) throws -> String? {
        var query = try query(for: provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CredentialError.keychain(status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw CredentialError.invalidValue
        }
        return value
    }

    static func remove(for provider: ModelFamily) throws {
        let status = SecItemDelete(try query(for: provider) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialError.keychain(status)
        }
    }

    private static func query(for provider: ModelFamily) throws -> [String: Any] {
        guard [.openAI, .groq, .anthropic].contains(provider) else {
            throw CredentialError.unsupportedProvider
        }
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
            kSecAttrSynchronizable as String: false,
        ]
    }

    enum CredentialError: LocalizedError {
        case invalidValue, unsupportedProvider
        case keychain(OSStatus)

        var errorDescription: String? {
            switch self {
            case .invalidValue: "Enter an API key without spaces or line breaks."
            case .unsupportedProvider: "This provider does not use a stored API key."
            case .keychain(let status):
                "The Keychain could not access this API key (error \(status)). Unlock your login Keychain and retry."
            }
        }
    }
}

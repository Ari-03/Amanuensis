import Foundation
import Security

/// API credentials live in the login Keychain, never in saved app configuration.
/// An OpenAI-compatible key is saved in one item with the base URL it belongs to, normalized by
/// `APIBaseURL`, and `get` returns it only for that exact address. The fixed providers take no address.
enum CredentialStore {
    private static let service = "dev.amanuensis.api-credentials"

    static func set(_ value: String, for provider: ModelFamily, server: URL? = nil) throws {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains(where: { $0.isWhitespace }) else {
            throw CredentialError.invalidValue
        }
        let query = try query(for: provider)
        guard (provider == .openAICompatible) == (server != nil) else {
            throw CredentialError.unsupportedProvider
        }
        var attributes: [String: Any] = [kSecValueData as String: Data(value.utf8)]
        if let server { attributes[kSecAttrGeneric as String] = Data(server.absoluteString.utf8) }
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

    /// Returns nil when no key is saved, or when a compatible key was saved for another address.
    static func get(for provider: ModelFamily, server: URL? = nil) throws -> String? {
        var query = try query(for: provider)
        guard (provider == .openAICompatible) == (server != nil) else {
            throw CredentialError.unsupportedProvider
        }
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CredentialError.keychain(status) }
        guard let item = result as? [String: Any], let data = item[kSecValueData as String] as? Data,
            let value = String(data: data, encoding: .utf8)
        else { throw CredentialError.invalidValue }
        if let server, item[kSecAttrGeneric as String] as? Data != Data(server.absoluteString.utf8) {
            return nil
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
        guard [.openAI, .groq, .anthropic, .openAICompatible].contains(provider) else {
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

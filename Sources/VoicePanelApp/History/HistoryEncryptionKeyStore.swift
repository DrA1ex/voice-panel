import Foundation
import LocalAuthentication
import Security

struct HistoryEncryptionKeyStore {
    private static let service = "com.voicepanel.history-encryption"
    private static let legacyIdentifier = "legacy-v1"
    private static let legacyAccount = "transcript-history-key-v1"
    private static let rotatedAccountPrefix = "transcript-history-key-v2-"
    private static let activeIdentifierDefaultsKey = "historyEncryptionKeyIdentifierV2"

    private let account: String

    static func activeIdentifier(defaults: UserDefaults = .standard) -> String {
        guard let identifier = defaults.string(forKey: activeIdentifierDefaultsKey),
            isValidIdentifier(identifier)
        else { return legacyIdentifier }
        return identifier
    }

    static func isValidIdentifier(_ identifier: String) -> Bool {
        identifier == legacyIdentifier || UUID(uuidString: identifier) != nil
    }

    static func active(defaults: UserDefaults = .standard) -> HistoryEncryptionKeyStore {
        forIdentifier(activeIdentifier(defaults: defaults))
    }

    static func forIdentifier(_ identifier: String) -> HistoryEncryptionKeyStore {
        HistoryEncryptionKeyStore(
            account: identifier == legacyIdentifier
                ? legacyAccount
                : rotatedAccountPrefix + identifier
        )
    }

    static func rotated() -> (identifier: String, keyStore: HistoryEncryptionKeyStore) {
        let identifier = UUID().uuidString.lowercased()
        return (identifier, forIdentifier(identifier))
    }

    static func activate(_ identifier: String, defaults: UserDefaults = .standard) {
        defaults.set(identifier, forKey: activeIdentifierDefaultsKey)
    }

    func loadExistingKey(allowsInteraction: Bool = true) throws -> Data {
        let (status, data) = copyKey(allowsInteraction: allowsInteraction)
        guard status == errSecSuccess, let data, data.count == 32 else {
            if status == errSecItemNotFound {
                throw HistoryKeyStoreError.keyNotFound
            }
            throw HistoryKeyStoreError.keychain(status)
        }
        return data
    }

    func loadOrCreateKey(allowsInteraction: Bool = true) throws -> Data {
        let (status, data) = copyKey(allowsInteraction: allowsInteraction)
        if status == errSecSuccess, let data, data.count == 32 {
            return data
        }
        guard status == errSecItemNotFound else {
            throw HistoryKeyStoreError.keychain(status)
        }

        return try createKey(allowsInteraction: allowsInteraction)
    }

    private func copyKey(allowsInteraction: Bool) -> (OSStatus, Data?) {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if !allowsInteraction {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }

    private func createKey(allowsInteraction: Bool) throws -> Data {
        var key = Data(count: 32)
        let randomStatus = key.withUnsafeMutableBytes { bytes in
            guard let address = bytes.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, bytes.count, address)
        }
        guard randomStatus == errSecSuccess else {
            throw HistoryKeyStoreError.randomGeneration(randomStatus)
        }

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: key,
            kSecAttrLabel as String: "VoicePanel encrypted transcript history",
        ]
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            return try loadOrCreateKey(allowsInteraction: allowsInteraction)
        }
        guard addStatus == errSecSuccess else {
            throw HistoryKeyStoreError.keychain(addStatus)
        }
        return key
    }
}

private enum HistoryKeyStoreError: LocalizedError {
    case keychain(OSStatus)
    case keyNotFound
    case randomGeneration(OSStatus)

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            return "The history encryption key could not be accessed in Keychain (\(status))."
        case .keyNotFound:
            return "The previous history encryption key is no longer present in Keychain."
        case .randomGeneration(let status):
            return "A secure history encryption key could not be generated (\(status))."
        }
    }
}

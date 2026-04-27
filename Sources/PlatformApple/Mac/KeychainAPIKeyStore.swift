#if canImport(Security)
import Foundation
import Security

/// Stores per-provider API keys in the macOS Keychain as generic-password
/// entries. Keychain ACLs are tied to the running app's code signature, so
/// stable signing (Apple Developer team via Xcode automatic signing) is a
/// prerequisite — ad-hoc CLI builds will produce orphaned entries.
public actor KeychainAPIKeyStore {
    public enum KeychainError: Error, Equatable {
        /// Keychain returned an unexpected OSStatus (not `errSecSuccess` or
        /// `errSecItemNotFound`). Inspect `status` for the raw code.
        case osStatus(OSStatus)
        /// A stored item was found but its data was not valid UTF-8.
        case malformedData
    }

    private let service: String

    /// - Parameter service: Keychain service name. Defaults to the production
    ///   bundle ID; tests should pass a unique value to isolate state.
    public init(service: String = "s900mhz.WhatchuSayMac") {
        self.service = service
    }

    /// Returns the stored key for `provider`, or `nil` if no entry exists.
    public func read(provider: String) throws -> String? {
        var query = baseQuery(provider: provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let string = String(data: data, encoding: .utf8)
            else { throw KeychainError.malformedData }
            return string
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.osStatus(status)
        }
    }

    /// Writes `key` for `provider`, overwriting any existing entry.
    public func write(provider: String, key: String) throws {
        let data = Data(key.utf8)
        let query = baseQuery(provider: provider)

        // Try update first; if no existing entry, fall through to add.
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus != errSecSuccess {
                throw KeychainError.osStatus(addStatus)
            }
        default:
            throw KeychainError.osStatus(updateStatus)
        }
    }

    /// Removes the entry for `provider` if present. No-op when missing.
    public func delete(provider: String) throws {
        let status = SecItemDelete(baseQuery(provider: provider) as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            throw KeychainError.osStatus(status)
        }
    }

    private func baseQuery(provider: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider,
        ]
    }
}
#endif

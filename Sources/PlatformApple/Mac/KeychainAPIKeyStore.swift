#if canImport(Security)
import Foundation
import Security

/// Stores per-provider API keys in the macOS Keychain as generic-password
/// entries. Keychain ACLs are tied to the running app's code signature, so
/// stable signing (Apple Developer team via Xcode automatic signing) is a
/// prerequisite. When the signing identity changes — an ad-hoc CLI build, or
/// an Apple Development certificate that has since been revoked or rotated —
/// the existing entry can no longer be read or updated; `write` recovers from
/// this by deleting the orphaned entry and re-adding it under the current
/// signature (see `recoverOrphanedEntry`).
public actor KeychainAPIKeyStore {
    public enum KeychainError: Error, Equatable, LocalizedError, CustomStringConvertible {
        /// Keychain returned an unexpected OSStatus (not `errSecSuccess` or
        /// `errSecItemNotFound`). Inspect `status` for the raw code.
        case osStatus(OSStatus)
        /// A stored item was found but its data was not valid UTF-8.
        case malformedData
        /// An entry exists but is bound to a previous, now-invalid code
        /// signature (e.g. a revoked Apple Development certificate), and the
        /// automatic delete-and-recreate recovery also failed. Carries the
        /// originating `SecItemUpdate` and `SecItemDelete` statuses.
        case orphanedEntry(updateStatus: OSStatus, deleteStatus: OSStatus)

        public var description: String {
            switch self {
            case .osStatus(let status):
                return "osStatus(\(status))"
            case .malformedData:
                return "malformedData"
            case .orphanedEntry(let updateStatus, let deleteStatus):
                return "The saved key is locked to a previous app signature "
                    + "and could not be cleared automatically "
                    + "(update \(updateStatus), delete \(deleteStatus)). "
                    + "Open Keychain Access, delete this app's API-key entry, "
                    + "then set the key again."
            }
        }

        public var errorDescription: String? { description }
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
            // Never delete on read. A dead-signature entry (e.g. a revoked
            // Apple Development certificate, `errSecCertificateRevoked`)
            // looks the same from here as a user clicking Deny on the access
            // prompt (`errSecUserCanceled` / `errSecAuthFailed`) or a locked
            // keychain (`errSecInteractionNotAllowed`) — and purging in those
            // cases silently destroyed a perfectly good key. The caller logs
            // the error and falls back to setup; the next `write` clears a
            // genuinely dead entry via `recoverOrphanedEntry`.
            throw KeychainError.osStatus(status)
        }
    }

    /// Writes `key` for `provider`, overwriting any existing entry.
    ///
    /// If an entry exists but is bound to a previous, now-invalid code
    /// signature (e.g. an Apple Development certificate that has since been
    /// revoked), `SecItemUpdate` fails with a trust error such as
    /// `errSecCertificateRevoked`. Rather than surfacing an unfixable error,
    /// `recoverOrphanedEntry` deletes the stale entry — which does not require
    /// decrypting it — and re-adds it under the current signature.
    public func write(provider: String, key: String) throws {
        let data = Data(key.utf8)
        let query = baseQuery(provider: provider)

        // Try update first; if no existing entry, add. Any other failure
        // means the entry is present but inaccessible — recover it.
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            try add(provider: provider, data: data)
        default:
            try recoverOrphanedEntry(
                provider: provider,
                data: data,
                updateStatus: updateStatus
            )
        }
    }

    /// Adds a fresh generic-password entry. Assumes no accessible entry
    /// already exists for `provider`.
    private func add(provider: String, data: Data) throws {
        var addQuery = baseQuery(provider: provider)
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus != errSecSuccess {
            throw KeychainError.osStatus(addStatus)
        }
    }

    /// Deletes an entry that exists but can't be updated, then re-adds it
    /// under the current signature.
    private func recoverOrphanedEntry(
        provider: String,
        data: Data,
        updateStatus: OSStatus
    ) throws {
        try purgeInaccessibleEntry(provider: provider, accessStatus: updateStatus)
        try add(provider: provider, data: data)
    }

    /// Deletes an entry whose data can't be accessed under the current code
    /// signature (e.g. it was written under a since-revoked Apple
    /// Development certificate). `SecItemDelete` does not consult the item's
    /// data-access ACL, so it succeeds even when `SecItemUpdate` /
    /// `SecItemCopyMatching` can't decrypt the entry — the same reason
    /// `security delete-generic-password` works. Throws `orphanedEntry` only
    /// if the delete itself fails, leaving the entry genuinely unrecoverable
    /// from this process; `accessStatus` is the originating update/copy
    /// status, carried into the actionable message.
    private func purgeInaccessibleEntry(
        provider: String,
        accessStatus: OSStatus
    ) throws {
        let deleteStatus = SecItemDelete(
            baseQuery(provider: provider) as CFDictionary
        )
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound
        else {
            throw KeychainError.orphanedEntry(
                updateStatus: accessStatus,
                deleteStatus: deleteStatus
            )
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

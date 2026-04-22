//
//  PasswordCredentialStore.swift
//  Socket
//
//  Keychain-backed store for web-form passwords (kSecClassInternetPassword).
//  Separate from BasicAuthCredentialStore: different class, different semantics,
//  profile-isolated via kSecAttrService keyed on the profile UUID.
//

import Foundation
import OSLog

#if canImport(Security)
import Security
#endif

#if canImport(LocalAuthentication)
import LocalAuthentication
#endif

@MainActor
final class PasswordCredentialStore {

    struct Record: Hashable, Identifiable {
        let persistentRef: Data
        let host: String
        let username: String
        let password: String
        let modified: Date
        let synchronizable: Bool

        var id: Data { persistentRef }
    }

    enum StoreError: Error, Equatable {
        case invalidInput
        case itemNotFound
        case decodingFailed
        case unhandled(OSStatus)
    }

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Socket",
                                category: "Passwords")

    private let servicePrefix: String
    private let useDataProtection: Bool

    /// - Parameters:
    ///   - servicePrefix: Tests pass a unique prefix so CRUD calls never
    ///     touch the user's real Keychain entries. Production uses `com.socket.passwords`.
    ///   - useDataProtection: Set `kSecUseDataProtectionKeychain`. Required for
    ///     iCloud Keychain sync but fails with `errSecMissingEntitlement` when
    ///     the host binary isn't signed with a `keychain-access-groups`
    ///     entitlement (e.g. unsigned test runners). Default true; tests override.
    init(servicePrefix: String = "com.socket.passwords",
         useDataProtection: Bool = true) {
        self.servicePrefix = servicePrefix
        self.useDataProtection = useDataProtection
    }

    // MARK: - Public CRUD

    @discardableResult
    func save(host: String,
              username: String,
              password: String,
              sync: Bool,
              profile: UUID) -> Result<Data, StoreError> {
        guard !host.isEmpty, !username.isEmpty, !password.isEmpty else {
            return .failure(.invalidInput)
        }
        #if canImport(Security)
        guard let passwordData = password.data(using: .utf8) else {
            return .failure(.invalidInput)
        }

        let base = baseAttributes(host: host, username: username, profile: profile)

        // Duplicate detection: Synchronizable is not mutable in place. If we find
        // a record with a different sync flag, delete+insert instead of update.
        switch existingRef(host: host, username: username, profile: profile) {
        case .success(let existing):
            if let existing {
                if existing.synchronizable == sync {
                    let update: [String: Any] = [kSecValueData as String: passwordData]
                    let status = SecItemUpdate(existing.query as CFDictionary,
                                               update as CFDictionary)
                    if status == errSecSuccess {
                        return .success(existing.ref)
                    }
                    logger.error("SecItemUpdate failed: \(status, privacy: .public)")
                    return .failure(.unhandled(status))
                } else {
                    // Recreate under the desired sync flag.
                    let delStatus = SecItemDelete(existing.query as CFDictionary)
                    if delStatus != errSecSuccess && delStatus != errSecItemNotFound {
                        logger.error("SecItemDelete during sync-flip failed: \(delStatus, privacy: .public)")
                    }
                }
            }
        case .failure(let error):
            return .failure(error)
        }

        var insert: [String: Any] = base
        insert[kSecValueData as String] = passwordData
        insert[kSecAttrSynchronizable as String] = sync ? kCFBooleanTrue : kCFBooleanFalse
        insert[kSecReturnPersistentRef as String] = true
        insert[kSecAttrLabel as String] = labelFor(host: host)
        // base[] already includes kSecUseDataProtectionKeychain keyed to the
        // instance setting; re-asserting it here would overwrite the false
        // case with true and break unsigned test runs.

        var item: CFTypeRef?
        let status = SecItemAdd(insert as CFDictionary, &item)
        guard status == errSecSuccess else {
            logger.error("SecItemAdd failed: \(status, privacy: .public)")
            return .failure(.unhandled(status))
        }
        guard let ref = item as? Data else {
            return .failure(.decodingFailed)
        }
        return .success(ref)
        #else
        return .failure(.unhandled(-1))
        #endif
    }

    func update(ref: Data, newPassword: String) -> Result<Void, StoreError> {
        guard !newPassword.isEmpty else { return .failure(.invalidInput) }
        #if canImport(Security)
        guard let passwordData = newPassword.data(using: .utf8) else {
            return .failure(.invalidInput)
        }

        var query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecValuePersistentRef as String: ref
        ]
        applyDataProtection(to: &query)
        let update: [String: Any] = [kSecValueData as String: passwordData]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        switch status {
        case errSecSuccess: return .success(())
        case errSecItemNotFound: return .failure(.itemNotFound)
        default:
            logger.error("SecItemUpdate by ref failed: \(status, privacy: .public)")
            return .failure(.unhandled(status))
        }
        #else
        return .failure(.unhandled(-1))
        #endif
    }

    func fetchAll(for host: String,
                  profile: UUID,
                  includePassword: Bool) -> [Record] {
        guard !host.isEmpty else { return [] }
        #if canImport(Security)
        var query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrService as String: service(for: profile),
            kSecAttrServer as String: host,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnPersistentRef as String: true,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        applyDataProtection(to: &query)
        let records = runQueryAll(query)
        // kSecReturnData alongside kSecMatchLimitAll + kSecReturnAttributes is
        // unreliable on macOS (returns an empty set in practice), so if the
        // caller wants passwords we fetch each item's data in a second pass.
        if includePassword {
            return records.map { record -> Record in
                guard case .success(let pw) = fetchPassword(ref: record.persistentRef) else {
                    return record
                }
                return Record(persistentRef: record.persistentRef,
                              host: record.host,
                              username: record.username,
                              password: pw,
                              modified: record.modified,
                              synchronizable: record.synchronizable)
            }
        }
        return records
        #else
        return []
        #endif
    }

    /// Read every `kSecClassInternetPassword` entry across all hosts,
    /// regardless of which app created it. Used for the Settings list so
    /// users see entries they saved in Safari / iCloud Keychain / System
    /// Settings → Passwords alongside Socket's own records.
    ///
    /// macOS shows "Socket wants to use your confidential information" per
    /// entry on first access. An "Always Allow" response silences it.
    func fetchAllSystemKeychain() -> [Record] {
        #if canImport(Security)
        var query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnPersistentRef as String: true,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        applyDataProtection(to: &query)
        return runQueryAll(query)
        #else
        return []
        #endif
    }

    /// Read every `kSecClassInternetPassword` entry for this host **regardless
    /// of which app created it** — Safari, iCloud Keychain, System Settings
    /// → Passwords, other apps. No `kSecAttrService` filter.
    ///
    /// macOS may surface a "Socket wants to use your confidential information
    /// stored in <entry>" prompt the first time; after "Always Allow" it's
    /// silent. Used to merge system Keychain entries into autofill
    /// suggestions so users see passwords they've already saved in Safari /
    /// iCloud without having to re-save them in Socket.
    func fetchSystemKeychain(for host: String) -> [Record] {
        guard !host.isEmpty else { return [] }
        #if canImport(Security)
        var query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: host,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnPersistentRef as String: true,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        applyDataProtection(to: &query)
        return runQueryAll(query)
        #else
        return []
        #endif
    }

    func fetchAllForProfile(_ profile: UUID) -> [Record] {
        #if canImport(Security)
        var query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrService as String: service(for: profile),
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnPersistentRef as String: true,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        applyDataProtection(to: &query)
        return runQueryAll(query)
        #else
        return []
        #endif
    }

    func fetchPassword(ref: Data, context: LAContext? = nil) -> Result<String, StoreError> {
        #if canImport(Security)
        var query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecValuePersistentRef as String: ref,
            kSecReturnData as String: true,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        applyDataProtection(to: &query)
        if let context {
            query[kSecUseAuthenticationContext as String] = context
        }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let pw = String(data: data, encoding: .utf8) else {
                return .failure(.decodingFailed)
            }
            return .success(pw)
        case errSecItemNotFound:
            return .failure(.itemNotFound)
        default:
            logger.error("fetchPassword failed: \(status, privacy: .public)")
            return .failure(.unhandled(status))
        }
        #else
        return .failure(.unhandled(-1))
        #endif
    }

    @discardableResult
    func delete(ref: Data) -> Result<Void, StoreError> {
        #if canImport(Security)
        var query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecValuePersistentRef as String: ref,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        applyDataProtection(to: &query)
        let status = SecItemDelete(query as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound: return .success(())
        default:
            logger.error("SecItemDelete failed: \(status, privacy: .public)")
            return .failure(.unhandled(status))
        }
        #else
        return .failure(.unhandled(-1))
        #endif
    }

    func exists(host: String, username: String, profile: UUID) -> Bool {
        guard !host.isEmpty, !username.isEmpty else { return false }
        switch existingRef(host: host, username: username, profile: profile) {
        case .success(let existing): return existing != nil
        case .failure: return false
        }
    }

    /// Delete every record stored under the given profile. Useful for ephemeral-profile teardown and tests.
    @discardableResult
    func purge(profile: UUID) -> Result<Void, StoreError> {
        #if canImport(Security)
        var query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrService as String: service(for: profile),
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        applyDataProtection(to: &query)
        let status = SecItemDelete(query as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound: return .success(())
        default: return .failure(.unhandled(status))
        }
        #else
        return .failure(.unhandled(-1))
        #endif
    }

    /// Wipe every Socket-owned internet-password record produced by this store's service prefix.
    /// Tests use this via `servicePrefix` isolation; production code should never call this.
    @discardableResult
    func purgeAllUnderPrefix() -> Result<Void, StoreError> {
        #if canImport(Security)
        // Keychain has no prefix query; enumerate all of our items and filter by service.
        var query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnPersistentRef as String: true,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        applyDataProtection(to: &query)
        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            return .failure(.unhandled(status))
        }
        let results = (items as? [[String: Any]]) ?? []
        for attrs in results {
            guard let svc = attrs[kSecAttrService as String] as? String,
                  svc.hasPrefix(servicePrefix),
                  let ref = attrs[kSecValuePersistentRef as String] as? Data else {
                continue
            }
            _ = delete(ref: ref)
        }
        return .success(())
        #else
        return .failure(.unhandled(-1))
        #endif
    }

    // MARK: - Private

    private func service(for profile: UUID) -> String {
        "\(servicePrefix).\(profile.uuidString)"
    }

    private func labelFor(host: String) -> String {
        "Socket — \(host)"
    }

    private func baseAttributes(host: String, username: String, profile: UUID) -> [String: Any] {
        var attrs: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrService as String: service(for: profile),
            kSecAttrServer as String: host,
            kSecAttrAccount as String: username,
            kSecAttrProtocol as String: kSecAttrProtocolHTTPS
        ]
        applyDataProtection(to: &attrs)
        return attrs
    }

    /// Only set `kSecUseDataProtectionKeychain` when enabled. Passing `false`
    /// explicitly behaves differently from omitting the key in some macOS
    /// versions — notably, unsigned hosts get `errSecMissingEntitlement` even
    /// when the intent is to opt out.
    private func applyDataProtection(to attrs: inout [String: Any]) {
        if useDataProtection {
            attrs[kSecUseDataProtectionKeychain as String] = true
        }
    }

    private struct ExistingRecord {
        let ref: Data
        let query: [String: Any]
        let synchronizable: Bool
    }

    private func existingRef(host: String,
                             username: String,
                             profile: UUID) -> Result<ExistingRecord?, StoreError> {
        #if canImport(Security)
        var query = baseAttributes(host: host, username: username, profile: profile)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnAttributes as String] = true
        query[kSecReturnPersistentRef as String] = true
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let dict = item as? [String: Any],
                  let ref = dict[kSecValuePersistentRef as String] as? Data else {
                return .failure(.decodingFailed)
            }
            let sync = (dict[kSecAttrSynchronizable as String] as? Bool) ?? false
            // Preserve the same selectors for update so we hit the exact record.
            let updateQuery = baseAttributes(host: host, username: username, profile: profile)
            return .success(ExistingRecord(ref: ref, query: updateQuery, synchronizable: sync))
        case errSecItemNotFound:
            return .success(nil)
        default:
            return .failure(.unhandled(status))
        }
        #else
        return .failure(.unhandled(-1))
        #endif
    }

    private func runQueryAll(_ query: [String: Any]) -> [Record] {
        #if canImport(Security)
        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        guard status == errSecSuccess else { return [] }
        let results = (items as? [[String: Any]]) ?? []
        return results.compactMap { dict -> Record? in
            guard let ref = dict[kSecValuePersistentRef as String] as? Data,
                  let host = dict[kSecAttrServer as String] as? String,
                  let username = dict[kSecAttrAccount as String] as? String else {
                return nil
            }
            let sync = (dict[kSecAttrSynchronizable as String] as? Bool) ?? false
            let modified = (dict[kSecAttrModificationDate as String] as? Date) ?? Date.distantPast
            var password = ""
            if let data = dict[kSecValueData as String] as? Data,
               let decoded = String(data: data, encoding: .utf8) {
                password = decoded
            }
            return Record(persistentRef: ref,
                          host: host,
                          username: username,
                          password: password,
                          modified: modified,
                          synchronizable: sync)
        }.sorted { lhs, rhs in
            if lhs.host == rhs.host { return lhs.username < rhs.username }
            return lhs.host < rhs.host
        }
        #else
        return []
        #endif
    }
}

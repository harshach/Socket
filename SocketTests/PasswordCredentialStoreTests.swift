//
//  PasswordCredentialStoreTests.swift
//  SocketTests
//
//  Tests never touch the user's real Keychain entries. Each test instance
//  uses a fresh randomized service prefix; tearDown purges it.
//

import XCTest
import Security
@testable import Socket

@MainActor
final class PasswordCredentialStoreTests: XCTestCase {

    private var store: PasswordCredentialStore!
    private var profile: UUID!
    private var servicePrefix: String!

    override func setUp() async throws {
        try await super.setUp()
        // Unsigned test runners (CI, local with CODE_SIGNING_ALLOWED=NO) can't
        // use Keychain Services and get errSecMissingEntitlement (-34018). Skip
        // the whole suite in that case — the test's contract is CRUD against
        // a real Keychain; if we can't reach one, the assertions are moot.
        try Self.skipIfKeychainUnavailable()
        // Unique per run so parallel test execution doesn't collide. Test
        // runners aren't signed with a keychain-access-groups entitlement, so
        // we opt out of the data-protection keychain here; production uses it.
        servicePrefix = "com.socket.passwords.test.\(UUID().uuidString)"
        store = PasswordCredentialStore(servicePrefix: servicePrefix,
                                        useDataProtection: false)
        profile = UUID()
    }

    override func tearDown() async throws {
        // Scrub everything this instance wrote.
        store?.purgeAllUnderPrefix()
        try await super.tearDown()
    }

    private static func skipIfKeychainUnavailable() throws {
        // Probe with a dummy add+round-trip fetch. macOS legacy Keychain
        // (unsigned test hosts) often accepts SecItemAdd but then can't
        // SecItemCopyMatching the same record reliably — so probe both.
        let probeService = "com.socket.passwords.test.probe.\(UUID().uuidString)"
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrService as String: probeService,
            kSecAttrServer as String: "probe.local",
            kSecAttrAccount as String: "probe",
            kSecAttrProtocol as String: kSecAttrProtocolHTTPS,
            kSecValueData as String: Data("probe".utf8)
        ]
        let addStatus = SecItemAdd(attrs as CFDictionary, nil)
        defer {
            _ = SecItemDelete([
                kSecClass as String: kSecClassInternetPassword,
                kSecAttrService as String: probeService
            ] as CFDictionary)
        }
        if addStatus == errSecMissingEntitlement || addStatus == -34018 {
            throw XCTSkip("""
                Keychain write unavailable (errSecMissingEntitlement -34018). \
                Sign the test host with a keychain-access-groups entitlement, \
                or run in Xcode with automatic signing to execute these tests.
                """)
        }
        guard addStatus == errSecSuccess else {
            throw XCTSkip("Keychain probe SecItemAdd failed with OSStatus \(addStatus); skipping.")
        }

        var item: CFTypeRef?
        let findStatus = SecItemCopyMatching([
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrService as String: probeService,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
            kSecReturnPersistentRef as String: true
        ] as CFDictionary, &item)
        if findStatus != errSecSuccess || (item as? [String: Any])?[kSecAttrServer as String] == nil {
            throw XCTSkip("""
                Keychain lookup is unreliable in this test host \
                (SecItemCopyMatching OSStatus \(findStatus)). This is typical \
                for unsigned hosts on macOS 15+. Run in Xcode (signed) to \
                execute these tests.
                """)
        }
    }

    // MARK: - Save / fetch

    func testSaveAndFetchRoundtrip() {
        let result = store.save(host: "example.com",
                                username: "alice",
                                password: "hunter2",
                                sync: false,
                                profile: profile)
        guard case .success(let ref) = result else {
            XCTFail("Expected save success, got \(result)")
            return
        }
        XCTAssertFalse(ref.isEmpty)

        let fetched = store.fetchAll(for: "example.com", profile: profile, includePassword: true)
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.username, "alice")
        XCTAssertEqual(fetched.first?.password, "hunter2")
        XCTAssertEqual(fetched.first?.host, "example.com")
        XCTAssertEqual(fetched.first?.synchronizable, false)
    }

    func testFetchWithoutPasswordDoesNotReturnData() {
        _ = store.save(host: "example.com", username: "alice", password: "p", sync: false, profile: profile)
        let fetched = store.fetchAll(for: "example.com", profile: profile, includePassword: false)
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.password, "")
    }

    func testExistsReturnsTrueAfterSave() {
        XCTAssertFalse(store.exists(host: "example.com", username: "alice", profile: profile))
        _ = store.save(host: "example.com", username: "alice", password: "p", sync: false, profile: profile)
        XCTAssertTrue(store.exists(host: "example.com", username: "alice", profile: profile))
    }

    // MARK: - Update / duplicate handling

    func testDuplicateSaveUpdatesExistingAndPreservesRef() {
        let first = store.save(host: "example.com", username: "alice", password: "old", sync: false, profile: profile)
        guard case .success(let refA) = first else { return XCTFail() }

        let second = store.save(host: "example.com", username: "alice", password: "new", sync: false, profile: profile)
        guard case .success(let refB) = second else { return XCTFail() }

        // When sync flag matches, update happens in place — ref stays equal.
        XCTAssertEqual(refA, refB)

        let fetched = store.fetchAll(for: "example.com", profile: profile, includePassword: true)
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.password, "new")
    }

    func testSyncFlipRecreatesRecord() {
        let first = store.save(host: "example.com", username: "alice", password: "p", sync: false, profile: profile)
        guard case .success(let refA) = first else { return XCTFail() }

        let second = store.save(host: "example.com", username: "alice", password: "p", sync: true, profile: profile)
        guard case .success(let refB) = second else { return XCTFail() }

        XCTAssertNotEqual(refA, refB, "Flipping synchronizable should delete+reinsert")
        let fetched = store.fetchAll(for: "example.com", profile: profile, includePassword: false)
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.synchronizable, true)
    }

    func testUpdateByRef() {
        let saved = store.save(host: "example.com", username: "alice", password: "old", sync: false, profile: profile)
        guard case .success(let ref) = saved else { return XCTFail() }

        let upd = store.update(ref: ref, newPassword: "newer")
        guard case .success = upd else { return XCTFail("update failed: \(upd)") }

        let fetched = store.fetchAll(for: "example.com", profile: profile, includePassword: true)
        XCTAssertEqual(fetched.first?.password, "newer")
    }

    // MARK: - Delete

    func testDelete() {
        let saved = store.save(host: "example.com", username: "alice", password: "p", sync: false, profile: profile)
        guard case .success(let ref) = saved else { return XCTFail() }

        let del = store.delete(ref: ref)
        guard case .success = del else { return XCTFail("delete failed: \(del)") }

        XCTAssertFalse(store.exists(host: "example.com", username: "alice", profile: profile))
    }

    func testDeleteOfMissingItemIsSuccess() {
        let bogusRef = Data(repeating: 0, count: 16)
        let del = store.delete(ref: bogusRef)
        guard case .success = del else {
            XCTFail("delete of missing item should return success, got \(del)")
            return
        }
    }

    // MARK: - Profile isolation

    func testProfileIsolation() {
        let profileA = UUID(), profileB = UUID()
        _ = store.save(host: "example.com", username: "alice", password: "A", sync: false, profile: profileA)
        _ = store.save(host: "example.com", username: "bob", password: "B", sync: false, profile: profileB)

        let aResults = store.fetchAll(for: "example.com", profile: profileA, includePassword: true)
        let bResults = store.fetchAll(for: "example.com", profile: profileB, includePassword: true)

        XCTAssertEqual(aResults.count, 1)
        XCTAssertEqual(aResults.first?.username, "alice")
        XCTAssertEqual(bResults.count, 1)
        XCTAssertEqual(bResults.first?.username, "bob")
    }

    func testPurgeProfileRemovesOnlyThatProfile() {
        let profileA = UUID(), profileB = UUID()
        _ = store.save(host: "a.com", username: "u", password: "p", sync: false, profile: profileA)
        _ = store.save(host: "a.com", username: "u", password: "p", sync: false, profile: profileB)

        _ = store.purge(profile: profileA)

        XCTAssertEqual(store.fetchAllForProfile(profileA).count, 0)
        XCTAssertEqual(store.fetchAllForProfile(profileB).count, 1)
    }

    // MARK: - Multi-account per host

    func testMultipleAccountsPerHost() {
        _ = store.save(host: "example.com", username: "alice", password: "a", sync: false, profile: profile)
        _ = store.save(host: "example.com", username: "bob",   password: "b", sync: false, profile: profile)

        let results = store.fetchAll(for: "example.com", profile: profile, includePassword: false)
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(Set(results.map { $0.username }), Set(["alice", "bob"]))
    }

    // MARK: - Input validation

    func testEmptyHostRejected() {
        let result = store.save(host: "", username: "a", password: "p", sync: false, profile: profile)
        guard case .failure(.invalidInput) = result else {
            XCTFail("Expected invalidInput, got \(result)")
            return
        }
    }

    func testEmptyUsernameRejected() {
        let result = store.save(host: "h.com", username: "", password: "p", sync: false, profile: profile)
        guard case .failure(.invalidInput) = result else {
            XCTFail("Expected invalidInput, got \(result)")
            return
        }
    }

    func testEmptyPasswordRejected() {
        let result = store.save(host: "h.com", username: "a", password: "", sync: false, profile: profile)
        guard case .failure(.invalidInput) = result else {
            XCTFail("Expected invalidInput, got \(result)")
            return
        }
    }

    // MARK: - Unicode

    func testUnicodeCredentials() {
        let u = "üsér名前"
        let p = "🔑pässwörd"
        _ = store.save(host: "example.com", username: u, password: p, sync: false, profile: profile)

        let results = store.fetchAll(for: "example.com", profile: profile, includePassword: true)
        XCTAssertEqual(results.first?.username, u)
        XCTAssertEqual(results.first?.password, p)
    }
}

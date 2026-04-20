//
//  PasswordProviderTests.swift
//  SocketTests
//
//  Unit tests for PasswordProviderID + CredentialSuggestion — the glue that
//  carries autofill suggestions between providers and across the JS bridge.
//

import XCTest
@testable import Socket

final class PasswordProviderTests: XCTestCase {

    // MARK: - PasswordProviderID

    func testRawValues_areStable() {
        // These strings are persisted in UserDefaults via
        // `settings.defaultPasswordDestination` and sent over the JS bridge
        // inside reply payloads. Renaming either will orphan user prefs.
        XCTAssertEqual(PasswordProviderID.keychain.rawValue, "keychain")
        XCTAssertEqual(PasswordProviderID.onePassword.rawValue, "1password")
    }

    func testRoundTripCodable() throws {
        for id in PasswordProviderID.allCases {
            let encoded = try JSONEncoder().encode(id)
            let decoded = try JSONDecoder().decode(PasswordProviderID.self, from: encoded)
            XCTAssertEqual(id, decoded)
        }
    }

    func testInitFromRawValue_handlesUnknown() {
        XCTAssertNil(PasswordProviderID(rawValue: "lastpass"))
        XCTAssertNil(PasswordProviderID(rawValue: ""))
    }

    func testDisplayName_isUserFacing() {
        XCTAssertEqual(PasswordProviderID.keychain.displayName, "Keychain")
        XCTAssertEqual(PasswordProviderID.onePassword.displayName, "1Password")
    }

    func testSymbolName_resolvesToSFSymbol() {
        // We don't verify SF Symbols exist (AppKit call), just that we return
        // a non-empty string for each case. Safer than a hardcoded list —
        // catches if someone returns "" by accident.
        for id in PasswordProviderID.allCases {
            XCTAssertFalse(id.symbolName.isEmpty, "\(id) returned empty symbolName")
        }
    }

    func testAllCases_coversExpectedProviders() {
        let expected: Set<PasswordProviderID> = [.keychain, .onePassword]
        XCTAssertEqual(Set(PasswordProviderID.allCases), expected)
    }

    func testIdentifiable_idEqualsRawValue() {
        for id in PasswordProviderID.allCases {
            XCTAssertEqual(id.id, id.rawValue)
        }
    }

    // MARK: - CredentialSuggestion

    func testAsScriptReply_keyShapeIsStable() {
        // This dict is sent to PasswordFormDetector.js via the reply channel.
        // Key renames = JS side breaks silently.
        let suggestion = CredentialSuggestion(
            provider: .keychain,
            ref: "ZGF0YQ==",
            host: "example.com",
            username: "alice"
        )
        let reply = suggestion.asScriptReply
        XCTAssertEqual(reply.keys.sorted(), ["host", "provider", "ref", "username"])
        XCTAssertEqual(reply["provider"] as? String, "keychain")
        XCTAssertEqual(reply["ref"] as? String, "ZGF0YQ==")
        XCTAssertEqual(reply["host"] as? String, "example.com")
        XCTAssertEqual(reply["username"] as? String, "alice")
    }

    func testAsScriptReply_onePasswordEncodesProviderRawValue() {
        // The JS reply uses the raw value ("1password"), NOT the display
        // name, so renaming displayName doesn't break the bridge.
        let suggestion = CredentialSuggestion(
            provider: .onePassword,
            ref: "abc123",
            host: "github.com",
            username: "octocat"
        )
        XCTAssertEqual(suggestion.asScriptReply["provider"] as? String, "1password")
    }

    func testHashable_sameFieldsAreEqual() {
        let a = CredentialSuggestion(provider: .keychain, ref: "r", host: "h", username: "u")
        let b = CredentialSuggestion(provider: .keychain, ref: "r", host: "h", username: "u")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)
    }

    func testHashable_differentProviderBreaksEquality() {
        // Useful when merging Keychain + 1Password suggestions for the same
        // host/username — they should NOT collapse into one.
        let keychain = CredentialSuggestion(provider: .keychain,
                                             ref: "r", host: "h", username: "u")
        let onepw = CredentialSuggestion(provider: .onePassword,
                                          ref: "r", host: "h", username: "u")
        XCTAssertNotEqual(keychain, onepw)
    }

    func testHashable_differentRefBreaksEquality() {
        // Two Keychain entries for the same host+username but different
        // persistent refs are distinct records.
        let a = CredentialSuggestion(provider: .keychain, ref: "r1", host: "h", username: "u")
        let b = CredentialSuggestion(provider: .keychain, ref: "r2", host: "h", username: "u")
        XCTAssertNotEqual(a, b)
    }

    func testCanBePutInSet() {
        let a = CredentialSuggestion(provider: .keychain, ref: "r", host: "h", username: "u")
        let b = CredentialSuggestion(provider: .keychain, ref: "r", host: "h", username: "u")
        let set: Set<CredentialSuggestion> = [a, b]
        XCTAssertEqual(set.count, 1, "Duplicates should collapse via Hashable")
    }
}

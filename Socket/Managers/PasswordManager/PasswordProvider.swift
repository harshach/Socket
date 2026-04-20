//
//  PasswordProvider.swift
//  Socket
//
//  Identifies where a saved credential lives. The PasswordManager routes
//  save + autofill requests based on `PasswordProviderID`.
//

import Foundation

enum PasswordProviderID: String, Codable, CaseIterable, Identifiable {
    case keychain
    case onePassword = "1password"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .keychain: return "Keychain"
        case .onePassword: return "1Password"
        }
    }

    var symbolName: String {
        switch self {
        case .keychain: return "key.horizontal"
        case .onePassword: return "lock.shield"
        }
    }
}

/// A single autofill suggestion surfaced in the popover. `ref` is opaque and
/// provider-specific: base64-encoded Keychain persistent ref for `.keychain`,
/// 1Password item UUID for `.onePassword`.
struct CredentialSuggestion: Hashable {
    let provider: PasswordProviderID
    let ref: String
    let host: String
    let username: String

    var asScriptReply: [String: Any] {
        [
            "provider": provider.rawValue,
            "ref": ref,
            "host": host,
            "username": username
        ]
    }
}

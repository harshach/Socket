//
//  IdentityShim.swift
//  Socket
//
//  chrome.identity shim. Apple's WKWebExtension exposes
//  `chrome.identity.launchWebAuthFlow` natively (backed by
//  ASWebAuthenticationSession), but does NOT expose
//  `chrome.identity.getAuthToken` (which in Chrome is a Google-OAuth-only
//  shortcut backed by Chrome's own client credentials).
//
//  Socket can't synthesize a Google OAuth flow without app-side OAuth
//  client config, so this shim fails fast with an actionable error
//  pointing callers at `launchWebAuthFlow` instead. The other identity
//  helpers (`getRedirectURL`, `removeCachedAuthToken`,
//  `clearAllCachedAuthTokens`, `getProfileUserInfo`, `getAccounts`) are
//  shimmed to non-hanging defaults so callers don't deadlock waiting on
//  unsupported APIs.
//

import Foundation
import os

@available(macOS 15.4, *)
@MainActor
final class IdentityShim: Shim {
    private static let logger = Logger(subsystem: "com.socket.browser", category: "IdentityShim")

    let namespaces: Set<String> = ["identity"]

    func handle(_ request: ShimRequest) async throws -> Any? {
        switch request.method {
        case "getAuthToken":
            // Apple's WKWebExtension exposes launchWebAuthFlow natively but
            // not getAuthToken. We can't replicate Chrome's getAuthToken
            // without our own Google OAuth client credentials, so we surface
            // a clear, actionable error. Extensions that detect the absence
            // typically fall back to launchWebAuthFlow on their own.
            throw ShimError.notSupported(
                "chrome.identity.getAuthToken is not implemented in Socket. " +
                "Use chrome.identity.launchWebAuthFlow with your own OAuth client instead."
            )

        case "removeCachedAuthToken", "clearAllCachedAuthTokens":
            // No cache yet — return success silently so callers don't hang.
            // Adding a Keychain-backed cache is straightforward when a real
            // consumer needs it.
            return nil

        case "getRedirectURL":
            // launchWebAuthFlow's standard redirect target. WKWebExtension
            // already returns this natively for callers that go through
            // chrome.identity.getRedirectURL, but we shim it for parity in
            // case the host implementation isn't reachable.
            guard let extId = request.extensionId else {
                throw ShimError.invalidArgument("getRedirectURL requires a registered extension")
            }
            let path = (request.args.first as? String) ?? ""
            // Chrome's URL shape: https://<32-char-id>.chromiumapp.org/<path>
            return "https://\(extId).chromiumapp.org/\(path)"

        case "getProfileUserInfo", "getAccounts":
            // Socket doesn't surface a signed-in user identity to extensions.
            // Return an empty info object — callers commonly check for an
            // empty `email` to detect signed-out state.
            return ["email": "", "id": ""]

        default:
            throw ShimError.unknownMethod(namespace: "identity", method: request.method)
        }
    }
}

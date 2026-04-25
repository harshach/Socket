//
//  SocketMessageHandlers.swift
//  Socket
//
//  Canonical registry of the `WKUserContentController` message-handler names
//  that Socket attaches to every tab's webview. Historically this list was
//  enumerated inline in 5+ sites (Tab.setupWebView add/remove,
//  Tab.unloadWebView, Tab.cleanupCloneWebView, WebViewCoordinator.createWebView,
//  WebViewCoordinator.performFallbackWebViewCleanup). Drift between those
//  copies is how the password handlers went missing from some teardown paths.
//

import Foundation
import WebKit

/// Canonical Socket webview message-handler registry.
///
/// `register` attaches all handlers for a given tab; `remove` tears them all
/// down. Callers don't need to know the specific names — update this file
/// when adding/removing a handler and every site stays in sync.
enum SocketMessageHandlers {
    /// Static handler names — same for every tab.
    static let staticNames: [String] = [
        "linkHover",
        "commandHover",
        "commandClick",
        "pipStateChange",
        "fullscreenStateChange",
        "historyStateDidChange",
        "SocketIdentity",
        "socketShortcutDetect",
        "passwordFormDetected",
        "passwordFormSubmitted",
    ]

    /// Name of the reply-style handler (WKScriptMessageHandlerWithReply).
    /// Registered separately because its API signature differs.
    static let replyHandlerName = "passwordAutofillRequest"

    /// Per-tab dynamic handler names (parameterised by tab id). Same tab id is
    /// used on both register and remove so they pair correctly.
    static func dynamicNames(for tabId: UUID) -> [String] {
        [
            "mediaStateChange_\(tabId.uuidString)",
            "backgroundColor_\(tabId.uuidString)",
        ]
    }

    /// Every name this module owns for a given tab — static + dynamic + reply.
    /// Useful for teardown paths that want to sweep everything.
    static func allNames(for tabId: UUID) -> [String] {
        staticNames + dynamicNames(for: tabId) + [replyHandlerName]
    }

    /// Register all Socket handlers on the webview's content controller.
    ///
    /// - `tab` is installed as the handler target for both normal and reply
    ///   message types. `Tab` conforms to `WKScriptMessageHandler` and
    ///   `WKScriptMessageHandlerWithReply`.
    @MainActor
    static func register(on webView: WKWebView, for tab: Tab) {
        let ucc = webView.configuration.userContentController
        for name in staticNames {
            ucc.add(tab, name: name)
        }
        for name in dynamicNames(for: tab.id) {
            ucc.add(tab, name: name)
        }
        ucc.addScriptMessageHandler(tab, contentWorld: .page, name: replyHandlerName)
    }

    /// Remove all Socket handlers from the webview's content controller.
    /// Idempotent — safe to call even if some handlers were never attached.
    @MainActor
    static func remove(from webView: WKWebView, tabId: UUID) {
        let ucc = webView.configuration.userContentController
        for name in allNames(for: tabId) {
            ucc.removeScriptMessageHandler(forName: name)
        }
    }
}

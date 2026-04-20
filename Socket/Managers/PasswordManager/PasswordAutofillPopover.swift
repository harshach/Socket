//
//  PasswordAutofillPopover.swift
//  Socket
//
//  NSPopover anchored to a WKWebView at a specific DOM rect, hosting a
//  SwiftUI list of credential suggestions. SwiftUI via NSHostingController;
//  AppKit handles positioning, dismiss-on-outside-click, and focus.
//

import AppKit
import SwiftUI
import WebKit

@MainActor
final class PasswordAutofillPopover {

    private var popover: NSPopover?
    private weak var anchoredWebView: WKWebView?

    func show(for webView: WKWebView,
              anchorRect: CGRect,
              suggestions: [CredentialSuggestion],
              onSelect: @escaping (CredentialSuggestion) -> Void,
              onManage: @escaping () -> Void) {
        dismiss()

        let host = NSHostingController(rootView: PasswordAutofillList(
            suggestions: suggestions,
            onSelect: { [weak self] chosen in
                onSelect(chosen)
                self?.dismiss()
            },
            onManage: { [weak self] in
                self?.dismiss()
                onManage()
            }
        ))
        host.view.layer?.backgroundColor = NSColor.clear.cgColor

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = host
        popover.contentSize = NSSize(width: 300,
                                     height: min(240, max(64, CGFloat(suggestions.count) * 48 + 44)))

        // Convert DOM client-space rect → webview-local NSRect. WKWebView uses
        // flipped coordinates (top-left origin) in its own coordinate system
        // for this purpose — getBoundingClientRect() already matches.
        let anchor = NSRect(
            x: anchorRect.origin.x,
            y: anchorRect.origin.y + anchorRect.size.height,
            width: max(1, anchorRect.size.width),
            height: 1
        )

        popover.show(relativeTo: anchor, of: webView, preferredEdge: .maxY)
        self.popover = popover
        self.anchoredWebView = webView
    }

    func dismiss() {
        popover?.performClose(nil)
        popover = nil
        anchoredWebView = nil
    }
}


//
//  ExtensionSidePanelView.swift
//  Socket
//
//  Right-side drawer that hosts a chrome.sidePanel extension page inside the
//  browser window. Mirrors the layout conventions of `AISidebar` (fixed
//  width column, leading-edge resize handle, transition animation) so the
//  two trailing-edge panels feel like the same family.
//

import AppKit
import SwiftUI
import WebKit
import os

@available(macOS 15.5, *)
struct ExtensionSidePanelView: View {
    @EnvironmentObject var browserManager: BrowserManager
    @Environment(BrowserWindowState.self) private var windowState

    /// Bound extension — captured when the panel opens, held for the
    /// lifetime of the host view so the webview stays stable even while the
    /// shim state evolves in the background.
    let extensionId: String
    let path: String

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ExtensionSidePanelWebViewHost(
                extensionManager: browserManager.extensionManager,
                extensionId: extensionId,
                path: path
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sidebar.right")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text(extensionDisplayName)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            Button {
                browserManager.closeSidePanel(in: windowState)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("Close side panel")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var extensionDisplayName: String {
        browserManager.extensionManager?
            .installedExtensions
            .first(where: { $0.id == extensionId })?.name
            ?? "Extension"
    }
}

// MARK: - WKWebView host

/// NSViewRepresentable that builds a WKWebView using the extension's
/// webViewConfiguration so the extension's `chrome.*` APIs are reachable.
/// Loads the configured path from the extension's `baseURL` at view init.
/// Guards against path traversal (same policy as the options-page loader).
@available(macOS 15.5, *)
private struct ExtensionSidePanelWebViewHost: NSViewRepresentable {
    let extensionManager: ExtensionManager?
    let extensionId: String
    let path: String

    func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: .zero)
        container.translatesAutoresizingMaskIntoConstraints = false

        guard let manager = extensionManager,
              let webView = manager.makeSidePanelWebView(for: extensionId, path: path)
        else {
            let label = NSTextField(labelWithString: "This extension does not expose a side panel page.")
            label.alignment = .center
            label.lineBreakMode = .byWordWrapping
            label.maximumNumberOfLines = 0
            label.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                label.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 16),
                label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16),
            ])
            return container
        }

        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        // Retain webView so it isn't deallocated when the representable is
        // re-diffed. NSView's subview ref-count keeps it alive.
        _ = webView
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // The host view is rebuilt on extensionId/path change; no live updates
        // are needed here. The extension-side panel page owns its own
        // navigation thereafter.
    }
}

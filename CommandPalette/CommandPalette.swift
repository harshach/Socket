//
//  CommandPalette.swift
//  Socket
//
//  Per-window command palette state and actions
//

import Foundation
import SwiftUI

enum CommandPalettePresentationMode: String, Codable {
    case newTab
    case replaceCurrentPage
    case splitRight
}

@MainActor
@Observable
class CommandPalette {
    /// Whether the command palette is visible
    var isVisible: Bool = false

    /// Text to prefill in the command palette
    var prefilledText: String = ""

    /// How the selected suggestion should be opened.
    var presentationMode: CommandPalettePresentationMode = .newTab

    /// Whether pressing Return should navigate the current tab (vs creating new tab).
    var shouldNavigateCurrentTab: Bool {
        presentationMode == .replaceCurrentPage
    }

    var shouldOpenInSplit: Bool {
        presentationMode == .splitRight
    }

    // MARK: - Actions

    /// Open the command palette with optional prefill text
    func open(
        prefill: String = "",
        mode: CommandPalettePresentationMode = .newTab
    ) {
        prefilledText = prefill
        presentationMode = mode
        DispatchQueue.main.async {
            self.isVisible = true
        }
    }

    func openReplacingCurrentPage(prefill: String = "") {
        open(
            prefill: prefill,
            mode: .replaceCurrentPage
        )
    }

    /// Open the command palette with the current tab's URL
    func openWithCurrentURL(_ url: URL) {
        openReplacingCurrentPage(prefill: url.absoluteString)
    }

    func openInSplit(prefill: String = "") {
        open(prefill: prefill, mode: .splitRight)
    }

    /// Close the command palette
    func close() {
        isVisible = false
        presentationMode = .newTab
        prefilledText = ""
    }

    /// Toggle the command palette visibility
    func toggle() {
        if isVisible {
            close()
        } else {
            open()
        }
    }
}

//
//  KeyboardShortcut.swift
//  Socket
//
//  Created by Jonathan Caudill on 09/30/2025.
//

import Foundation
import AppKit

// MARK: - Keyboard Shortcut Data Model
struct KeyboardShortcut: Identifiable, Hashable, Codable {
    let id: UUID
    let action: ShortcutAction
    var keyCombination: KeyCombination
    var isEnabled: Bool = true
    var isCustomizable: Bool = true

    init(action: ShortcutAction, keyCombination: KeyCombination, isEnabled: Bool = true, isCustomizable: Bool = true) {
        self.id = UUID()
        self.action = action
        self.keyCombination = keyCombination
        self.isEnabled = isEnabled
        self.isCustomizable = isCustomizable
    }

    /// Unique hash for O(1) lookup: "cmd+shift+t"
    var lookupKey: String {
        keyCombination.lookupKey
    }
}

// MARK: - Shortcut Actions
enum ShortcutAction: String, CaseIterable, Hashable, Codable {
    // Navigation
    case goBack = "go_back"
    case goForward = "go_forward"
    case refresh = "refresh"
    case clearCookiesAndRefresh = "clear_cookies_and_refresh"

    // Tab Management
    case newTab = "new_tab"
    case closeTab = "close_tab"
    case undoCloseTab = "undo_close_tab"
    case nextTab = "next_tab"
    case previousTab = "previous_tab"
    case goToTab1 = "go_to_tab_1"
    case goToTab2 = "go_to_tab_2"
    case goToTab3 = "go_to_tab_3"
    case goToTab4 = "go_to_tab_4"
    case goToTab5 = "go_to_tab_5"
    case goToTab6 = "go_to_tab_6"
    case goToTab7 = "go_to_tab_7"
    case goToTab8 = "go_to_tab_8"
    case goToLastTab = "go_to_last_tab"
    case duplicateTab = "duplicate_tab"
    case toggleTopBarAddressView = "toggle_top_bar_address_view"

    // Space Management
    case nextSpace = "next_space"
    case previousSpace = "previous_space"
    case goToWorkspace1 = "go_to_workspace_1"
    case goToWorkspace2 = "go_to_workspace_2"
    case goToWorkspace3 = "go_to_workspace_3"
    case goToWorkspace4 = "go_to_workspace_4"
    case goToWorkspace5 = "go_to_workspace_5"
    case goToWorkspace6 = "go_to_workspace_6"
    case goToWorkspace7 = "go_to_workspace_7"
    case goToWorkspace8 = "go_to_workspace_8"
    case goToWorkspace9 = "go_to_workspace_9"
    case createWorkspace = "create_workspace"
    case editCurrentWorkspace = "edit_current_workspace"
    case moveWorkspaceUp = "move_workspace_up"
    case moveWorkspaceDown = "move_workspace_down"
    case createPrivateWindow = "create_private_window"

    // Window Management
    case newWindow = "new_window"
    case closeWindow = "close_window"
    case closeBrowser = "close_browser"
    case toggleFullScreen = "toggle_full_screen"
    case toggleFocusMode = "toggle_focus_mode"
    case enterInsertMode = "enter_insert_mode"
    case focusOutOfWebContent = "focus_out_of_web_content"
    case focusSplitScreen = "focus_split_screen"
    case toggleSplitScreenFocus = "toggle_split_screen_focus"
    case toggleSplitMode = "toggle_split_mode"
    case sendCurrentPageToSplit = "send_current_page_to_split"
    case sendSplitPageToMain = "send_split_page_to_main"
    case closeSplitPage = "close_split_page"
    case refreshSplitPage = "refresh_split_page"

    // Tools & Features
    case openCommandPalette = "open_command_palette"
    case openCommandPaletteInSplit = "open_command_palette_in_split"
    case replaceCurrentPageWithPalette = "replace_current_page_with_palette"
    case openShortcutsCheatSheet = "open_shortcuts_cheat_sheet"
    case openDevTools = "open_dev_tools"
    case viewDownloads = "view_downloads"
    case viewHistory = "view_history"
    case expandAllFolders = "expand_all_folders"
    case openExtensionsPanel = "open_extensions_panel"
    case moveCurrentPageUp = "move_current_page_up"
    case moveCurrentPageDown = "move_current_page_down"

    // Missing actions that exist in SocketCommands but not here
    case focusAddressBar = "focus_address_bar"  // Cmd+L
    case findInPage = "find_in_page"            // Cmd+F
    case zoomIn = "zoom_in"                     // Cmd++
    case zoomOut = "zoom_out"                   // Cmd+-
    case actualSize = "actual_size"             // Cmd+0

    // NEW: Menu items in SocketCommands that were missing ShortcutAction definitions
    case toggleSidebar = "toggle_sidebar"                      // Cmd+S
    case toggleAIAssistant = "toggle_ai_assistant"             // Cmd+Shift+A
    case togglePictureInPicture = "toggle_pip"                 // Cmd+Shift+P
    case copyCurrentURL = "copy_current_url"                   // Cmd+Shift+C
    case hardReload = "hard_reload"                            // Cmd+Shift+R
    case muteUnmuteAudio = "mute_unmute_audio"                 // Cmd+M
    case installExtension = "install_extension"                // Cmd+Shift+E
    case customizeSpaceGradient = "customize_space_gradient"   // Cmd+Shift+G
    case createBoost = "create_boost"                          // Cmd+Shift+B

    var displayName: String {
        switch self {
        case .goBack: return "Go Back"
        case .goForward: return "Go Forward"
        case .refresh: return "Refresh"
        case .clearCookiesAndRefresh: return "Clear Cookies and Refresh"
        case .newTab: return "New Page"
        case .closeTab: return "Close Page"
        case .undoCloseTab: return "Undo Close Tab"
        case .nextTab: return "Next Page"
        case .previousTab: return "Previous Page"
        case .goToTab1: return "Go to Tab 1"
        case .goToTab2: return "Go to Tab 2"
        case .goToTab3: return "Go to Tab 3"
        case .goToTab4: return "Go to Tab 4"
        case .goToTab5: return "Go to Tab 5"
        case .goToTab6: return "Go to Tab 6"
        case .goToTab7: return "Go to Tab 7"
        case .goToTab8: return "Go to Tab 8"
        case .goToLastTab: return "Go to Last Tab"
        case .duplicateTab: return "Duplicate Tab"
        case .toggleTopBarAddressView: return "Toggle Top Bar Address View"
        case .nextSpace: return "Next Workspace"
        case .previousSpace: return "Previous Workspace"
        case .goToWorkspace1: return "Go to Workspace 1"
        case .goToWorkspace2: return "Go to Workspace 2"
        case .goToWorkspace3: return "Go to Workspace 3"
        case .goToWorkspace4: return "Go to Workspace 4"
        case .goToWorkspace5: return "Go to Workspace 5"
        case .goToWorkspace6: return "Go to Workspace 6"
        case .goToWorkspace7: return "Go to Workspace 7"
        case .goToWorkspace8: return "Go to Workspace 8"
        case .goToWorkspace9: return "Go to Workspace 9"
        case .createWorkspace: return "Create Workspace"
        case .editCurrentWorkspace: return "Edit Current Workspace"
        case .moveWorkspaceUp: return "Move Workspace Up"
        case .moveWorkspaceDown: return "Move Workspace Down"
        case .createPrivateWindow: return "New Private Window"
        case .newWindow: return "New Window"
        case .closeWindow: return "Close Window"
        case .closeBrowser: return "Close Browser"
        case .toggleFullScreen: return "Toggle Full Screen"
        case .toggleFocusMode: return "Toggle Focus Mode"
        case .enterInsertMode: return "Enter Insert Mode"
        case .focusOutOfWebContent: return "Focus Out of Web Content"
        case .focusSplitScreen: return "Focus Split Screen"
        case .toggleSplitScreenFocus: return "Toggle Split Focus"
        case .toggleSplitMode: return "Toggle Split Mode"
        case .sendCurrentPageToSplit: return "Send Current Page to Split"
        case .sendSplitPageToMain: return "Send Split Page to Main"
        case .closeSplitPage: return "Close Split Page"
        case .refreshSplitPage: return "Refresh Split Page"
        case .openCommandPalette: return "Open Command Palette"
        case .openCommandPaletteInSplit: return "Open Command Palette in Split"
        case .replaceCurrentPageWithPalette: return "Replace Current Page"
        case .openShortcutsCheatSheet: return "Open Shortcut Cheat Sheet"
        case .openDevTools: return "Developer Tools"
        case .viewDownloads: return "View Downloads"
        case .viewHistory: return "Search History"
        case .expandAllFolders: return "Expand All Folders"
        case .openExtensionsPanel: return "Open Extensions Panel"
        case .moveCurrentPageUp: return "Move Current Page Up"
        case .moveCurrentPageDown: return "Move Current Page Down"
        case .focusAddressBar: return "Focus Address Bar"
        case .findInPage: return "Find in Page"
        case .zoomIn: return "Zoom In"
        case .zoomOut: return "Zoom Out"
        case .actualSize: return "Actual Size"
        case .toggleSidebar: return "Toggle Sidebar"
        case .toggleAIAssistant: return "Toggle AI Assistant"
        case .togglePictureInPicture: return "Toggle Picture in Picture"
        case .copyCurrentURL: return "Copy Current URL"
        case .hardReload: return "Hard Reload"
        case .muteUnmuteAudio: return "Mute/Unmute Audio"
        case .installExtension: return "Install Extension"
        case .customizeSpaceGradient: return "Customize Space Gradient"
        case .createBoost: return "Create Boost"
        }
    }

    var category: ShortcutCategory {
        switch self {
        case .goBack, .goForward, .refresh, .clearCookiesAndRefresh:
            return .navigation
        case .newTab, .closeTab, .undoCloseTab, .nextTab, .previousTab, .goToTab1, .goToTab2, .goToTab3, .goToTab4, .goToTab5, .goToTab6, .goToTab7, .goToTab8, .goToLastTab, .duplicateTab, .toggleTopBarAddressView, .moveCurrentPageUp, .moveCurrentPageDown:
            return .tabs
        case .nextSpace, .previousSpace, .goToWorkspace1, .goToWorkspace2, .goToWorkspace3, .goToWorkspace4, .goToWorkspace5, .goToWorkspace6, .goToWorkspace7, .goToWorkspace8, .goToWorkspace9, .createWorkspace, .editCurrentWorkspace, .moveWorkspaceUp, .moveWorkspaceDown, .createPrivateWindow:
            return .spaces
        case .newWindow, .closeWindow, .closeBrowser, .toggleFullScreen, .toggleFocusMode, .enterInsertMode, .focusOutOfWebContent, .focusSplitScreen, .toggleSplitScreenFocus, .toggleSplitMode, .sendCurrentPageToSplit, .sendSplitPageToMain, .closeSplitPage, .refreshSplitPage:
            return .window
        case .openCommandPalette, .openCommandPaletteInSplit, .replaceCurrentPageWithPalette, .openShortcutsCheatSheet, .openDevTools, .viewDownloads, .viewHistory, .expandAllFolders, .openExtensionsPanel:
            return .tools
        case .focusAddressBar, .findInPage:
            return .navigation
        case .zoomIn, .zoomOut, .actualSize:
            return .tools
        case .toggleSidebar:
            return .window
        case .toggleAIAssistant:
            return .tools
        case .togglePictureInPicture:
            return .tools
        case .copyCurrentURL:
            return .tools
        case .hardReload:
            return .navigation
        case .muteUnmuteAudio:
            return .tools
        case .installExtension:
            return .tools
        case .customizeSpaceGradient:
            return .spaces
        case .createBoost:
            return .tools
        }
    }
}

// MARK: - Shortcut Categories
enum ShortcutCategory: String, CaseIterable, Hashable, Codable {
    case navigation = "navigation"
    case tabs = "tabs"
    case spaces = "spaces"
    case window = "window"
    case tools = "tools"

    var displayName: String {
        switch self {
        case .navigation: return "Navigation"
        case .tabs: return "Pages"
        case .spaces: return "Workspaces"
        case .window: return "Window"
        case .tools: return "Tools"
        }
    }

    var icon: String {
        switch self {
        case .navigation: return "arrow.left.arrow.right"
        case .tabs: return "doc.on.doc"
        case .spaces: return "rectangle.3.group"
        case .window: return "macwindow"
        case .tools: return "wrench.and.screwdriver"
        }
    }
}

// MARK: - Key Combination
struct KeyCombination: Hashable, Codable {
    let key: String
    let modifiers: Modifiers

    init(key: String, modifiers: Modifiers = []) {
        self.key = key.lowercased()
        self.modifiers = modifiers
    }

    var displayString: String {
        var parts = modifiers.displayStrings
        parts.append(prettyKeyDisplay(key))
        return parts.joined(separator: " + ")
    }

    // For matching with NSEvent
    func matches(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown || event.type == .keyUp else { return false }

        let keyWithoutModifiers = KeyCombination(from: event)?.key ?? ""
        let keyWithModifiers = event.characters?.lowercased() ?? ""

        // Match if either form matches (handles bracket keys on different layouts)
        let keyMatches = (keyWithoutModifiers == key) || (keyWithModifiers == key)

        let modifierMatches =
            (modifiers.contains(.command) == (event.modifierFlags.contains(.command))) &&
            (modifiers.contains(.option) == (event.modifierFlags.contains(.option))) &&
            (modifiers.contains(.control) == (event.modifierFlags.contains(.control))) &&
            (modifiers.contains(.shift) == (event.modifierFlags.contains(.shift)))

        return keyMatches && modifierMatches
    }

    /// Unique hash for O(1) lookup: "cmd+shift+t"
    var lookupKey: String {
        var parts: [String] = []
        if modifiers.contains(.command) { parts.append("cmd") }
        if modifiers.contains(.option) { parts.append("opt") }
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.shift) { parts.append("shift") }
        parts.append(key.lowercased())
        return parts.joined(separator: "+")
    }

    /// Initialize from NSEvent
    init?(from event: NSEvent) {
        let mappedKey: String?
        switch event.keyCode {
        case 36, 76: mappedKey = "return"
        case 48: mappedKey = "tab"
        case 49: mappedKey = "space"
        case 51: mappedKey = "delete"
        case 53: mappedKey = "escape"
        case 115: mappedKey = "home"
        case 116: mappedKey = "pageup"
        case 117: mappedKey = "forwarddelete"
        case 119: mappedKey = "end"
        case 121: mappedKey = "pagedown"
        case 123: mappedKey = "leftarrow"
        case 124: mappedKey = "rightarrow"
        case 125: mappedKey = "downarrow"
        case 126: mappedKey = "uparrow"
        default:
            // Use charactersIgnoringModifiers for consistent handling of printable keys.
            mappedKey = event.charactersIgnoringModifiers?.lowercased()
        }

        guard let key = mappedKey, !key.isEmpty else { return nil }

        var modifiers: Modifiers = []
        if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
        if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
        if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
        if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }

        self.key = key
        self.modifiers = modifiers
    }

    private func prettyKeyDisplay(_ key: String) -> String {
        switch key.lowercased() {
        case "leftarrow": return "←"
        case "rightarrow": return "→"
        case "uparrow": return "↑"
        case "downarrow": return "↓"
        case "escape": return "Esc"
        case "space": return "Space"
        case "tab": return "Tab"
        case "return": return "Return"
        case "delete": return "Delete"
        case "forwarddelete": return "Forward Delete"
        case "pageup": return "Page Up"
        case "pagedown": return "Page Down"
        default: return key.uppercased()
        }
    }
}

// MARK: - Modifiers
struct Modifiers: OptionSet, Hashable, Codable {
    let rawValue: Int

    static let command = Modifiers(rawValue: 1 << 0)
    static let option = Modifiers(rawValue: 1 << 1)
    static let control = Modifiers(rawValue: 1 << 2)
    static let shift = Modifiers(rawValue: 1 << 3)

    var displayStrings: [String] {
        var strings: [String] = []
        if contains(.command) { strings.append("⌘") }
        if contains(.option) { strings.append("⌥") }
        if contains(.control) { strings.append("⌃") }
        if contains(.shift) { strings.append("⇧") }
        return strings
    }
}

// MARK: - Default Shortcuts
extension KeyboardShortcut {
    static var defaultShortcuts: [KeyboardShortcut] {
        [
            // Navigation
            KeyboardShortcut(action: .goBack, keyCombination: KeyCombination(key: "[")),
            KeyboardShortcut(action: .goBack, keyCombination: KeyCombination(key: "[", modifiers: [.command])),
            KeyboardShortcut(action: .goForward, keyCombination: KeyCombination(key: "]")),
            KeyboardShortcut(action: .goForward, keyCombination: KeyCombination(key: "]", modifiers: [.command])),
            KeyboardShortcut(action: .refresh, keyCombination: KeyCombination(key: "r", modifiers: [.command])),
            KeyboardShortcut(action: .clearCookiesAndRefresh, keyCombination: KeyCombination(key: "r", modifiers: [.command, .shift, .option])),

            // Tab Management
            KeyboardShortcut(action: .newTab, keyCombination: KeyCombination(key: "t", modifiers: [.command])),
            KeyboardShortcut(action: .closeTab, keyCombination: KeyCombination(key: "w", modifiers: [.command])),
            KeyboardShortcut(action: .closeTab, keyCombination: KeyCombination(key: "d")),
            KeyboardShortcut(action: .undoCloseTab, keyCombination: KeyCombination(key: "z")),
            KeyboardShortcut(action: .undoCloseTab, keyCombination: KeyCombination(key: "z", modifiers: [.command])),
            KeyboardShortcut(action: .nextTab, keyCombination: KeyCombination(key: "tab", modifiers: [.control])),
            KeyboardShortcut(action: .nextTab, keyCombination: KeyCombination(key: "downarrow")),
            KeyboardShortcut(action: .nextTab, keyCombination: KeyCombination(key: "j")),
            KeyboardShortcut(action: .previousTab, keyCombination: KeyCombination(key: "tab", modifiers: [.control, .shift])),
            KeyboardShortcut(action: .previousTab, keyCombination: KeyCombination(key: "uparrow")),
            KeyboardShortcut(action: .previousTab, keyCombination: KeyCombination(key: "k")),
            KeyboardShortcut(action: .moveCurrentPageDown, keyCombination: KeyCombination(key: "j", modifiers: [.option])),
            KeyboardShortcut(action: .moveCurrentPageUp, keyCombination: KeyCombination(key: "k", modifiers: [.option])),
            KeyboardShortcut(action: .duplicateTab, keyCombination: KeyCombination(key: "d", modifiers: [.option])),
            KeyboardShortcut(action: .toggleTopBarAddressView, keyCombination: KeyCombination(key: "t", modifiers: [.command, .option])),

            // Space Management
            KeyboardShortcut(action: .createWorkspace, keyCombination: KeyCombination(key: "w")),
            KeyboardShortcut(action: .editCurrentWorkspace, keyCombination: KeyCombination(key: "w", modifiers: [.option])),
            KeyboardShortcut(action: .createPrivateWindow, keyCombination: KeyCombination(key: "w", modifiers: [.control])),
            KeyboardShortcut(action: .nextSpace, keyCombination: KeyCombination(key: "g")),
            KeyboardShortcut(action: .previousSpace, keyCombination: KeyCombination(key: "g", modifiers: [.shift])),
            KeyboardShortcut(action: .previousSpace, keyCombination: KeyCombination(key: "uparrow", modifiers: [.command])),
            KeyboardShortcut(action: .nextSpace, keyCombination: KeyCombination(key: "downarrow", modifiers: [.command])),
            KeyboardShortcut(action: .nextSpace, keyCombination: KeyCombination(key: "]", modifiers: [.command, .control])),
            KeyboardShortcut(action: .previousSpace, keyCombination: KeyCombination(key: "[", modifiers: [.command, .control])),
            KeyboardShortcut(action: .moveWorkspaceUp, keyCombination: KeyCombination(key: "uparrow", modifiers: [.command, .option])),
            KeyboardShortcut(action: .moveWorkspaceDown, keyCombination: KeyCombination(key: "downarrow", modifiers: [.command, .option])),
            KeyboardShortcut(action: .goToWorkspace1, keyCombination: KeyCombination(key: "1", modifiers: [.command])),
            KeyboardShortcut(action: .goToWorkspace2, keyCombination: KeyCombination(key: "2", modifiers: [.command])),
            KeyboardShortcut(action: .goToWorkspace3, keyCombination: KeyCombination(key: "3", modifiers: [.command])),
            KeyboardShortcut(action: .goToWorkspace4, keyCombination: KeyCombination(key: "4", modifiers: [.command])),
            KeyboardShortcut(action: .goToWorkspace5, keyCombination: KeyCombination(key: "5", modifiers: [.command])),
            KeyboardShortcut(action: .goToWorkspace6, keyCombination: KeyCombination(key: "6", modifiers: [.command])),
            KeyboardShortcut(action: .goToWorkspace7, keyCombination: KeyCombination(key: "7", modifiers: [.command])),
            KeyboardShortcut(action: .goToWorkspace8, keyCombination: KeyCombination(key: "8", modifiers: [.command])),
            KeyboardShortcut(action: .goToWorkspace9, keyCombination: KeyCombination(key: "9", modifiers: [.command])),

            // Window Management
            KeyboardShortcut(action: .newWindow, keyCombination: KeyCombination(key: "n", modifiers: [.command])),
            KeyboardShortcut(action: .closeWindow, keyCombination: KeyCombination(key: "w", modifiers: [.command, .shift])),
            KeyboardShortcut(action: .closeBrowser, keyCombination: KeyCombination(key: "q", modifiers: [.command])),
            KeyboardShortcut(action: .toggleFullScreen, keyCombination: KeyCombination(key: "f", modifiers: [.command, .control])),
            KeyboardShortcut(action: .toggleFocusMode, keyCombination: KeyCombination(key: "f")),
            KeyboardShortcut(action: .enterInsertMode, keyCombination: KeyCombination(key: "i")),
            KeyboardShortcut(action: .focusOutOfWebContent, keyCombination: KeyCombination(key: "escape", modifiers: [.command])),
            KeyboardShortcut(action: .focusSplitScreen, keyCombination: KeyCombination(key: "i", modifiers: [.shift])),
            KeyboardShortcut(action: .toggleSplitScreenFocus, keyCombination: KeyCombination(key: ";", modifiers: [.command])),
            KeyboardShortcut(action: .toggleSplitMode, keyCombination: KeyCombination(key: "rightarrow", modifiers: [.command])),
            KeyboardShortcut(action: .sendCurrentPageToSplit, keyCombination: KeyCombination(key: "rightarrow", modifiers: [.shift])),
            KeyboardShortcut(action: .sendSplitPageToMain, keyCombination: KeyCombination(key: "leftarrow", modifiers: [.shift])),
            KeyboardShortcut(action: .closeSplitPage, keyCombination: KeyCombination(key: "d", modifiers: [.shift])),
            KeyboardShortcut(action: .refreshSplitPage, keyCombination: KeyCombination(key: "r", modifiers: [.command, .shift])),

            // Tools & Features
            KeyboardShortcut(action: .openShortcutsCheatSheet, keyCombination: KeyCombination(key: "c")),
            KeyboardShortcut(action: .openCommandPalette, keyCombination: KeyCombination(key: "space")),
            KeyboardShortcut(action: .openCommandPalette, keyCombination: KeyCombination(key: "/")),
            KeyboardShortcut(action: .openCommandPaletteInSplit, keyCombination: KeyCombination(key: "space", modifiers: [.shift])),
            KeyboardShortcut(action: .replaceCurrentPageWithPalette, keyCombination: KeyCombination(key: "space", modifiers: [.option])),
            KeyboardShortcut(action: .openCommandPalette, keyCombination: KeyCombination(key: "k", modifiers: [.command])),
            KeyboardShortcut(action: .openCommandPalette, keyCombination: KeyCombination(key: "k", modifiers: [.control])),
            KeyboardShortcut(action: .openDevTools, keyCombination: KeyCombination(key: "i", modifiers: [.command, .option])),
            KeyboardShortcut(action: .viewDownloads, keyCombination: KeyCombination(key: "j", modifiers: [.command, .shift])),
            KeyboardShortcut(action: .viewHistory, keyCombination: KeyCombination(key: "y", modifiers: [.command])),
            KeyboardShortcut(action: .expandAllFolders, keyCombination: KeyCombination(key: "e", modifiers: [.command, .shift])),
            KeyboardShortcut(action: .openExtensionsPanel, keyCombination: KeyCombination(key: "e")),
            KeyboardShortcut(action: .openExtensionsPanel, keyCombination: KeyCombination(key: "e", modifiers: [.option])),

            // Missing shortcuts that exist in SocketCommands
            KeyboardShortcut(action: .focusAddressBar, keyCombination: KeyCombination(key: "l", modifiers: [.command])),
            KeyboardShortcut(action: .findInPage, keyCombination: KeyCombination(key: "f", modifiers: [.command])),
            KeyboardShortcut(action: .zoomIn, keyCombination: KeyCombination(key: "+", modifiers: [.command])),
            KeyboardShortcut(action: .zoomOut, keyCombination: KeyCombination(key: "-", modifiers: [.command])),
            KeyboardShortcut(action: .actualSize, keyCombination: KeyCombination(key: "0", modifiers: [.command])),

            // NEW: Menu shortcuts that were missing from ShortcutAction
            KeyboardShortcut(action: .toggleSidebar, keyCombination: KeyCombination(key: "leftarrow", modifiers: [.command])),
            KeyboardShortcut(action: .toggleAIAssistant, keyCombination: KeyCombination(key: "a", modifiers: [.command, .shift])),
            KeyboardShortcut(action: .togglePictureInPicture, keyCombination: KeyCombination(key: "o")),
            KeyboardShortcut(action: .copyCurrentURL, keyCombination: KeyCombination(key: "c", modifiers: [.command, .shift])),
            KeyboardShortcut(action: .hardReload, keyCombination: KeyCombination(key: "r", modifiers: [.command, .shift, .option])),
            KeyboardShortcut(action: .muteUnmuteAudio, keyCombination: KeyCombination(key: "m", modifiers: [.command])),
            KeyboardShortcut(action: .installExtension, keyCombination: KeyCombination(key: "e", modifiers: [.command, .shift])),
            KeyboardShortcut(action: .customizeSpaceGradient, keyCombination: KeyCombination(key: "g", modifiers: [.command, .shift])),
            KeyboardShortcut(action: .createBoost, keyCombination: KeyCombination(key: "b", modifiers: [.command, .shift]))
        ]
    }
}

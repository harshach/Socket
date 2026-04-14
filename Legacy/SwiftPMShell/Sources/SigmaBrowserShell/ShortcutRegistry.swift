import AppKit
import BrowserCore
import Foundation

enum ShortcutScope: String, CaseIterable, Codable {
    case global
    case commandMode
    case insertMode
}

struct ShortcutContext {
    var isInsertMode: Bool
}

enum ShortcutAction: String, CaseIterable, Codable {
    case showCheatSheet
    case showCommandLine
    case openLazySearch
    case openLazySearchSlash
    case openLazySearchCommandT
    case openLazySearchInSplit
    case replaceCurrentPage
    case searchHistory
    case openQuickSearchWorkspace
    case createWorkspace
    case editWorkspace
    case deleteWorkspace
    case selectPreviousWorkspace
    case selectNextWorkspace
    case selectWorkspace1
    case selectWorkspace2
    case selectWorkspace3
    case selectWorkspace4
    case selectWorkspace5
    case selectWorkspace6
    case selectWorkspace7
    case selectWorkspace8
    case selectWorkspace9
    case selectPreviousPage
    case selectNextPage
    case movePageUp
    case movePageDown
    case indentPage
    case outdentPage
    case closePage
    case togglePageDone
    case showMovePage
    case showSnoozePage
    case toggleFocusMode
    case enterInsertMode
    case exitInsertMode
    case focusOtherPane
    case goBack
    case goForward
    case toggleSplit
    case openFocusedPageInSplit
    case closeSplit
    case selectNextSplitPage
    case selectPreviousSplitPage
    case closeSplitPage
    case moveSplitPage
    case snoozeSplitPage
    case reloadSplitPage
    case showExtensions
    case openPinnedExtensions
    case showPasswords
    case openPasswordSettings
    case showReminders
    case createReminder
    case showDownloads
    case showSettings
    case showFeedback
}

struct ShortcutActionDefinition: Identifiable {
    let action: ShortcutAction
    let title: String
    let category: String
    let defaultBinding: String
    let scope: ShortcutScope

    var id: ShortcutAction { action }
}

@MainActor
protocol ShortcutActionHandling: AnyObject {
    func performShortcutAction(_ action: ShortcutAction)
}

struct KeyBindingDescriptor: Equatable {
    let rawValue: String
    let modifiers: NSEvent.ModifierFlags
    let key: Key

    enum Key: Equatable {
        case character(String)
        case keyCode(UInt16)
    }

    static func parse(_ rawValue: String) -> KeyBindingDescriptor? {
        let normalized = rawValue
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "⌘", with: "cmd+")
            .replacingOccurrences(of: "⌥", with: "option+")
            .replacingOccurrences(of: "⇧", with: "shift+")
            .replacingOccurrences(of: "⌃", with: "control+")

        let parts = normalized.split(separator: "+").map(String.init)
        guard !parts.isEmpty else {
            return nil
        }

        var modifiers: NSEvent.ModifierFlags = []
        var keyPart: String?

        for part in parts {
            switch part {
            case "cmd", "command":
                modifiers.insert(.command)
            case "shift":
                modifiers.insert(.shift)
            case "option", "alt":
                modifiers.insert(.option)
            case "control", "ctrl":
                modifiers.insert(.control)
            default:
                keyPart = part
            }
        }

        guard let keyPart else {
            return nil
        }

        let key: Key
        switch keyPart {
        case "space":
            key = .character(" ")
        case "slash", "/":
            key = .character("/")
        case "semicolon", ";":
            key = .character(";")
        case "comma", ",":
            key = .character(",")
        case "period", ".":
            key = .character(".")
        case "leftbracket", "[":
            key = .character("[")
        case "rightbracket", "]":
            key = .character("]")
        case "escape", "esc":
            key = .keyCode(53)
        case "up":
            key = .keyCode(126)
        case "down":
            key = .keyCode(125)
        case "left":
            key = .keyCode(123)
        case "right":
            key = .keyCode(124)
        default:
            guard keyPart.count == 1 else {
                return nil
            }
            key = .character(keyPart)
        }

        return KeyBindingDescriptor(rawValue: rawValue, modifiers: modifiers, key: key)
    }

    func matches(_ event: NSEvent) -> Bool {
        let eventModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard eventModifiers == modifiers else {
            return false
        }

        switch key {
        case .keyCode(let keyCode):
            return event.keyCode == keyCode
        case .character(let value):
            return event.charactersIgnoringModifiers?.lowercased() == value
        }
    }
}

@MainActor
final class ShortcutRegistry {
    private let shellStore: BrowserShellStore

    init(shellStore: BrowserShellStore) {
        self.shellStore = shellStore
    }

    func definitions() -> [ShortcutActionDefinition] {
        Self.definitionTable
    }

    func bindingString(for action: ShortcutAction) -> String {
        shellStore.settings.shortcutOverrides[action.rawValue]
            ?? Self.definitionTable.first(where: { $0.action == action })?.defaultBinding
            ?? ""
    }

    func parsedBinding(for action: ShortcutAction) -> KeyBindingDescriptor? {
        KeyBindingDescriptor.parse(bindingString(for: action))
    }

    func action(matching event: NSEvent, context: ShortcutContext) -> ShortcutAction? {
        for definition in Self.definitionTable {
            guard scope(definition.scope, matches: context),
                  let binding = parsedBinding(for: definition.action),
                  binding.matches(event) else {
                continue
            }
            return definition.action
        }
        return nil
    }

    func setOverride(_ binding: String?, for action: ShortcutAction) {
        shellStore.setShortcutOverride(actionID: action.rawValue, binding: binding)
    }

    func resetOverrides() {
        shellStore.replaceShortcutOverrides([:])
    }

    func exportOverrides(to url: URL) throws {
        let data = try JSONEncoder().encode(shellStore.settings.shortcutOverrides)
        try data.write(to: url, options: [.atomic])
    }

    func importOverrides(from url: URL) throws {
        let data = try Data(contentsOf: url)
        let overrides = try JSONDecoder().decode([String: String].self, from: data)
        shellStore.replaceShortcutOverrides(overrides)
    }

    private func scope(_ scope: ShortcutScope, matches context: ShortcutContext) -> Bool {
        switch scope {
        case .global:
            return true
        case .commandMode:
            return !context.isInsertMode
        case .insertMode:
            return context.isInsertMode
        }
    }

    private static let definitionTable: [ShortcutActionDefinition] = [
        .init(action: .showCheatSheet, title: "Shortcuts cheat sheet", category: "General", defaultBinding: "c", scope: .commandMode),
        .init(action: .showCommandLine, title: "Command line", category: "General", defaultBinding: "cmd+k", scope: .commandMode),
        .init(action: .showFeedback, title: "Share feedback", category: "General", defaultBinding: "control+/", scope: .commandMode),
        .init(action: .openLazySearch, title: "Lazy Search / new page", category: "Lazy Search", defaultBinding: "space", scope: .commandMode),
        .init(action: .openLazySearchSlash, title: "Lazy Search / new page (/)", category: "Lazy Search", defaultBinding: "slash", scope: .commandMode),
        .init(action: .openLazySearchCommandT, title: "Lazy Search / new page (Cmd+T)", category: "Lazy Search", defaultBinding: "cmd+t", scope: .commandMode),
        .init(action: .openLazySearchInSplit, title: "Open in split", category: "Lazy Search", defaultBinding: "shift+space", scope: .commandMode),
        .init(action: .replaceCurrentPage, title: "Replace current page", category: "Lazy Search", defaultBinding: "option+space", scope: .commandMode),
        .init(action: .searchHistory, title: "Search history", category: "Lazy Search", defaultBinding: "cmd+y", scope: .commandMode),
        .init(action: .openQuickSearchWorkspace, title: "Quick Search workspace", category: "Lazy Search", defaultBinding: "q", scope: .commandMode),
        .init(action: .createWorkspace, title: "Create workspace", category: "Workspaces", defaultBinding: "w", scope: .commandMode),
        .init(action: .editWorkspace, title: "Edit workspace", category: "Workspaces", defaultBinding: "option+w", scope: .commandMode),
        .init(action: .deleteWorkspace, title: "Delete workspace", category: "Workspaces", defaultBinding: "control+w", scope: .commandMode),
        .init(action: .selectPreviousWorkspace, title: "Previous workspace", category: "Workspaces", defaultBinding: "cmd+left", scope: .commandMode),
        .init(action: .selectNextWorkspace, title: "Next workspace", category: "Workspaces", defaultBinding: "option+cmd+down", scope: .commandMode),
        .init(action: .selectWorkspace1, title: "Go to workspace 1", category: "Workspaces", defaultBinding: "cmd+1", scope: .commandMode),
        .init(action: .selectWorkspace2, title: "Go to workspace 2", category: "Workspaces", defaultBinding: "cmd+2", scope: .commandMode),
        .init(action: .selectWorkspace3, title: "Go to workspace 3", category: "Workspaces", defaultBinding: "cmd+3", scope: .commandMode),
        .init(action: .selectWorkspace4, title: "Go to workspace 4", category: "Workspaces", defaultBinding: "cmd+4", scope: .commandMode),
        .init(action: .selectWorkspace5, title: "Go to workspace 5", category: "Workspaces", defaultBinding: "cmd+5", scope: .commandMode),
        .init(action: .selectWorkspace6, title: "Go to workspace 6", category: "Workspaces", defaultBinding: "cmd+6", scope: .commandMode),
        .init(action: .selectWorkspace7, title: "Go to workspace 7", category: "Workspaces", defaultBinding: "cmd+7", scope: .commandMode),
        .init(action: .selectWorkspace8, title: "Go to workspace 8", category: "Workspaces", defaultBinding: "cmd+8", scope: .commandMode),
        .init(action: .selectWorkspace9, title: "Go to workspace 9", category: "Workspaces", defaultBinding: "cmd+9", scope: .commandMode),
        .init(action: .selectPreviousPage, title: "Select previous page", category: "Navigation", defaultBinding: "k", scope: .commandMode),
        .init(action: .selectNextPage, title: "Select next page", category: "Navigation", defaultBinding: "j", scope: .commandMode),
        .init(action: .movePageUp, title: "Move page up", category: "Pages", defaultBinding: "option+k", scope: .commandMode),
        .init(action: .movePageDown, title: "Move page down", category: "Pages", defaultBinding: "option+j", scope: .commandMode),
        .init(action: .indentPage, title: "Indent page", category: "Pages", defaultBinding: "shift+period", scope: .commandMode),
        .init(action: .outdentPage, title: "Outdent page", category: "Pages", defaultBinding: "shift+comma", scope: .commandMode),
        .init(action: .closePage, title: "Mark page done / close", category: "Pages", defaultBinding: "d", scope: .commandMode),
        .init(action: .togglePageDone, title: "Toggle page done", category: "Pages", defaultBinding: "m", scope: .commandMode),
        .init(action: .showMovePage, title: "Move page", category: "Pages", defaultBinding: "h", scope: .commandMode),
        .init(action: .showSnoozePage, title: "Snooze page", category: "Pages", defaultBinding: "s", scope: .commandMode),
        .init(action: .toggleFocusMode, title: "Focus mode", category: "Pages", defaultBinding: "f", scope: .commandMode),
        .init(action: .enterInsertMode, title: "Enter insert mode", category: "Focus", defaultBinding: "i", scope: .commandMode),
        .init(action: .exitInsertMode, title: "Exit insert mode", category: "Focus", defaultBinding: "cmd+esc", scope: .insertMode),
        .init(action: .focusOtherPane, title: "Switch pane focus", category: "Focus", defaultBinding: "cmd+;", scope: .commandMode),
        .init(action: .goBack, title: "Go back", category: "Navigation", defaultBinding: "leftBracket", scope: .commandMode),
        .init(action: .goForward, title: "Go forward", category: "Navigation", defaultBinding: "rightBracket", scope: .commandMode),
        .init(action: .toggleSplit, title: "Toggle split", category: "Split", defaultBinding: "cmd+right", scope: .commandMode),
        .init(action: .openFocusedPageInSplit, title: "Open focused page in split", category: "Split", defaultBinding: "shift+right", scope: .commandMode),
        .init(action: .closeSplit, title: "Close split", category: "Split", defaultBinding: "shift+left", scope: .commandMode),
        .init(action: .selectPreviousSplitPage, title: "Previous split page", category: "Split", defaultBinding: "shift+k", scope: .commandMode),
        .init(action: .selectNextSplitPage, title: "Next split page", category: "Split", defaultBinding: "shift+j", scope: .commandMode),
        .init(action: .closeSplitPage, title: "Close split page", category: "Split", defaultBinding: "shift+d", scope: .commandMode),
        .init(action: .moveSplitPage, title: "Move split page", category: "Split", defaultBinding: "shift+m", scope: .commandMode),
        .init(action: .snoozeSplitPage, title: "Snooze split page", category: "Split", defaultBinding: "shift+h", scope: .commandMode),
        .init(action: .reloadSplitPage, title: "Reload split page", category: "Split", defaultBinding: "shift+cmd+r", scope: .commandMode),
        .init(action: .showExtensions, title: "Extensions panel", category: "Tools", defaultBinding: "e", scope: .commandMode),
        .init(action: .openPinnedExtensions, title: "Open pinned extensions", category: "Tools", defaultBinding: "option+e", scope: .commandMode),
        .init(action: .showPasswords, title: "Passwords", category: "Tools", defaultBinding: "p", scope: .commandMode),
        .init(action: .openPasswordSettings, title: "Password settings", category: "Tools", defaultBinding: "option+p", scope: .commandMode),
        .init(action: .showReminders, title: "Reminders", category: "Tools", defaultBinding: "r", scope: .commandMode),
        .init(action: .createReminder, title: "Create reminder", category: "Tools", defaultBinding: "option+r", scope: .commandMode),
        .init(action: .showDownloads, title: "Downloads", category: "Tools", defaultBinding: "cmd+shift+d", scope: .commandMode),
        .init(action: .showSettings, title: "Settings", category: "Tools", defaultBinding: "cmd+,", scope: .global),
    ]
}

//
//  ShortcutDispatchTests.swift
//  SocketTests
//
//  Branch coverage for `KeyboardShortcutManager.shouldHandleModifierlessShortcut(_:in:)`.
//  Every blocking gate (dialog visible, native input focused, extension UI
//  focused, insert mode, web editable focused) needs to actually block, and
//  modifier-bearing shortcuts must always pass even when the gate would
//  otherwise close. A regression here is what caused the user-reported
//  "shortcuts firing while typing in App Store Connect" bug.
//

import XCTest

@testable import Socket

@MainActor
final class ShortcutDispatchTests: XCTestCase {
    // MARK: - bare keys with all gates open → fire

    func test_bareKey_allGatesOpen_fires() {
        let combo = KeyCombination(key: "j")
        XCTAssertTrue(
            KeyboardShortcutManager.shouldHandleModifierlessShortcut(combo, in: .allShortcutsAllowed),
            "Bare j with everything clear is the canonical 'fire' case."
        )
    }

    // MARK: - modifier shortcuts always pass, even with gates closed

    func test_commandShortcut_passesEvenWithDialogVisible() {
        // Cmd+T must still open a new tab even if a dialog is on screen —
        // dialogs only own the bare Enter / Esc / single-key bindings.
        let combo = KeyCombination(key: "t", modifiers: [.command])
        let context = ShortcutDispatchContext(
            sigmaCommandModeEnabled: true,
            isDialogVisible: true,
            hasNativeTextInputFocus: true,
            hasExtensionUIFocus: true,
            isInsertModeEnabled: true,
            isEditableElementFocusedInWeb: true
        )
        XCTAssertTrue(
            KeyboardShortcutManager.shouldHandleModifierlessShortcut(combo, in: context),
            "Modifier-bearing shortcuts must short-circuit past the gate — they aren't single-key navigation."
        )
    }

    func test_optionShortcut_passesEvenWithGatesClosed() {
        let combo = KeyCombination(key: "left", modifiers: [.option])
        let context = ShortcutDispatchContext(
            sigmaCommandModeEnabled: false,
            isDialogVisible: true,
            hasNativeTextInputFocus: true,
            hasExtensionUIFocus: true,
            isInsertModeEnabled: true,
            isEditableElementFocusedInWeb: true
        )
        XCTAssertTrue(KeyboardShortcutManager.shouldHandleModifierlessShortcut(combo, in: context))
    }

    func test_controlShortcut_passesEvenWithGatesClosed() {
        let combo = KeyCombination(key: "tab", modifiers: [.control])
        let context = ShortcutDispatchContext.allShortcutsAllowed
        XCTAssertTrue(KeyboardShortcutManager.shouldHandleModifierlessShortcut(combo, in: context))
    }

    // MARK: - shift-only is treated like bare (still gateable)

    func test_shiftOnly_isGated() {
        // Shift+J (e.g. typing capital J in an input) must NOT fire any
        // shortcut bound to Shift+J when an input is focused.
        let combo = KeyCombination(key: "j", modifiers: [.shift])
        var context = ShortcutDispatchContext.allShortcutsAllowed
        context = ShortcutDispatchContext(
            sigmaCommandModeEnabled: true,
            isDialogVisible: false,
            hasNativeTextInputFocus: false,
            hasExtensionUIFocus: false,
            isInsertModeEnabled: false,
            isEditableElementFocusedInWeb: true
        )
        XCTAssertFalse(
            KeyboardShortcutManager.shouldHandleModifierlessShortcut(combo, in: context),
            "Shift-only shortcuts must obey the typing-in-web-input gate; otherwise capital letters fire navigation."
        )
    }

    // MARK: - individual gates

    func test_blocked_whenSigmaCommandModeDisabled() {
        let combo = KeyCombination(key: "j")
        var context = ShortcutDispatchContext.allShortcutsAllowed
        context = ShortcutDispatchContext(
            sigmaCommandModeEnabled: false,
            isDialogVisible: context.isDialogVisible,
            hasNativeTextInputFocus: context.hasNativeTextInputFocus,
            hasExtensionUIFocus: context.hasExtensionUIFocus,
            isInsertModeEnabled: context.isInsertModeEnabled,
            isEditableElementFocusedInWeb: context.isEditableElementFocusedInWeb
        )
        XCTAssertFalse(
            KeyboardShortcutManager.shouldHandleModifierlessShortcut(combo, in: context),
            "User toggled Sigma off → no single-key shortcuts at all."
        )
    }

    func test_blocked_whenDialogVisible() {
        let combo = KeyCombination(key: "j")
        var context = ShortcutDispatchContext.allShortcutsAllowed
        context = ShortcutDispatchContext(
            sigmaCommandModeEnabled: context.sigmaCommandModeEnabled,
            isDialogVisible: true,
            hasNativeTextInputFocus: context.hasNativeTextInputFocus,
            hasExtensionUIFocus: context.hasExtensionUIFocus,
            isInsertModeEnabled: context.isInsertModeEnabled,
            isEditableElementFocusedInWeb: context.isEditableElementFocusedInWeb
        )
        XCTAssertFalse(KeyboardShortcutManager.shouldHandleModifierlessShortcut(combo, in: context))
    }

    func test_blocked_whenNativeInputFocused() {
        // The URL bar / find bar / settings text field case.
        let combo = KeyCombination(key: "j")
        var context = ShortcutDispatchContext.allShortcutsAllowed
        context = ShortcutDispatchContext(
            sigmaCommandModeEnabled: context.sigmaCommandModeEnabled,
            isDialogVisible: context.isDialogVisible,
            hasNativeTextInputFocus: true,
            hasExtensionUIFocus: context.hasExtensionUIFocus,
            isInsertModeEnabled: context.isInsertModeEnabled,
            isEditableElementFocusedInWeb: context.isEditableElementFocusedInWeb
        )
        XCTAssertFalse(KeyboardShortcutManager.shouldHandleModifierlessShortcut(combo, in: context))
    }

    func test_blocked_whenExtensionUIFocused() {
        let combo = KeyCombination(key: "/")
        var context = ShortcutDispatchContext.allShortcutsAllowed
        context = ShortcutDispatchContext(
            sigmaCommandModeEnabled: context.sigmaCommandModeEnabled,
            isDialogVisible: context.isDialogVisible,
            hasNativeTextInputFocus: context.hasNativeTextInputFocus,
            hasExtensionUIFocus: true,
            isInsertModeEnabled: context.isInsertModeEnabled,
            isEditableElementFocusedInWeb: context.isEditableElementFocusedInWeb
        )
        XCTAssertFalse(KeyboardShortcutManager.shouldHandleModifierlessShortcut(combo, in: context))
    }

    func test_blocked_whenInsertModeEnabled() {
        let combo = KeyCombination(key: "j")
        var context = ShortcutDispatchContext.allShortcutsAllowed
        context = ShortcutDispatchContext(
            sigmaCommandModeEnabled: context.sigmaCommandModeEnabled,
            isDialogVisible: context.isDialogVisible,
            hasNativeTextInputFocus: context.hasNativeTextInputFocus,
            hasExtensionUIFocus: context.hasExtensionUIFocus,
            isInsertModeEnabled: true,
            isEditableElementFocusedInWeb: context.isEditableElementFocusedInWeb
        )
        XCTAssertFalse(
            KeyboardShortcutManager.shouldHandleModifierlessShortcut(combo, in: context),
            "Vim-style Insert Mode (entered via I) must suppress navigation keys."
        )
    }

    func test_blocked_whenWebEditableFocused() {
        // The App Store Connect / Google search box case — typing in a
        // page input must never fire single-key shortcuts.
        let combo = KeyCombination(key: "h")
        var context = ShortcutDispatchContext.allShortcutsAllowed
        context = ShortcutDispatchContext(
            sigmaCommandModeEnabled: context.sigmaCommandModeEnabled,
            isDialogVisible: context.isDialogVisible,
            hasNativeTextInputFocus: context.hasNativeTextInputFocus,
            hasExtensionUIFocus: context.hasExtensionUIFocus,
            isInsertModeEnabled: context.isInsertModeEnabled,
            isEditableElementFocusedInWeb: true
        )
        XCTAssertFalse(
            KeyboardShortcutManager.shouldHandleModifierlessShortcut(combo, in: context),
            "Pressing 'h' in a focused web input must NOT trigger History navigation. This is the original user-reported bug."
        )
    }
}

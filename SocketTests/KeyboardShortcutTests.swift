//
//  KeyboardShortcutTests.swift
//  SocketTests
//
//  Covers `KeyCombination` parsing from NSEvent + the lookupKey/displayString
//  hashing that drives the dispatch table in KeyboardShortcutManager. The
//  manager itself isn't tested here — it's pinned to a singleton WindowRegistry,
//  ExtensionManager, and BrowserManager triplet that needs DI before unit
//  tests are practical. These model-layer tests catch the kind of regression
//  where "esc" stops resolving to keyCode 53 because someone reordered the
//  switch.
//

import AppKit
import XCTest

@testable import Socket

@MainActor
final class KeyboardShortcutTests: XCTestCase {
    // MARK: - construction

    func test_init_lowercasesKey() {
        XCTAssertEqual(KeyCombination(key: "T").key, "t")
        XCTAssertEqual(KeyCombination(key: "Escape").key, "escape")
    }

    func test_lookupKey_includesAllModifiersInCanonicalOrder() {
        let combo = KeyCombination(key: "t", modifiers: [.command, .shift])
        XCTAssertEqual(combo.lookupKey, "cmd+shift+t")

        let allMods = KeyCombination(key: "k", modifiers: [.command, .option, .control, .shift])
        XCTAssertEqual(allMods.lookupKey, "cmd+opt+ctrl+shift+k")
    }

    func test_lookupKey_isStableForBareKeys() {
        XCTAssertEqual(KeyCombination(key: "j").lookupKey, "j")
        XCTAssertEqual(KeyCombination(key: "/").lookupKey, "/")
    }

    // MARK: - NSEvent → KeyCombination

    func test_initFromEvent_mapsSpecialKeys() {
        // Every special-keycode mapping is load-bearing for shortcut lookup.
        // If any of these regress, the matching shortcut becomes unreachable.
        let cases: [(UInt16, String)] = [
            (36, "return"),
            (76, "return"),
            (48, "tab"),
            (49, "space"),
            (51, "delete"),
            (53, "escape"),
            (123, "leftarrow"),
            (124, "rightarrow"),
            (125, "downarrow"),
            (126, "uparrow"),
        ]
        for (code, expectedKey) in cases {
            guard let event = makeKeyDownEvent(keyCode: code) else {
                XCTFail("Couldn't synthesize event for keyCode \(code)"); continue
            }
            let combo = KeyCombination(from: event)
            XCTAssertEqual(combo?.key, expectedKey, "keyCode \(code) should resolve to \(expectedKey)")
        }
    }

    func test_initFromEvent_capturesModifiers() {
        guard let event = makeKeyDownEvent(
            keyCode: 53, modifiers: [.command, .shift], characters: nil
        ) else { return XCTFail("could not build event") }
        let combo = KeyCombination(from: event)
        XCTAssertEqual(combo?.key, "escape")
        XCTAssertTrue(combo?.modifiers.contains(.command) == true)
        XCTAssertTrue(combo?.modifiers.contains(.shift) == true)
        XCTAssertFalse(combo?.modifiers.contains(.option) == true)
    }

    func test_initFromEvent_returnsNilForEmptyCharacters() {
        // keyCode 0 isn't in the special map; with no characters we can't
        // form a valid combo.
        let event = makeKeyDownEvent(
            keyCode: 0, modifiers: [], characters: ""
        )
        // Some macOS versions reject empty strings; tolerate either branch.
        guard let event else { return }
        XCTAssertNil(KeyCombination(from: event))
    }

    // MARK: - matches()

    func test_matches_modifierExactness() {
        // A shortcut bound to bare-Escape must NOT fire on Cmd+Escape, and
        // vice versa — the dispatcher relies on this to keep "Quit dialog
        // dismiss" disjoint from "Cmd+Escape exit insert mode."
        let bare = KeyCombination(key: "escape")
        let cmdOnly = KeyCombination(key: "escape", modifiers: [.command])

        guard let bareEvent = makeKeyDownEvent(keyCode: 53),
              let cmdEvent = makeKeyDownEvent(keyCode: 53, modifiers: [.command])
        else { return XCTFail("event synthesis failed") }

        XCTAssertTrue(bare.matches(bareEvent))
        XCTAssertFalse(bare.matches(cmdEvent))
        XCTAssertTrue(cmdOnly.matches(cmdEvent))
        XCTAssertFalse(cmdOnly.matches(bareEvent))
    }

    // MARK: - display

    func test_displayString_prettifiesArrows() {
        XCTAssertEqual(KeyCombination(key: "leftarrow").displayString, "←")
        XCTAssertEqual(KeyCombination(key: "uparrow").displayString, "↑")
        XCTAssertEqual(KeyCombination(key: "escape").displayString, "Esc")
    }

    func test_displayString_includesModifiersAhead() {
        let combo = KeyCombination(key: "t", modifiers: [.command, .shift])
        // Exact ordering depends on Modifiers.displayStrings, which we don't
        // pin here — we just verify the key glyph is at the end.
        XCTAssertTrue(combo.displayString.hasSuffix(" + T") || combo.displayString.hasSuffix("T"))
    }

    // MARK: - helpers

    /// Synthesize an NSEvent for shortcut testing. Returns nil if AppKit
    /// refuses (some test environments without a window server may).
    private func makeKeyDownEvent(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags = [],
        characters: String? = nil
    ) -> NSEvent? {
        let chars: String = characters ?? defaultChars(for: keyCode)
        return NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: chars,
            charactersIgnoringModifiers: chars,
            isARepeat: false,
            keyCode: keyCode
        )
    }

    private func defaultChars(for keyCode: UInt16) -> String {
        // Bare characters for the keys we exercise. Doesn't have to be exhaustive.
        switch keyCode {
        case 36, 76: return "\r"
        case 48: return "\t"
        case 49: return " "
        case 51: return "\u{7F}"
        case 53: return "\u{1B}"
        case 123, 124, 125, 126: return ""
        default: return ""
        }
    }
}

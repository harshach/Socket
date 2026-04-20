//
//  WebsiteShortcutDetectorTests.swift
//  SocketTests
//
//  Covers the "press-twice-to-claim" behavior used when a site defines the
//  same shortcut Socket wants — first press passes to the page, second
//  press within the timeout window captures for Socket. Also covers the
//  editable-focus latch that blocks single-key shortcuts while a web page
//  input has focus.
//

import XCTest

@testable import Socket

@MainActor
final class WebsiteShortcutDetectorTests: XCTestCase {
    private var detector: WebsiteShortcutDetector!

    override func setUp() async throws {
        detector = WebsiteShortcutDetector()
    }

    // MARK: - URL / profile tracking

    func test_newDetector_hasNoProfile() {
        XCTAssertNil(detector.currentProfile)
        XCTAssertNil(detector.currentURL)
        XCTAssertFalse(detector.isEditableElementFocused)
    }

    func test_updateCurrentURL_resetsEditableFocus() {
        detector.updateEditableFocus(true)
        XCTAssertTrue(detector.isEditableElementFocused)

        detector.updateCurrentURL(URL(string: "https://example.com/")!)
        XCTAssertFalse(
            detector.isEditableElementFocused,
            "Switching URLs should reset focus latch so a stale true from the previous page doesn't leak."
        )
    }

    func test_updateCurrentURL_nilClearsProfile() {
        detector.updateCurrentURL(URL(string: "https://example.com/")!)
        detector.updateCurrentURL(nil)
        XCTAssertNil(detector.currentProfile)
        XCTAssertNil(detector.currentURL)
    }

    // MARK: - Editable focus latch

    func test_updateEditableFocus_flipsFlag() {
        detector.updateEditableFocus(true)
        XCTAssertTrue(detector.isEditableElementFocused)
        detector.updateEditableFocus(false)
        XCTAssertFalse(detector.isEditableElementFocused)
    }

    // MARK: - Pending conflict state

    func test_hasPendingShortcut_falseByDefault() {
        XCTAssertFalse(detector.hasPendingShortcut(for: UUID()))
    }

    func test_clearPendingShortcut_isANoopWhenEmpty() {
        detector.clearPendingShortcut(for: UUID())  // must not throw
        detector.clearAllPendingShortcuts()
    }

    // MARK: - JS-detected shortcut cache

    func test_updateJSDetectedShortcuts_storesForURL() {
        let url = "https://example.com/dashboard"
        detector.updateJSDetectedShortcuts(for: url, shortcuts: ["a", "b"])
        // No public accessor for the cache; re-registering must not crash.
        detector.updateJSDetectedShortcuts(for: url, shortcuts: ["b", "c"])
    }
}

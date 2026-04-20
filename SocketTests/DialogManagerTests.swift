//
//  DialogManagerTests.swift
//  SocketTests
//
//  Covers the keyboard dispatch regression we just fixed: Enter → primary
//  action, Escape → cancel action (falling back to `closeDialog` when the
//  caller didn't set one). Without these guarantees, bare Enter/Escape
//  bleed through to a focused WKWebView input and the dialog never hears
//  them.
//

import SwiftUI
import XCTest

@testable import Socket

@MainActor
final class DialogManagerTests: XCTestCase {
    private var manager: DialogManager!

    override func setUp() async throws {
        manager = DialogManager()
    }

    // MARK: - showDialog / closeDialog lifecycle

    func test_newManager_isNotVisible() {
        XCTAssertFalse(manager.isVisible)
        XCTAssertNil(manager.activeDialog)
        XCTAssertNil(manager.primaryAction)
        XCTAssertNil(manager.cancelAction)
    }

    func test_showDialog_setsVisibleAndStoresContent() {
        manager.showDialog(Text("Hello"))
        XCTAssertTrue(manager.isVisible)
        XCTAssertNotNil(manager.activeDialog)
    }

    func test_closeDialog_clearsActionsImmediately() {
        var fired = false
        manager.showDialog(
            Text("Dialog"),
            primaryAction: { fired = true },
            cancelAction: { fired = true }
        )
        XCTAssertTrue(manager.isVisible)
        XCTAssertNotNil(manager.primaryAction)
        XCTAssertNotNil(manager.cancelAction)

        manager.closeDialog()

        XCTAssertFalse(manager.isVisible)
        // Actions should be nil immediately so a late keydown can't invoke
        // the stale callback of a just-closed dialog.
        XCTAssertNil(manager.primaryAction)
        XCTAssertNil(manager.cancelAction)
        XCTAssertFalse(fired)
    }

    // MARK: - showDialog routing wires actions that the KSM invokes

    func test_primaryAction_isInvokedWhenCalled() {
        let exp = expectation(description: "primary called")
        manager.showDialog(
            Text("Quit?"),
            primaryAction: { exp.fulfill() },
            cancelAction: nil
        )
        manager.primaryAction?()
        wait(for: [exp], timeout: 0.1)
    }

    func test_cancelAction_isInvokedWhenCalled() {
        let exp = expectation(description: "cancel called")
        manager.showDialog(
            Text("Quit?"),
            primaryAction: nil,
            cancelAction: { exp.fulfill() }
        )
        manager.cancelAction?()
        wait(for: [exp], timeout: 0.1)
    }

    // MARK: - showQuitDialog — specific failure mode from the bug report

    func test_showQuitDialog_wiresPrimaryToOnQuit() {
        let exp = expectation(description: "onQuit invoked")
        manager.showQuitDialog(
            onAlwaysQuit: { XCTFail("onAlwaysQuit should not fire from primary") },
            onQuit: { exp.fulfill() }
        )
        XCTAssertTrue(manager.isVisible)
        XCTAssertNotNil(manager.primaryAction, "Quit dialog must expose primaryAction so Enter confirms it")
        manager.primaryAction?()
        wait(for: [exp], timeout: 0.1)
    }

    func test_showQuitDialog_escapeClosesTheDialog() {
        manager.showQuitDialog(onAlwaysQuit: {}, onQuit: { XCTFail("Escape must not quit") })
        XCTAssertTrue(manager.isVisible)

        XCTAssertNotNil(manager.cancelAction, "Quit dialog must expose cancelAction so Escape dismisses it")
        manager.cancelAction?()

        // closeDialog flips `isVisible` synchronously.
        XCTAssertFalse(manager.isVisible)
    }
}

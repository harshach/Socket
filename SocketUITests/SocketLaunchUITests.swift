//
//  SocketLaunchUITests.swift
//  SocketUITests
//
//  XCUITest scaffold. UI tests live in their own target so they can launch
//  the app out-of-process without dragging XCUITest's heavy state into the
//  fast unit-test suite. A single end-to-end happy path lives here as a
//  smoke check; deeper UI flows belong in dedicated files (sidebar, tabs,
//  command palette, …) following this same structure.
//

import XCTest

final class SocketLaunchUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// Smoke test — confirms the app launches without crashing and exposes
    /// a `Socket`-named application object. If this fails the whole UI test
    /// target is broken, so most other UI tests will be cascading noise.
    func test_app_launches() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 10),
            "Socket should reach foreground within 10 seconds of launch."
        )
    }
}

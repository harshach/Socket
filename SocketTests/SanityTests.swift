//
//  SanityTests.swift
//  SocketTests
//
//  Smoke test: proves the SocketTests target builds, loads into the Socket
//  app bundle, and can access `@testable` internals of the app module. If
//  this fails, nothing else in this target will run — treat any failure
//  here as a test-infrastructure problem, not a product bug.
//

import XCTest

@testable import Socket

final class SanityTests: XCTestCase {
    func test_targetIsAlive() {
        XCTAssertTrue(true, "If this isn't green, the test target isn't loading at all.")
    }

    func test_canReferenceAppInternals() {
        // UpdateChannel lives in App/AppDelegate.swift at app-internal scope.
        // Failing to resolve it means @testable import isn't wired up right.
        XCTAssertEqual(UpdateChannel.stable.rawValue, "stable")
        XCTAssertEqual(UpdateChannel.nightly.rawValue, "nightly")
    }
}

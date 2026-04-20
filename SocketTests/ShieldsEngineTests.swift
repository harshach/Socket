//
//  ShieldsEngineTests.swift
//  SocketTests
//
//  Covers the Swift-side decoder for the Rust shields_compiler FFI output.
//  We don't invoke the Rust library here (integration tests can do that);
//  we just assert the JSON contract — version skew between Swift and Rust
//  has bitten us before.
//

import XCTest

@testable import Socket

final class ShieldsEngineTests: XCTestCase {
    // MARK: - Happy path

    func test_decode_newFormat_withNotifyRules() throws {
        let json = """
        {
          "rulesJSON": "[]",
          "notifyRulesJSON": "[]",
          "totalRuleCount": 1234,
          "networkRuleCount": 1200,
          "cosmeticRuleCount": 34
        }
        """.data(using: .utf8)!

        let output = try JSONDecoder().decode(ShieldsEngineOutput.self, from: json)
        XCTAssertEqual(output.totalRuleCount, 1234)
        XCTAssertEqual(output.networkRuleCount, 1200)
        XCTAssertEqual(output.cosmeticRuleCount, 34)
        XCTAssertEqual(output.rulesJSON, "[]")
        XCTAssertEqual(output.notifyRulesJSON, "[]")
    }

    func test_decode_legacyFormat_withoutNotifyRules() throws {
        // Older Rust binaries predate the notify-mirror feature. Keep the
        // field optional so we don't break on in-place downgrades.
        let json = """
        {
          "rulesJSON": "[]",
          "totalRuleCount": 1,
          "networkRuleCount": 1,
          "cosmeticRuleCount": 0
        }
        """.data(using: .utf8)!

        let output = try JSONDecoder().decode(ShieldsEngineOutput.self, from: json)
        XCTAssertNil(output.notifyRulesJSON)
        XCTAssertEqual(output.totalRuleCount, 1)
    }

    // MARK: - Error surface

    func test_decode_rejectsMissingRequiredField() {
        let json = """
        {
          "rulesJSON": "[]"
        }
        """.data(using: .utf8)!

        XCTAssertThrowsError(
            try JSONDecoder().decode(ShieldsEngineOutput.self, from: json),
            "Decoder must refuse output that's missing the rule counts — skipping the check would hide a breaking change in the Rust side."
        )
    }

    func test_ShieldsEngineError_descriptions() {
        XCTAssertTrue(ShieldsEngineError.invalidInputEncoding.description.contains("UTF-8"))
        XCTAssertTrue(ShieldsEngineError.invalidOutputEncoding.description.contains("UTF-8"))
        XCTAssertTrue(ShieldsEngineError.rustSideError("boom").description.contains("boom"))
    }
}

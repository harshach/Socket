//
//  ExtensionUtilsTests.swift
//  SocketTests
//
//  Covers manifest validation + hostname sanitization. These are the
//  pre-flight checks that decide whether a Chrome-style .zip / .appex /
//  .app bundle ever makes it to WKWebExtensionController. Bugs here are
//  silent: a malformed manifest gets handed to WebKit and fails with a
//  cryptic error far downstream.
//
//  We don't test the private patcher methods (`patchManifestForWebKit`,
//  `patchServiceWorkerForCompat`) here — they're `private` on
//  ExtensionManager. Promoting them to `internal` to test directly is a
//  small follow-up worth doing once we find a real regression.
//

import XCTest

@testable import Socket

@MainActor
final class ExtensionUtilsTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = URL(
            fileURLWithPath: NSTemporaryDirectory(),
            isDirectory: true
        ).appendingPathComponent("extutil-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - validateManifest happy path

    func test_validateManifest_acceptsMinimalMV3() throws {
        let url = try writeManifest([
            "manifest_version": 3,
            "name": "Test Extension",
            "version": "1.0.0",
        ])
        let parsed = try ExtensionUtils.validateManifest(at: url)
        XCTAssertEqual(parsed["name"] as? String, "Test Extension")
        XCTAssertEqual(parsed["version"] as? String, "1.0.0")
    }

    func test_validateManifest_acceptsMV2() throws {
        // We accept both 2 and 3 — Chrome Web Store still has a long tail of
        // MV2 extensions and WKWebExtension supports them.
        let url = try writeManifest([
            "manifest_version": 2,
            "name": "Legacy",
            "version": "0.1",
        ])
        XCTAssertNoThrow(try ExtensionUtils.validateManifest(at: url))
    }

    // MARK: - validateManifest error surface

    func test_validateManifest_rejectsMissingFile() {
        let missing = tempDir.appendingPathComponent("nope.json")
        XCTAssertThrowsError(try ExtensionUtils.validateManifest(at: missing)) { err in
            XCTAssertTrue(
                "\(err)".contains("missing"),
                "Error should make it obvious that manifest.json wasn't where we expected."
            )
        }
    }

    func test_validateManifest_rejectsMalformedJSON() throws {
        let url = tempDir.appendingPathComponent("manifest.json")
        try Data("{ this is not json".utf8).write(to: url)
        XCTAssertThrowsError(try ExtensionUtils.validateManifest(at: url))
    }

    func test_validateManifest_rejectsMissingName() throws {
        let url = try writeManifest([
            "manifest_version": 3,
            "version": "1.0",
        ])
        XCTAssertThrowsError(try ExtensionUtils.validateManifest(at: url)) { err in
            XCTAssertTrue("\(err)".lowercased().contains("name"))
        }
    }

    func test_validateManifest_rejectsMissingVersion() throws {
        let url = try writeManifest([
            "manifest_version": 3,
            "name": "x",
        ])
        XCTAssertThrowsError(try ExtensionUtils.validateManifest(at: url)) { err in
            XCTAssertTrue("\(err)".lowercased().contains("version"))
        }
    }

    func test_validateManifest_rejectsUnsupportedManifestVersion() throws {
        let url = try writeManifest([
            "manifest_version": 4,
            "name": "x",
            "version": "1.0",
        ])
        XCTAssertThrowsError(try ExtensionUtils.validateManifest(at: url)) { err in
            XCTAssertTrue("\(err)".lowercased().contains("manifest_version"))
        }
    }

    func test_validateManifest_rejectsOversizedPermissions() throws {
        let permissions = (0..<(ExtensionUtils.maxPermissionsCount + 1)).map { "perm.\($0)" }
        let url = try writeManifest([
            "manifest_version": 3,
            "name": "Greedy",
            "version": "1.0",
            "permissions": permissions,
        ])
        XCTAssertThrowsError(try ExtensionUtils.validateManifest(at: url)) { err in
            XCTAssertTrue("\(err)".lowercased().contains("permissions"))
        }
    }

    func test_validateManifest_rejectsControlCharsInExternallyConnectable() throws {
        let url = try writeManifest([
            "manifest_version": 3,
            "name": "x",
            "version": "1.0",
            "externally_connectable": [
                "matches": ["https://evil.example.com\u{0000}\nlol/*"],
            ],
        ])
        XCTAssertThrowsError(try ExtensionUtils.validateManifest(at: url)) { err in
            XCTAssertTrue("\(err)".lowercased().contains("control"))
        }
    }

    // MARK: - hostname validation

    func test_isValidHostname_acceptsTypicalDomains() {
        for host in ["example.com", "sub.example.co.uk", "a.b.c.d", "x"] {
            XCTAssertTrue(
                ExtensionUtils.isValidHostname(host),
                "\(host) is a normal hostname and must validate."
            )
        }
    }

    func test_isValidHostname_rejectsControlChars() {
        for host in ["bad\nhost.com", "weird\u{0000}.com", "tab\there"] {
            XCTAssertFalse(
                ExtensionUtils.isValidHostname(host),
                "\(host.debugDescription) contains control characters and must NOT validate — these get embedded into injected JS."
            )
        }
    }

    func test_isValidHostname_rejectsLeadingTrailingDash() {
        XCTAssertFalse(ExtensionUtils.isValidHostname("-leading.com"))
        XCTAssertFalse(ExtensionUtils.isValidHostname("trailing-.com"))
    }

    func test_isValidHostname_rejectsEmptyAndOversize() {
        XCTAssertFalse(ExtensionUtils.isValidHostname(""))
        XCTAssertFalse(ExtensionUtils.isValidHostname("..bad.."))
        XCTAssertFalse(ExtensionUtils.isValidHostname(String(repeating: "a", count: 254)))
    }

    func test_isValidHostname_rejectsLabelOver63Chars() {
        let host = String(repeating: "x", count: 64) + ".com"
        XCTAssertFalse(ExtensionUtils.isValidHostname(host))
    }

    // MARK: - generateExtensionId

    func test_generateExtensionId_isUniqueAndLowercase() {
        let a = ExtensionUtils.generateExtensionId()
        let b = ExtensionUtils.generateExtensionId()
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a, a.lowercased())
    }

    // MARK: - helpers

    private func writeManifest(_ dict: [String: Any]) throws -> URL {
        let url = tempDir.appendingPathComponent("manifest.json")
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted])
        try data.write(to: url)
        return url
    }
}

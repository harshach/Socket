//
//  ExtensionPatchersTests.swift
//  SocketTests
//
//  Drives `patchManifestForWebKit` + `patchServiceWorkerForCompat` against
//  fixture extension dirs in /tmp. The patchers were `private` until we
//  bumped them to `internal` for testability — they encode the WebKit
//  compatibility tweaks Socket applies to every Chrome extension at install
//  time, so silent regressions here corrupt every installed extension.
//

import XCTest

@testable import Socket

@available(macOS 15.4, *)
@MainActor
final class ExtensionPatchersTests: XCTestCase {
    private var packageDir: URL!
    private var manifestURL: URL!
    private var swURL: URL!
    private var manager: ExtensionManager { ExtensionManager.shared }

    override func setUp() async throws {
        packageDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ext-patcher-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: packageDir, withIntermediateDirectories: true)
        manifestURL = packageDir.appendingPathComponent("manifest.json")
        swURL = packageDir.appendingPathComponent("bg.js")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: packageDir)
    }

    // MARK: - patchServiceWorkerForCompat

    func test_swPatch_prependsPolyfillOnFirstRun() throws {
        try writeManifest([
            "manifest_version": 3,
            "name": "T",
            "version": "1.0",
            "background": ["service_worker": "bg.js"],
        ])
        try writeSW("console.log('user code');\n")

        manager.patchServiceWorkerForCompat(packageDir: packageDir, manifestURL: manifestURL)

        let after = try String(contentsOf: swURL, encoding: .utf8)
        XCTAssertTrue(
            after.contains(ExtensionManager.serviceWorkerPolyfillMarker),
            "First-run patch must inject the polyfill marker so future runs know it's already done."
        )
        XCTAssertTrue(after.contains("console.log('user code')"), "Original SW source must be preserved.")
    }

    func test_swPatch_isIdempotent() throws {
        try writeManifest([
            "manifest_version": 3,
            "name": "T",
            "version": "1.0",
            "background": ["service_worker": "bg.js"],
        ])
        try writeSW("console.log('user');\n")

        manager.patchServiceWorkerForCompat(packageDir: packageDir, manifestURL: manifestURL)
        let firstPass = try String(contentsOf: swURL, encoding: .utf8)
        manager.patchServiceWorkerForCompat(packageDir: packageDir, manifestURL: manifestURL)
        let secondPass = try String(contentsOf: swURL, encoding: .utf8)

        XCTAssertEqual(
            firstPass, secondPass,
            "Re-patching a SW that already carries the marker must be a no-op — re-prepending breaks the SW."
        )
    }

    func test_swPatch_stripsTypeModuleFromManifest() throws {
        try writeManifest([
            "manifest_version": 3,
            "name": "ModuleSW",
            "version": "1.0",
            "background": [
                "service_worker": "bg.js",
                "type": "module",
            ],
        ])
        try writeSW("export default {};\n")

        manager.patchServiceWorkerForCompat(packageDir: packageDir, manifestURL: manifestURL)

        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
        let background = manifest?["background"] as? [String: Any]
        XCTAssertNil(
            background?["type"],
            "patcher must strip `type: module` so WKWebExtension treats the SW as classic — module SWs are silently dropped."
        )
        XCTAssertEqual(background?["service_worker"] as? String, "bg.js", "service_worker filename should remain intact.")
    }

    func test_swPatch_addsModuleStripMarkerWhenSourceIsRewritten() throws {
        try writeManifest([
            "manifest_version": 3,
            "name": "ModuleSW",
            "version": "1.0",
            "background": [
                "service_worker": "bg.js",
                "type": "module",
            ],
        ])
        // Top-level `export {…}` triggers the ESM rewriter; only when the
        // rewriter actually touches the source does the strip marker land.
        try writeSW("var x = 1;\nexport { x };\n")

        manager.patchServiceWorkerForCompat(packageDir: packageDir, manifestURL: manifestURL)

        let after = try String(contentsOf: swURL, encoding: .utf8)
        XCTAssertTrue(
            after.contains(ExtensionManager.serviceWorkerModuleStripMarker),
            "When the ESM rewriter modifies the SW, the strip marker must be added so re-patches stay idempotent."
        )
    }

    func test_swPatch_doesNothingWhenManifestHasNoBackground() throws {
        try writeManifest([
            "manifest_version": 3,
            "name": "Empty",
            "version": "1.0",
        ])
        // No SW file even.
        manager.patchServiceWorkerForCompat(packageDir: packageDir, manifestURL: manifestURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: swURL.path))
    }

    // MARK: - patchManifestForWebKit

    func test_manifestPatch_injectsExternallyConnectableBridge() throws {
        try writeManifest([
            "manifest_version": 3,
            "name": "WithBridge",
            "version": "1.0",
            "externally_connectable": [
                "matches": ["https://account.proton.me/*"],
            ],
        ])

        manager.patchManifestForWebKit(at: manifestURL)

        let updated = try parseManifest()
        let scripts = updated["content_scripts"] as? [[String: Any]] ?? []
        let bridge = scripts.first { ($0["js"] as? [String])?.contains("socket_bridge.js") == true }
        XCTAssertNotNil(bridge, "Bridge content script entry must be added when externally_connectable is present.")
        XCTAssertEqual(bridge?["all_frames"] as? Bool, true)
        XCTAssertEqual(bridge?["run_at"] as? String, "document_start")
        XCTAssertEqual(bridge?["matches"] as? [String], ["https://account.proton.me/*"])

        // The bridge JS file should also be written to disk alongside the manifest.
        let bridgeFile = packageDir.appendingPathComponent("socket_bridge.js")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: bridgeFile.path),
            "Bridge content script must point at a file that actually exists on disk; otherwise WKWebExtension fails to inject it."
        )
    }

    func test_manifestPatch_isIdempotentForBridge() throws {
        try writeManifest([
            "manifest_version": 3,
            "name": "WithBridge",
            "version": "1.0",
            "externally_connectable": ["matches": ["https://x.com/*"]],
        ])

        manager.patchManifestForWebKit(at: manifestURL)
        let pass1 = try parseManifest()
        manager.patchManifestForWebKit(at: manifestURL)
        let pass2 = try parseManifest()

        let cs1 = pass1["content_scripts"] as? [[String: Any]] ?? []
        let cs2 = pass2["content_scripts"] as? [[String: Any]] ?? []
        XCTAssertEqual(
            cs1.count, cs2.count,
            "Re-patching must NOT append duplicate bridge entries — a duplicate would cause WKWebExtension to register the listener twice."
        )
    }

    func test_manifestPatch_revertsMainWorldOnDomainSpecificContentScripts() throws {
        // Earlier code incorrectly patched these; the new patcher should
        // revert them (MAIN-world content scripts lose browser.runtime).
        try writeManifest([
            "manifest_version": 3,
            "name": "DomainScripts",
            "version": "1.0",
            "content_scripts": [
                [
                    "matches": ["https://specific.example.com/*"],
                    "js": ["site.js"],
                    "world": "MAIN",
                ],
            ],
        ])

        manager.patchManifestForWebKit(at: manifestURL)

        let updated = try parseManifest()
        let scripts = updated["content_scripts"] as? [[String: Any]] ?? []
        XCTAssertNil(
            scripts.first?["world"],
            "Domain-specific content scripts marked MAIN must be reverted to ISOLATED so they can call browser.runtime.*"
        )
    }

    func test_manifestPatch_leavesWildcardMainWorldScriptsAlone() throws {
        // Wildcard host patterns are intentional MAIN-world (e.g. analytics
        // shims). The reverter only targets domain-specific entries, so
        // wildcards must pass through unchanged.
        try writeManifest([
            "manifest_version": 3,
            "name": "Wildcard",
            "version": "1.0",
            "content_scripts": [
                [
                    "matches": ["*://*/*"],
                    "js": ["everywhere.js"],
                    "world": "MAIN",
                ],
            ],
        ])

        manager.patchManifestForWebKit(at: manifestURL)

        let updated = try parseManifest()
        let scripts = updated["content_scripts"] as? [[String: Any]] ?? []
        XCTAssertEqual(
            scripts.first?["world"] as? String, "MAIN",
            "Wildcard-match MAIN-world entries are intentional — the patcher must not strip them."
        )
    }

    // MARK: - validateMV3Requirements

    func test_mv3Validation_rejectsManifestPointingAtMissingSW() throws {
        try writeManifest([
            "manifest_version": 3,
            "name": "GhostSW",
            "version": "1.0",
            "background": ["service_worker": "missing.js"],
        ])
        // Note: no missing.js file written — the validator should refuse this.
        let manifest = try ExtensionUtils.validateManifest(at: manifestURL)
        XCTAssertThrowsError(
            try manager.validateMV3Requirements(manifest: manifest, baseURL: packageDir)
        ) { err in
            XCTAssertTrue(
                "\(err)".contains("missing"),
                "Should be obvious in the error that the SW file isn't on disk."
            )
        }
    }

    func test_mv3Validation_acceptsManifestWhereSWExists() throws {
        try writeManifest([
            "manifest_version": 3,
            "name": "RealSW",
            "version": "1.0",
            "background": ["service_worker": "bg.js"],
        ])
        try writeSW("// noop\n")
        let manifest = try ExtensionUtils.validateManifest(at: manifestURL)
        XCTAssertNoThrow(try manager.validateMV3Requirements(manifest: manifest, baseURL: packageDir))
    }

    func test_mv3Validation_acceptsManifestWithoutBackground() throws {
        // Lots of real extensions ship as content-scripts only — no SW at all.
        try writeManifest([
            "manifest_version": 3,
            "name": "ScriptsOnly",
            "version": "1.0",
            "content_scripts": [["matches": ["*://*/*"], "js": ["content.js"]]],
        ])
        let manifest = try ExtensionUtils.validateManifest(at: manifestURL)
        XCTAssertNoThrow(try manager.validateMV3Requirements(manifest: manifest, baseURL: packageDir))
    }

    // MARK: - install pipeline (validate → patch) end-to-end

    func test_installPipeline_modulesSWGetsTransformedAndManifestUpdated() throws {
        // Replicates the install order: validateManifest → validateMV3 →
        // patchManifestForWebKit → patchServiceWorkerForCompat. A 1Password-
        // style module SW with externally_connectable hits all three patchers.
        try writeManifest([
            "manifest_version": 3,
            "name": "ProtonLike",
            "version": "1.0.0",
            "background": [
                "service_worker": "bg.js",
                "type": "module",
            ],
            "externally_connectable": [
                "matches": ["https://account.proton.me/*"],
            ],
        ])
        try writeSW("var greeting = 'hi';\nexport { greeting };\n")

        let manifest = try ExtensionUtils.validateManifest(at: manifestURL)
        XCTAssertNoThrow(try manager.validateMV3Requirements(manifest: manifest, baseURL: packageDir))
        manager.patchManifestForWebKit(at: manifestURL)
        manager.patchServiceWorkerForCompat(packageDir: packageDir, manifestURL: manifestURL)

        let finalManifest = try parseManifest()
        let background = finalManifest["background"] as? [String: Any]
        XCTAssertNil(
            background?["type"],
            "End-to-end: type:module must be stripped before WebKit sees the package."
        )

        let scripts = finalManifest["content_scripts"] as? [[String: Any]] ?? []
        XCTAssertTrue(
            scripts.contains(where: { ($0["js"] as? [String])?.contains("socket_bridge.js") == true }),
            "End-to-end: externally_connectable bridge must be installed in the same pass."
        )

        let bridgeFile = packageDir.appendingPathComponent("socket_bridge.js")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bridgeFile.path))

        let swAfter = try String(contentsOf: swURL, encoding: .utf8)
        XCTAssertTrue(
            swAfter.contains(ExtensionManager.serviceWorkerPolyfillMarker),
            "End-to-end: SW polyfill must be in place."
        )
    }

    // MARK: - helpers

    private func writeManifest(_ dict: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted])
        try data.write(to: manifestURL)
    }

    private func writeSW(_ source: String) throws {
        try Data(source.utf8).write(to: swURL)
    }

    private func parseManifest() throws -> [String: Any] {
        let data = try Data(contentsOf: manifestURL)
        return try (JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}

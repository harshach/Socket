//
//  ExtensionUtils.swift
//  Socket
//
//  Created for WKWebExtension support
//

import Foundation

@MainActor
struct ExtensionUtils {
    /// Maximum acceptable manifest.json size on disk. Real extensions are
    /// almost always under 100KB; the cap exists so a hostile package can't
    /// force unbounded JSON parsing.
    static let maxManifestSizeBytes: Int = 4 * 1024 * 1024

    /// Maximum acceptable extension package size on disk after extraction.
    /// 200MB matches Chrome Web Store's per-extension limit.
    static let maxExtensionSizeBytes: Int64 = 200 * 1024 * 1024

    /// Maximum entries we accept in a `permissions` / `host_permissions` /
    /// `optional_permissions` / `optional_host_permissions` array. Largest
    /// real-world extensions land around ~80 entries; 500 is well above
    /// anything legitimate and small enough to bound permission-prompt UX.
    static let maxPermissionsCount: Int = 500

    /// Maximum entries we accept in a `content_scripts` array.
    static let maxContentScriptsCount: Int = 200

    /// Manifest versions we recognise. Anything outside this set is rejected
    /// with a clear error rather than handed to WKWebExtension.
    static let supportedManifestVersions: Set<Int> = [2, 3]

    /// Check if the current OS supports WKWebExtension APIs we rely on
    /// We target the newest OS that includes `world` support for scripting/content scripts.
    /// Requires iOS/iPadOS 18.5+ or macOS 15.5+.
    static var isExtensionSupportAvailable: Bool {
        if #available(iOS 18.5, macOS 15.5, *) { return true }
        return false
    }

    /// Whether MAIN/ISOLATED execution worlds are supported for `chrome.scripting` and content scripts.
    /// Newer WebKit builds honor `world: 'MAIN'|'ISOLATED'` and `content_scripts[].world`.
    static var isWorldInjectionSupported: Bool {
        if #available(iOS 18.5, macOS 15.5, *) { return true }
        return false
    }

    /// Show an alert when extensions are not available on older OS versions
    static func showUnsupportedOSAlert() {
        // This will be implemented when we add alert functionality
        print("Extensions require iOS 18.5+ or macOS 15.5+")
    }

    /// Validate a manifest.json file structure. Strict — rejects anything we
    /// cannot safely hand to WKWebExtension.
    ///
    /// - Throws: `ExtensionError.invalidManifest` with a user-readable reason.
    /// - Returns: the parsed manifest dictionary.
    static func validateManifest(at url: URL) throws -> [String: Any] {
        // File must exist and be sized sanely. An attacker can't force us to
        // parse a multi-gigabyte file just because they renamed it manifest.json.
        let attrs: [FileAttributeKey: Any]
        do {
            attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            throw ExtensionError.invalidManifest("manifest.json missing: \(error.localizedDescription)")
        }
        if let size = attrs[.size] as? Int, size > maxManifestSizeBytes {
            throw ExtensionError.invalidManifest("manifest.json too large (\(size) bytes; limit \(maxManifestSizeBytes))")
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ExtensionError.invalidManifest("cannot read manifest.json: \(error.localizedDescription)")
        }

        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ExtensionError.invalidManifest("malformed JSON: \(error.localizedDescription)")
        }
        guard let manifest = parsed as? [String: Any] else {
            throw ExtensionError.invalidManifest("top-level must be a JSON object")
        }

        // manifest_version: must be present and within the set we recognize.
        guard let mv = manifest["manifest_version"] as? Int else {
            throw ExtensionError.invalidManifest("missing or non-numeric manifest_version")
        }
        guard supportedManifestVersions.contains(mv) else {
            throw ExtensionError.invalidManifest("unsupported manifest_version \(mv); supported: \(supportedManifestVersions.sorted())")
        }

        // name: required non-empty.
        guard let name = manifest["name"] as? String, !name.isEmpty else {
            throw ExtensionError.invalidManifest("missing or empty name")
        }
        if name.count > 1024 {
            throw ExtensionError.invalidManifest("name too long")
        }

        // version: required non-empty.
        guard let version = manifest["version"] as? String, !version.isEmpty else {
            throw ExtensionError.invalidManifest("missing or empty version")
        }
        if version.count > 256 {
            throw ExtensionError.invalidManifest("version too long")
        }

        // Bound permissions arrays so a hostile extension can't generate a
        // multi-megabyte permission prompt.
        try checkArraySize(manifest, key: "permissions", limit: maxPermissionsCount)
        try checkArraySize(manifest, key: "host_permissions", limit: maxPermissionsCount)
        try checkArraySize(manifest, key: "optional_permissions", limit: maxPermissionsCount)
        try checkArraySize(manifest, key: "optional_host_permissions", limit: maxPermissionsCount)
        try checkArraySize(manifest, key: "content_scripts", limit: maxContentScriptsCount)

        // externally_connectable.matches: hostnames must look like hostnames.
        // We extract hostnames from match patterns elsewhere; reject anything
        // that contains characters that could break out of the JS string we
        // embed downstream.
        if let ec = manifest["externally_connectable"] as? [String: Any],
           let matches = ec["matches"] as? [String] {
            if matches.count > maxPermissionsCount {
                throw ExtensionError.invalidManifest("externally_connectable.matches has too many entries (\(matches.count); limit \(maxPermissionsCount))")
            }
            for pattern in matches {
                if pattern.contains("\u{0000}") || pattern.contains("\n") || pattern.contains("\r") {
                    throw ExtensionError.invalidManifest("externally_connectable.matches contains control characters")
                }
            }
        }

        return manifest
    }

    /// RFC1123-ish hostname check. Accepts a single label or a dotted name with
    /// each label 1–63 characters of `[A-Za-z0-9-]` (no leading/trailing dash).
    /// Used when embedding hostnames into injected JavaScript strings — anything
    /// outside this shape is rejected to keep the bridge JS injection-safe.
    static func isValidHostname(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 253 else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty else { return false }
        for label in labels {
            guard !label.isEmpty, label.count <= 63 else { return false }
            if label.first == "-" || label.last == "-" { return false }
            for scalar in label.unicodeScalars {
                let v = scalar.value
                let isAlpha = (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A)
                let isDigit = v >= 0x30 && v <= 0x39
                let isDash = v == 0x2D
                if !(isAlpha || isDigit || isDash) { return false }
            }
        }
        return true
    }

    /// Generate a unique extension identifier
    static func generateExtensionId() -> String {
        return UUID().uuidString.lowercased()
    }

    // MARK: - Internals

    private static func checkArraySize(_ manifest: [String: Any], key: String, limit: Int) throws {
        if let array = manifest[key] as? [Any], array.count > limit {
            throw ExtensionError.invalidManifest("\(key) has too many entries (\(array.count); limit \(limit))")
        }
    }
}

enum ExtensionError: LocalizedError {
    case unsupportedOS
    case invalidManifest(String)
    case installationFailed(String)
    case packageRejected(String)
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .unsupportedOS:
            return "Extensions require iOS 18.5+ or macOS 15.5+"
        case .invalidManifest(let reason):
            return "Invalid manifest.json: \(reason)"
        case .installationFailed(let reason):
            return "Installation failed: \(reason)"
        case .packageRejected(let reason):
            return "Extension package rejected: \(reason)"
        case .permissionDenied:
            return "Permission denied"
        }
    }
}

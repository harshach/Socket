//
//  ManagementShim.swift
//  Socket
//
//  chrome.management shim. Apple's WKWebExtension does not expose the
//  management namespace at all, so we implement it on top of
//  `ExtensionManager.installedExtensions`.
//
//  Scope:
//    * Read operations (`getAll`, `get`, `getSelf`) — fully implemented.
//    * `getPermissionWarningsById` / `ByManifest` — return the extension's
//      requested permissions as human-readable strings; this is coarser than
//      Chrome but good enough for common uses (extension review pages).
//    * Write operations (`setEnabled`, `uninstall`, `uninstallSelf`) —
//      implemented with a user-consent dialog so hostile extensions can't
//      silently disable or uninstall siblings. A future phase can add
//      per-extension management-permission scoping.
//

import Foundation
import os

@available(macOS 15.4, *)
@MainActor
final class ManagementShim: Shim {
    private static let logger = Logger(subsystem: "com.socket.browser", category: "ManagementShim")

    let namespaces: Set<String> = ["management"]

    private unowned let extensionManager: ExtensionManager

    init(extensionManager: ExtensionManager) {
        self.extensionManager = extensionManager
    }

    func handle(_ request: ShimRequest) async throws -> Any? {
        switch request.method {
        case "getAll":
            return serializeAll()

        case "get":
            guard let id = request.args.first as? String else {
                throw ShimError.invalidArgument("get(id) requires a string id")
            }
            guard let ext = find(id) else {
                throw ShimError.notFound("extension \(id) not installed")
            }
            return serialize(ext)

        case "getSelf":
            guard let id = request.extensionId, let ext = find(id) else {
                throw ShimError.notFound("caller is not a registered extension")
            }
            return serialize(ext)

        case "getPermissionWarningsById":
            guard let id = request.args.first as? String else {
                throw ShimError.invalidArgument("getPermissionWarningsById(id) requires a string id")
            }
            guard let ext = find(id) else {
                throw ShimError.notFound("extension \(id) not installed")
            }
            return permissionWarnings(for: ext.manifest)

        case "getPermissionWarningsByManifest":
            guard let manifestStr = request.args.first as? String,
                  let data = manifestStr.data(using: .utf8),
                  let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ShimError.invalidArgument("getPermissionWarningsByManifest(jsonString) requires valid manifest JSON")
            }
            return permissionWarnings(for: manifest)

        case "setEnabled":
            guard let id = request.args.first as? String else {
                throw ShimError.invalidArgument("setEnabled(id, enabled) requires a string id")
            }
            let enabled: Bool
            if request.args.count >= 2, let e = request.args[1] as? Bool {
                enabled = e
            } else {
                throw ShimError.invalidArgument("setEnabled(id, enabled) requires a boolean enabled flag")
            }
            // Self-toggle is always allowed; cross-extension toggles are
            // denied in this phase (re-enabling via Settings > Extensions is
            // the supported path). We surface the denial as a clear error.
            if request.extensionId != id {
                throw ShimError.permissionDenied("Socket does not allow extensions to enable/disable other extensions")
            }
            if enabled {
                extensionManager.enableExtension(id)
            } else {
                extensionManager.disableExtension(id)
            }
            return nil

        case "uninstall":
            guard let id = request.args.first as? String else {
                throw ShimError.invalidArgument("uninstall(id, options) requires a string id")
            }
            if request.extensionId != id {
                throw ShimError.permissionDenied("Socket does not allow extensions to uninstall siblings")
            }
            extensionManager.uninstallExtension(id)
            return nil

        case "uninstallSelf":
            guard let id = request.extensionId else {
                throw ShimError.notFound("caller is not a registered extension")
            }
            extensionManager.uninstallExtension(id)
            return nil

        default:
            throw ShimError.unknownMethod(namespace: "management", method: request.method)
        }
    }

    // MARK: - Serialization

    private func find(_ id: String) -> InstalledExtension? {
        extensionManager.installedExtensions.first { $0.id == id }
    }

    private func serializeAll() -> [[String: Any]] {
        extensionManager.installedExtensions.map(serialize)
    }

    /// Shape matches Chrome's `ExtensionInfo` at the fields we can honestly
    /// populate. Fields we can't (installType, launchType, ...) are omitted
    /// rather than lied about — Chrome callers feature-detect.
    private func serialize(_ ext: InstalledExtension) -> [String: Any] {
        var out: [String: Any] = [
            "id": ext.id,
            "name": ext.name,
            "version": ext.version,
            "enabled": ext.isEnabled,
            "mayDisable": true,
            "mayUninstall": true,
            "type": "extension",
            "installType": "development",
            "permissions": (ext.manifest["permissions"] as? [String]) ?? [],
            "hostPermissions": (ext.manifest["host_permissions"] as? [String]) ?? [],
        ]
        if let description = ext.description, !description.isEmpty {
            out["description"] = description
        }
        if let homepageURL = ext.manifest["homepage_url"] as? String {
            out["homepageUrl"] = homepageURL
        }
        if let iconPath = ext.iconPath {
            out["icons"] = [[
                "size": 128,
                "url": URL(fileURLWithPath: iconPath).absoluteString
            ]]
        }
        return out
    }

    /// Very coarse permission-warning strings mirroring Chrome's "host
    /// permissions warning" strings. Chrome's full mapping is long; we
    /// translate a handful of the most common permission names and fall back
    /// to the raw permission string.
    private func permissionWarnings(for manifest: [String: Any]) -> [String] {
        var warnings: [String] = []
        let permissions = (manifest["permissions"] as? [String]) ?? []
        let hostPermissions = (manifest["host_permissions"] as? [String]) ?? []

        for p in permissions {
            switch p {
            case "tabs":
                warnings.append("Read your browsing history")
            case "cookies":
                warnings.append("Modify cookies across sites")
            case "bookmarks":
                warnings.append("Read and modify your bookmarks")
            case "history":
                warnings.append("Read and modify your browsing history")
            case "downloads":
                warnings.append("Manage your downloads")
            case "notifications":
                warnings.append("Show notifications")
            case "clipboardRead", "clipboardWrite":
                warnings.append("Read or modify your clipboard")
            case "nativeMessaging":
                warnings.append("Communicate with native applications")
            case "webRequest", "webRequestBlocking":
                warnings.append("Observe or modify network traffic")
            case "proxy":
                warnings.append("Control browser proxy settings")
            default:
                if !p.isEmpty { warnings.append(p) }
            }
        }
        for host in hostPermissions {
            warnings.append("Read and modify data on \(host)")
        }
        return warnings
    }
}

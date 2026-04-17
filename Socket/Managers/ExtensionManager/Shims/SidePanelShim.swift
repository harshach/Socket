//
//  SidePanelShim.swift
//  Socket
//
//  chrome.sidePanel shim. Apple's WKWebExtension does not expose side panels;
//  Socket projects the API onto a right-side drawer (`ExtensionSidePanelView`)
//  that hosts the extension's panel page.
//
//  Storage model:
//    * Per-extension config (path, enabled, openPanelOnActionClick,
//      default_path inherited from manifest.side_panel.default_path).
//    * Per-tab path overrides are NOT stored in this phase — Chrome supports
//      `setOptions({ tabId, path })` but most extensions use the global
//      config and swap paths via `open`. Tab-scoped paths can be layered
//      on top without breaking the wire format.
//
//  open() honors `openPanelOnActionClick` only when triggered from the
//  action popup path (not implemented yet); explicit open() calls always
//  show the panel.
//

import Foundation
import os

@available(macOS 15.5, *)
@MainActor
final class SidePanelShim: Shim {
    private static let logger = Logger(subsystem: "com.socket.browser", category: "SidePanelShim")

    let namespaces: Set<String> = ["sidePanel"]

    private unowned let extensionManager: ExtensionManager

    private struct PanelConfig {
        var path: String?
        var enabled: Bool = true
        var openPanelOnActionClick: Bool = false
    }

    /// Per-extension config keyed by extension id. Populated by `setOptions`
    /// and read by `getOptions` / `open`.
    private var configs: [String: PanelConfig] = [:]

    init(extensionManager: ExtensionManager) {
        self.extensionManager = extensionManager
    }

    func handle(_ request: ShimRequest) async throws -> Any? {
        switch request.method {
        case "setOptions":         return try setOptions(request)
        case "getOptions":         return try getOptions(request)
        case "open":               return try open(request)
        case "setPanelBehavior":   return try setPanelBehavior(request)
        case "getPanelBehavior":   return try getPanelBehavior(request)
        default:
            throw ShimError.unknownMethod(namespace: "sidePanel", method: request.method)
        }
    }

    // MARK: - setOptions / getOptions

    private func setOptions(_ request: ShimRequest) throws -> Any? {
        let extId = try requireExtensionId(request)
        guard let opts = request.args.first as? [String: Any] else {
            throw ShimError.invalidArgument("setOptions expects an options object")
        }
        var config = configs[extId] ?? defaultConfig(for: extId)
        if let path = opts["path"] as? String { config.path = path }
        if let enabled = opts["enabled"] as? Bool { config.enabled = enabled }
        configs[extId] = config
        Self.logger.info("setOptions ext=\(extId, privacy: .public) path=\(config.path ?? "(default)", privacy: .public) enabled=\(config.enabled, privacy: .public)")

        // If this extension's panel is currently open in any window and the
        // path changed, refresh the webview by re-opening.
        refreshOpenPanels(for: extId)
        return nil
    }

    private func getOptions(_ request: ShimRequest) throws -> [String: Any] {
        let extId = try requireExtensionId(request)
        let config = configs[extId] ?? defaultConfig(for: extId)
        var result: [String: Any] = [
            "enabled": config.enabled,
        ]
        if let path = config.path { result["path"] = path }
        return result
    }

    // MARK: - open

    private func open(_ request: ShimRequest) throws -> Any? {
        let extId = try requireExtensionId(request)
        let config = configs[extId] ?? defaultConfig(for: extId)
        guard config.enabled else {
            throw ShimError.permissionDenied("side panel is disabled for this extension")
        }
        guard let path = config.path, !path.isEmpty else {
            throw ShimError.invalidArgument("No side panel path configured; call setOptions({path}) first or set side_panel.default_path in manifest")
        }
        guard let browser = extensionManager.attachedBrowserManager else {
            throw ShimError.internalError("no BrowserManager attached")
        }
        browser.openSidePanel(extensionId: extId, path: path)
        return nil
    }

    // MARK: - setPanelBehavior / getPanelBehavior

    private func setPanelBehavior(_ request: ShimRequest) throws -> Any? {
        let extId = try requireExtensionId(request)
        guard let behavior = request.args.first as? [String: Any] else {
            throw ShimError.invalidArgument("setPanelBehavior expects an object")
        }
        var config = configs[extId] ?? defaultConfig(for: extId)
        if let flag = behavior["openPanelOnActionClick"] as? Bool {
            config.openPanelOnActionClick = flag
        }
        configs[extId] = config
        return nil
    }

    private func getPanelBehavior(_ request: ShimRequest) throws -> [String: Any] {
        let extId = try requireExtensionId(request)
        let config = configs[extId] ?? defaultConfig(for: extId)
        return ["openPanelOnActionClick": config.openPanelOnActionClick]
    }

    // MARK: - Helpers

    /// Extract `chrome.runtime.id` or fail with a clear message.
    private func requireExtensionId(_ request: ShimRequest) throws -> String {
        guard let id = request.extensionId, !id.isEmpty else {
            throw ShimError.invalidArgument("caller is not a registered extension")
        }
        return id
    }

    /// Fresh config derived from manifest.side_panel.default_path when
    /// available. Used when an extension calls `getOptions`/`open` without
    /// having called `setOptions` first — matches Chrome's behavior.
    private func defaultConfig(for extensionId: String) -> PanelConfig {
        guard let ext = extensionManager.installedExtensions.first(where: { $0.id == extensionId }) else {
            return PanelConfig()
        }
        if let sidePanel = ext.manifest["side_panel"] as? [String: Any],
           let path = sidePanel["default_path"] as? String, !path.isEmpty {
            return PanelConfig(path: path, enabled: true, openPanelOnActionClick: false)
        }
        return PanelConfig()
    }

    /// Re-trigger open for every window currently showing this extension's
    /// panel so a path change from setOptions takes effect without requiring
    /// the extension to call open() again.
    private func refreshOpenPanels(for extensionId: String) {
        guard let browser = extensionManager.attachedBrowserManager,
              let path = configs[extensionId]?.path else { return }
        browser.refreshSidePanelIfShowing(extensionId: extensionId, newPath: path)
    }
}

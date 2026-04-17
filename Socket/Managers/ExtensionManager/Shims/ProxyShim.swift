//
//  ProxyShim.swift
//  Socket
//
//  chrome.proxy shim. Apple's WKWebExtension does not expose chrome.proxy,
//  so we apply the requested configuration directly to the active profile's
//  WKWebsiteDataStore via its `proxyConfigurations` (macOS 14+).
//
//  Scope:
//    * `chrome.proxy.settings.set({ value, scope? })` — applies to the active
//      profile. `scope` is ignored: Socket has no separate "regular vs
//      incognito" surface here; ephemeral profiles get the same handling
//      because their data store is already isolated.
//    * `chrome.proxy.settings.get(...)` — echoes the last `set` payload.
//      Reverse-engineering ProxyConfiguration objects is lossy, so we cache.
//    * `chrome.proxy.settings.clear(...)` — clears `proxyConfigurations`.
//    * Modes: `direct`, `system` (both clear the configs), `fixed_servers`
//      (translated to ProxyConfiguration). `pac_script` and `auto_detect`
//      are not yet supported and surface a clear error.
//

import Foundation
import Network
import WebKit
import os

@available(macOS 15.4, *)
@MainActor
final class ProxyShim: Shim {
    private static let logger = Logger(subsystem: "com.socket.browser", category: "ProxyShim")

    let namespaces: Set<String> = ["proxy"]

    private unowned let extensionManager: ExtensionManager

    /// Cache of the last user-supplied config keyed by profile id. Used by
    /// `settings.get` so callers see exactly what was set.
    private var lastSetByProfile: [UUID: [String: Any]] = [:]

    init(extensionManager: ExtensionManager) {
        self.extensionManager = extensionManager
    }

    func handle(_ request: ShimRequest) async throws -> Any? {
        switch request.method {
        case "settings.set":   return try setSettings(args: request.args)
        case "settings.get":   return getSettings()
        case "settings.clear": return try clearSettings()
        case "settings.onChange.addListener",
             "settings.onChange.removeListener",
             "settings.onChange.hasListener":
            // Event APIs are no-ops for now. Pipe-back via JS would need
            // KVO on proxyConfigurations (no public hook) or polling, which
            // isn't worth the cost until a real consumer asks for it.
            return nil
        default:
            throw ShimError.unknownMethod(namespace: "proxy", method: request.method)
        }
    }

    // MARK: - settings.set

    private func setSettings(args: [Any]) throws -> Any? {
        guard let profile = currentProfile() else {
            throw ShimError.internalError("No active profile to apply proxy settings to")
        }
        guard let payload = args.first as? [String: Any] else {
            throw ShimError.invalidArgument("settings.set expects { value, scope? } as first argument")
        }
        guard let value = payload["value"] as? [String: Any] else {
            throw ShimError.invalidArgument("settings.set requires 'value'")
        }
        guard let mode = value["mode"] as? String else {
            throw ShimError.invalidArgument("proxy config requires 'mode'")
        }

        let configs = try buildProxyConfigurations(mode: mode, value: value)
        profile.dataStore.proxyConfigurations = configs
        lastSetByProfile[profile.id] = value
        Self.logger.info("Applied proxy mode=\(mode, privacy: .public) configs=\(configs.count, privacy: .public) profile=\(profile.id.uuidString, privacy: .public)")
        return nil
    }

    private func getSettings() -> [String: Any] {
        let value: [String: Any]
        if let id = currentProfile()?.id, let last = lastSetByProfile[id] {
            value = last
        } else {
            value = ["mode": "system"]
        }
        return [
            // The shim is the controlling extension once it has called set
            // at least once. Before that we report "not_controllable" so the
            // caller can branch on first-use.
            "levelOfControl": lastSetByProfile.isEmpty ? "not_controllable" : "controlled_by_this_extension",
            "value": value,
        ]
    }

    private func clearSettings() throws -> Any? {
        guard let profile = currentProfile() else { return nil }
        profile.dataStore.proxyConfigurations = []
        lastSetByProfile.removeValue(forKey: profile.id)
        return nil
    }

    // MARK: - Mapping

    /// Translate a Chrome proxy `mode` + payload into Network framework
    /// `ProxyConfiguration` values. An empty array tells WebKit to use the
    /// default route (no proxy).
    private func buildProxyConfigurations(mode: String, value: [String: Any]) throws -> [ProxyConfiguration] {
        switch mode {
        case "direct", "system":
            return []
        case "auto_detect":
            throw ShimError.notSupported("mode 'auto_detect' (WPAD) is not supported")
        case "pac_script":
            throw ShimError.notSupported("mode 'pac_script' is not yet supported")
        case "fixed_servers":
            guard let rules = value["rules"] as? [String: Any] else {
                throw ShimError.invalidArgument("'fixed_servers' mode requires 'rules'")
            }
            return try buildFromRules(rules: rules)
        default:
            throw ShimError.invalidArgument("Unknown proxy mode '\(mode)'")
        }
    }

    private func buildFromRules(rules: [String: Any]) throws -> [ProxyConfiguration] {
        let bypass = (rules["bypassList"] as? [String]) ?? []

        // singleProxy applies to all schemes. Per Chrome docs it cannot
        // coexist with proxyForHttp/etc.
        if let single = rules["singleProxy"] as? [String: Any] {
            return [try buildProxyConfig(spec: single, excludedDomains: bypass)]
        }

        var configs: [ProxyConfiguration] = []
        for key in ["proxyForHttp", "proxyForHttps", "proxyForFtp", "fallbackProxy"] {
            if let spec = rules[key] as? [String: Any] {
                configs.append(try buildProxyConfig(spec: spec, excludedDomains: bypass))
            }
        }
        if configs.isEmpty {
            throw ShimError.invalidArgument("'fixed_servers' rules must specify at least one proxy")
        }
        return configs
    }

    private func buildProxyConfig(spec: [String: Any], excludedDomains: [String]) throws -> ProxyConfiguration {
        guard let host = spec["host"] as? String, !host.isEmpty else {
            throw ShimError.invalidArgument("proxy spec requires 'host'")
        }
        let scheme = (spec["scheme"] as? String)?.lowercased() ?? "http"
        let portRaw: Int
        if let p = spec["port"] as? Int { portRaw = p }
        else if let p = spec["port"] as? Double { portRaw = Int(p) }
        else {
            // Chrome's defaults
            switch scheme {
            case "http":             portRaw = 80
            case "https":            portRaw = 443
            case "socks5", "socks":  portRaw = 1080
            default:                 portRaw = 8080
            }
        }
        guard portRaw > 0, portRaw <= 65535,
              let nwPort = NWEndpoint.Port(rawValue: UInt16(portRaw)) else {
            throw ShimError.invalidArgument("invalid port \(portRaw)")
        }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)

        var config: ProxyConfiguration
        switch scheme {
        case "http", "https":
            // ProxyConfiguration only models HTTPS-CONNECT proxies for HTTP/S
            // traffic. Plain (non-CONNECT) HTTP proxies aren't representable;
            // CONNECT works for the common case (most modern HTTP proxies do
            // both). TLS to the proxy is opt-in via tlsOptions; we don't set
            // it because Chrome's `https` scheme refers to the destination,
            // not the proxy hop.
            config = ProxyConfiguration(httpCONNECTProxy: endpoint, tlsOptions: nil)
        case "socks5", "socks":
            config = ProxyConfiguration(socksv5Proxy: endpoint)
        case "socks4":
            throw ShimError.notSupported("SOCKS4 is not supported; use SOCKS5")
        default:
            throw ShimError.invalidArgument("unknown proxy scheme '\(scheme)'")
        }

        for domain in excludedDomains where !domain.isEmpty {
            config.excludedDomains.append(domain)
        }
        return config
    }

    // MARK: - Helpers

    private func currentProfile() -> Profile? {
        extensionManager.attachedBrowserManager?.currentProfile
    }
}

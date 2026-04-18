//
//  TrackingProtectionManager.swift
//  Socket
//
//  WebKit-first Shields coordinator. This manages subscription-backed content
//  blocking, a Rust helper compilation path for ABP/uBO lists, a built-in
//  fallback artifact, site exceptions, and lightweight page-level telemetry.
//
import Combine
import CryptoKit
import Foundation
import WebKit

enum ShieldsCompilerStatus: Equatable, Sendable {
    case idle
    case preparing(String)
    case ready(String)
    case fallback(String)
    case failed(String)

    var title: String {
        switch self {
        case .idle:
            return "Idle"
        case .preparing(let value):
            return value
        case .ready(let value):
            return value
        case .fallback(let value):
            return value
        case .failed(let value):
            return value
        }
    }

    var tint: String {
        switch self {
        case .idle:
            return "secondary"
        case .preparing:
            return "orange"
        case .ready:
            return "green"
        case .fallback:
            return "blue"
        case .failed:
            return "red"
        }
    }
}

struct FilterSubscription: Identifiable, Codable, Hashable, Sendable {
    enum Category: String, Codable, CaseIterable, Sendable {
        case core
        case regional
    }

    enum Source: String, Codable, Sendable {
        case bundled
        case remote
    }

    enum FilterFormat: String, Codable, Sendable {
        case standard
        case hosts
    }

    var id: String
    var title: String
    var category: Category
    var source: Source
    var format: FilterFormat
    var remoteURLString: String?
    var isEnabled: Bool
    var checksum: String?
    var lastUpdatedAt: Date?
    var lastErrorDescription: String?

    var remoteURL: URL? {
        guard let remoteURLString else { return nil }
        return URL(string: remoteURLString)
    }

    var subtitle: String {
        switch category {
        case .core:
            return "Core"
        case .regional:
            return "Regional"
        }
    }
}

struct CompiledRuleArtifact: Codable, Equatable, Sendable {
    var identifier: String
    var sourceDigest: String
    var rulesFileName: String
    /// Filename of the notify-action mirror list (sibling to rulesFileName).
    /// Nil for artifacts built before Phase 3 Stage 2 or when the Rust
    /// compiler didn't emit a mirror (e.g. built-in fallback).
    var notifyRulesFileName: String?
    var compilerName: String
    var generatedAt: Date
    var totalRuleCount: Int
    var networkRuleCount: Int
    var cosmeticRuleCount: Int
    var scriptletCandidateCount: Int
    var unsupportedRuleCount: Int
}

struct PageBlockStats: Equatable, Sendable {
    var networkRuleCount: Int
    var cosmeticRuleCount: Int
    var hiddenElementCount: Int
    var scriptletActionCount: Int
    var thirdPartyStorageRestricted: Bool
    var temporaryRelaxed: Bool
    var allowlisted: Bool
}

struct SiteProtectionState: Equatable, Sendable {
    var host: String?
    var isGlobalProtectionEnabled: Bool
    var isAllowlisted: Bool
    var isTemporarilyRelaxed: Bool
    var thirdPartyStorageRestricted: Bool
    var scriptletMode: ScriptletPolicy.Mode
    var stats: PageBlockStats
    var activeArtifact: CompiledRuleArtifact?

    var effectiveShieldIcon: String {
        if !isGlobalProtectionEnabled {
            return "shield.slash"
        }
        if isAllowlisted || isTemporarilyRelaxed {
            return "shield.lefthalf.filled.slash"
        }
        return "lock.shield"
    }
}

struct ShieldsException: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case allowlistedDomain
        case temporaryRelaxation
    }

    var kind: Kind
    var host: String
    var expiresAt: Date?
}

struct ScriptletPolicy: Codable, Equatable, Sendable {
    enum Mode: String, Codable, Sendable {
        case disabled
        case conservative
    }

    var mode: Mode
    var protectedHostSuffixes: [String]

    static let conservative = ScriptletPolicy(
        mode: .conservative,
        protectedHostSuffixes: [
            "accounts.google.com",
            "appleid.apple.com",
            "idmsa.apple.com",
            "login.microsoftonline.com",
            "login.live.com",
            "github.com",
            "stripe.com",
            "paypal.com",
            "bank",
            "billing"
        ]
    )

    func allows(host: String?) -> Bool {
        guard mode != .disabled else { return false }
        guard let host else { return true }
        let normalized = host.lowercased()
        return !protectedHostSuffixes.contains { protected in
            normalized == protected || normalized.hasSuffix(".\(protected)")
        }
    }
}

private struct PersistedShieldsState: Codable, Sendable {
    var subscriptions: [FilterSubscription]
    var allowedDomains: [String]
    var activeArtifact: CompiledRuleArtifact?
}

private struct FilterSourceSnapshot: Sendable {
    var subscription: FilterSubscription
    var text: String
}

private struct RustCompilerInput: Codable, Sendable {
    struct Subscription: Codable, Sendable {
        var id: String
        var text: String
        var format: String
    }

    var subscriptions: [Subscription]
}

private struct RustCompilerOutput: Codable, Sendable {
    var rulesJSON: String
    /// Notify-action mirror of the network-block rules. Compiled into a
    /// second `WKContentRuleList` alongside the blocker so the page
    /// receives `_content-blocker:notify-rule_` events when URLs match;
    /// the Shields content-world script forwards those to native so
    /// per-tab stats reflect real blocks instead of the static rule count.
    /// Optional for backward compatibility with older cached artifacts.
    var notifyRulesJSON: String?
    var totalRuleCount: Int
    var networkRuleCount: Int
    var cosmeticRuleCount: Int
}

@MainActor
final class TrackingProtectionManager: ObservableObject {
    weak var browserManager: BrowserManager?
    private(set) var isEnabled: Bool = false

    @Published private(set) var compilerStatus: ShieldsCompilerStatus = .idle
    @Published private(set) var filterSubscriptions: [FilterSubscription] = []
    @Published private(set) var activeArtifact: CompiledRuleArtifact?
    @Published private(set) var pageStatsByTabID: [UUID: PageBlockStats] = [:]
    @Published private(set) var pageStatesByTabID: [UUID: SiteProtectionState] = [:]

    private var installedRuleList: WKContentRuleList?
    /// Notify-action mirror of `installedRuleList`. Installed in parallel
    /// so each blocked URL fires a `_content-blocker:notify-rule_` event
    /// the Shields content-world script forwards to native for real-time
    /// per-tab block counting. Nil when the artifact predates Stage 2 or
    /// when the compiler returned no notify rules.
    private var installedNotifyList: WKContentRuleList?
    /// Single message handler instance shared across UCCs; lazy because we
    /// only want to register it once per shared/profile UCC.
    private lazy var notifyMessageHandler: ShieldsNotifyMessageHandler = {
        ShieldsNotifyMessageHandler(manager: self)
    }()
    /// Marker token in the Shields user script's source so we can detect
    /// duplicate installs across applyToSharedConfiguration calls.
    private static let notifyScriptMarker = "__SOCKET_SHIELDS_NOTIFY_LISTENER__"
    /// Name under which the Shields user script posts back to native.
    static let shieldsNotifyMessageName = "socketShieldsNotify"

    private let refreshInterval: TimeInterval = 24 * 60 * 60
    private let stateFileName = "shields-state.json"
    private let rulesFilePrefix = "compiled-rules-"
    private let helperBinaryName = "shields_compiler"

    /// Dedicated content world for Shields cosmetic injection. Keeps our
    /// MutationObserver + helper globals isolated from page JS and from
    /// extension content scripts (which run in their own per-extension
    /// isolated worlds). Without this, `window.__socketShieldsCleanupObserver`
    /// would land in the page world and could collide with site code.
    static let shieldsContentWorld = WKContentWorld.world(name: "SocketShields")
    private let thirdPartyCookieMarker = "document.requestStorageAccess = function()"
    private let genericCleanupSelectors: [String] = [
        // Cookie / consent banners
        "#onetrust-banner-sdk",
        ".ot-sdk-container",
        ".fc-consent-root",
        "[id*='cookie-consent']",
        "[class*='cookie-consent']",
        "[class*='cookie-banner']",
        "[class*='consent-banner']",
        "[aria-label='cookie banner']",
        "[data-testid*='cookie']",
        "[data-cookiebanner]",

        // Ad containers — ONLY unambiguous ad-tech markers. Broad
        // `[class*='ad-']` style patterns are deliberately omitted because
        // they false-positive on legitimate content (e.g. `class="add-to-cart"`,
        // `class="header"`, etc.).
        "[id^='div-gpt-ad']",          // Google Publisher Tags — always an ad
        "[id*='google_ads_iframe']",   // Google ads iframe
        "[data-ad-slot]",              // AdSense — required attribute on ad slots
        "[data-google-query-id]",      // GAM tracking attribute
        "ins.adsbygoogle",             // AdSense markup convention
        "[class*='adsbygoogle']",      // same

        // Iframes resolving to known ad-tech hostnames. Each pattern is a
        // unique-to-ads domain — no false-positive risk because no
        // first-party site embeds these hosts for legitimate content.
        "iframe[src*='googletagservices']",
        "iframe[src*='googlesyndication']",
        "iframe[src*='doubleclick.net']",
        "iframe[src*='googleads.g.doubleclick']",
        "iframe[src*='amazon-adsystem']",
        "iframe[src*='adservice.google']",
        "iframe[src*='adnxs.com']",
        "iframe[src*='pubmatic.com']",
        "iframe[src*='rubiconproject.com']",
        "iframe[src*='criteo.com']",
        "iframe[src*='taboola.com']",
        "iframe[src*='outbrain.com']",
    ]
    private let scriptletPolicy = ScriptletPolicy.conservative

    private var temporarilyDisabledTabs: [UUID: Date] = [:]
    private var allowedDomains: Set<String> = []

    private var thirdPartyCookieScript: WKUserScript {
        let js = """
        (function() {
          try {
            if (window.top === window) return;
            var ref = document.referrer || "";
            var thirdParty = false;
            try {
              var refHost = ref ? new URL(ref).hostname : null;
              thirdParty = !!refHost && refHost !== window.location.hostname;
            } catch (e) { thirdParty = false; }
            if (!thirdParty) return;

            Object.defineProperty(document, 'cookie', {
              configurable: false,
              enumerable: false,
              get: function() { return ''; },
              set: function(_) { return true; }
            });
            try {
              document.requestStorageAccess = function() { return Promise.reject(new DOMException('Blocked by Socket', 'NotAllowedError')); };
            } catch (e) {}
          } catch (e) {}
        })();
        """
        return WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }

    init() {
        loadPersistedState()
    }

    // MARK: - Public state

    var allowedDomainList: [String] {
        allowedDomains.sorted()
    }

    var allowedDomainCount: Int {
        allowedDomains.count
    }

    var isRuleListInstalled: Bool {
        installedRuleList != nil
    }

    func attach(browserManager: BrowserManager) {
        self.browserManager = browserManager
    }

    func isTemporarilyDisabled(tabId: UUID) -> Bool {
        if let until = temporarilyDisabledTabs[tabId] {
            if until > Date() { return true }
            temporarilyDisabledTabs.removeValue(forKey: tabId)
        }
        return false
    }

    func pageStats(for tab: Tab?) -> PageBlockStats? {
        guard let tab else { return nil }
        return pageStatsByTabID[tab.id]
    }

    func siteProtectionState(for tab: Tab?) -> SiteProtectionState? {
        guard let tab else { return nil }
        let host = resolvedHost(for: tab)
        let stats = pageStatsByTabID[tab.id] ?? makeEmptyStats(for: tab)
        return SiteProtectionState(
            host: host,
            isGlobalProtectionEnabled: isEnabled,
            isAllowlisted: isDomainAllowed(host),
            isTemporarilyRelaxed: isTemporarilyDisabled(tabId: tab.id),
            thirdPartyStorageRestricted: shouldApplyTracking(to: tab),
            scriptletMode: scriptletPolicy.mode,
            stats: stats,
            activeArtifact: activeArtifact
        )
    }

    // MARK: - Settings and exceptions

    func allowDomain(_ host: String, allowed: Bool = true) {
        let normalized = normalizeHost(host)
        guard !normalized.isEmpty else { return }
        if allowed {
            allowedDomains.insert(normalized)
        } else {
            allowedDomains.remove(normalized)
        }
        persistState()
        reapplyTrackingForAllTabs()
    }

    func isDomainAllowed(_ host: String?) -> Bool {
        let normalized = normalizeHost(host)
        guard !normalized.isEmpty else { return false }
        return allowedDomains.contains(normalized)
    }

    func clearAllowedDomains() {
        guard !allowedDomains.isEmpty else { return }
        allowedDomains.removeAll()
        persistState()
        reapplyTrackingForAllTabs()
    }

    func disableTemporarily(for tab: Tab, duration: TimeInterval, reload: Bool = true) {
        let until = Date().addingTimeInterval(duration)
        temporarilyDisabledTabs[tab.id] = until
        pageStatsByTabID[tab.id] = makeEmptyStats(for: tab, temporaryRelaxed: true)
        pageStatesByTabID[tab.id] = siteProtectionState(for: tab)

        if let wv = existingWebView(for: tab) {
            removeTracking(from: wv)
            if reload {
                wv.reloadFromOrigin()
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self, weak tab] in
            guard let self, let tab else { return }
            if let expiry = self.temporarilyDisabledTabs[tab.id], expiry <= Date() {
                self.temporarilyDisabledTabs.removeValue(forKey: tab.id)
                if reload {
                    self.refreshFor(tab: tab)
                } else if let wv = self.existingWebView(for: tab) {
                    if self.shouldApplyTracking(to: tab) {
                        self.applyTracking(to: wv)
                    } else {
                        self.removeTracking(from: wv)
                    }
                    self.pageStatsByTabID[tab.id] = self.makeEmptyStats(for: tab)
                    self.pageStatesByTabID[tab.id] = self.siteProtectionState(for: tab)
                }
            }
        }
    }

    func setSubscriptionEnabled(_ subscriptionID: String, enabled: Bool) {
        guard let index = filterSubscriptions.firstIndex(where: { $0.id == subscriptionID }) else { return }
        filterSubscriptions[index].isEnabled = enabled
        filterSubscriptions[index].lastErrorDescription = nil
        persistState()
        Task { @MainActor in
            await refreshListsAndRecompile(forceRemoteUpdate: false)
        }
    }

    func restoreDefaultSubscriptions() {
        filterSubscriptions = Self.defaultSubscriptions()
        persistState()
        Task { @MainActor in
            await refreshListsAndRecompile(forceRemoteUpdate: false)
        }
    }

    // MARK: - Lifecycle

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else {
            if enabled {
                Task { @MainActor in
                    await ensurePreparedArtifact(forceRemoteUpdate: false)
                }
            }
            return
        }

        isEnabled = enabled
        Task { @MainActor in
            if enabled {
                await ensurePreparedArtifact(forceRemoteUpdate: false)
                applyToSharedConfiguration()
                applyToExistingWebViews()
            } else {
                removeFromSharedConfiguration()
                removeFromExistingWebViews()
            }
        }
    }

    func configureNewWebView(_ webView: WKWebView, for tab: Tab) {
        // New popup/OAuth webviews can inherit an opener configuration that
        // already has rule lists and storage restrictions attached. Remove
        // those synchronously when protections should not apply so the first
        // navigation request is not made under the wrong policy.
        if !shouldApplyTracking(to: tab) {
            removeTracking(from: webView)
            pageStatesByTabID[tab.id] = siteProtectionState(for: tab)
            return
        }

        Task { @MainActor [weak self, weak webView] in
            guard let self, let webView else { return }

            if self.isEnabled && self.installedRuleList == nil {
                await self.ensurePreparedArtifact(forceRemoteUpdate: false)
            }

            if self.shouldApplyTracking(to: tab) {
                self.applyTracking(to: webView)
            } else {
                self.removeTracking(from: webView)
            }
        }
    }

    func refreshListsAndRecompile(forceRemoteUpdate: Bool = true) async {
        await ensurePreparedArtifact(forceRemoteUpdate: forceRemoteUpdate, alwaysRefresh: true)
    }

    func handleDidStartNavigation(for tab: Tab) {
        pageStatsByTabID[tab.id] = makeEmptyStats(for: tab)
        pageStatesByTabID[tab.id] = siteProtectionState(for: tab)
    }

    func handleDidFinishNavigation(for tab: Tab, webView: WKWebView) {
        let shouldRestrict = shouldApplyTracking(to: tab)
        var stats = PageBlockStats(
            networkRuleCount: activeArtifact?.networkRuleCount ?? 0,
            cosmeticRuleCount: activeArtifact?.cosmeticRuleCount ?? 0,
            hiddenElementCount: 0,
            scriptletActionCount: 0,
            thirdPartyStorageRestricted: shouldRestrict,
            temporaryRelaxed: isTemporarilyDisabled(tabId: tab.id),
            allowlisted: isDomainAllowed(webView.url?.host ?? tab.url.host)
        )

        pageStatsByTabID[tab.id] = stats
        pageStatesByTabID[tab.id] = siteProtectionState(for: tab)

        guard shouldRestrict, scriptletPolicy.allows(host: webView.url?.host ?? tab.url.host) else {
            return
        }

        Task { @MainActor [weak self, weak webView] in
            guard let self, let webView else { return }
            let hiddenCount = await self.applyGenericCleanupScript(to: webView)
            guard self.pageStatsByTabID[tab.id] != nil else { return }
            stats.hiddenElementCount = hiddenCount
            stats.scriptletActionCount = hiddenCount > 0 ? 1 : 0
            self.pageStatsByTabID[tab.id] = stats
            self.pageStatesByTabID[tab.id] = self.siteProtectionState(for: tab)
        }
    }

    func handleNavigationFailure(for tab: Tab) {
        pageStatsByTabID[tab.id] = makeEmptyStats(for: tab)
        pageStatesByTabID[tab.id] = siteProtectionState(for: tab)
    }

    func refreshFor(tab: Tab) {
        guard let webView = existingWebView(for: tab) else { return }
        if shouldApplyTracking(to: tab) {
            applyTracking(to: webView)
        } else {
            removeTracking(from: webView)
        }
        pageStatsByTabID[tab.id] = makeEmptyStats(for: tab)
        pageStatesByTabID[tab.id] = siteProtectionState(for: tab)
        webView.reloadFromOrigin()
    }

    // MARK: - Preparation and compilation

    private func ensurePreparedArtifact(
        forceRemoteUpdate: Bool,
        alwaysRefresh: Bool = false
    ) async {
        if let activeArtifact, !alwaysRefresh {
            await installArtifactIfNeeded(activeArtifact)
            if !shouldRefreshRemoteLists() && installedRuleList != nil {
                compilerStatus = .ready("Shields Ready")
                return
            }
        } else if let persistedArtifact = activeArtifact {
            await installArtifactIfNeeded(persistedArtifact)
        } else {
            await installBuiltInFallbackIfNeeded()
        }

        if alwaysRefresh || forceRemoteUpdate || shouldRefreshRemoteLists() {
            compilerStatus = .preparing("Refreshing Lists")
            let sources = await resolveEnabledSources(forceRemoteUpdate: forceRemoteUpdate || alwaysRefresh)
            if let artifact = await compileArtifact(from: sources) {
                activeArtifact = artifact
                persistState()
                await installArtifactIfNeeded(artifact)
                compilerStatus = .ready("Shields Ready")
            } else {
                compilerStatus = .fallback("Using Built-In Fallback")
                await installBuiltInFallbackIfNeeded()
            }
        }
    }

    private func shouldRefreshRemoteLists() -> Bool {
        let now = Date()
        return filterSubscriptions.contains { subscription in
            guard subscription.isEnabled, subscription.source == .remote else { return false }
            guard let lastUpdatedAt = subscription.lastUpdatedAt else { return true }
            return now.timeIntervalSince(lastUpdatedAt) >= refreshInterval
        }
    }

    private func resolveEnabledSources(forceRemoteUpdate: Bool) async -> [FilterSourceSnapshot] {
        if filterSubscriptions.isEmpty {
            filterSubscriptions = Self.defaultSubscriptions()
        }

        var resolvedSources: [FilterSourceSnapshot] = []

        for index in filterSubscriptions.indices {
            let subscription = filterSubscriptions[index]
            guard subscription.isEnabled else { continue }

            switch subscription.source {
            case .bundled:
                resolvedSources.append(
                    FilterSourceSnapshot(
                        subscription: subscription,
                        text: Self.bundledFilterListText(for: subscription.id)
                    )
                )
            case .remote:
                if let cached = loadCachedListText(for: subscription.id),
                   !forceRemoteUpdate,
                   let updatedAt = subscription.lastUpdatedAt,
                   Date().timeIntervalSince(updatedAt) < refreshInterval {
                    resolvedSources.append(
                        FilterSourceSnapshot(subscription: subscription, text: cached)
                    )
                    continue
                }

                do {
                    let text = try await fetchListText(for: subscription)
                    filterSubscriptions[index].lastUpdatedAt = Date()
                    filterSubscriptions[index].checksum = sha256(text)
                    filterSubscriptions[index].lastErrorDescription = nil
                    saveCachedListText(text, for: subscription.id)
                    resolvedSources.append(
                        FilterSourceSnapshot(
                            subscription: filterSubscriptions[index],
                            text: text
                        )
                    )
                } catch {
                    filterSubscriptions[index].lastErrorDescription = error.localizedDescription
                    if let cached = loadCachedListText(for: subscription.id) {
                        resolvedSources.append(
                            FilterSourceSnapshot(
                                subscription: filterSubscriptions[index],
                                text: cached
                            )
                        )
                    }
                }
            }
        }

        persistState()
        return resolvedSources
    }

    private func compileArtifact(from sources: [FilterSourceSnapshot]) async -> CompiledRuleArtifact? {
        guard !sources.isEmpty else { return nil }

        let digestInput = sources
            .map { "\($0.subscription.id):\(sha256($0.text))" }
            .joined(separator: "|")
        let sourceDigest = sha256(digestInput)

        if let activeArtifact,
           activeArtifact.sourceDigest == sourceDigest,
           let rulesJSON = loadRulesJSON(for: activeArtifact),
           !rulesJSON.isEmpty {
            compilerStatus = .ready("Shields Ready")
            return activeArtifact
        }

        let unsupportedRuleCount = sources.reduce(0) { partial, source in
            partial + Self.estimatedUnsupportedRuleCount(in: source.text)
        }
        let scriptletCandidateCount = sources.reduce(0) { partial, source in
            partial + Self.estimatedScriptletCount(in: source.text)
        }

        if let rustOutput = await compileWithRustHelper(sources: sources) {
            let digestPrefix = sourceDigest.prefix(12)
            let rulesFileName = "\(rulesFilePrefix)\(digestPrefix).json"
            saveRulesJSON(rustOutput.rulesJSON, fileName: rulesFileName)

            // Save the notify mirror if the compiler emitted one (new Rust
            // binaries) and it contains at least one rule.
            var notifyRulesFileName: String? = nil
            if let notifyJSON = rustOutput.notifyRulesJSON,
               !notifyJSON.isEmpty, notifyJSON != "[]" {
                let fileName = "\(rulesFilePrefix)notify-\(digestPrefix).json"
                saveRulesJSON(notifyJSON, fileName: fileName)
                notifyRulesFileName = fileName
            }

            return CompiledRuleArtifact(
                identifier: "SocketTrackingBlocker-\(digestPrefix)",
                sourceDigest: sourceDigest,
                rulesFileName: rulesFileName,
                notifyRulesFileName: notifyRulesFileName,
                compilerName: "adblock-rust",
                generatedAt: Date(),
                totalRuleCount: rustOutput.totalRuleCount,
                networkRuleCount: rustOutput.networkRuleCount,
                cosmeticRuleCount: rustOutput.cosmeticRuleCount,
                scriptletCandidateCount: scriptletCandidateCount,
                unsupportedRuleCount: unsupportedRuleCount
            )
        }

        let rulesJSON = Self.makeFallbackRuleJSON()
        let rulesFileName = "\(rulesFilePrefix)\(sourceDigest.prefix(12)).json"
        saveRulesJSON(rulesJSON, fileName: rulesFileName)
        return CompiledRuleArtifact(
            identifier: "SocketTrackingBlocker-\(sourceDigest.prefix(12))",
            sourceDigest: sourceDigest,
            rulesFileName: rulesFileName,
            notifyRulesFileName: nil,
            compilerName: "built-in",
            generatedAt: Date(),
            totalRuleCount: Self.defaultNetworkHosts.count + Self.defaultCosmeticSelectors.count + 1,
            networkRuleCount: Self.defaultNetworkHosts.count + 1,
            cosmeticRuleCount: Self.defaultCosmeticSelectors.count,
            scriptletCandidateCount: scriptletCandidateCount,
            unsupportedRuleCount: unsupportedRuleCount
        )
    }

    private func installBuiltInFallbackIfNeeded() async {
        let sourceDigest = sha256("built-in-fallback")
        let rulesFileName = "\(rulesFilePrefix)\(sourceDigest.prefix(12)).json"
        if loadRulesJSON(fileName: rulesFileName) == nil {
            saveRulesJSON(Self.makeFallbackRuleJSON(), fileName: rulesFileName)
        }

        let fallbackArtifact = CompiledRuleArtifact(
            identifier: "SocketTrackingBlocker-\(sourceDigest.prefix(12))",
            sourceDigest: sourceDigest,
            rulesFileName: rulesFileName,
            notifyRulesFileName: nil,
            compilerName: "built-in",
            generatedAt: Date(),
            totalRuleCount: Self.defaultNetworkHosts.count + Self.defaultCosmeticSelectors.count + 1,
            networkRuleCount: Self.defaultNetworkHosts.count + 1,
            cosmeticRuleCount: Self.defaultCosmeticSelectors.count,
            scriptletCandidateCount: 0,
            unsupportedRuleCount: 0
        )
        activeArtifact = fallbackArtifact
        persistState()
        await installArtifactIfNeeded(fallbackArtifact)
    }

    private func installArtifactIfNeeded(_ artifact: CompiledRuleArtifact) async {
        guard let rulesJSON = loadRulesJSON(for: artifact), !rulesJSON.isEmpty else { return }
        guard let store = WKContentRuleListStore.default() else { return }

        // Main blocker list ----------------------------------------------------
        if let existing = await withCheckedContinuation({ (cont: CheckedContinuation<WKContentRuleList?, Never>) in
            store.lookUpContentRuleList(forIdentifier: artifact.identifier) { list, _ in
                cont.resume(returning: list)
            }
        }) {
            installedRuleList = existing
        } else {
            let compiled = await withCheckedContinuation { (cont: CheckedContinuation<WKContentRuleList?, Never>) in
                store.compileContentRuleList(
                    forIdentifier: artifact.identifier,
                    encodedContentRuleList: rulesJSON
                ) { list, error in
                    if let error {
                        print("[Shields] Rule compile error: \(error.localizedDescription)")
                    }
                    cont.resume(returning: list)
                }
            }
            if let compiled { installedRuleList = compiled }
        }

        // Notify-mirror list (Stage 2) ----------------------------------------
        // Compiled separately so each blocked URL fires a JS event we can
        // count in real time. Cached under a sibling identifier so it
        // stays in sync with the artifact digest.
        if let notifyFile = artifact.notifyRulesFileName,
           let notifyJSON = loadRulesJSON(fileName: notifyFile),
           !notifyJSON.isEmpty, notifyJSON != "[]" {
            let notifyId = "\(artifact.identifier)-notify"
            if let existing = await withCheckedContinuation({ (cont: CheckedContinuation<WKContentRuleList?, Never>) in
                store.lookUpContentRuleList(forIdentifier: notifyId) { list, _ in
                    cont.resume(returning: list)
                }
            }) {
                installedNotifyList = existing
            } else {
                let compiled = await withCheckedContinuation { (cont: CheckedContinuation<WKContentRuleList?, Never>) in
                    store.compileContentRuleList(
                        forIdentifier: notifyId,
                        encodedContentRuleList: notifyJSON
                    ) { list, error in
                        if let error {
                            print("[Shields] Notify-mirror compile error: \(error.localizedDescription)")
                        }
                        cont.resume(returning: list)
                    }
                }
                if let compiled { installedNotifyList = compiled }
            }
        } else {
            installedNotifyList = nil
        }
    }

    // MARK: - Shared configuration

    private func applyToSharedConfiguration() {
        guard let list = installedRuleList else { return }
        let configuration = BrowserConfiguration.shared.webViewConfiguration
        let controller = configuration.userContentController
        controller.removeAllContentRuleLists()
        controller.add(list)
        if let notifyList = installedNotifyList {
            controller.add(notifyList)
        }
        if !controller.userScripts.contains(where: { $0.source.contains(thirdPartyCookieMarker) }) {
            controller.addUserScript(thirdPartyCookieScript)
        }
        installShieldsNotifyHooks(on: controller)
    }

    private func removeFromSharedConfiguration() {
        let configuration = BrowserConfiguration.shared.webViewConfiguration
        let controller = configuration.userContentController
        controller.removeAllContentRuleLists()
        let remaining = controller.userScripts.filter {
            !$0.source.contains(thirdPartyCookieMarker)
            && !$0.source.contains(Self.notifyScriptMarker)
        }
        controller.removeAllUserScripts()
        remaining.forEach { controller.addUserScript($0) }
        // Remove our message handler if it was registered.
        controller.removeScriptMessageHandler(forName: Self.shieldsNotifyMessageName)
    }

    private func applyToExistingWebViews() {
        guard let browserManager else { return }
        for tab in browserManager.tabManager.allTabs() {
            guard let webView = existingWebView(for: tab) else { continue }
            if shouldApplyTracking(to: tab) {
                applyTracking(to: webView)
            } else {
                removeTracking(from: webView)
            }
            pageStatesByTabID[tab.id] = siteProtectionState(for: tab)
            webView.reloadFromOrigin()
        }
    }

    private func removeFromExistingWebViews() {
        guard let browserManager else { return }
        for tab in browserManager.tabManager.allTabs() {
            guard let webView = existingWebView(for: tab) else { continue }
            removeTracking(from: webView)
            pageStatsByTabID[tab.id] = makeEmptyStats(for: tab)
            pageStatesByTabID[tab.id] = siteProtectionState(for: tab)
            webView.reloadFromOrigin()
        }
    }

    private func reapplyTrackingForAllTabs() {
        guard let browserManager else { return }
        for tab in browserManager.tabManager.allTabs() {
            refreshFor(tab: tab)
        }
    }

    private func shouldApplyTracking(to tab: Tab) -> Bool {
        if !isEnabled { return false }
        if isTemporarilyDisabled(tabId: tab.id) { return false }
        if isDomainAllowed(resolvedHost(for: tab)) { return false }
        if tab.isOAuthFlow { return false }
        return true
    }

    private func applyTracking(to webView: WKWebView) {
        guard let installedRuleList else { return }
        let controller = webView.configuration.userContentController
        controller.removeAllContentRuleLists()
        controller.add(installedRuleList)
        if let notifyList = installedNotifyList {
            controller.add(notifyList)
        }
        if !controller.userScripts.contains(where: { $0.source.contains(thirdPartyCookieMarker) }) {
            controller.addUserScript(thirdPartyCookieScript)
        }
        installShieldsNotifyHooks(on: controller)
    }

    private func removeTracking(from webView: WKWebView) {
        let controller = webView.configuration.userContentController
        controller.removeAllContentRuleLists()
        let remaining = controller.userScripts.filter {
            !$0.source.contains(thirdPartyCookieMarker)
            && !$0.source.contains(Self.notifyScriptMarker)
        }
        controller.removeAllUserScripts()
        remaining.forEach { controller.addUserScript($0) }
        controller.removeScriptMessageHandler(forName: Self.shieldsNotifyMessageName)
    }

    // MARK: - Generic cleanup / telemetry

    private func applyGenericCleanupScript(to webView: WKWebView) async -> Int {
        guard scriptletPolicy.mode != .disabled else { return 0 }
        guard let selectorsData = try? JSONEncoder().encode(genericCleanupSelectors),
              let selectorsJSON = String(data: selectorsData, encoding: .utf8) else {
            return 0
        }

        let script = """
        (function() {
          try {
            const selectors = \(selectorsJSON);
            const hasSelectors = Array.isArray(selectors) && selectors.length > 0;

            if (window.__socketShieldsCleanupObserver) {
              try { window.__socketShieldsCleanupObserver.disconnect(); } catch (e) {}
            }

            const seen = new WeakSet();
            let hiddenCount = 0;

            const hideNode = (node) => {
              if (!node || seen.has(node)) return;
              seen.add(node);
              hiddenCount += 1;
              try {
                node.style.setProperty('display', 'none', 'important');
                node.style.setProperty('visibility', 'hidden', 'important');
                node.setAttribute('data-socket-shields-hidden', '1');
              } catch (e) {}
            };

            const applyCleanup = () => {
              if (hasSelectors) {
                selectors.forEach((selector) => {
                  try {
                    document.querySelectorAll(selector).forEach(hideNode);
                  } catch (e) {}
                });
              }
              return hiddenCount;
            };

            // Element-collapse pass: when WKContentRuleList kills a network
            // request, the placeholder iframe/img is still in the DOM and
            // reserves layout space (the visible white box on ad-heavy
            // pages). Walk every iframe/img that loaded with no content,
            // climb to its container, and hide the whole thing — same
            // behaviour Brave/uBlock Origin call "element collapsing".
            const COLLAPSE_THRESHOLD_PX = 20;
            // Strict ad-container test — only matches markers that are
            // *exclusively* used for advertising containers. We deliberately
            // avoid matching loose substrings like 'banner' or 'promo'
            // because they appear on legitimate site furniture (hero
            // banners, promotion blocks). False-positives here would hide
            // real content; we'd rather leave a tiny bit of whitespace.
            const adAttrPattern = /(?:^|[\\s_-])(?:advertisement|advertising|advertorial|adsense|adsbygoogle|adslot|adunit|adcontainer|adwrapper)(?:$|[\\s_-])|^div-gpt-ad|google_ads_iframe/;
            const isLikelyAdContainer = (el) => {
              if (!el || el === document.body || el === document.documentElement) return false;
              const cls = (el.className && typeof el.className === 'string') ? el.className.toLowerCase() : '';
              const id = (el.id || '').toLowerCase();
              if (adAttrPattern.test(cls)) return true;
              if (adAttrPattern.test(id)) return true;
              if (el.hasAttribute && (el.hasAttribute('data-ad-slot') || el.hasAttribute('data-google-query-id'))) return true;
              return false;
            };
            const findAdContainer = (start) => {
              // Walk up looking for an UNAMBIGUOUS ad container. If we
              // can't find one within 4 hops, return null and leave the
              // wrapper alone. This keeps empty-but-legitimate embeds from
              // collapsing page structure.
              let el = start;
              for (let depth = 0; depth < 5 && el && el !== document.body; depth += 1) {
                if (isLikelyAdContainer(el)) return el;
                el = el.parentElement;
              }
              return null;
            };
            // Iframe `src` patterns we treat as definitively-an-ad even when
            // we can't peek at their contentDocument (cross-origin). When
            // WKContentRuleList kills the request, the iframe element
            // stays in the DOM with these src strings — collapsing the
            // wrapper reclaims the layout space.
            const AD_HOST_PATTERN = /(googletagservices|googlesyndication|doubleclick\\.net|googleads\\.g\\.doubleclick|amazon-adsystem|adservice\\.google|adnxs\\.com|pubmatic\\.com|rubiconproject\\.com|criteo|taboola|outbrain|adsystem|adform)/i;

            const collapseEmpties = () => {
              try {
                document.querySelectorAll('iframe, img').forEach((el) => {
                  if (seen.has(el)) return;
                  // Skip elements with negligible footprint.
                  const r = el.getBoundingClientRect();
                  if (r.width < COLLAPSE_THRESHOLD_PX && r.height < COLLAPSE_THRESHOLD_PX) return;

                  const adContainer = findAdContainer(el);
                  let blocked = false;
                  let collapseTarget = adContainer;
                  if (el.tagName === 'IMG') {
                    // Broken images are only safe to collapse when they're
                    // inside an explicitly ad-marked container.
                    blocked = !!adContainer && el.complete && el.naturalWidth === 0 && el.naturalHeight === 0;
                  } else if (el.tagName === 'IFRAME') {
                    const src = (el.getAttribute('src') || '').trim();
                    // 1) Known ad-tech host in src — collapse regardless of
                    //    cross-origin opacity.
                    if (AD_HOST_PATTERN.test(src)) {
                      blocked = true;
                      collapseTarget = adContainer || el;
                    } else {
                      // 2) Same-origin / no-src iframes: only collapse when
                      //    an explicit ad marker exists nearby. Blank iframes
                      //    are common in legitimate widgets and login flows.
                      if (adContainer) {
                        try {
                          blocked = (el.contentDocument && !el.contentDocument.body)
                                 || src === '' || src === 'about:blank';
                        } catch (e) {
                          // Cross-origin without an ad-host match — leave alone.
                          blocked = false;
                        }
                      }
                    }
                  }

                  if (!blocked || !collapseTarget) return;
                  hideNode(collapseTarget);
                });
              } catch (e) {}
            };

            applyCleanup();
            collapseEmpties();
            const observer = new MutationObserver(() => {
              applyCleanup();
              collapseEmpties();
            });
            observer.observe(document.documentElement || document.body, {
              subtree: true,
              childList: true,
              attributes: false
            });
            window.__socketShieldsCleanupObserver = observer;
            return hiddenCount;
          } catch (e) {
            return 0;
          }
        })();
        """

        // Run in our dedicated Shields content world so the helper globals
        // (`__socketShieldsCleanupObserver`) and the MutationObserver don't
        // leak into the page world or any extension's isolated world.
        return await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(
                script,
                in: nil,
                in: Self.shieldsContentWorld
            ) { result in
                switch result {
                case .success(let value):
                    if let n = value as? NSNumber {
                        continuation.resume(returning: n.intValue)
                    } else if let i = value as? Int {
                        continuation.resume(returning: i)
                    } else {
                        continuation.resume(returning: 0)
                    }
                case .failure:
                    continuation.resume(returning: 0)
                }
            }
        }
    }

    private func makeEmptyStats(
        for tab: Tab,
        temporaryRelaxed: Bool? = nil
    ) -> PageBlockStats {
        // networkRuleCount and cosmeticRuleCount reset to 0 per navigation;
        // they're real-time counters now, populated by the notify handler
        // (`handleShieldsNotify`) for network blocks and by
        // `applyGenericCleanupScript` for cosmetic hides. The artifact's
        // total rule count is surfaced separately as the "rules loaded"
        // figure in Settings — it's not a per-page metric.
        PageBlockStats(
            networkRuleCount: 0,
            cosmeticRuleCount: 0,
            hiddenElementCount: 0,
            scriptletActionCount: 0,
            thirdPartyStorageRestricted: shouldApplyTracking(to: tab),
            temporaryRelaxed: temporaryRelaxed ?? isTemporarilyDisabled(tabId: tab.id),
            allowlisted: isDomainAllowed(resolvedHost(for: tab))
        )
    }

    private func resolvedHost(for tab: Tab) -> String? {
        existingWebView(for: tab)?.url?.host ?? tab.url.host
    }

    private func existingWebView(for tab: Tab) -> WKWebView? {
        if let webView = tab.assignedWebView ?? tab.existingWebView {
            return webView
        }

        guard let browserManager, let windowRegistry = browserManager.windowRegistry else {
            return nil
        }

        for (_, windowState) in windowRegistry.windows {
            if let webView = browserManager.getWebView(for: tab.id, in: windowState.id) {
                return webView
            }
        }

        return nil
    }

    // MARK: - Persistence

    private func loadPersistedState() {
        if let data = try? Data(contentsOf: stateFileURL()),
           let decoded = try? JSONDecoder().decode(PersistedShieldsState.self, from: data) {
            filterSubscriptions = decoded.subscriptions
            allowedDomains = Set(decoded.allowedDomains)
            activeArtifact = decoded.activeArtifact
        } else {
            filterSubscriptions = Self.defaultSubscriptions()
            allowedDomains = []
        }
    }

    private func persistState() {
        let state = PersistedShieldsState(
            subscriptions: filterSubscriptions,
            allowedDomains: allowedDomains.sorted(),
            activeArtifact: activeArtifact
        )
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: stateFileURL(), options: .atomic)
    }

    private func saveCachedListText(_ text: String, for subscriptionID: String) {
        try? text.write(to: cachedListURL(for: subscriptionID), atomically: true, encoding: .utf8)
    }

    private func loadCachedListText(for subscriptionID: String) -> String? {
        try? String(contentsOf: cachedListURL(for: subscriptionID), encoding: .utf8)
    }

    private func saveRulesJSON(_ rulesJSON: String, fileName: String) {
        try? rulesJSON.write(to: rulesFileURL(fileName: fileName), atomically: true, encoding: .utf8)
    }

    private func loadRulesJSON(for artifact: CompiledRuleArtifact) -> String? {
        loadRulesJSON(fileName: artifact.rulesFileName)
    }

    private func loadRulesJSON(fileName: String) -> String? {
        try? String(contentsOf: rulesFileURL(fileName: fileName), encoding: .utf8)
    }

    private func stateFileURL() -> URL {
        shieldsDirectoryURL().appendingPathComponent(stateFileName, isDirectory: false)
    }

    private func cachedListURL(for subscriptionID: String) -> URL {
        shieldsDirectoryURL()
            .appendingPathComponent("lists", isDirectory: true)
            .appendingPathComponent("\(subscriptionID).txt", isDirectory: false)
    }

    private func rulesFileURL(fileName: String) -> URL {
        shieldsDirectoryURL()
            .appendingPathComponent("artifacts", isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    private func shieldsDirectoryURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let bundleID = Bundle.main.bundleIdentifier ?? "Socket"
        let directory = base.appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("Shields", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        try? FileManager.default.createDirectory(
            at: directory.appendingPathComponent("lists", isDirectory: true),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try? FileManager.default.createDirectory(
            at: directory.appendingPathComponent("artifacts", isDirectory: true),
            withIntermediateDirectories: true,
            attributes: nil
        )
        return directory
    }

    // MARK: - Remote updates

    private func fetchListText(for subscription: FilterSubscription) async throws -> String {
        guard let url = subscription.remoteURL else {
            throw NSError(domain: "Shields", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing list URL"])
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            throw NSError(
                domain: "Shields",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "List request failed with HTTP \(httpResponse.statusCode)"]
            )
        }
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            throw NSError(domain: "Shields", code: -2, userInfo: [NSLocalizedDescriptionKey: "List response was empty"])
        }
        return text
    }

    // MARK: - Rust helper

    private func compileWithRustHelper(sources: [FilterSourceSnapshot]) async -> RustCompilerOutput? {
        compilerStatus = .preparing("Compiling Rules")
        let input = RustCompilerInput(
            subscriptions: sources.map { source in
                RustCompilerInput.Subscription(
                    id: source.subscription.id,
                    text: source.text,
                    format: source.subscription.format.rawValue
                )
            }
        )

        return await Task.detached(priority: .utility) {
            // Preferred path: in-process FFI into the shields_compiler static
            // library. Same JSON contract as the subprocess path, no cargo
            // at runtime, no Process spawn. Falls back to the subprocess
            // path on ShieldsEngine error so operator mistakes (missing
            // static lib, stale build) don't take Shields offline entirely.
            do {
                let inputData = try JSONEncoder().encode(input)
                guard let inputJSON = String(data: inputData, encoding: .utf8) else {
                    throw ShieldsEngineError.invalidInputEncoding
                }
                let result = try ShieldsEngine.shared.compile(rawJSON: inputJSON)
                return RustCompilerOutput(
                    rulesJSON: result.rulesJSON,
                    notifyRulesJSON: result.notifyRulesJSON,
                    totalRuleCount: result.totalRuleCount,
                    networkRuleCount: result.networkRuleCount,
                    cosmeticRuleCount: result.cosmeticRuleCount
                )
            } catch {
                print("[Shields] in-process FFI failed (\(error.localizedDescription)); falling back to subprocess")
            }

            do {
                let executableURL = try Self.ensureRustHelperBinary()
                let inputData = try JSONEncoder().encode(input)
                let outputData = try Self.runProcess(
                    executableURL: executableURL,
                    arguments: [],
                    stdin: inputData
                )
                return try JSONDecoder().decode(RustCompilerOutput.self, from: outputData)
            } catch {
                print("[Shields] Rust helper unavailable: \(error.localizedDescription)")
                return nil
            }
        }.value
    }

    nonisolated private static func ensureRustHelperBinary() throws -> URL {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let manifestURL = repoRoot.appendingPathComponent("Support/ShieldsCompiler/Cargo.toml")
        let binaryURL = repoRoot.appendingPathComponent("Support/ShieldsCompiler/target/release/shields_compiler")

        if FileManager.default.fileExists(atPath: binaryURL.path) {
            return binaryURL
        }

        _ = try runProcess(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["cargo", "build", "--manifest-path", manifestURL.path, "--release"],
            stdin: nil
        )

        guard FileManager.default.fileExists(atPath: binaryURL.path) else {
            throw NSError(
                domain: "Shields",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Rust helper binary was not produced"]
            )
        }

        return binaryURL
    }

    nonisolated private static func runProcess(
        executableURL: URL,
        arguments: [String],
        stdin: Data?
    ) throws -> Data {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        if stdin != nil {
            let stdinPipe = Pipe()
            process.standardInput = stdinPipe
            try process.run()
            stdinPipe.fileHandleForWriting.write(stdin!)
            try? stdinPipe.fileHandleForWriting.close()
        } else {
            try process.run()
        }

        process.waitUntilExit()

        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus != 0 {
            let errorText = String(data: errorData, encoding: .utf8) ?? "Unknown process error"
            throw NSError(
                domain: "Shields",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: errorText]
            )
        }
        return output
    }

    // MARK: - Defaults and helpers

    private static let defaultNetworkHosts: [String] = [
        "google-analytics.com",
        "analytics.google.com",
        "googletagmanager.com",
        "googletagservices.com",
        "doubleclick.net",
        "googlesyndication.com",
        "googleadservices.com",
        "2mdn.net",
        "adnxs.com",
        "adsrvr.org",
        "advertising.com",
        "amazon-adsystem.com",
        "casalemedia.com",
        "criteo.com",
        "criteo.net",
        "facebook.net",
        "connect.facebook.net",
        "graph.facebook.com",
        "scorecardresearch.com",
        "outbrain.com",
        "taboola.com",
        "pubmatic.com",
        "rubiconproject.com",
        "openx.net",
        "doubleverify.com",
        "moatads.com",
        "quantserve.com",
        "zedo.com",
        "teads.tv",
        "lijit.com",
        "sharethrough.com",
        "hotjar.com",
        "segment.io",
        "cdn.segment.com",
        "mixpanel.com",
        "sentry.io",
        "optimizely.com",
        "newrelic.com",
        "clarity.ms",
        "branch.io",
        "onesignal.com",
        "appsflyer.com",
        "adjust.com",
        "usefathom.com",
        "mathtag.com"
    ]

    private static let defaultCosmeticSelectors: [String] = [
        "[id^='div-gpt-ad']",
        "[id*='google_ads']",
        "[id*='ad-slot']",
        "[class^='ad-']",
        "[class^='ads-']",
        "[class*='advert']",
        "[data-ad]",
        "[data-ad-container]",
        "[data-ad-unit]",
        "[data-testid='ad']",
        "[aria-label='advertisement']",
        "[aria-label='Advertisement']",
        "iframe[src*='doubleclick.net']",
        "iframe[src*='googlesyndication.com']",
        "iframe[id*='google_ads']",
        ".adsbygoogle",
        ".adsbox",
        ".ad-banner",
        ".ad-container",
        ".ad-wrapper",
        ".advertisement",
        ".advert",
        ".sponsored-content",
        ".promotedlink",
        ".taboola",
        ".outbrain",
        ".dfp-ad"
    ]

    private static func bundledFilterListText(for subscriptionID: String) -> String {
        switch subscriptionID {
        case "socket-baseline":
            return makeBundledBaselineList()
        default:
            return makeBundledBaselineList()
        }
    }

    private static func makeBundledBaselineList() -> String {
        let networkRules = defaultNetworkHosts.map { "||\($0)^" }
        let cosmeticRules = defaultCosmeticSelectors.map { "##\($0)" }
        return ([
            "! Title: Socket Baseline",
            "! Homepage: https://github.com/socket-browser/socket"
        ] + networkRules + cosmeticRules).joined(separator: "\n")
    }

    private static func defaultSubscriptions() -> [FilterSubscription] {
        [
            FilterSubscription(
                id: "socket-baseline",
                title: "Socket Baseline",
                category: .core,
                source: .bundled,
                format: .standard,
                remoteURLString: nil,
                isEnabled: true,
                checksum: nil,
                lastUpdatedAt: Date(),
                lastErrorDescription: nil
            ),
            FilterSubscription(
                id: "easylist",
                title: "EasyList",
                category: .core,
                source: .remote,
                format: .standard,
                remoteURLString: "https://easylist.to/easylist/easylist.txt",
                isEnabled: true,
                checksum: nil,
                lastUpdatedAt: nil,
                lastErrorDescription: nil
            ),
            FilterSubscription(
                id: "easyprivacy",
                title: "EasyPrivacy",
                category: .core,
                source: .remote,
                format: .standard,
                remoteURLString: "https://easylist.to/easylist/easyprivacy.txt",
                isEnabled: true,
                checksum: nil,
                lastUpdatedAt: nil,
                lastErrorDescription: nil
            ),
            FilterSubscription(
                id: "easylist-germany",
                title: "EasyList Germany",
                category: .regional,
                source: .remote,
                format: .standard,
                remoteURLString: "https://easylist.to/easylistgermany/easylistgermany.txt",
                isEnabled: false,
                checksum: nil,
                lastUpdatedAt: nil,
                lastErrorDescription: nil
            )
        ]
    }

    private static func estimatedScriptletCount(in text: String) -> Int {
        text.split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { $0.contains("##+js(") || $0.contains("#%#//scriptlet(") }
            .count
    }

    private static func estimatedUnsupportedRuleCount(in text: String) -> Int {
        text.split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { line in
                line.contains("##+js(")
                    || line.contains("#?#")
                    || line.contains("#@?#")
                    || line.contains("$removeparam")
                    || line.contains("$csp")
                    || line.contains("$redirect")
                    || line.contains("$rewrite")
            }
            .count
    }

    private static func makeFallbackRuleJSON() -> String {
        var rules: [[String: Any]] = [[
            "trigger": [
                "url-filter": ".*",
                "load-type": ["third-party"]
            ],
            "action": ["type": "block-cookies"]
        ]]

        for host in defaultNetworkHosts {
            rules.append([
                "trigger": [
                    "url-filter": "https?://([^/]+\\.)?\(NSRegularExpression.escapedPattern(for: host))/.*",
                    "load-type": ["third-party"]
                ],
                "action": ["type": "block"]
            ])
        }

        for selector in defaultCosmeticSelectors {
            rules.append([
                "trigger": ["url-filter": ".*"],
                "action": [
                    "type": "css-display-none",
                    "selector": selector
                ]
            ])
        }

        guard let data = try? JSONSerialization.data(withJSONObject: rules, options: []),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }

    private func normalizeHost(_ host: String?) -> String {
        host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }

    private func sha256(_ value: String) -> String {
        Self.sha256(value)
    }

    private static func sha256(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Shields notify hooks (Stage 2)

    /// Install (or re-install idempotently) the message handler + JS
    /// listener that turns `_content-blocker:notify-rule_` events from the
    /// notify-mirror rule list into per-tab `networkRuleCount` increments.
    fileprivate func installShieldsNotifyHooks(on controller: WKUserContentController) {
        // Re-register the handler unconditionally — `removeScriptMessageHandler`
        // is a no-op when nothing is registered. Without removal first we'd
        // hit `NSInternalInconsistencyException: A user script handler with
        // the name '...' was already added`.
        controller.removeScriptMessageHandler(forName: Self.shieldsNotifyMessageName)
        controller.add(notifyMessageHandler, name: Self.shieldsNotifyMessageName)

        // Install the listener exactly once per UCC (marker check).
        let alreadyInstalled = controller.userScripts.contains {
            $0.source.contains(Self.notifyScriptMarker)
        }
        if alreadyInstalled { return }

        let source = """
        \(Self.notifyScriptMarker)
        // Socket Shields: forward WKContentRuleList notify-action events to
        // native so per-tab block counts reflect real activity. The notify
        // mirror rules carry the identifier "socketShields"; we match on
        // that to avoid double-counting unrelated content-blocker events.
        (function() {
          if (window.__socketShieldsNotifyListenerInstalled) return;
          window.__socketShieldsNotifyListenerInstalled = true;
          document.addEventListener('webkitcontentblocked', function(event) {
            try {
              var detail = event && event.detail;
              if (!detail || detail.identifier !== 'socketShields') return;
              if (window.webkit && window.webkit.messageHandlers
                  && window.webkit.messageHandlers.\(Self.shieldsNotifyMessageName)) {
                window.webkit.messageHandlers.\(Self.shieldsNotifyMessageName).postMessage({
                  url: detail.url || (event.target && event.target.URL) || ''
                });
              }
            } catch (e) {}
          }, false);
        })();
        """
        controller.addUserScript(WKUserScript(
            source: source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
    }

    /// Bump the network block counter for whichever tab owns `webView`.
    /// Called from `ShieldsNotifyMessageHandler` on every notify event.
    fileprivate func handleShieldsNotify(from webView: WKWebView?) {
        guard let webView else { return }
        guard let browserManager else { return }
        guard let tab = browserManager.tabManager.allTabs().first(where: { tab in
            existingWebView(for: tab) === webView
        }) else { return }
        var stats = pageStatsByTabID[tab.id] ?? makeEmptyStats(for: tab)
        stats.networkRuleCount += 1
        pageStatsByTabID[tab.id] = stats
        pageStatesByTabID[tab.id] = siteProtectionState(for: tab)
    }
}

// MARK: - Notify-event message handler

/// Bridges `_content-blocker:notify-rule_` JS events back to
/// `TrackingProtectionManager` so it can increment per-tab block counts.
@MainActor
private final class ShieldsNotifyMessageHandler: NSObject, WKScriptMessageHandler {
    weak var manager: TrackingProtectionManager?

    init(manager: TrackingProtectionManager) {
        self.manager = manager
        super.init()
    }

    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        // Hop to MainActor to touch manager state safely. The webView
        // reference is captured before the hop because WKScriptMessage
        // properties aren't Sendable.
        let webView = message.webView
        Task { @MainActor [weak self] in
            self?.manager?.handleShieldsNotify(from: webView)
        }
    }
}

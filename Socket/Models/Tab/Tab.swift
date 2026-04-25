//
//  Tab.swift
//  Socket
//
//  Created by Maciek Bagiński on 30/07/2025.
//

import AVFoundation
import AppKit
import Combine
import CoreAudio
import FaviconFinder
import Foundation
import SwiftUI
import WebKit
import os

@MainActor
public class Tab: NSObject, Identifiable, ObservableObject, WKDownloadDelegate {
    /// User agent presented to Chrome Web Store / Edge Add-ons domains so
    /// Google/Microsoft render their native "Add to <browser>" button as
    /// clickable. Our `WebStoreInjector.js` then replaces it with "Add to
    /// Socket". Safari-family UA gets a disabled button and an "install
    /// Chrome" banner, which is why we spoof here and only here.
    static let chromeWebStoreSpoofUserAgent: String =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

    /// True when the URL's host is Chrome Web Store or Edge Add-ons. Narrow
    /// on purpose — we don't want to spoof Chrome UA beyond these two.
    static func isChromeWebStoreHost(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if host == "chromewebstore.google.com" { return true }
        if host == "chrome.google.com" && url.path.lowercased().contains("/webstore") { return true }
        if host == "microsoftedge.microsoft.com" && url.path.lowercased().contains("/addons") { return true }
        return false
    }

    /// Hosts where we spoof Chrome UA to unblock extension-side login flows.
    /// Zoom's `logintransit.bundle.js` content script is supposed to close
    /// the auth tab and hand the token to the background worker; when it
    /// sees Safari UA on the redirect page it takes a non-extension code
    /// path and hangs on "Login in progress. Please wait." Extend carefully
    /// — adding hosts here makes every page on those hosts see a Chrome UA.
    static func requiresChromeUserAgentSpoof(_ url: URL) -> Bool {
        if isChromeWebStoreHost(url) { return true }
        guard let host = url.host?.lowercased() else { return false }
        if host.hasSuffix(".zoom.us") || host == "zoom.us" {
            // Narrow to the extension-login transit pages so regular Zoom
            // traffic (joining meetings, Zoom web app) still sees Socket's
            // real UA. Both `/zm/extension_login/` and `/myhome` are where
            // Zoom's installed content scripts match.
            let path = url.path.lowercased()
            if path.contains("/zm/extension_login/") { return true }
            if path.contains("/myhome") { return true }
        }
        return false
    }

    public let id: UUID
    var url: URL
    var name: String
    var favicon: SwiftUI.Image
    var spaceId: UUID?
    var index: Int
    var profileId: UUID?
    // If true, this tab is created to host a popup window; do not perform initial load.
    var isPopupHost: Bool = false

    // Track Option key state for Peek functionality
    var isOptionKeyDown: Bool = false

    // MARK: - OAuth Flow State
    /// Whether this tab is hosting an OAuth/sign-in flow popup
    var isOAuthFlow: Bool = false
    /// Reference to the parent tab that initiated this OAuth flow
    var oauthParentTabId: UUID?
    /// The OAuth provider host (e.g., "accounts.google.com") for tracking protection exemption
    var oauthProviderHost: String?
    /// The URL pattern that indicates OAuth completion (redirect back to original domain)
    var oauthCompletionURLPattern: String?
    /// Original opener URL that should receive the authenticated session after popup completion.
    var oauthReturnURL: URL?
    /// Initial popup URL used to detect whether the auth window meaningfully progressed.
    var oauthInitialURL: URL?
    /// Tracks whether the popup navigated away from its initial auth URL.
    var oauthDidProgress: Bool = false
    /// Ensures popup OAuth completion is only relayed to the opener once.
    var didHandleOAuthCompletion: Bool = false
    /// Parent-side auth callback currently being completed before returning to the original page.
    var pendingOAuthCallbackURL: URL?
    /// Parent-side destination to restore once the callback endpoint has committed session state.
    var pendingOAuthReturnURL: URL?
    private var pendingOAuthReturnWorkItem: DispatchWorkItem?
    private var cachedOAuthStorageSnapshot: OAuthStorageSnapshot?
    private var scheduledAuthPageDiagnosticKeys: Set<String> = []

    /// OSSignposter state for the current provisional-nav → didFinish interval.
    /// Reset on each didStart so nested/concurrent navigations don't cross streams.
    private var navigationSignpostState: OSSignpostIntervalState?
    private var scheduledSiteOwnedOAuthBridgeKeys: Set<String> = []
    private var completedSiteOwnedOAuthBridgeKeys: Set<String> = []

    private struct OAuthStorageSnapshot {
        let href: String
        let title: String
        let windowName: String
        let localStorage: [String: String]
        let sessionStorage: [String: String]
        let cookiePreview: String
    }

    private struct SiteOwnedOAuthBridgePlan {
        let identifier: String
        let cookieName: String
        let targetHost: String
    }

    private struct SiteOwnedOAuthBridgePayload {
        let encodedCookieValue: String
        let cookieAlreadyPresent: Bool
        let hasInitialOptions: Bool
        let nameLength: Int
        let tokenLength: Int
        let cookiePreview: String
        let href: String
        let title: String
    }

    // MARK: - Pin State
    var isPinned: Bool = false  // Global pinned (essentials)
    var isSpacePinned: Bool = false  // Space-level pinned
    var folderId: UUID?  // Folder membership for tabs within spacepinned area
    var parentTabId: UUID?  // Hierarchical sidebar parent for Sigma-style subpages
    
    // MARK: - Ephemeral State
    /// Whether this tab belongs to an ephemeral/incognito session
    var isEphemeral: Bool {
        return resolveProfile()?.isEphemeral ?? false
    }

    // MARK: - Favicon Cache
    // Global favicon cache shared across profiles by design to increase hit rate
    // and reduce duplicate downloads. Favicons are cached persistently to survive app restarts.
    private static var faviconCache: [String: SwiftUI.Image] = [:]
    /// MEMORY LEAK FIX: Track insertion order for proper LRU eviction
    private static var faviconCacheOrder: [String] = []
    private static let faviconCacheMaxSize = 200
    private static let faviconCacheQueue = DispatchQueue(
        label: "favicon.cache", attributes: .concurrent)
    private static let faviconCacheLock = NSLock()
    private static let authLogQueue = DispatchQueue(label: "socket.auth-log")
    private static let authLogFileURL: URL = {
        let logDir =
            FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("Socket", isDirectory: true)
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        return logDir.appendingPathComponent("auth-trace.log", isDirectory: false)
    }()

    // Persistent cache storage
    private static let faviconCacheDirectory: URL = {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let faviconDir = cacheDir.appendingPathComponent("FaviconCache")
        try? FileManager.default.createDirectory(at: faviconDir, withIntermediateDirectories: true)
        return faviconDir
    }()

    // MARK: - Loading State
    enum LoadingState: Equatable {
        case idle
        case didStartProvisionalNavigation
        case didCommit
        case didFinish
        case didFail(Error)
        case didFailProvisionalNavigation(Error)

        static func == (lhs: LoadingState, rhs: LoadingState) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle),
                 (.didStartProvisionalNavigation, .didStartProvisionalNavigation),
                 (.didCommit, .didCommit),
                 (.didFinish, .didFinish):
                return true
            case (.didFail, .didFail),
                 (.didFailProvisionalNavigation, .didFailProvisionalNavigation):
                // Compare error descriptions for equality
                return lhs.description == rhs.description
            default:
                return false
            }
        }

        var isLoading: Bool {
            switch self {
            case .idle, .didFinish, .didFail, .didFailProvisionalNavigation:
                return false
            case .didStartProvisionalNavigation, .didCommit:
                return true
            }
        }

        var description: String {
            switch self {
            case .idle:
                return "Idle"
            case .didStartProvisionalNavigation:
                return "Loading started"
            case .didCommit:
                return "Content loading"
            case .didFinish:
                return "Loading finished"
            case .didFail(let error):
                return "Loading failed: \(error.localizedDescription)"
            case .didFailProvisionalNavigation(let error):
                return "Connection failed: \(error.localizedDescription)"
            }
        }
    }

    var loadingState: LoadingState = .idle

    @Published var canGoBack: Bool = false
    @Published var canGoForward: Bool = false

    // Restored navigation state from undo/session restoration (applied when web view is created)
    var restoredCanGoBack: Bool?
    var restoredCanGoForward: Bool?
    private var persistedNavigationHistory: [String] = []
    private var persistedNavigationIndex: Int = 0
    private var pendingPersistedNavigationIndex: Int?

    // MARK: - Video State
    @Published var hasPlayingVideo: Bool = false
    @Published var hasVideoContent: Bool = false  // Track if tab has any video content
    @Published var hasPiPActive: Bool = false

    // MARK: - Audio State
    @Published var hasPlayingAudio: Bool = false
    @Published var isAudioMuted: Bool = false
    @Published var hasAudioContent: Bool = false {
        didSet {
            if oldValue != hasAudioContent {
                if hasAudioContent {
                    startNativeAudioMonitoring()
                } else {
                    stopNativeAudioMonitoring()
                }
            }
        }
    }
    @Published var pageBackgroundColor: NSColor? = nil
    @Published var topBarBackgroundColor: NSColor? = nil
    
    // Track the last domain/subdomain we sampled color for
    private var lastSampledDomain: String? = nil

    // MARK: - Rename State
    @Published var isRenaming: Bool = false
    @Published var editingName: String = ""

    // MARK: - Native Audio Monitoring
    private var audioDeviceListenerProc: AudioObjectPropertyListenerProc?
    private var isMonitoringNativeAudio = false
    private var lastAudioDeviceCheckTime: Date = Date()
    private var audioMonitoringTimer: Timer?
    private var hasAddedCoreAudioListener = false
    private var profileAwaitCancellable: AnyCancellable?
    private var extensionAwaitCancellable: AnyCancellable?

    // Web Store integration
    private var webStoreHandler: WebStoreScriptHandler?

    // Debounce task for SPA navigation persistence
    private var spaPersistDebounceTask: Task<Void, Never>?

    // Block-based title observation. Replaces NSObject KVO on "title" —
    // SPAs mutate document.title without a real navigation, so the
    // WKNavigationDelegate callbacks aren't enough. Swift's block-style
    // observe is lighter than routing through observeValue(forKeyPath:).
    private var titleObservation: NSKeyValueObservation?

    // Block-based canGoBack / canGoForward observation. Fires exactly once
    // per real property change and replaces the previous 3×-poll fallback
    // (0ms / 100ms / 250ms asyncAfter) that existed to catch same-domain
    // navigations where the delegate update lagged.
    private var canGoBackObservation: NSKeyValueObservation?
    private var canGoForwardObservation: NSKeyValueObservation?

    // MARK: - Tab State
    var isUnloaded: Bool {
        return _webView == nil
    }

    private var _webView: WKWebView?
    private var _existingWebView: WKWebView?
    var pendingContextMenuPayload: WebContextMenuPayload?
    var didNotifyOpenToExtensions: Bool = false
    
    // MARK: - WebView Ownership Tracking (Memory Optimization)
    /// The window ID that currently "owns" the primary WebView for this tab
    /// If nil, no window is displaying this tab yet
    var primaryWindowId: UUID?
    
    /// Returns true if this tab has an assigned primary WebView (displayed in any window)
    var hasAssignedPrimaryWebView: Bool {
        return primaryWindowId != nil && _webView != nil
    }
    
    /// Returns the WebView IF it has been assigned to a window, nil otherwise
    /// This prevents creating "orphan" WebViews that are never displayed
    var assignedWebView: WKWebView? {
        // Only return WebView if it's been assigned to a window
        // This prevents the old behavior of creating a WebView on first access
        return primaryWindowId != nil ? _webView : nil
    }
    
    var webView: WKWebView? {
        if _webView == nil {
            let stackSymbols = Thread.callStackSymbols.prefix(8).joined(separator: "\n  ")
            DLog("🔍 [MEMDEBUG] Tab.webView LAZY ACCESS - Tab: \(id.uuidString.prefix(8)), URL: \(url.absoluteString)")
            DLog("🔍 [MEMDEBUG] Stack trace:\n  \(stackSymbols)")
            setupWebView()
        }
        return _webView
    }

    var activeWebView: WKWebView {
        if _webView == nil {
            setupWebView()
        }
        return _webView!
    }

    /// Returns the existing WebView without triggering lazy initialization
    var existingWebView: WKWebView? {
        return _webView
    }
    
    /// Assigns the WebView to a specific window as its "primary" display
    /// Call this when a window first displays this tab
    func assignWebViewToWindow(_ webView: WKWebView, windowId: UUID) {
        DLog("🔍 [MEMDEBUG] Tab.assignWebViewToWindow() - Tab: \(id.uuidString.prefix(8)), Window: \(windowId.uuidString.prefix(8)), WebView: \(Unmanaged.passUnretained(webView).toOpaque())")
        
        // If we already have a WebView assigned to a different window, this is an error
        // (should have been caught by WebViewCoordinator)
        if let existingWindow = primaryWindowId, existingWindow != windowId {
            print("⚠️ [MEMDEBUG] WARNING: Reassigning WebView from window \(existingWindow.uuidString.prefix(8)) to \(windowId.uuidString.prefix(8))")
        }
        
        _webView = webView
        primaryWindowId = windowId

        if #available(macOS 15.5, *) {
            ExtensionManager.shared.notifyTabOpened(self)
            if browserManager?.currentTabForActiveWindow()?.id == self.id {
                ExtensionManager.shared.notifyTabActivated(newTab: self, previous: nil)
            }
        }

        DLog("🔍 [MEMDEBUG]   -> Primary window assigned: \(windowId.uuidString.prefix(8))")
    }

    weak var browserManager: BrowserManager?
    weak var socketSettings: SocketSettingsService?

    // MARK: - Link Hover Callback
    var onLinkHover: ((String?) -> Void)? = nil
    var onCommandHover: ((String?) -> Void)? = nil
    
    private struct RecentModifiedOpen {
        let key: String
        let timestamp: Date
    }
    
    private var lastModifiedOpen: RecentModifiedOpen?
    private var lastModifiedOpenPopupSuppression: RecentModifiedOpen?
    private let modifiedOpenDeduplicationWindow: TimeInterval = 0.35
    private let modifiedOpenPopupSuppressionWindow: TimeInterval = 1.0

    private let themeColorObservedWebViews = NSHashTable<AnyObject>.weakObjects()
    private let navigationStateObservedWebViews = NSHashTable<AnyObject>.weakObjects()

    var isCurrentTab: Bool {
        // This property is used in contexts where we don't have window state
        // For now, we'll keep it using the global current tab for backward compatibility
        return browserManager?.tabManager.currentTab?.id == id
    }

    var isActiveInSpace: Bool {
        guard let spaceId = self.spaceId,
            let browserManager = self.browserManager,
            let space = browserManager.tabManager.spaces.first(where: { $0.id == spaceId })
        else {
            return isCurrentTab  // Fallback to current tab for pinned tabs or if no space
        }
        return space.activeTabId == id
    }

    var isLoading: Bool {
        return loadingState.isLoading
    }

    // MARK: - Initializers
    init(
        id: UUID = UUID(),
        url: URL = URL(string: "https://www.google.com")!,
        name: String = "New Tab",
        favicon: String = "globe",
        spaceId: UUID? = nil,
        index: Int = 0,
        browserManager: BrowserManager? = nil,
        existingWebView: WKWebView? = nil
    ) {
        self.id = id
        self.url = url
        self.name = name
        self.favicon = Image(systemName: favicon)
        self.spaceId = spaceId
        self.index = index
        self.browserManager = browserManager
        self._existingWebView = existingWebView
        super.init()
        seedPersistedNavigationHistoryIfNeeded(with: url)

        Task { @MainActor in
            await fetchAndSetFavicon(for: url)
        }
    }

    public init(
        id: UUID = UUID(),
        url: URL = URL(string: "https://www.google.com")!,
        name: String = "New Tab",
        favicon: String = "globe",
        spaceId: UUID? = nil,
        index: Int = 0
    ) {
        self.id = id
        self.url = url
        self.name = name
        self.favicon = Image(systemName: favicon)
        self.spaceId = spaceId
        self.index = index
        self.browserManager = nil
        super.init()
        seedPersistedNavigationHistoryIfNeeded(with: url)

        Task { @MainActor in
            await fetchAndSetFavicon(for: url)
        }
    }

    // MARK: - Controls
    func goBack() {
        guard canGoBack else { return }

        if let webView = _webView, webView.canGoBack {
            webView.goBack()
            return
        }

        guard persistedNavigationIndex > 0 else { return }
        let targetIndex = persistedNavigationIndex - 1
        navigateUsingPersistedHistory(to: targetIndex)
    }

    func goForward() {
        guard canGoForward else { return }

        if let webView = _webView, webView.canGoForward {
            webView.goForward()
            return
        }

        guard persistedNavigationIndex + 1 < persistedNavigationHistory.count else { return }
        let targetIndex = persistedNavigationIndex + 1
        navigateUsingPersistedHistory(to: targetIndex)
    }

    func refresh() {
        loadingState = .didStartProvisionalNavigation
        _webView?.reload()

        // Synchronize refresh across all windows that are displaying this tab
        browserManager?.reloadTabAcrossWindows(self.id)
    }

    func stop() {
        _webView?.stopLoading()
        loadingState = .idle
    }

    private func updateNavigationState() {
        guard let webView = _webView else { return }

        // Force UI update by notifying object will change
        objectWillChange.send()

        let newCanGoBack = webView.canGoBack || persistedNavigationIndex > 0
        let newCanGoForward = webView.canGoForward || (persistedNavigationIndex + 1 < persistedNavigationHistory.count)

        // Only update if values actually changed to prevent unnecessary redraws
        if newCanGoBack != canGoBack || newCanGoForward != canGoForward {
            canGoBack = newCanGoBack
            canGoForward = newCanGoForward

            // Notify TabManager to persist navigation state
            browserManager?.tabManager.updateTabNavigationState(self)
        }
    }

    /// Applies restored navigation state from undo/session restoration.
    /// Call this after setting up navigation observers to ensure proper initial state.
    private func applyRestoredNavigationState() {
        guard let back = restoredCanGoBack else { return }
        // Only apply restored state if webView hasn't already set different values
        // This preserves actual webView state when it differs from restored state
        if back != canGoBack {
            canGoBack = back
        }
        if let forward = restoredCanGoForward, forward != canGoForward {
            canGoForward = forward
        }
        // Clear restored state after applying
        restoredCanGoBack = nil
        restoredCanGoForward = nil
        refreshNavigationAvailability()
    }

    /// Navigation-state update from a WKNavigationDelegate callback. Block-based
    /// KVO on canGoBack / canGoForward (installed in setupNavigationStateObservers)
    /// picks up any changes that lag the delegate — no need for the 0/100/250ms
    /// poll that was here previously.
    func updateNavigationStateEnhanced(source: String = "unknown") {
        updateNavigationState()
    }

    var navigationHistoryForPersistence: [String] {
        let normalized = persistedNavigationHistory.filter { !$0.isEmpty }
        if normalized.isEmpty {
            return [url.absoluteString]
        }
        return normalized
    }

    var navigationHistoryIndexForPersistence: Int {
        let history = navigationHistoryForPersistence
        guard !history.isEmpty else { return 0 }
        return min(max(persistedNavigationIndex, 0), history.count - 1)
    }

    func restoreNavigationHistory(_ history: [String], currentIndex: Int) {
        let normalized = history.filter { URL(string: $0) != nil }
        if normalized.isEmpty {
            persistedNavigationHistory = [url.absoluteString]
            persistedNavigationIndex = 0
        } else {
            persistedNavigationHistory = normalized
            persistedNavigationIndex = min(max(currentIndex, 0), normalized.count - 1)

            let currentURLString = url.absoluteString
            if persistedNavigationHistory[persistedNavigationIndex] != currentURLString {
                if let matchingIndex = persistedNavigationHistory.lastIndex(of: currentURLString) {
                    persistedNavigationIndex = matchingIndex
                } else {
                    persistedNavigationHistory.append(currentURLString)
                    persistedNavigationIndex = persistedNavigationHistory.count - 1
                }
            }
        }

        pendingPersistedNavigationIndex = nil
        refreshNavigationAvailability()
    }

    private func seedPersistedNavigationHistoryIfNeeded(with url: URL) {
        guard persistedNavigationHistory.isEmpty else { return }
        persistedNavigationHistory = [url.absoluteString]
        persistedNavigationIndex = 0
        pendingPersistedNavigationIndex = nil
    }

    private func navigateUsingPersistedHistory(to targetIndex: Int) {
        guard persistedNavigationHistory.indices.contains(targetIndex),
              let targetURL = URL(string: persistedNavigationHistory[targetIndex]) else { return }

        pendingPersistedNavigationIndex = targetIndex
        persistedNavigationIndex = targetIndex
        refreshNavigationAvailability()
        loadURL(targetURL)
    }

    private func synchronizePersistedNavigationHistory(with currentURL: URL) {
        let currentURLString = currentURL.absoluteString
        persistedNavigationHistory = persistedNavigationHistory.filter { URL(string: $0) != nil }

        if persistedNavigationHistory.isEmpty {
            persistedNavigationHistory = [currentURLString]
            persistedNavigationIndex = 0
            pendingPersistedNavigationIndex = nil
            refreshNavigationAvailability()
            return
        }

        persistedNavigationIndex = min(max(persistedNavigationIndex, 0), persistedNavigationHistory.count - 1)

        if let pendingIndex = pendingPersistedNavigationIndex,
           persistedNavigationHistory.indices.contains(pendingIndex),
           persistedNavigationHistory[pendingIndex] == currentURLString {
            persistedNavigationIndex = pendingIndex
            pendingPersistedNavigationIndex = nil
            refreshNavigationAvailability()
            return
        }

        pendingPersistedNavigationIndex = nil

        if persistedNavigationHistory[persistedNavigationIndex] == currentURLString {
            refreshNavigationAvailability()
            return
        }

        if persistedNavigationIndex > 0,
           persistedNavigationHistory[persistedNavigationIndex - 1] == currentURLString {
            persistedNavigationIndex -= 1
            refreshNavigationAvailability()
            return
        }

        if persistedNavigationIndex + 1 < persistedNavigationHistory.count,
           persistedNavigationHistory[persistedNavigationIndex + 1] == currentURLString {
            persistedNavigationIndex += 1
            refreshNavigationAvailability()
            return
        }

        let prefixEnd = min(max(persistedNavigationIndex + 1, 0), persistedNavigationHistory.count)
        let truncatedHistory = Array(persistedNavigationHistory.prefix(prefixEnd))

        if truncatedHistory.last == currentURLString {
            persistedNavigationHistory = truncatedHistory
            persistedNavigationIndex = max(truncatedHistory.count - 1, 0)
        } else {
            persistedNavigationHistory = truncatedHistory + [currentURLString]
            persistedNavigationIndex = persistedNavigationHistory.count - 1
        }

        refreshNavigationAvailability()
    }

    private func refreshNavigationAvailability() {
        let liveCanGoBack = _webView?.canGoBack ?? false
        let liveCanGoForward = _webView?.canGoForward ?? false
        let fallbackCanGoBack = persistedNavigationIndex > 0
        let fallbackCanGoForward = persistedNavigationIndex + 1 < persistedNavigationHistory.count

        let newCanGoBack = liveCanGoBack || fallbackCanGoBack
        let newCanGoForward = liveCanGoForward || fallbackCanGoForward

        if newCanGoBack != canGoBack {
            canGoBack = newCanGoBack
        }
        if newCanGoForward != canGoForward {
            canGoForward = newCanGoForward
        }
    }

    // MARK: - Chrome Web Store Integration

    /// Inject Web Store script after navigation completes
    private func injectWebStoreScriptIfNeeded(for url: URL, in webView: WKWebView) {
        guard let browserManager = browserManager else {
            return
        }

        guard BrowserConfiguration.isChromeWebStore(url) else { return }

        // Ensure message handler is registered (remove old handler first to avoid duplicates)
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: "socketWebStore")

        webStoreHandler = WebStoreScriptHandler(browserManager: browserManager)
        webView.configuration.userContentController.add(webStoreHandler!, name: "socketWebStore")

        // Get the script source from bundle
        guard let script = BrowserConfiguration.webStoreInjectorScript() else { return }

        // Inject with slight delay to ensure DOM is ready
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            webView.evaluateJavaScript(script.source) { _, error in
                if let error = error {
                    print("[Tab] Web Store script injection failed: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Boosts Integration
    
    // Track boost scripts to optimize removal (only remove boost scripts, not all scripts)
    // Use array instead of Set since WKUserScript doesn't conform to Hashable
    private var currentBoostScripts: [WKUserScript] = []
    
    private func setupBoostUserScript(for url: URL, in webView: WKWebView) {
        guard let browserManager = browserManager,
            let domain = url.host
        else {
            return
        }

        let userContentController = webView.configuration.userContentController
        let boostScriptIdentifier = "SOCKET_BOOST_SCRIPT_IDENTIFIER"
        
        // Optimized: Only remove boost scripts, preserve other user scripts
        // This is much faster than removing all scripts and re-adding them
        if !currentBoostScripts.isEmpty {
            // Remove only the boost scripts we previously added
            // Compare by source content since WKUserScript doesn't conform to Equatable
            let allScripts = userContentController.userScripts
            userContentController.removeAllUserScripts()
            
            // Re-add only non-boost scripts (those not in our tracked list)
            let boostScriptSources = Set(currentBoostScripts.map { $0.source })
//            for script in allScripts {
//                if !boostScriptSources.contains(script.source) {
//                    userContentController.addUserScript(script)
//                }
//            }
// MARK: This causes the browser to crash when loading boosted pages
            
            currentBoostScripts.removeAll()
        } else {
            // First time setup - still need to check for any existing boost scripts
            // (in case webview was reused or scripts were added elsewhere)
            let existingBoostScripts = userContentController.userScripts.filter { script in
                script.source.contains(boostScriptIdentifier)
            }
            
            if !existingBoostScripts.isEmpty {
                // Remove existing boost scripts
                let remainingScripts = userContentController.userScripts.filter { script in
                    !script.source.contains(boostScriptIdentifier)
                }
                userContentController.removeAllUserScripts()
                remainingScripts.forEach { userContentController.addUserScript($0) }
            }
        }

        // Check if this domain has a boost configured
        guard let boostConfig = browserManager.boostsManager.getBoost(for: domain) else {
            // No boost for this domain - scripts already removed above
            return
        }

        print("🚀 [Tab] Setting up boost user scripts for domain: \(domain)")

        // Create and add boost user scripts (will inject at document start)
        // Returns array: [fontScript (optional), mainBoostScript]
        let boostScripts = browserManager.boostsManager.createBoostUserScripts(for: boostConfig, domain: domain)
        
        // Track these scripts for efficient removal later
        // Prevent duplicates by checking if script source already exists
        let existingSources = Set(userContentController.userScripts.map { $0.source })
        for script in boostScripts {
            // Only add if not already present (prevents duplicates during rapid navigation)
            if !existingSources.contains(script.source) {
                currentBoostScripts.append(script)
                userContentController.addUserScript(script)
            }
        }
        print("✅ [Tab] Added \(boostScripts.count) boost script(s) for: \(domain)")
    }
    
    private func injectBoostIfNeeded(for url: URL, in webView: WKWebView) {
        // This method is kept for backward compatibility but boost injection
        // now happens via user scripts at document start
        // Fallback: still inject if user script didn't work
        guard let browserManager = browserManager,
            let domain = url.host
        else {
            return
        }

        // Check if this domain has a boost configured
        guard let boostConfig = browserManager.boostsManager.getBoost(for: domain) else {
            return
        }

        print("🚀 [Tab] Fallback boost injection for domain: \(domain)")

        // Inject boost with a slight delay to ensure DOM is ready
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            browserManager.boostsManager.injectBoost(boostConfig, into: webView) { success in
                if success {
                    print("✅ [Tab] Fallback boost injection successful for: \(domain)")
                } else {
                    print("❌ [Tab] Fallback boost injection failed for: \(domain)")
                }
            }
        }
    }

    // MARK: - WebView Setup

    private func setupWebView() {
        DLog("🔍 [MEMDEBUG] Tab.setupWebView() START - Tab: \(id.uuidString.prefix(8)), Name: \(name), URL: \(url.absoluteString)")
        DLog("🔍 [MEMDEBUG]   _webView exists: \(_webView != nil), _existingWebView exists: \(_existingWebView != nil)")
        
        let resolvedProfile = resolveProfile()
        let configuration: WKWebViewConfiguration
        if let profile = resolvedProfile {
            configuration = BrowserConfiguration.shared.cacheOptimizedWebViewConfiguration(
                for: profile)
        } else {
            // Edge case: currentProfile not yet available. Delay creating WKWebView until it resolves.
            if profileAwaitCancellable == nil {
                print(
                    "[Tab] No profile resolved yet; deferring WebView creation and observing currentProfile…"
                )
                profileAwaitCancellable = browserManager?
                    .$currentProfile
                    .receive(on: RunLoop.main)
                    .sink { [weak self] value in
                        guard let self = self else { return }
                        if value != nil && self._webView == nil {
                            self.profileAwaitCancellable?.cancel()
                            self.profileAwaitCancellable = nil
                            self.setupWebView()
                        }
                    }
            }
            return
        }


        // No need to block on extensionsLoaded — the shared config already has the
        // extension controller set (from setupExtensionController). Content scripts will
        // inject once individual extension contexts finish loading asynchronously.

        // Ensure the configuration has the extension controller so content scripts can inject
        if #available(macOS 15.5, *) {
            if configuration.webExtensionController == nil,
               let controller = ExtensionManager.shared.nativeController {
                configuration.webExtensionController = controller
            }
            let ctrl = configuration.webExtensionController
            let ctxs = ctrl?.extensionContexts.count ?? -1
            let samePool = configuration.processPool === BrowserConfiguration.shared.webViewConfiguration.processPool
            print("[EXT-CFG] '\(name)' controller=\(ctrl != nil), contexts=\(ctxs), sameProcessPool=\(samePool), existing=\(_existingWebView != nil)")
        }

        // Check if we have an existing WebView to inject
        if let existingWebView = _existingWebView {
            _webView = existingWebView
        } else {
            let newWebView = FocusableWKWebView(frame: .zero, configuration: configuration)
            newWebView.underPageBackgroundColor = .white
            _webView = newWebView
            DLog("🔍 [MEMDEBUG] Tab CREATED NEW PRIMARY WebView - Tab: \(id.uuidString.prefix(8)), WebView: \(Unmanaged.passUnretained(newWebView).toOpaque()), ConfigStore: \(configuration.websiteDataStore.identifier?.uuidString.prefix(8) ?? "default")")
            if let fv = _webView as? FocusableWKWebView {
                fv.owningTab = self
                fv.contextMenuBridge = WebContextMenuBridge(tab: self, configuration: configuration)
            }
        }

        _webView?.navigationDelegate = self
        _webView?.uiDelegate = self
        _webView?.allowsBackForwardNavigationGestures = true
        _webView?.allowsMagnification = true

        if let webView = _webView {
            setupThemeColorObserver(for: webView)
            setupNavigationStateObservers(for: webView)
            applyRestoredNavigationState()
        }

        // Only set up script handlers and user agent for new WebViews
        // Existing WebViews (from Peek) already have these configured
        if _existingWebView == nil, let webView = _webView {
            // Clean + re-register the canonical Socket handlers. The list
            // lives in SocketMessageHandlers so every site (setup, unload,
            // coordinator create, fallback cleanup) shares one source of
            // truth — previously these were enumerated inline in 5+ places
            // and drifted, causing the password-handler-missing bug.
            SocketMessageHandlers.remove(from: webView, tabId: id)
            SocketMessageHandlers.register(on: webView, for: self)
            webView.configuration.userContentController.addUserScript(
                WKUserScript(
                    source: WebsiteShortcutDetector.jsDetectionScript,
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: true
                )
            )

            // Web-Store integration uses its own handler target (not Tab), so
            // it lives outside the canonical set.
            if let browserManager = browserManager {
                webView.configuration.userContentController.removeScriptMessageHandler(
                    forName: "socketWebStore")
                webStoreHandler = WebStoreScriptHandler(browserManager: browserManager)
                webView.configuration.userContentController.add(
                    webStoreHandler!, name: "socketWebStore")

                if BrowserConfiguration.isChromeWebStore(url),
                    let script = BrowserConfiguration.webStoreInjectorScript()
                {
                    webView.configuration.userContentController.addUserScript(script)
                }
            }

            // Use the dynamic Safari UA from the config's applicationNameForUserAgent
            // instead of hardcoding. This ensures the UA matches the real Safari on
            // this system, which affects COOP header handling by auth providers.

            // Let the web content control its own background so extension styles
            // (like Dark Reader) can paint dark backgrounds. The app's themed
            // background is only visible while the page is loading.
            _webView?.setValue(true, forKey: "drawsBackground")
        }

        if let webView = _webView {
            if #available(macOS 13.3, *) {
                webView.isInspectable = true
            }

            webView.allowsLinkPreview = true
            webView.configuration.preferences
                .isFraudulentWebsiteWarningEnabled = true
            webView.configuration.preferences
                .javaScriptCanOpenWindowsAutomatically = true
            // No ad-hoc page script injection here; rely on WKWebExtension
            browserManager?.trackingProtectionManager.configureNewWebView(
                webView,
                for: self
            )
        }

        // For existing WebViews, ensure the delegates are updated to point to this tab
        if _existingWebView != nil {
            DLog("🔍 [MEMDEBUG] Tab setup COMPLETE (existing WebView) - Tab: \(id.uuidString.prefix(8))")
        } else {
            DLog("🔍 [MEMDEBUG] Tab setup COMPLETE (new WebView) - Tab: \(id.uuidString.prefix(8)), WebView: \(Unmanaged.passUnretained(_webView!).toOpaque())")
        }

        // Inform extensions that this tab's view is now open/available BEFORE loading,
        // so content scripts and messaging can resolve this tab during early document phases
        if #available(macOS 15.5, *), didNotifyOpenToExtensions == false {
            ExtensionManager.shared.notifyTabOpened(self)
            // Also activate this tab if it's the current one, so the controller
            // can route chrome.runtime messages correctly
            if browserManager?.currentTabForActiveWindow()?.id == self.id {
                ExtensionManager.shared.notifyTabActivated(newTab: self, previous: nil)
            }
        }
        // For popup-hosting tabs, don't trigger an initial navigation. WebKit will
        // drive the load into this returned webView from createWebViewWith:.
        // Also don't reload if we're using an existing WebView (from Peek)
        if !isPopupHost && _existingWebView == nil {
            loadURL(url)
        }
    }

    // Resolve the Profile for this tab via its space association, or fall back to currentProfile, then default profile
    func resolveProfile() -> Profile? {
        // First, check if we have a direct profileId assignment (including ephemeral tabs)
        if let pid = profileId {
            // Check ephemeral profiles first
            if let windowState = browserManager?.windowRegistry?.windows.values.first(where: { window in
                window.ephemeralTabs.contains(where: { $0.id == self.id })
            }),
               let ephemeralProfile = windowState.ephemeralProfile,
               ephemeralProfile.id == pid {
                return ephemeralProfile
            }
            // Check regular profiles
            if let profile = browserManager?.profileManager.profiles.first(where: { $0.id == pid }) {
                return profile
            }
        }
        
        // Attempt to resolve via associated space
        if let sid = spaceId,
            let space = browserManager?.tabManager.spaces.first(where: { $0.id == sid })
        {
            if let pid = space.profileId,
                let profile = browserManager?.profileManager.profiles.first(where: { $0.id == pid })
            {
                return profile
            }
        }
        // Fallback to the current profile
        if let cp = browserManager?.currentProfile { return cp }
        // Final fallback to the default profile
        return browserManager?.profileManager.profiles.first
    }

    // Minimal hook to satisfy ExtensionManager: update extension controller on existing webView.
    func applyWebViewConfigurationOverride(_ configuration: WKWebViewConfiguration) {
        guard let existing = _webView else { return }
        if #available(macOS 15.5, *), let controller = configuration.webExtensionController {
            existing.configuration.webExtensionController = controller
        }
    }

    // MARK: - Tab Actions
    func closeTab() {
        print("Closing tab: \(self.name)")

        // IMMEDIATELY RESET PiP STATE to prevent any further PiP operations
        hasPiPActive = false

        // MEMORY LEAK FIX: Use comprehensive cleanup instead of scattered cleanup
        performComprehensiveWebViewCleanup()

        // 11. RESET ALL STATE
        hasPlayingVideo = false
        hasVideoContent = false
        hasPlayingAudio = false
        hasAudioContent = false
        isAudioMuted = false
        hasPiPActive = false
        loadingState = .idle

        // 13. CLEANUP ZOOM DATA
        browserManager?.cleanupZoomForTab(self.id)

        // 14. FORCE COMPOSITOR UPDATE
        // Note: This is called during tab loading, so we use the global current tab
        // The compositor will handle window-specific visibility in its update methods
        browserManager?.compositorManager.updateTabVisibility(
            currentTabId: browserManager?.tabManager.currentTab?.id)

        // 13. STOP NATIVE AUDIO MONITORING
        stopNativeAudioMonitoring()

        // 14. REMOVE THEME COLOR OBSERVER
        if let webView = _webView {
            removeThemeColorObserver(from: webView)
            removeNavigationStateObservers(from: webView)
        }

        // 15. REMOVE FROM TAB MANAGER
        browserManager?.tabManager.removeTab(self.id)

        // Cancel any pending observations
        profileAwaitCancellable?.cancel()
        profileAwaitCancellable = nil
        extensionAwaitCancellable?.cancel()
        extensionAwaitCancellable = nil

        print("Tab killed: \(name)")
    }

    deinit {
        // MEMORY LEAK FIX: Ensure cleanup when tab is deallocated
        // Note: We can't access main actor-isolated properties in deinit,
        // but we can still clean up non-actor properties

        // Cancel any pending observations
        profileAwaitCancellable?.cancel()
        profileAwaitCancellable = nil
        extensionAwaitCancellable?.cancel()
        extensionAwaitCancellable = nil

        // Clear theme color observers
        themeColorObservedWebViews.removeAllObjects()

        // Note: stopNativeAudioMonitoring() is main actor-isolated and cannot be called from deinit
        // The cleanup will be handled by the closeTab() method which is called before deinit

        print("🧹 [Tab] deinit cleanup completed for: \(name)")
    }

    func loadURL(_ newURL: URL) {
        loadURL(newURL, cachePolicy: .returnCacheDataElseLoad)
    }

    func loadURLFresh(_ newURL: URL) {
        loadURL(newURL, cachePolicy: .reloadIgnoringLocalCacheData)
    }

    private func loadURL(_ newURL: URL, cachePolicy: URLRequest.CachePolicy) {
        self.url = newURL
        loadingState = .didStartProvisionalNavigation

        // Grant extension access before loading so content scripts inject at document_start
        if #available(macOS 15.4, *) {
            ExtensionManager.shared.grantExtensionAccessToURL(newURL)
        }

        // Reset audio tracking for new page but preserve mute state
        hasAudioContent = false
        hasPlayingAudio = false
        // Note: isAudioMuted is preserved to maintain user's mute preference

        if newURL.isFileURL {
            // Grant read access to the containing directory for local resources
            let directoryURL = newURL.deletingLastPathComponent()
            print("🔧 [Tab] Loading file URL with directory access: \(directoryURL.path)")
            activeWebView.loadFileURL(newURL, allowingReadAccessTo: directoryURL)
        } else {
            // Use cache policy appropriate to the caller. Auth callback handoffs
            // must bypass cache so the new session state is fetched from the
            // network instead of replaying a logged-out page snapshot.
            var request = URLRequest(url: newURL)
            request.cachePolicy = cachePolicy
            request.timeoutInterval = 30.0
            print("🚀 [Tab] Loading URL with cache policy: \(request.cachePolicy.rawValue)")
            activeWebView.load(request)
        }

        // Synchronize navigation across all windows that are displaying this tab
        browserManager?.syncTabAcrossWindows(self.id)

        Task { @MainActor in
            await fetchAndSetFavicon(for: newURL)
        }
    }

    func loadURL(_ urlString: String) {
        guard let newURL = URL(string: urlString) else {
            print("Invalid URL: \(urlString)")
            return
        }
        loadURL(newURL)
    }

    /// Navigate to a new URL with proper search engine normalization
    func navigateToURL(_ input: String) {
        let settings = socketSettings ?? browserManager?.socketSettings
        let template = settings?.resolvedSearchEngineTemplate ?? SearchProvider.google.queryTemplate
        let normalizedUrl = normalizeURL(input, queryTemplate: template)

        guard let validURL = URL(string: normalizedUrl) else {
            print("Invalid URL after normalization: \(input) -> \(normalizedUrl)")
            return
        }

        print("🌐 [Tab] Navigating current tab to: \(normalizedUrl)")
        loadURL(validURL)
    }

    func requestPictureInPicture() {
        // In multi-window setup, we need to work with the WebView that's actually visible
        // in the current window, not just the first WebView created
        if let browserManager = browserManager,
           let activeWindowId = browserManager.windowRegistry?.activeWindow?.id,
            let activeWebView = browserManager.getWebView(for: self.id, in: activeWindowId)
        {
            // Use the WebView that's actually visible in the current window
            PiPManager.shared.requestPiP(for: self, webView: activeWebView)
        } else {
            // Fallback to the original behavior for backward compatibility
            PiPManager.shared.requestPiP(for: self)
        }
    }

    // MARK: - Rename Methods
    func startRenaming() {
        isRenaming = true
        editingName = name
    }

    func saveRename() {
        if !editingName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            name = editingName.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        isRenaming = false
        editingName = ""
    }

    func cancelRename() {
        isRenaming = false
        editingName = ""
    }

    // MARK: - Simple Media Detection (mainly for manual checks)
    func checkMediaState() {
        // Get all web views for this tab across all windows
        let allWebViews: [WKWebView]
        if let coordinator = browserManager?.webViewCoordinator {
            allWebViews = coordinator.getAllWebViews(for: id)
        } else if let webView = _webView {
            // Fallback to original web view for backward compatibility
            allWebViews = [webView]
        } else {
            return
        }

        // Simple state check - optimized single-pass version
        let mediaCheckScript = """
            (() => {
                const audios = document.querySelectorAll('audio');
                const videos = document.querySelectorAll('video');

                // Single pass through audios
                const hasPlayingAudio = Array.from(audios).some(audio =>
                    !audio.paused && !audio.ended && audio.readyState >= 2
                );

                // Single pass through videos for all checks
                let hasPlayingVideoWithAudio = false;
                let hasPlayingVideo = false;

                Array.from(videos).forEach(video => {
                    const isPlaying = !video.paused && !video.ended && video.readyState >= 2;
                    if (isPlaying) {
                        hasPlayingVideo = true;
                        if (!video.muted && video.volume > 0) {
                            hasPlayingVideoWithAudio = true;
                        }
                    }
                });

                const hasAudioContent = hasPlayingAudio || hasPlayingVideoWithAudio;

                return {
                    hasAudioContent: hasAudioContent,
                    hasPlayingAudio: hasAudioContent,
                    hasVideoContent: videos.length > 0,
                    hasPlayingVideo: hasPlayingVideo
                };
            })();
            """

        // Check media state across all web views and aggregate results
        var aggregatedResults: [String: Bool] = [
            "hasAudioContent": false,
            "hasPlayingAudio": false,
            "hasVideoContent": false,
            "hasPlayingVideo": false,
        ]

        let group = DispatchGroup()

        for webView in allWebViews {
            group.enter()
            webView.evaluateJavaScript(mediaCheckScript) { result, error in
                defer { group.leave() }

                if let error = error {
                    print("[Media Check] Error: \(error.localizedDescription)")
                    return
                }

                if let state = result as? [String: Bool] {
                    // Aggregate results - if any web view has media, the tab has media
                    aggregatedResults["hasAudioContent"] =
                        (aggregatedResults["hasAudioContent"] ?? false)
                        || (state["hasAudioContent"] ?? false)
                    aggregatedResults["hasPlayingAudio"] =
                        (aggregatedResults["hasPlayingAudio"] ?? false)
                        || (state["hasPlayingAudio"] ?? false)
                    aggregatedResults["hasVideoContent"] =
                        (aggregatedResults["hasVideoContent"] ?? false)
                        || (state["hasVideoContent"] ?? false)
                    aggregatedResults["hasPlayingVideo"] =
                        (aggregatedResults["hasPlayingVideo"] ?? false)
                        || (state["hasPlayingVideo"] ?? false)
                }
            }
        }

        // Update tab state after all web views have been checked
        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            self.hasAudioContent = aggregatedResults["hasAudioContent"] ?? false
            self.hasPlayingAudio = aggregatedResults["hasPlayingAudio"] ?? false
            self.hasVideoContent = aggregatedResults["hasVideoContent"] ?? false
            self.hasPlayingVideo = aggregatedResults["hasPlayingVideo"] ?? false
        }
    }

    private func injectMediaDetection(to webView: WKWebView) {
        let mediaDetectionScript = """
            (function() {
                const handlerName = 'mediaStateChange_\(id.uuidString)';

                // Track current URL for navigation detection
                window.__SocketCurrentURL = window.location.href;

                function resetSoundTracking() {
                    window.webkit.messageHandlers[handlerName].postMessage({
                        hasAudioContent: false,
                        hasPlayingAudio: false,
                        hasVideoContent: false,
                        hasPlayingVideo: false
                    });
                    setTimeout(checkMediaState, 100);
                }

                const originalPushState = history.pushState;
                const originalReplaceState = history.replaceState;

                history.pushState = function(...args) {
                    originalPushState.apply(history, args);
                    setTimeout(() => {
                        if (window.location.href !== window.__SocketCurrentURL) {
                            window.__SocketCurrentURL = window.location.href;
                            resetSoundTracking();
                        }
                    }, 0);
                };

                history.replaceState = function(...args) {
                    originalReplaceState.apply(history, args);
                    setTimeout(() => {
                        if (window.location.href !== window.__SocketCurrentURL) {
                            window.__SocketCurrentURL = window.location.href;
                            resetSoundTracking();
                        }
                    }, 0);
                };

                // Listen for popstate events (back/forward)
                window.addEventListener('popstate', resetSoundTracking);

                function checkMediaState() {
                    const audios = document.querySelectorAll('audio');
                    const videos = document.querySelectorAll('video');

                    // Standard media detection
                    let hasPlayingAudio = false;
                    let hasPlayingVideoWithAudio = false;
                    let hasPlayingVideo = false;

                    // Check audio elements with enhanced detection
                    Array.from(audios).forEach(audio => {
                        const standardPlaying = !audio.paused && !audio.ended && audio.readyState >= 2;

                        // Enhanced detection for DRM content using WebKit properties
                        let drmAudioPlaying = false;
                        try {
                            // Check for decoded audio bytes (WebKit-specific)
                            if ('webkitAudioDecodedByteCount' in audio) {
                                const decodedBytes = audio.webkitAudioDecodedByteCount;
                                if (window.__SocketLastDecodedBytes === undefined) {
                                    window.__SocketLastDecodedBytes = {};
                                }
                                const lastBytes = window.__SocketLastDecodedBytes[audio.src] || 0;
                                if (decodedBytes > lastBytes && audio.currentTime > 0) {
                                    drmAudioPlaying = true;
                                }
                                window.__SocketLastDecodedBytes[audio.src] = decodedBytes;
                            }

                            // Check if current time is progressing (for DRM content)
                            if (!window.__SocketLastCurrentTime) window.__SocketLastCurrentTime = {};
                            const lastTime = window.__SocketLastCurrentTime[audio.src] || 0;
                            if (audio.currentTime > lastTime + 0.1 && audio.readyState >= 2) {
                                drmAudioPlaying = true;
                            }
                            window.__SocketLastCurrentTime[audio.src] = audio.currentTime;
                        } catch (e) {
                            // Silently continue if WebKit properties aren't available
                        }

                        if (standardPlaying || drmAudioPlaying) {
                            hasPlayingAudio = true;
                        }
                    });

                    // Check video elements with enhanced detection
                    Array.from(videos).forEach(video => {
                        const standardPlaying = !video.paused && !video.ended && video.readyState >= 2;

                        // Enhanced detection for DRM video content
                        let drmVideoPlaying = false;
                        try {
                            // Check for decoded bytes (WebKit-specific)
                            if ('webkitAudioDecodedByteCount' in video || 'webkitVideoDecodedByteCount' in video) {
                                const audioBytes = video.webkitAudioDecodedByteCount || 0;
                                const videoBytes = video.webkitVideoDecodedByteCount || 0;
                                if (!window.__SocketLastVideoBytes) window.__SocketLastVideoBytes = {};
                                const lastAudioBytes = window.__SocketLastVideoBytes[video.src + '_audio'] || 0;
                                const lastVideoBytes = window.__SocketLastVideoBytes[video.src + '_video'] || 0;

                                if ((audioBytes > lastAudioBytes || videoBytes > lastVideoBytes) && video.currentTime > 0) {
                                    drmVideoPlaying = true;
                                }
                                window.__SocketLastVideoBytes[video.src + '_audio'] = audioBytes;
                                window.__SocketLastVideoBytes[video.src + '_video'] = videoBytes;
                            }

                            // Check if current time is progressing
                            if (!window.__SocketLastVideoCurrentTime) window.__SocketLastVideoCurrentTime = {};
                            const lastTime = window.__SocketLastVideoCurrentTime[video.src] || 0;
                            if (video.currentTime > lastTime + 0.1 && video.readyState >= 2) {
                                drmVideoPlaying = true;
                            }
                            window.__SocketLastVideoCurrentTime[video.src] = video.currentTime;
                        } catch (e) {
                            // Silently continue if WebKit properties aren't available
                        }

                        const isPlaying = standardPlaying || drmVideoPlaying;
                        if (isPlaying) {
                            hasPlayingVideo = true;
                            if (!video.muted && video.volume > 0) {
                                hasPlayingVideoWithAudio = true;
                            }
                        }
                    });

                    // Additional heuristic detection for streaming sites
                    let heuristicAudioDetected = false;
                    try {
                        // Check for common streaming site indicators
                        const isSpotify = window.location.hostname.includes('spotify.com');
                        const isYouTube = window.location.hostname.includes('youtube.com') || window.location.hostname.includes('youtu.be');
                        const isSoundCloud = window.location.hostname.includes('soundcloud.com');
                        const isAppleMusic = window.location.hostname.includes('music.apple.com');

                        if (isSpotify) {
                            const playButton = document.querySelector('[data-testid="control-button-playpause"]');
                            if (playButton) {
                                const ariaLabel = playButton.getAttribute('aria-label') || '';
                                heuristicAudioDetected = ariaLabel.toLowerCase().includes('pause');
                            }
                        } else if (isYouTube) {
                            const player = document.querySelector('.html5-video-player');
                            const video = document.querySelector('video');
                            if (player && video) {
                                heuristicAudioDetected = player.classList.contains('playing-mode') ||
                                                       (!video.paused && video.currentTime > 0);
                            }
                        } else if (isSoundCloud) {
                            const playButton = document.querySelector('.playControl');
                            heuristicAudioDetected = playButton && playButton.classList.contains('playing');
                        } else if (isAppleMusic) {
                            const playButton = document.querySelector('button[aria-label*="pause"], button[aria-label*="Pause"]');
                            heuristicAudioDetected = !!playButton;
                        }
                    } catch (e) {}

                    const hasAudioContent = hasPlayingAudio || hasPlayingVideoWithAudio || heuristicAudioDetected;

                    window.webkit.messageHandlers[handlerName].postMessage({
                        hasAudioContent: hasAudioContent,
                        hasPlayingAudio: hasAudioContent,
                        hasVideoContent: videos.length > 0,
                        hasPlayingVideo: hasPlayingVideo
                    });
                }

                function addAudioListeners(element) {
                    ['play', 'pause', 'ended', 'loadedmetadata', 'canplay', 'volumechange', 'timeupdate'].forEach(event => {
                        element.addEventListener(event, function() {
                            setTimeout(checkMediaState, 50);
                        });
                    });

                    try {
                        if ('webkitneedkey' in element) {
                            element.addEventListener('webkitneedkey', function() {
                                setTimeout(checkMediaState, 100);
                            });
                        }

                        if ('encrypted' in element) {
                            element.addEventListener('encrypted', function() {
                                setTimeout(checkMediaState, 100);
                            });
                        }
                    } catch (e) {}
                }

                document.querySelectorAll('video, audio').forEach(addAudioListeners);

                const mediaObserver = new MutationObserver(function(mutations) {
                    let hasChanges = false;
                    mutations.forEach(function(mutation) {
                        mutation.addedNodes.forEach(function(node) {
                            if (node.nodeType === 1) {
                                if (node.tagName === 'VIDEO' || node.tagName === 'AUDIO') {
                                    addAudioListeners(node);
                                    hasChanges = true;
                                } else if (node.querySelector) {
                                    const mediaElements = node.querySelectorAll('video, audio');
                                    if (mediaElements.length > 0) {
                                        mediaElements.forEach(addAudioListeners);
                                        hasChanges = true;
                                    }
                                }
                            }
                        });

                        mutation.removedNodes.forEach(function(node) {
                            if (node.nodeType === 1) {
                                if (node.tagName === 'VIDEO' || node.tagName === 'AUDIO' ||
                                    (node.querySelector && node.querySelectorAll('video, audio').length > 0)) {
                                    hasChanges = true;
                                }
                            }
                        });
                    });

                    if (hasChanges) {
                        setTimeout(checkMediaState, 100);
                    }
                });
                mediaObserver.observe(document.body, { childList: true, subtree: true });

                function setupStreamingSiteMonitoring() {
                    const hostname = window.location.hostname;

                    if (hostname.includes('spotify.com')) {
                        const observer = new MutationObserver(() => {
                            setTimeout(checkMediaState, 100);
                        });

                        const playerArea = document.querySelector('[data-testid="now-playing-widget"]') || document.body;
                        if (playerArea) {
                            observer.observe(playerArea, {
                                childList: true,
                                subtree: true,
                                attributes: true,
                                attributeFilter: ['aria-label', 'class', 'data-testid']
                            });
                        }
                    } else if (hostname.includes('youtube.com') || hostname.includes('youtu.be')) {
                        window.addEventListener('yt-navigate-finish', () => {
                            setTimeout(checkMediaState, 500);
                        });

                        const observer = new MutationObserver(() => {
                            setTimeout(checkMediaState, 100);
                        });

                        const playerElement = document.querySelector('#movie_player') || document.querySelector('.html5-video-player');
                        if (playerElement) {
                            observer.observe(playerElement, {
                                attributes: true,
                                attributeFilter: ['class']
                            });
                        }
                    } else if (hostname.includes('soundcloud.com')) {
                        const observer = new MutationObserver(() => {
                            setTimeout(checkMediaState, 100);
                        });

                        const playerElement = document.querySelector('.playControls') || document.body;
                        observer.observe(playerElement, {
                            childList: true,
                            subtree: true,
                            attributes: true,
                            attributeFilter: ['class']
                        });
                    } else if (hostname.includes('music.apple.com')) {
                        const observer = new MutationObserver(() => {
                            setTimeout(checkMediaState, 100);
                        });

                        const playerElement = document.querySelector('.web-chrome-playback-controls') || document.body;
                        observer.observe(playerElement, {
                            childList: true,
                            subtree: true,
                            attributes: true,
                            attributeFilter: ['aria-label', 'class']
                        });
                    }
                }

                setTimeout(setupStreamingSiteMonitoring, 1000);
                setTimeout(checkMediaState, 500);
                setInterval(() => {
                    checkMediaState();
                }, 5000);
            })();
            """

        webView.evaluateJavaScript(mediaDetectionScript) { result, error in
            if let error = error {
                print("[Media Detection] Error: \(error.localizedDescription)")
            } else {
                print("[Media Detection] Audio event tracking injected successfully")
            }
        }
    }

    func unloadWebView() {
        print("🔄 [Tab] Unloading webview for: \(name)")

        guard let webView = _webView else {
            print("🔄 [Tab] WebView already unloaded for: \(name)")
            return
        }

        // FORCE KILL ALL MEDIA AND PROCESSES
        webView.stopLoading()

        // Kill all media and PiP via JavaScript
        let killScript = """
            (() => {
                // FORCE KILL ALL PiP SESSIONS FIRST
                try {
                    // Exit any active PiP sessions
                    if (document.pictureInPictureElement) {
                        document.exitPictureInPicture();
                    }

                    // Force exit WebKit PiP for all videos
                    document.querySelectorAll('video').forEach(video => {
                        if (video.webkitSupportsPresentationMode && video.webkitPresentationMode === 'picture-in-picture') {
                            video.webkitSetPresentationMode('inline');
                        }
                    });

                    // Disable PiP on all videos permanently
                    document.querySelectorAll('video').forEach(video => {
                        video.disablePictureInPicture = true;
                        video.webkitSupportsPresentationMode = false;
                    });
                } catch (e) {
                    console.log('PiP destruction error:', e);
                }

                // Kill all media
                document.querySelectorAll('video, audio').forEach(el => {
                    el.pause();
                    el.currentTime = 0;
                    el.src = '';
                    el.load();
                    el.remove();
                });

                // Kill all WebAudio
                if (window.AudioContext || window.webkitAudioContext) {
                    if (window.__SocketAudioContexts) {
                        window.__SocketAudioContexts.forEach(ctx => ctx.close());
                        delete window.__SocketAudioContexts;
                    }
                }

                // Kill all timers
                const maxId = setTimeout(() => {}, 0);
                for (let i = 0; i < maxId; i++) {
                    clearTimeout(i);
                    clearInterval(i);
                }

                // Force garbage collection if available
                if (window.gc) {
                    window.gc();
                }
            })();
            """
        webView.evaluateJavaScript(killScript) { _, error in
            if let error = error {
                print("[Tab] Error during media/PiP kill in unload: \(error.localizedDescription)")
            } else {
                print("[Tab] Media and PiP successfully killed during unload for: \(self.name)")
            }
        }

        // Tear down the canonical Socket handlers plus the Tab-specific Web-Store
        // handler (whose target isn't Tab).
        SocketMessageHandlers.remove(from: webView, tabId: id)
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: "socketWebStore")

        // Remove from view hierarchy and clear delegates
        webView.removeFromSuperview()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil

        // Remove theme color and navigation state observers before clearing webview reference
        if let webView = _webView {
            removeThemeColorObserver(from: webView)
            removeNavigationStateObservers(from: webView)
        }

        // Clear the webview reference (this will trigger reload when accessed)
        _webView = nil

        // Stop native audio monitoring since webview is unloaded
        stopNativeAudioMonitoring()

        // Reset loading state
        loadingState = .idle

        print("💀 [Tab] WebView FORCE UNLOADED for: \(name)")
    }

    func loadWebViewIfNeeded() {
        if _webView == nil {
            print("🔄 [Tab] Loading webview for: \(name)")
            setupWebView()
        }
    }

    func toggleMute() {
        setMuted(!isAudioMuted)
    }

    func setMuted(_ muted: Bool) {
        if let webView = _webView {
            // Set the mute state using MuteableWKWebView's muted property
            webView.isMuted = muted
        } else {
            print("🔇 [Tab] Mute state queued at \(muted); base webView not loaded yet")
        }

        browserManager?.setMuteState(
            muted, for: id, originatingWindowId: browserManager?.windowRegistry?.activeWindow?.id)

        // Update our internal state
        DispatchQueue.main.async { [weak self] in
            self?.isAudioMuted = muted
        }
    }

    // MARK: - Native Audio Monitoring
    private func startNativeAudioMonitoring() {
        guard !isMonitoringNativeAudio else { return }
        isMonitoringNativeAudio = true

        audioMonitoringTimer = Timer.scheduledTimer(
            timeInterval: 1.0, target: self,
            selector: #selector(handleNativeAudioMonitoringTimer(_:)), userInfo: nil, repeats: true)

        setupAudioSessionNotifications()
    }

    private func stopNativeAudioMonitoring() {
        guard isMonitoringNativeAudio else { return }
        isMonitoringNativeAudio = false

        audioMonitoringTimer?.invalidate()
        audioMonitoringTimer = nil

        removeCoreAudioPropertyListeners()
    }

    private func setupAudioSessionNotifications() {
        setupCoreAudioPropertyListeners()
    }

    private func setupCoreAudioPropertyListeners() {
        guard !hasAddedCoreAudioListener else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        audioDeviceListenerProc = { (objectID, numAddresses, addresses, clientData) in
            guard let clientData = clientData else { return noErr }
            let tab = Unmanaged<Tab>.fromOpaque(clientData).takeUnretainedValue()

            DispatchQueue.main.async {
                tab.checkNativeAudioActivity()
            }

            return noErr
        }

        if let listenerProc = audioDeviceListenerProc {
            let status = AudioObjectAddPropertyListener(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                listenerProc,
                Unmanaged.passUnretained(self).toOpaque()
            )

            if status == noErr {
                hasAddedCoreAudioListener = true
            }
        }
    }

    private func removeCoreAudioPropertyListeners() {
        guard hasAddedCoreAudioListener, let listenerProc = audioDeviceListenerProc else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectRemovePropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            listenerProc,
            Unmanaged.passUnretained(self).toOpaque()
        )

        if status == noErr {
            hasAddedCoreAudioListener = false
            audioDeviceListenerProc = nil
        }
    }

    @objc private func handleNativeAudioMonitoringTimer(_ timer: Timer) {
        checkNativeAudioActivity()
    }

    private func checkNativeAudioActivity() {
        let now = Date()
        guard now.timeIntervalSince(lastAudioDeviceCheckTime) > 0.5 else { return }
        lastAudioDeviceCheckTime = now

        let isDeviceActive = isDefaultAudioDeviceActive()

        if isDeviceActive && hasAudioContent {
            if !hasPlayingAudio {
                hasPlayingAudio = true
            }
        } else if hasPlayingAudio && !isDeviceActive {
            hasPlayingAudio = false
        }
    }

    private func isDefaultAudioDeviceActive() -> Bool {
        var deviceID: AudioDeviceID = 0
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        )

        guard status == noErr else {
            return false
        }

        var isRunning: UInt32 = 0
        dataSize = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere

        let runningStatus = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            &isRunning
        )

        return runningStatus == noErr && isRunning != 0
    }

    // MARK: - Background Color Management
    func setupThemeColorObserver(for webView: WKWebView) {
        guard #available(macOS 12.0, *) else { return }
        if !themeColorObservedWebViews.contains(webView) {
            webView.addObserver(
                self, forKeyPath: "themeColor", options: [.new, .initial], context: nil)
            themeColorObservedWebViews.add(webView)
        }
    }

    func removeThemeColorObserver(from webView: WKWebView) {
        guard #available(macOS 12.0, *) else { return }
        if themeColorObservedWebViews.contains(webView) {
            webView.removeObserver(self, forKeyPath: "themeColor")
            themeColorObservedWebViews.remove(webView)
        }
    }

    // MARK: - Navigation State Observation

    /// Set up observers for navigation state properties.
    ///
    /// canGoBack / canGoForward don't need KVO at all — WKNavigationDelegate
    /// (didCommit / didFinish / didFail*) already calls
    /// `updateNavigationStateEnhanced`, which reads the live values. The old
    /// KVO path duplicated every delegate call with an extra main-thread hit.
    ///
    /// title still needs an observer (SPAs mutate document.title without a
    /// nav), but block-based `webView.observe(\.title)` is cheaper than
    /// NSObject KVO routed through `observeValue(forKeyPath:)`.
    func setupNavigationStateObservers(for webView: WKWebView) {
        guard !navigationStateObservedWebViews.contains(webView) else { return }
        titleObservation?.invalidate()
        canGoBackObservation?.invalidate()
        canGoForwardObservation?.invalidate()

        titleObservation = webView.observe(\.title, options: [.new]) { [weak self] wv, _ in
            guard let self else { return }
            guard let newTitle = wv.title, !newTitle.isEmpty, newTitle != self.name else { return }
            DispatchQueue.main.async { [weak self] in
                self?.updateTitle(newTitle)
            }
        }
        canGoBackObservation = webView.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { [weak self] in
                self?.updateNavigationState()
            }
        }
        canGoForwardObservation = webView.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { [weak self] in
                self?.updateNavigationState()
            }
        }
        navigationStateObservedWebViews.add(webView)
    }

    /// Tear down title + canGoBack / canGoForward observations.
    func removeNavigationStateObservers(from webView: WKWebView) {
        guard navigationStateObservedWebViews.contains(webView) else { return }
        titleObservation?.invalidate()
        titleObservation = nil
        canGoBackObservation?.invalidate()
        canGoBackObservation = nil
        canGoForwardObservation?.invalidate()
        canGoForwardObservation = nil
        navigationStateObservedWebViews.remove(webView)
    }

    /// MEMORY LEAK FIX: Comprehensive WebView cleanup to prevent memory leaks
    func cleanupCloneWebView(_ webView: WKWebView) {
        print("🧹 [Tab] Starting comprehensive WebView cleanup for: \(name)")

        // 1. Stop all loading and media
        webView.stopLoading()

        // 2. Kill all media and JavaScript execution
        let killScript = """
            (() => {
                try {
                    // Kill all media
                    document.querySelectorAll('video, audio').forEach(el => {
                        el.pause();
                        el.currentTime = 0;
                        el.src = '';
                        el.load();
                    });

                    // Kill all WebAudio contexts
                    if (window.AudioContext || window.webkitAudioContext) {
                        if (window.__SocketAudioContexts) {
                            window.__SocketAudioContexts.forEach(ctx => ctx.close());
                            delete window.__SocketAudioContexts;
                        }
                    }

                    // Kill all timers
                    const maxId = setTimeout(() => {}, 0);
                    for (let i = 0; i < maxId; i++) {
                        clearTimeout(i);
                        clearInterval(i);
                    }
                } catch (e) {
                    console.log('Cleanup script error:', e);
                }
            })();
            """
        webView.evaluateJavaScript(killScript) { _, error in
            if let error = error {
                print("⚠️ [Tab] Cleanup script error: \(error.localizedDescription)")
            }
        }

        // 3. Remove all Socket-owned message handlers (canonical + Web Store).
        SocketMessageHandlers.remove(from: webView, tabId: id)
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: "socketWebStore")

        // 4. MEMORY LEAK FIX: Detach contextMenuBridge before clearing delegates
        // This breaks the retain cycle: WKWebView → contextMenuBridge → userContentController → WKWebView
        if let focusableWebView = webView as? FocusableWKWebView {
            focusableWebView.contextMenuBridge?.detach()
            focusableWebView.contextMenuBridge = nil
        }

        // 5. Remove theme color and navigation state observers
        removeThemeColorObserver(from: webView)
        removeNavigationStateObservers(from: webView)

        // 6. Clear all delegates
        webView.navigationDelegate = nil
        webView.uiDelegate = nil

        // 7. Remove from view hierarchy
        webView.removeFromSuperview()

        // 7. Force remove from compositor
        browserManager?.webViewCoordinator?.removeWebViewFromContainers(webView)

        print("✅ [Tab] WebView cleanup completed for: \(name)")
    }

    /// MEMORY LEAK FIX: Comprehensive cleanup for the main tab WebView
    public func performComprehensiveWebViewCleanup() {
        guard let webView = _webView else { return }

        print("🧹 [Tab] Performing comprehensive cleanup for main WebView: \(name)")

        // Use the same comprehensive cleanup as clone WebViews
        cleanupCloneWebView(webView)

        // Additional cleanup for main WebView
        _webView = nil

        print("✅ [Tab] Main WebView cleanup completed for: \(name)")
    }

    public override func observeValue(
        forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        // Only themeColor still uses NSObject KVO here. canGoBack / canGoForward
        // are driven by the WKNavigationDelegate callbacks; title is observed via
        // a block-based NSKeyValueObservation in setupNavigationStateObservers.
        if keyPath == "themeColor", let webView = object as? WKWebView {
            updateBackgroundColor(from: webView)
            return
        }
        super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
    }

    private func updateBackgroundColor(from webView: WKWebView) {
        // Check if we should sample based on domain change
        guard let currentURL = webView.url,
              let currentDomain = extractDomain(from: currentURL) else {
            // If no URL/domain, still try theme color but skip pixel sampling
            if #available(macOS 12.0, *), let themeColor = webView.themeColor {
                DispatchQueue.main.async { [weak self] in
                    self?.pageBackgroundColor = themeColor
                    webView.underPageBackgroundColor = themeColor
                }
            }
            return
        }
        
        // Only sample if domain changed or we haven't sampled yet
        let shouldSample = lastSampledDomain != currentDomain
        
        var newColor: NSColor? = nil

        if #available(macOS 12.0, *) {
            newColor = webView.themeColor
        }

        if let themeColor = newColor {
            DispatchQueue.main.async { [weak self] in
                self?.pageBackgroundColor = themeColor
                webView.underPageBackgroundColor = themeColor
            }
        }

        if shouldSample {
            // Even when WebKit exposes a themeColor, keep running the more
            // specific page-background extractor once per domain. themeColor
            // is often a good first paint, but some sites without a true
            // page theme report a dark fallback here, which regresses the
            // visible gutters compared to Safari/Brave.
            extractBackgroundColorWithJavaScript(from: webView)
        }
    }
    
    /// Extract domain and subdomain from URL (e.g., "subdomain.example.com" -> "subdomain.example.com")
    private func extractDomain(from url: URL) -> String? {
        guard let host = url.host else { return nil }
        return host
    }

    private func extractBackgroundColorWithJavaScript(from webView: WKWebView) {
        guard let sampleRect = colorSampleRect(for: webView) else {
            runLegacyBackgroundColorScript(on: webView)
            return
        }

        let configuration = WKSnapshotConfiguration()
        configuration.rect = sampleRect
        configuration.afterScreenUpdates = true
        configuration.snapshotWidth = 1

        webView.takeSnapshot(with: configuration) { [weak self, weak webView] image, error in
            guard let self = self, let webView = webView else { return }

            if let color = image?.singlePixelColor {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.pageBackgroundColor = color
                    webView.underPageBackgroundColor = color
                    // Update sampled domain after successful extraction
                    if let currentURL = webView.url,
                       let currentDomain = self.extractDomain(from: currentURL) {
                        self.lastSampledDomain = currentDomain
                    }
                }
            } else {
                self.runLegacyBackgroundColorScript(on: webView)
            }
        }
    }

    private func colorSampleRect(for webView: WKWebView) -> CGRect? {
        let bounds = webView.bounds
        guard bounds.width >= 1, bounds.height >= 1 else { return nil }

        var sampleX = bounds.midX
        sampleX = min(max(bounds.minX, sampleX), bounds.maxX - 1)

        let offset: CGFloat = 2.0
        let yCandidate: CGFloat
        if webView.isFlipped {
            yCandidate = bounds.minY + offset
        } else {
            yCandidate = bounds.maxY - offset - 1
        }
        let sampleY = min(max(yCandidate, bounds.minY), bounds.maxY - 1)

        return CGRect(x: sampleX, y: sampleY, width: 1, height: 1)
    }
    
    private func topRightPixelRect(for webView: WKWebView) -> CGRect? {
        let bounds = webView.bounds
        guard bounds.width >= 1, bounds.height >= 1 else { return nil }
        
        // Sample the top-rightmost pixel
        let sampleX = bounds.maxX - 1
        let sampleY: CGFloat
        if webView.isFlipped {
            // In flipped coordinates, minY is at the top
            sampleY = bounds.minY
        } else {
            // In non-flipped coordinates, maxY is at the top
            sampleY = bounds.maxY - 1
        }
        
        return CGRect(x: sampleX, y: sampleY, width: 1, height: 1)
    }
    
    private func extractTopBarColor(from webView: WKWebView) {
        guard let sampleRect = topRightPixelRect(for: webView) else {
            return
        }
        
        let configuration = WKSnapshotConfiguration()
        configuration.rect = sampleRect
        configuration.afterScreenUpdates = true
        configuration.snapshotWidth = 1
        
        webView.takeSnapshot(with: configuration) { [weak self] image, error in
            guard let self = self else { return }
            
            if let color = image?.singlePixelColor {
                DispatchQueue.main.async {
                    self.topBarBackgroundColor = color
                }
            }
        }
    }

    private func runLegacyBackgroundColorScript(on webView: WKWebView) {
        let colorExtractionScript = """
            (function() {
                function rgbToHex(r, g, b) {
                    return '#' + [r, g, b].map(x => {
                        const hex = x.toString(16);
                        return hex.length === 1 ? '0' + hex : hex;
                    }).join('');
                }

                function parseColor(color) {
                    const div = document.createElement('div');
                    div.style.color = color;
                    document.body.appendChild(div);
                    const computedColor = window.getComputedStyle(div).color;
                    document.body.removeChild(div);

                    const match = computedColor.match(/rgb\\((\\d+),\\s*(\\d+),\\s*(\\d+)\\)/);
                    if (match) {
                        return rgbToHex(parseInt(match[1]), parseInt(match[2]), parseInt(match[3]));
                    }
                    return null;
                }

                function attributeBackgroundColor(element) {
                    if (!element || !element.getAttribute) {
                        return null;
                    }

                    const raw = element.getAttribute('bgcolor');
                    if (!raw) {
                        return null;
                    }

                    return parseColor(raw);
                }

                function computedBackgroundColor(element) {
                    if (!element) {
                        return null;
                    }

                    const bg = window.getComputedStyle(element).backgroundColor;
                    if (!bg || bg === 'rgba(0, 0, 0, 0)' || bg === 'transparent') {
                        return null;
                    }

                    return parseColor(bg);
                }

                function extractBackgroundColor() {
                    const body = document.body;
                    const html = document.documentElement;

                    const attributeCandidates = [
                        body,
                        html,
                        document.querySelector('#hnmain'),
                        document.querySelector('table[bgcolor]'),
                        document.querySelector('[bgcolor]')
                    ].filter(el => el);

                    for (const el of attributeCandidates) {
                        const attrBg = attributeBackgroundColor(el);
                        if (attrBg) {
                            return attrBg;
                        }
                    }

                    // Try body background first
                    const bodyBg = computedBackgroundColor(body);
                    if (bodyBg) {
                        return bodyBg;
                    }

                    // Try html background
                    const htmlBg = computedBackgroundColor(html);
                    if (htmlBg) {
                        return htmlBg;
                    }

                    // Try sampling dominant colors from visible elements
                    const sampleElements = [
                        document.elementFromPoint(window.innerWidth / 2, Math.max(1, window.innerHeight * 0.15)),
                        document.elementFromPoint(window.innerWidth / 2, window.innerHeight / 2),
                        document.querySelector('#hnmain'),
                        document.querySelector('table[bgcolor]'),
                        document.querySelector('header'),
                        document.querySelector('nav'),
                        document.querySelector('main'),
                        document.querySelector('article'),
                        document.querySelector('section'),
                        document.querySelector('.container'),
                        document.querySelector('#main'),
                        document.querySelector('[class*="background"]'),
                        document.querySelector('[class*="bg"]')
                    ].filter(el => el);

                    for (const el of sampleElements) {
                        const attrBg = attributeBackgroundColor(el);
                        if (attrBg) {
                            return attrBg;
                        }

                        const bg = computedBackgroundColor(el);
                        if (bg) {
                            return bg;
                        }
                    }

                    // Fallback: detect if page looks dark or light and return appropriate gray
                    const isDarkMode = window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches;
                    const textColor = window.getComputedStyle(body).color;
                    const isLightText = textColor && (textColor.includes('255') || textColor.includes('white'));

                    if (isDarkMode || isLightText) {
                        return '#1a1a1a'; // Dark gray for dark themes
                    } else {
                        return '#ffffff'; // White for light themes
                    }
                }

                const bgColor = extractBackgroundColor();
                if (bgColor) {
                    window.webkit.messageHandlers['backgroundColor_\(id.uuidString)'].postMessage({
                        backgroundColor: bgColor
                    });
                }
            })();
            """

        webView.evaluateJavaScript(colorExtractionScript) { _, _ in }
    }

    // MARK: - JavaScript Injection
    private func injectLinkHoverJavaScript(to webView: WKWebView) {
        let linkHoverScript = """
            (function() {
                if (window.__socketLinkHoverScriptInstalled) {
                    return;
                }
                window.__socketLinkHoverScriptInstalled = true;

                var currentHoveredLink = null;
                var isCommandPressed = false;
                var hoverCheckInterval = null;

                // Trailing-edge debounce per channel. On link lists the pointer
                // traverses dozens of <a>s in <100ms — without coalescing we
                // post a bridge message for every mouseenter/mouseleave. 50ms
                // is below perceptual threshold for a hover effect but far
                // above the raw mouse event rate.
                var HOVER_DEBOUNCE_MS = 50;
                var pendingLinkHover = { href: undefined, timer: null };
                var pendingCommandHover = { href: undefined, timer: null };

                function flushChannel(state, handlerName) {
                    state.timer = null;
                    var href = state.href;
                    state.href = undefined;
                    // Backgrounded tabs can't actually be hovered — if the
                    // document isn't visible, drop the post. Prevents cross-tab
                    // hover storms from mattering when the user is focused
                    // elsewhere.
                    if (document.visibilityState !== 'visible') { return; }
                    var handlers = window.webkit && window.webkit.messageHandlers;
                    if (handlers && handlers[handlerName]) {
                        handlers[handlerName].postMessage(href == null ? null : href);
                    }
                }

                function queueLinkHover(href) {
                    pendingLinkHover.href = href;
                    if (pendingLinkHover.timer != null) { return; }
                    pendingLinkHover.timer = setTimeout(function () {
                        flushChannel(pendingLinkHover, 'linkHover');
                    }, HOVER_DEBOUNCE_MS);
                }

                function queueCommandHover(href) {
                    pendingCommandHover.href = href;
                    if (pendingCommandHover.timer != null) { return; }
                    pendingCommandHover.timer = setTimeout(function () {
                        flushChannel(pendingCommandHover, 'commandHover');
                    }, HOVER_DEBOUNCE_MS);
                }

                function sendLinkHover(href) { queueLinkHover(href); }
                function sendCommandHover(href) { queueCommandHover(href); }

                // Track Command key state
                document.addEventListener('keydown', function(e) {
                    if (e.metaKey) {
                        isCommandPressed = true;
                        if (currentHoveredLink) {
                            sendCommandHover(currentHoveredLink);
                        }
                    }
                });

                document.addEventListener('keyup', function(e) {
                    if (!e.metaKey) {
                        isCommandPressed = false;
                        sendCommandHover(null);
                    }
                });

                function findAnchor(startNode) {
                    var target = startNode;
                    while (target && target !== document) {
                        if (target.tagName === 'A' && target.href) {
                            return target;
                        }
                        target = target.parentElement;
                    }
                    return null;
                }

                // Event delegation (replaces per-link listener attachment +
                // document-wide subtree MutationObserver). mouseover/mouseout
                // bubble, so one pair of document-level listeners covers every
                // present and future <a> on the page — no attachment churn on
                // DOM mutations.
                document.addEventListener('mouseover', function (e) {
                    var anchor = findAnchor(e.target);
                    if (!anchor) { return; }
                    if (currentHoveredLink === anchor.href) { return; }
                    currentHoveredLink = anchor.href;
                    sendLinkHover(anchor.href);
                    if (isCommandPressed) {
                        sendCommandHover(anchor.href);
                    }
                }, { passive: true, capture: true });

                document.addEventListener('mouseout', function (e) {
                    var fromAnchor = findAnchor(e.target);
                    if (!fromAnchor) { return; }
                    // Only clear when the pointer actually left this anchor's
                    // subtree (mouseout also fires when crossing nested children).
                    var toAnchor = findAnchor(e.relatedTarget);
                    if (toAnchor && toAnchor.href === fromAnchor.href) { return; }
                    if (currentHoveredLink === fromAnchor.href) {
                        currentHoveredLink = null;
                        sendLinkHover(null);
                        sendCommandHover(null);
                    }
                }, { passive: true, capture: true });

                function handleModifiedLinkOpen(e) {
                    if (e.metaKey || e.shiftKey) {
                        var anchor = findAnchor(e.target);
                        if (!anchor) {
                            return;
                        }

                        e.preventDefault();
                        if (typeof e.stopImmediatePropagation === 'function') {
                            e.stopImmediatePropagation();
                        }
                        e.stopPropagation();

                        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.commandClick) {
                            window.webkit.messageHandlers.commandClick.postMessage({
                                href: anchor.href,
                                openInSplit: !!e.shiftKey,
                                openAsChild: !!e.metaKey
                            });
                        }
                        return false;
                    }
                }

                // Capture phase prevents WebKit from also treating the same gesture as a native new tab/window open.
                document.addEventListener('click', handleModifiedLinkOpen, true);
            })();
            """

        webView.evaluateJavaScript(linkHoverScript) { result, error in
            if let error = error {
                print("Error injecting link hover JavaScript: \(error.localizedDescription)")
            }
        }
    }

    private func injectHistoryStateObserver(into webView: WKWebView) {
        let historyScript = """
            (function() {
                if (window.__socketHistorySyncInstalled) { return; }
                window.__socketHistorySyncInstalled = true;

                function notify() {
                    try {
                        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.historyStateDidChange) {
                            window.webkit.messageHandlers.historyStateDidChange.postMessage(window.location.href);
                        }
                    } catch (err) {
                        console.error('historyStateDidChange failed', err);
                    }
                }

                var originalPushState = history.pushState;
                history.pushState = function() {
                    var result = originalPushState.apply(this, arguments);
                    setTimeout(notify, 0);
                    return result;
                };

                var originalReplaceState = history.replaceState;
                history.replaceState = function() {
                    var result = originalReplaceState.apply(this, arguments);
                    setTimeout(notify, 0);
                    return result;
                };

                window.addEventListener('popstate', notify);
                window.addEventListener('hashchange', notify);
                document.addEventListener('yt-navigate-finish', notify);

                notify();
            })();
            """

        webView.evaluateJavaScript(historyScript) { _, error in
            if let error = error {
                print(
                    "[Tab] Error injecting history observer JavaScript: \(error.localizedDescription)"
                )
            }
        }
    }

    private func injectPiPStateListener(to webView: WKWebView) {
        let pipStateScript = """
            (function() {
                function notifyPiPStateChange(isActive) {
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.pipStateChange) {
                        window.webkit.messageHandlers.pipStateChange.postMessage({ active: isActive });
                    }
                }

                document.addEventListener('enterpictureinpicture', function() {
                    notifyPiPStateChange(true);
                });

                document.addEventListener('leavepictureinpicture', function() {
                    notifyPiPStateChange(false);
                });

                const videos = document.querySelectorAll('video');
                videos.forEach(video => {
                    if (video.webkitSupportsPresentationMode) {
                        video.addEventListener('webkitpresentationmodechanged', function() {
                            const isInPiP = video.webkitPresentationMode === 'picture-in-picture';
                            notifyPiPStateChange(isInPiP);
                        });
                    }
                });

                const observer = new MutationObserver(function(mutations) {
                    mutations.forEach(function(mutation) {
                        mutation.addedNodes.forEach(function(node) {
                            if (node.tagName === 'VIDEO' && node.webkitSupportsPresentationMode) {
                                node.addEventListener('webkitpresentationmodechanged', function() {
                                    const isInPiP = node.webkitPresentationMode === 'picture-in-picture';
                                    notifyPiPStateChange(isInPiP);
                                });
                            }
                        });
                    });
                });

                observer.observe(document.body, { childList: true, subtree: true });
            })();
            """

        webView.evaluateJavaScript(pipStateScript) { result, error in
            if let error = error {
                print("Error injecting PiP state listener: \(error.localizedDescription)")
            } else {
                print("[PiP] State listener injected successfully")
            }
        }
    }
    
    private func injectShortcutDetection(to webView: WKWebView) {
        // Inject the JS script from WebsiteShortcutDetector for runtime shortcut detection
        let script = WebsiteShortcutDetector.jsDetectionScript
        
        webView.evaluateJavaScript(script) { _, error in
            if let error = error {
                print("⚠️ [Tab] Error injecting shortcut detection: \(error.localizedDescription)")
            } else {
                print("⌨️ [Tab] Shortcut detection script injected")
            }
        }
    }

    func activate() {
        browserManager?.tabManager.setActiveTab(self)
        // Media state is automatically tracked by injected script
    }

    func pause() {
        if !hasPiPActive && !PiPManager.shared.isPiPActive(for: self) {
            _webView?.evaluateJavaScript(
                "document.querySelectorAll('video, audio').forEach(el => el.pause());",
                completionHandler: nil
            )
        }

        hasPlayingVideo = false
        hasPlayingAudio = false
    }

    func updateTitle(_ title: String) {
        let newName = title.isEmpty ? url.host ?? "New Tab" : title
        // Only update if title actually changed to prevent redundant redraws
        guard newName != self.name else { return }
        self.name = newName
        if #available(macOS 15.5, *) {
            ExtensionManager.shared.notifyTabPropertiesChanged(self, properties: [.title])
        }
    }

    // MARK: - Favicon Logic
    private func fetchAndSetFavicon(for url: URL) async {
        let defaultFavicon = SwiftUI.Image(systemName: "globe")

        // Skip favicon fetching for non-web schemes
        guard url.scheme == "http" || url.scheme == "https", url.host != nil
        else {
            await MainActor.run {
                self.favicon = defaultFavicon
            }
            return
        }

        // Check cache first
        let cacheKey = url.host ?? url.absoluteString
        if let cachedFavicon = Self.getCachedFavicon(for: cacheKey) {
            print("🎯 [Favicon] Cache hit for: \(cacheKey)")
            await MainActor.run {
                self.favicon = cachedFavicon
            }
            return
        }

        print("🌐 [Favicon] Cache miss for: \(cacheKey), fetching from network...")

        do {
            let favicon = try await FaviconFinder(url: url)
                .fetchFaviconURLs()
                .download()
                .largest()

            if let faviconImage = favicon.image {
                let nsImage = faviconImage.image
                let swiftUIImage = SwiftUI.Image(nsImage: nsImage)

                // Cache the favicon (both in memory and on disk)
                Self.cacheFavicon(swiftUIImage, for: cacheKey)
                Self.saveFaviconToDisk(nsImage, for: cacheKey)
                print("💾 [Favicon] Cached favicon for: \(cacheKey)")

                await MainActor.run {
                    self.favicon = swiftUIImage
                }
            } else {
                await MainActor.run {
                    self.favicon = defaultFavicon
                }
            }
        } catch {
            print(
                "Error fetching favicon for \(url): \(error.localizedDescription)"
            )
            await MainActor.run {
                self.favicon = defaultFavicon
            }
        }
    }

    // MARK: - Favicon Cache Management
    static func getCachedFavicon(for key: String) -> SwiftUI.Image? {
        faviconCacheLock.lock()
        defer { faviconCacheLock.unlock() }

        // Check memory cache first
        if let cachedFavicon = faviconCache[key] {
            return cachedFavicon
        }

        // Check persistent cache
        if let persistentFavicon = loadFaviconFromDisk(for: key) {
            // Load into memory cache for faster access
            faviconCache[key] = persistentFavicon
            return persistentFavicon
        }

        return nil
    }

    static func cacheFavicon(_ favicon: SwiftUI.Image, for key: String) {
        faviconCacheLock.lock()
        defer { faviconCacheLock.unlock() }

        faviconCache[key] = favicon

        // MEMORY LEAK FIX: Maintain insertion order for proper LRU eviction
        faviconCacheOrder.removeAll { $0 == key }
        faviconCacheOrder.append(key)

        // Evict oldest entries when cache exceeds max size
        if faviconCache.count > faviconCacheMaxSize {
            let evictCount = faviconCache.count - faviconCacheMaxSize + 20
            let keysToRemove = Array(faviconCacheOrder.prefix(evictCount))
            for keyToRemove in keysToRemove {
                faviconCache.removeValue(forKey: keyToRemove)
                removeFaviconFromDisk(for: keyToRemove)
            }
            faviconCacheOrder.removeFirst(min(evictCount, faviconCacheOrder.count))
        }
    }

    // MARK: - Cache Management
    static func clearFaviconCache() {
        faviconCacheLock.lock()
        defer { faviconCacheLock.unlock() }
        faviconCache.removeAll()
        clearAllFaviconCacheFromDisk()
    }

    static func getFaviconCacheStats() -> (count: Int, domains: [String]) {
        faviconCacheLock.lock()
        defer { faviconCacheLock.unlock() }
        return (faviconCache.count, Array(faviconCache.keys))
    }

    // MARK: - Persistent Storage Helpers
    private static func saveFaviconToDisk(_ nsImage: NSImage, for key: String) {
        let fileURL = faviconCacheDirectory.appendingPathComponent("\(key).png")

        // Convert NSImage to PNG data and save
        if let tiffData = nsImage.tiffRepresentation,
            let bitmapRep = NSBitmapImageRep(data: tiffData),
            let pngData = bitmapRep.representation(using: .png, properties: [:])
        {
            try? pngData.write(to: fileURL)
        }
    }

    private static func loadFaviconFromDisk(for key: String) -> SwiftUI.Image? {
        let fileURL = faviconCacheDirectory.appendingPathComponent("\(key).png")

        guard let imageData = try? Data(contentsOf: fileURL),
            let nsImage = NSImage(data: imageData)
        else {
            return nil
        }

        return SwiftUI.Image(nsImage: nsImage)
    }

    private static func removeFaviconFromDisk(for key: String) {
        let fileURL = faviconCacheDirectory.appendingPathComponent("\(key).png")
        try? FileManager.default.removeItem(at: fileURL)
    }

    private static func clearAllFaviconCacheFromDisk() {
        try? FileManager.default.removeItem(at: faviconCacheDirectory)
        try? FileManager.default.createDirectory(
            at: faviconCacheDirectory, withIntermediateDirectories: true)
    }
}

// MARK: - WKNavigationDelegate
extension Tab: WKNavigationDelegate {

    // MARK: - Loading Start
    public func webView(
        _ webView: WKWebView,
        didStartProvisionalNavigation navigation: WKNavigation!
    ) {
        // If a previous navigation never resolved, close its interval before
        // starting a new one so Instruments doesn't chain them together.
        if let prior = navigationSignpostState {
            PerfSignpost.navigation.endInterval("Navigation", prior)
        }
        navigationSignpostState = PerfSignpost.navigation.beginInterval("Navigation")
        print(
            "🌐 [Tab] didStartProvisionalNavigation for: \(webView.url?.absoluteString ?? "unknown")"
        )
        loadingState = .didStartProvisionalNavigation
        if #available(macOS 15.5, *) {
            ExtensionManager.shared.notifyTabPropertiesChanged(self, properties: [.loading])
        }

        if let newURL = webView.url {
            // Only reset for actual URL changes, not just reloads
            if newURL.absoluteString != self.url.absoluteString {
                hasAudioContent = false
                hasPlayingAudio = false
                // Note: isAudioMuted is preserved to maintain user's mute preference
                print(
                    "🔄 [Tab] Swift reset audio tracking for navigation to: \(newURL.absoluteString)"
                )
                // Reset sampled domain to force resampling on new page
                if let newDomain = extractDomain(from: newURL),
                   newDomain != lastSampledDomain {
                    lastSampledDomain = nil
                }
                // Update URL but don't persist yet - wait for navigation to complete
                self.url = newURL
            } else {
                self.url = newURL
            }
        }

        logAuthTrace("didStartProvisionalNavigation", currentURL: webView.url)

        browserManager?.trackingProtectionManager.handleDidStartNavigation(for: self)
    }

    // MARK: - Content Committed
    public func webView(
        _ webView: WKWebView,
        didCommit navigation: WKNavigation!
    ) {
        print("🌐 [Tab] didCommit navigation for: \(webView.url?.absoluteString ?? "unknown")")
        loadingState = .didCommit
        if #available(macOS 15.5, *) {
            ExtensionManager.shared.notifyTabPropertiesChanged(self, properties: [.loading])
        }

        if let newURL = webView.url {
            self.url = newURL
            synchronizePersistedNavigationHistory(with: newURL)
            if isOAuthFlow {
                if oauthInitialURL == nil {
                    oauthInitialURL = newURL
                } else if oauthInitialURL?.absoluteString != newURL.absoluteString {
                    oauthDidProgress = true
                }

                if let host = newURL.host?.lowercased(),
                   host != oauthCompletionURLPattern?.lowercased() {
                    oauthProviderHost = host
                    browserManager?.oauthAllowDomain(host)
                }
            }
            browserManager?.syncTabAcrossWindows(self.id)
            // Update website shortcut detector with new URL
            browserManager?.keyboardShortcutManager?.websiteShortcutDetector.updateCurrentURL(newURL)
            if #available(macOS 15.5, *) {
                ExtensionManager.shared.notifyTabPropertiesChanged(self, properties: [.URL])
            }
            // Don't persist here - wait for navigation to complete
        }

        logAuthTrace(
            "didCommit",
            currentURL: webView.url,
            extra: "oauthDidProgress=\(oauthDidProgress) initialURL=\(oauthInitialURL?.absoluteString ?? "nil")"
        )

        if isOAuthFlow, let currentURL = webView.url {
            scheduleSiteOwnedOAuthBridgeIfNeeded(in: webView, currentURL: currentURL)
        }

    }

    // MARK: - Loading Success
    public func webView(
        _ webView: WKWebView,
        didFinish navigation: WKNavigation!
    ) {
        if let state = navigationSignpostState {
            PerfSignpost.navigation.endInterval("Navigation", state)
            navigationSignpostState = nil
        }
        print("✅ [Tab] didFinish navigation for: \(webView.url?.absoluteString ?? "unknown")")
        loadingState = .didFinish
        if #available(macOS 15.5, *) {
            ExtensionManager.shared.notifyTabPropertiesChanged(self, properties: [.loading])
        }

        if let newURL = webView.url {
            self.url = newURL
            synchronizePersistedNavigationHistory(with: newURL)
            if #available(macOS 15.5, *) {
                ExtensionManager.shared.notifyTabPropertiesChanged(self, properties: [.URL])

                // Extension diagnostics: check content scripts, background worker, and messaging
                ExtensionManager.shared.diagnoseExtensionState(for: webView, url: newURL)
            }
            browserManager?.syncTabAcrossWindows(self.id)

            // Load saved zoom level for the new domain
            browserManager?.loadZoomForTab(self.id)

            // CHROME WEB STORE INTEGRATION: Inject script after navigation
            injectWebStoreScriptIfNeeded(for: newURL, in: webView)

            // BOOSTS: Inject boost if domain has one configured
            injectBoostIfNeeded(for: newURL, in: webView)
        }

        if let loadedURL = webView.url, !isOAuthFlow {
            handlePendingOAuthReturnIfNeeded(afterLoading: loadedURL)
            if shouldTraceAuth(url: loadedURL),
               shouldLoadOAuthCallbackInParent(loadedURL, parentTab: self) {
                logAuthCookieSnapshot(
                    reason: "oauth-parent-cookie-snapshot",
                    webView: webView,
                    currentURL: loadedURL
                )
            }
        }

        if let loadedURL = webView.url {
            scheduleAuthPageDiagnosticsIfNeeded(
                in: webView,
                currentURL: loadedURL,
                phase: isOAuthFlow ? "oauth-popup-didFinish" : "didFinish"
            )
        }

        // CRITICAL: Update navigation state after back/forward navigation
        updateNavigationStateEnhanced(source: "didFinish")

        webView.evaluateJavaScript("document.title") {
            [weak self] result, error in
            if let title = result as? String {
                print("📄 [Tab] Got title from JavaScript: '\(title)'")
                DispatchQueue.main.async {
                    self?.updateTitle(title)

                    // Add to profile-aware history after title is updated
                    if let currentURL = webView.url {
                        let profile = self?.resolveProfile()
                        let profileId = profile?.id ?? self?.browserManager?.currentProfile?.id
                        let isEphemeral = profile?.isEphemeral ?? false
                        self?.browserManager?.historyManager.addVisit(
                            url: currentURL,
                            title: title,
                            timestamp: Date(),
                            tabId: self?.id,
                            profileId: profileId,
                            isEphemeral: isEphemeral
                        )
                    }

                    // Persist tab changes after navigation completes (only once)
                    self?.browserManager?.tabManager.persistSnapshot()
                }
            } else if let jsError = error {
                print("⚠️ [Tab] Failed to get document.title: \(jsError.localizedDescription)")
                // Still persist even if title fetch failed, since URL was updated
                DispatchQueue.main.async {
                    self?.browserManager?.tabManager.persistSnapshot()
                }
            }
        }

        // Fetch favicon after page loads
        if let currentURL = webView.url {
            Task { @MainActor in
                await self.fetchAndSetFavicon(for: currentURL)
            }
        }

        injectLinkHoverJavaScript(to: webView)
        injectPiPStateListener(to: webView)
        injectMediaDetection(to: webView)
        injectHistoryStateObserver(into: webView)
        // Shortcut detection is already attached as a documentEnd userScript
        // (WebViewCoordinator.swift). The script's idempotency guard makes a
        // post-didFinish re-evaluation a no-op except for parse cost — skip.
        updateNavigationStateEnhanced(source: "didCommit")

        // Trigger background color extraction after page fully loads
        // Wait a bit for boosts to apply and rendering to complete
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self, weak webView] in
            guard let self = self, let webView = webView else { return }
            // Only sample if page is still loaded (not navigating away)
            if self.loadingState == .didFinish {
                self.updateBackgroundColor(from: webView)
                // Extract top bar color once per page load (resamples on any navigation)
                self.extractTopBarColor(from: webView)
            }
        }

        // Apply mute state using MuteableWKWebView if the tab was previously muted
        if isAudioMuted {
            setMuted(true)
        }
        
        // Check for OAuth completion and auto-close if needed
        if isOAuthFlow, let currentURL = webView.url {
            logOAuthPopupRuntimeState(in: webView, phase: "didFinish")
            checkOAuthCompletion(url: currentURL)
        }


        logAuthTrace(
            "didFinish",
            currentURL: webView.url,
            extra: "title=\(webView.title ?? "nil")"
        )

        browserManager?.trackingProtectionManager.handleDidFinishNavigation(for: self, webView: webView)
    }

    // MARK: - Loading Failed (after content started loading)
    public func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        if let state = navigationSignpostState {
            PerfSignpost.navigation.endInterval("Navigation", state)
            navigationSignpostState = nil
        }
        print("❌ [Tab] didFail navigation for: \(webView.url?.absoluteString ?? "unknown")")
        print("   Error: \(error.localizedDescription)")
        loadingState = .didFail(error)

        // Set error favicon on navigation failure
        Task { @MainActor in
            self.favicon = Image(systemName: "exclamationmark.triangle")
        }

        updateNavigationStateEnhanced(source: "didFail")
        logAuthTrace("didFail", currentURL: webView.url, extra: "error=\(error.localizedDescription)")
        browserManager?.trackingProtectionManager.handleNavigationFailure(for: self)
    }

    // MARK: - Loading Failed (before content started loading)
    public func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        if let state = navigationSignpostState {
            PerfSignpost.navigation.endInterval("Navigation", state)
            navigationSignpostState = nil
        }
        print(
            "💥 [Tab] didFailProvisionalNavigation for: \(webView.url?.absoluteString ?? "unknown")")
        print("   Error: \(error.localizedDescription)")
        loadingState = .didFailProvisionalNavigation(error)

        // Set connection error favicon
        Task { @MainActor in
            self.favicon = Image(systemName: "wifi.exclamationmark")
        }

        updateNavigationStateEnhanced(source: "didFailProvisional")
        logAuthTrace(
            "didFailProvisionalNavigation",
            currentURL: webView.url,
            extra: "error=\(error.localizedDescription)"
        )
        browserManager?.trackingProtectionManager.handleNavigationFailure(for: self)
    }

    public func webView(
        _ webView: WKWebView,
        didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!
    ) {
        logAuthTrace("didReceiveServerRedirect", currentURL: webView.url)
    }

    public func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if let handled = browserManager?.authenticationManager.handleAuthenticationChallenge(
            challenge,
            for: self,
            completionHandler: completionHandler
        ), handled {
            return
        }

        completionHandler(.performDefaultHandling, nil)
    }

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if let destinationURL = navigationAction.request.url, shouldTraceAuth(url: destinationURL) {
            let sourceURL = navigationAction.sourceFrame.request.url?.absoluteString ?? "nil"
            let targetFrameDescription: String
            if let targetFrame = navigationAction.targetFrame {
                targetFrameDescription = targetFrame.isMainFrame ? "main-frame" : "sub-frame"
            } else {
                targetFrameDescription = "nil"
            }
            logAuthTrace(
                "decidePolicyForNavigationAction",
                currentURL: destinationURL,
                extra:
                    "sourceURL=\(sourceURL) navType=\(authNavigationTypeDescription(navigationAction.navigationType)) targetFrame=\(targetFrameDescription)"
            )
        }

        if let url = navigationAction.request.url,
            navigationAction.targetFrame?.isMainFrame == true
        {
            browserManager?.maybeShowOAuthAssist(for: url, in: self)

            // Grant extension access to this URL BEFORE navigation starts
            // so content scripts can inject at document_start
            if #available(macOS 15.4, *) {
                ExtensionManager.shared.grantExtensionAccessToURL(url)
            }

            // Inject Shields scriptlets for this URL BEFORE the load
            // begins. WKUserScripts added after `.load()` apply to the
            // *next* navigation, so this must happen here. Engine
            // returns empty (no-op) for URLs with no scriptlet rules.
            browserManager?.trackingProtectionManager.applyURLSpecificScriptlets(
                for: url,
                on: webView
            )

            // Setup boost user script before navigation starts
            setupBoostUserScript(for: url, in: webView)

            // UA spoof: a few extension-critical hosts branch on User-Agent
            // (Chrome Web Store's "Add to Chrome" button; Zoom's
            // logintransit page). Present a Chrome UA on just those pages;
            // reset elsewhere so the rest of the web sees Socket's normal
            // Safari-like UA.
            if Self.requiresChromeUserAgentSpoof(url) {
                webView.customUserAgent = Self.chromeWebStoreSpoofUserAgent
            } else if webView.customUserAgent != nil {
                webView.customUserAgent = nil
            }

            // Pre-wake the background service worker for the navigating
            // extension contexts when the URL matches any content script
            // match pattern. Prevents a race where the content script fires
            // at document_end but `runtime.sendMessage` lands on a suspended
            // background worker and gets dropped. This is best-effort; any
            // error is logged by WKWebExtension itself.
            if #available(macOS 15.5, *) {
                ExtensionManager.shared.warmBackgroundIfNeeded(for: url)
            }
        }


        // Check for Option+click to trigger Peek for any link
        if let url = navigationAction.request.url,
            navigationAction.navigationType == .linkActivated,
            isOptionKeyDown
        {

            // Trigger Peek instead of normal navigation
            decisionHandler(.cancel)
            RunLoop.current.perform { [weak self] in
                guard let self else { return }
                self.browserManager?.peekManager.presentExternalURL(url, from: self)
            }
            return
        }

        if #available(macOS 12.3, *), navigationAction.shouldPerformDownload {
            decisionHandler(.download)
            return
        }

        decisionHandler(.allow)
    }

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        if shouldTraceAuth(url: navigationResponse.response.url) {
            let responseURL = navigationResponse.response.url?.absoluteString ?? "nil"
            let mimeType = navigationResponse.response.mimeType ?? "nil"
            let httpResponse = navigationResponse.response as? HTTPURLResponse
            let statusCode = httpResponse?.statusCode ?? -1
            let setCookieNames = httpResponse.map { Self.authSetCookieNames(from: $0) } ?? []
            logAuthTrace(
                "decidePolicyForNavigationResponse",
                currentURL: navigationResponse.response.url,
                extra:
                    "status=\(statusCode) isMainFrame=\(navigationResponse.isForMainFrame) canShowMIMEType=\(navigationResponse.canShowMIMEType) mimeType=\(mimeType) responseURL=\(responseURL) setCookieNames=\(setCookieNames)"
            )
        }

        if let response = navigationResponse.response as? HTTPURLResponse,
            let disposition = response.allHeaderFields["Content-Disposition"] as? String,
            disposition.lowercased().contains("attachment")
        {
            decisionHandler(.download)
            return
        }

        if navigationResponse.isForMainFrame && !navigationResponse.canShowMIMEType {
            decisionHandler(.download)
            return
        }

        decisionHandler(.allow)
    }

    //MARK: - Downloads
    public func webView(
        _ webView: WKWebView,
        navigationAction: WKNavigationAction,
        didBecome download: WKDownload
    ) {
        let originalURL = navigationAction.request.url ?? URL(string: "https://example.com")!
        let suggestedFilename = navigationAction.request.url?.lastPathComponent ?? "download"

        print("🔽 [Tab] Download started from navigationAction: \(originalURL.absoluteString)")
        print("🔽 [Tab] Suggested filename: \(suggestedFilename)")
        print("🔽 [Tab] BrowserManager available: \(browserManager != nil)")

        _ = browserManager?.downloadManager.addDownload(
            download, originalURL: originalURL, suggestedFilename: suggestedFilename)
    }

    public func webView(
        _ webView: WKWebView,
        navigationResponse: WKNavigationResponse,
        didBecome download: WKDownload
    ) {
        let originalURL = navigationResponse.response.url ?? URL(string: "https://example.com")!
        let suggestedFilename = navigationResponse.response.url?.lastPathComponent ?? "download"

        print("🔽 [Tab] Download started from navigationResponse: \(originalURL.absoluteString)")
        print("🔽 [Tab] Suggested filename: \(suggestedFilename)")
        print("🔽 [Tab] BrowserManager available: \(browserManager != nil)")

        _ = browserManager?.downloadManager.addDownload(
            download, originalURL: originalURL, suggestedFilename: suggestedFilename)
    }

    // MARK: - WKDownloadDelegate
    public func download(
        _ download: WKDownload, decideDestinationUsing response: URLResponse,
        suggestedFilename: String, completionHandler: @escaping (URL?) -> Void
    ) {
        print("🔽 [Tab] WKDownloadDelegate decideDestinationUsing called")
        // Handle download destination directly
        guard
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)
                .first
        else {
            completionHandler(nil)
            return
        }

        let defaultName = suggestedFilename.isEmpty ? "download" : suggestedFilename
        let cleanName = defaultName.replacingOccurrences(of: "/", with: "_")
        var dest = downloads.appendingPathComponent(cleanName)

        // Handle duplicate files
        let ext = dest.pathExtension
        let base = dest.deletingPathExtension().lastPathComponent
        var counter = 1
        while FileManager.default.fileExists(atPath: dest.path) {
            let newName = "\(base) (\(counter))" + (ext.isEmpty ? "" : ".\(ext)")
            dest = downloads.appendingPathComponent(newName)
            counter += 1
        }

        print("🔽 [Tab] Download destination set: \(dest.path)")
        completionHandler(dest)
    }

    public func download(
        _ download: WKDownload, decideDestinationUsing response: URLResponse,
        suggestedFilename: String, completionHandler: @escaping (URL, Bool) -> Void
    ) {
        print("🔽 [Tab] WKDownloadDelegate decideDestinationUsing (macOS) called")
        // Handle download destination directly for macOS
        guard
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)
                .first
        else {
            completionHandler(
                FileManager.default.temporaryDirectory.appendingPathComponent("download"), false)
            return
        }

        let defaultName = suggestedFilename.isEmpty ? "download" : suggestedFilename
        let cleanName = defaultName.replacingOccurrences(of: "/", with: "_")
        var dest = downloads.appendingPathComponent(cleanName)

        // Handle duplicate files
        let ext = dest.pathExtension
        let base = dest.deletingPathExtension().lastPathComponent
        var counter = 1
        while FileManager.default.fileExists(atPath: dest.path) {
            let newName = "\(base) (\(counter))" + (ext.isEmpty ? "" : ".\(ext)")
            dest = downloads.appendingPathComponent(newName)
            counter += 1
        }

        print("🔽 [Tab] Download destination set: \(dest.path)")
        // Return true to grant sandbox extension - this allows WebKit to write to the destination
        completionHandler(dest, true)
    }

    public func download(_ download: WKDownload, didFinishDownloadingTo location: URL) {
        print("🔽 [Tab] Download finished to: \(location.path)")
        // Download completed successfully
    }

    public func download(_ download: WKDownload, didFailWithError error: Error) {
        print("🔽 [Tab] Download failed: \(error.localizedDescription)")
        // Download failed
    }

}

// MARK: - WKScriptMessageHandlerWithReply (passwordAutofillRequest)
extension Tab: WKScriptMessageHandlerWithReply {
    public func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        switch message.name {
        case "passwordAutofillRequest":
            browserManager?.passwordManager.handleAutofillRequest(
                message.body,
                tab: self,
                reply: { value, error in
                    replyHandler(value, error)
                }
            )
        default:
            replyHandler(nil, "Unhandled message: \(message.name)")
        }
    }
}

// MARK: - WKScriptMessageHandler
extension Tab: WKScriptMessageHandler {
    public func userContentController(
        _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
    ) {
        switch message.name {
        case "linkHover":
            let href = message.body as? String
            DispatchQueue.main.async {
                // Warm DNS / TCP / TLS against the hovered origin so a click
                // has a head start. Dedup'd per-host for 30s inside the mgr.
                PreconnectManager.shared.preconnect(href)
                self.onLinkHover?(href)
            }

        case "commandHover":
            let href = message.body as? String
            DispatchQueue.main.async {
                self.onCommandHover?(href)
            }

        case "commandClick":
            if let payload = message.body as? [String: Any],
               let href = payload["href"] as? String,
               let url = URL(string: href) {
                let openInSplit = payload["openInSplit"] as? Bool ?? false
                let openAsChild = payload["openAsChild"] as? Bool ?? true
                DispatchQueue.main.async {
                    self.handleCommandClick(url: url, openInSplit: openInSplit, openAsChild: openAsChild)
                }
            } else if let href = message.body as? String, let url = URL(string: href) {
                DispatchQueue.main.async {
                    self.handleCommandClick(url: url, openInSplit: false, openAsChild: true)
                }
            }

        case "pipStateChange":
            if let dict = message.body as? [String: Any], let active = dict["active"] as? Bool {
                DispatchQueue.main.async {
                    print("[PiP] State change detected from web: \(active)")
                    self.hasPiPActive = active
                }
            }

        case let name where name.hasPrefix("mediaStateChange_"):
            if let dict = message.body as? [String: Bool] {
                DispatchQueue.main.async {
                    self.hasPlayingVideo = dict["hasPlayingVideo"] ?? false
                    self.hasVideoContent = dict["hasVideoContent"] ?? false
                    self.hasAudioContent = dict["hasAudioContent"] ?? false
                    self.hasPlayingAudio = dict["hasPlayingAudio"] ?? false
                    // Don't override isAudioMuted - it's managed by toggleMute()
                }
            }

        case let name where name.hasPrefix("backgroundColor_"):
            if let dict = message.body as? [String: String],
                let colorHex = dict["backgroundColor"]
            {
                DispatchQueue.main.async {
                    self.pageBackgroundColor = NSColor(hex: colorHex)
                    if let webView = self._webView, let color = NSColor(hex: colorHex) {
                        webView.underPageBackgroundColor = color
                        // Update sampled domain after successful extraction
                        if let currentURL = webView.url,
                           let currentDomain = self.extractDomain(from: currentURL) {
                            self.lastSampledDomain = currentDomain
                        }
                    }
                }
            }
            

        case "historyStateDidChange":
            if let href = message.body as? String, let url = URL(string: href) {
                DispatchQueue.main.async {
                    if self.url.absoluteString != url.absoluteString {
                        self.url = url
                        self.synchronizePersistedNavigationHistory(with: url)
                        self.browserManager?.syncTabAcrossWindows(self.id)

                        // Debounce persistence for SPA navigation to avoid excessive writes
                        self.spaPersistDebounceTask?.cancel()
                        self.spaPersistDebounceTask = Task { [weak self] in
                            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
                            guard !Task.isCancelled else { return }
                            self?.browserManager?.tabManager.persistSnapshot()
                        }
                    } else {
                        self.refreshNavigationAvailability()
                    }
                }
            }

        case "SocketIdentity":
            handleOAuthRequest(message: message)

        case "socketShortcutDetect":
            handleShortcutDetection(message: message)

        case "passwordFormDetected":
            browserManager?.passwordManager.handleFormDetected(message.body, tab: self)

        case "passwordFormSubmitted":
            browserManager?.passwordManager.handleFormSubmitted(message.body, tab: self)

        default:
            break
        }
    }
    
    private func handleShortcutDetection(message: WKScriptMessage) {
        // Use the frame's webView URL for correct attribution, fallback to _webView
        let currentURL = message.frameInfo.webView?.url?.absoluteString ?? _webView?.url?.absoluteString
        guard let url = currentURL else { return }

        if let payload = message.body as? [String: Any] {
            let shortcuts = Set((payload["shortcuts"] as? [String]) ?? [])
            let isEditableFocused = payload["isEditableElementFocused"] as? Bool ?? false

            browserManager?.keyboardShortcutManager?.websiteShortcutDetector.updateJSDetectedShortcuts(
                for: url,
                shortcuts: shortcuts
            )

            // Editable-focus is global at the shortcut-manager layer, so only the
            // active tab in the active window is allowed to update it. Background
            // tabs continue reporting state, but they must not knock the browser
            // out of typing mode while the user is composing in another tab.
            if browserManager?.currentTabForActiveWindow()?.id == id {
                browserManager?.keyboardShortcutManager?.websiteShortcutDetector.updateEditableFocus(isEditableFocused)
            }
            return
        }

        guard let shortcutsString = message.body as? String else { return }
        let shortcuts = Set(shortcutsString.split(separator: ",").map { String($0) })

        browserManager?.keyboardShortcutManager?.websiteShortcutDetector.updateJSDetectedShortcuts(
            for: url,
            shortcuts: shortcuts
        )
    }

    private func handleCommandClick(url: URL, openInSplit: Bool, openAsChild: Bool) {
        guard let browserManager else { return }
        guard shouldHandleModifiedOpen(url: url, openInSplit: openInSplit, openAsChild: openAsChild)
        else {
            print("↩️ [Tab] Ignoring duplicate modified link open for: \(url.absoluteString)")
            return
        }

        markPopupSuppression(for: url)

        let targetWindowState = owningWindowState() ?? browserManager.windowRegistry?.activeWindow
        let newTab =
            targetWindowState.flatMap { browserManager.createNewTab(in: $0, url: url.absoluteString) }
            ?? browserManager.tabManager.createNewTab(
                url: url.absoluteString,
                in: browserManager.tabManager.currentSpace
            )

        if openAsChild {
            browserManager.tabManager.attachTab(newTab, asChildOf: self)
        }

        if openInSplit,
           let windowState = targetWindowState,
           !windowState.isIncognito {
            browserManager.splitManager.enterSplit(with: newTab, placeOn: .right, in: windowState)
        }
    }

    private func navigationKey(for url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }

        if components.scheme == "http", components.port == 80 {
            components.port = nil
        } else if components.scheme == "https", components.port == 443 {
            components.port = nil
        }

        return components.string ?? url.absoluteString
    }

    private func shouldHandleModifiedOpen(url: URL, openInSplit: Bool, openAsChild: Bool) -> Bool {
        let key = "\(navigationKey(for: url))|split:\(openInSplit)|child:\(openAsChild)"
        let now = Date()

        if let lastModifiedOpen,
           lastModifiedOpen.key == key,
           now.timeIntervalSince(lastModifiedOpen.timestamp) < modifiedOpenDeduplicationWindow {
            return false
        }

        self.lastModifiedOpen = RecentModifiedOpen(key: key, timestamp: now)
        return true
    }

    private func markPopupSuppression(for url: URL) {
        lastModifiedOpenPopupSuppression = RecentModifiedOpen(
            key: navigationKey(for: url),
            timestamp: Date()
        )
    }

    private func shouldSuppressPopupCreation(for url: URL) -> Bool {
        guard let lastModifiedOpenPopupSuppression else { return false }

        let elapsed = Date().timeIntervalSince(lastModifiedOpenPopupSuppression.timestamp)
        if elapsed > modifiedOpenPopupSuppressionWindow {
            self.lastModifiedOpenPopupSuppression = nil
            return false
        }

        return lastModifiedOpenPopupSuppression.key == navigationKey(for: url)
    }

    private func shouldReuseCurrentTabForPopupNavigation(
        destinationURL: URL,
        navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> Bool {
        guard let destinationHost = destinationURL.host?.lowercased() else { return false }
        let sourceHost =
            navigationAction.sourceFrame.request.url?.host?.lowercased()
            ?? webView?.url?.host?.lowercased()
            ?? url.host?.lowercased()
        let path = destinationURL.path.lowercased()
        let query = destinationURL.query?.lowercased() ?? ""
        let components = URLComponents(url: destinationURL, resolvingAgainstBaseURL: false)
        let queryKeys = Set((components?.queryItems ?? []).map { $0.name.lowercased() })

        let accountSwitchPaths = [
            "/accountchooser",
            "/addsession",
            "/selectsession",
            "/signinchooser",
            "/servicelogin",
            "/setsid",
            "/logout",
            "/lookup",
            "/identifier",
            "/chooseaccount"
        ]

        let hasAccountSwitchPath = accountSwitchPaths.contains(where: { path.contains($0) })
        let hasContinuationTarget =
            queryKeys.contains("continue")
            || queryKeys.contains("followup")
            || queryKeys.contains("service")
            || queryKeys.contains("passive")
            || queryKeys.contains("authuser")
            || query.contains("usp=account_switch")
            || query.contains("authuser=")
        let isGoogleDestination =
            destinationHost == "google.com"
            || destinationHost.hasSuffix(".google.com")
        let isGoogleSource =
            sourceHost == "google.com"
            || sourceHost?.hasSuffix(".google.com") == true

        // Google's in-product account switching often routes through popup-style
        // URLs even though the intended UX is "replace this page with the same
        // product under another account". Keep those flows in the current tab.
        if isGoogleSource && isGoogleDestination {
            if hasAccountSwitchPath || hasContinuationTarget || path.contains("/u/") {
                return true
            }
        }

        // If a Google property opens an intermediate accounts.google.com chooser,
        // prefer reusing the current tab so the selected account reloads the
        // current product instead of spawning a detached auth window.
        let isGoogleAccountsHost =
            destinationHost == "accounts.google.com"
            || destinationHost.hasSuffix(".accounts.google.com")
        let shouldReuse =
            (isGoogleSource && isGoogleDestination && (hasAccountSwitchPath || hasContinuationTarget || path.contains("/u/")))
            || (isGoogleSource && isGoogleAccountsHost && (hasAccountSwitchPath || hasContinuationTarget))

        if isGoogleSource || isGoogleDestination || isGoogleAccountsHost {
            let width = windowFeatures.width?.stringValue ?? "nil"
            let height = windowFeatures.height?.stringValue ?? "nil"
            logAuthTrace(
                "google-account-switch-eval",
                currentURL: destinationURL,
                extra:
                    "sourceHost=\(sourceHost ?? "nil") destinationHost=\(destinationHost) path=\(path) hasAccountSwitchPath=\(hasAccountSwitchPath) hasContinuationTarget=\(hasContinuationTarget) queryKeys=\(Array(queryKeys).sorted()) windowWidth=\(width) windowHeight=\(height) decision=\(shouldReuse)"
            )
        }

        return shouldReuse
    }

    private func shouldOpenPopupNavigationAsChildTab(
        navigationAction: WKNavigationAction,
        isFromExtension: Bool,
        isLikelyOAuthPopup: Bool
    ) -> Bool {
        guard !isFromExtension else { return false }
        guard !isLikelyOAuthPopup else { return false }
        guard navigationAction.targetFrame == nil else { return false }
        guard navigationAction.navigationType == .linkActivated else { return false }
        guard let url = navigationAction.request.url,
              let scheme = url.scheme?.lowercased() else { return false }

        return scheme == "http" || scheme == "https" || scheme == "about"
    }

    private func sourceWindowState(for webView: WKWebView) -> BrowserWindowState? {
        guard let browserManager,
              let registry = browserManager.windowRegistry else {
            return nil
        }

        if let windowId = browserManager.webViewCoordinator?.windowId(for: webView),
           let resolvedWindow = registry.windows[windowId] {
            return resolvedWindow
        }

        if let exactWindow = registry.windows.values.first(where: { $0.window === webView.window }) {
            return exactWindow
        }

        if let ownerWindow = owningWindowState() {
            return ownerWindow
        }

        return registry.activeWindow
    }

    private func owningWindowState() -> BrowserWindowState? {
        guard let registry = browserManager?.windowRegistry else { return nil }

        if let incognitoOwner = registry.windows.values.first(where: { windowState in
            windowState.isIncognito && windowState.ephemeralTabs.contains(where: { $0.id == self.id })
        }) {
            return incognitoOwner
        }

        return registry.windows.values.first(where: { $0.currentTabId == self.id })
    }

    private func handleOAuthRequest(message: WKScriptMessage) {
        guard let dict = message.body as? [String: Any],
            let urlString = dict["url"] as? String,
            let url = URL(string: urlString)
        else {
            print("❌ [Tab] Invalid OAuth request: missing or invalid URL")
            return
        }
        let interactive = dict["interactive"] as? Bool ?? true
        let prefersEphemeral = dict["prefersEphemeral"] as? Bool ?? false
        let providedScheme = (dict["callbackScheme"] as? String)?.trimmingCharacters(
            in: .whitespacesAndNewlines)
        let rawRequestId = (dict["requestId"] as? String)?.trimmingCharacters(
            in: .whitespacesAndNewlines)
        let requestId = (rawRequestId?.isEmpty == false ? rawRequestId! : UUID().uuidString)

        print(
            "🔐 [Tab] OAuth request received: id=\(requestId) url=\(url.absoluteString) interactive=\(interactive) ephemeral=\(prefersEphemeral) scheme=\(providedScheme ?? "nil")"
        )

        guard let manager = browserManager else {
            finishIdentityFlow(requestId: requestId, with: .failure(.unableToStart))
            return
        }

        let identityRequest = AuthenticationManager.IdentityRequest(
            requestId: requestId,
            url: url,
            interactive: interactive,
            prefersEphemeralSession: prefersEphemeral,
            explicitCallbackScheme: providedScheme?.isEmpty == true ? nil : providedScheme
        )

        manager.authenticationManager.beginIdentityFlow(identityRequest, from: self)
    }

    func finishIdentityFlow(
        requestId: String,
        with result: AuthenticationManager.IdentityFlowResult
    ) {
        guard let webView else {
            print("⚠️ [Tab] Unable to deliver identity result; webView missing")
            return
        }

        var payload: [String: Any] = ["requestId": requestId]

        switch result {
        case .success(let url):
            payload["status"] = "success"
            payload["url"] = url.absoluteString
        case .cancelled:
            payload["status"] = "cancelled"
            payload["code"] = "cancelled"
            payload["message"] = "Authentication cancelled by user."
        case .failure(let failure):
            payload["status"] = "failure"
            payload["code"] = failure.code
            payload["message"] = failure.message
        }

        if let status = payload["status"] as? String {
            let urlDescription = payload["url"] as? String ?? "nil"
            print(
                "🔐 [Tab] Identity flow completed: id=\(requestId) status=\(status) url=\(urlDescription)"
            )
        }

        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
            let jsonString = String(data: data, encoding: .utf8)
        else {
            print("❌ [Tab] Failed to serialise identity payload for requestId=\(requestId)")
            return
        }

        let script =
            "window.__socketCompleteIdentityFlow && window.__socketCompleteIdentityFlow(\(jsonString));"
        webView.evaluateJavaScript(script) { _, error in
            if let error {
                print("❌ [Tab] Failed to deliver identity result: \(error.localizedDescription)")
            }
        }
    }

    private func isLikelyOAuthOrExternalWindow(url: URL, windowFeatures: WKWindowFeatures) -> Bool {
        if OAuthDetector.isLikelyOAuthPopupURL(url) { return true }

        // If the popup has explicit dimensions it's almost certainly a modal sign-in window
        if let width = windowFeatures.width, let height = windowFeatures.height,
            width.doubleValue > 0 && height.doubleValue > 0
        {
            return true
        }

        return false
    }

    private func alignPopupConfigurationWithOpener(
        _ popupConfiguration: WKWebViewConfiguration,
        openerWebView: WKWebView,
        popupURL: URL?,
        popupTab: Tab
    ) {
        let openerConfiguration = openerWebView.configuration
        let openerProfile = resolveProfile()
        let targetStore = openerConfiguration.websiteDataStore

        popupTab.spaceId = self.spaceId
        popupTab.profileId = openerProfile?.id ?? self.profileId

        popupConfiguration.websiteDataStore = targetStore
        popupConfiguration.processPool = openerConfiguration.processPool
        popupConfiguration.preferences.javaScriptCanOpenWindowsAutomatically =
            openerConfiguration.preferences.javaScriptCanOpenWindowsAutomatically
        popupConfiguration.preferences.isFraudulentWebsiteWarningEnabled =
            openerConfiguration.preferences.isFraudulentWebsiteWarningEnabled
        popupConfiguration.defaultWebpagePreferences.allowsContentJavaScript =
            openerConfiguration.defaultWebpagePreferences.allowsContentJavaScript

        if #available(macOS 15.5, *) {
            popupConfiguration.webExtensionController = openerConfiguration.webExtensionController
        }

        debugLogPopupSession(
            reason: "popup-created",
            openerWebView: openerWebView,
            popupConfiguration: popupConfiguration,
            popupURL: popupURL,
            popupTab: popupTab
        )
    }

    private func debugLogPopupSession(
        reason: String,
        openerWebView: WKWebView,
        popupConfiguration: WKWebViewConfiguration,
        popupURL: URL?,
        popupTab: Tab
    ) {
        let openerStore = openerWebView.configuration.websiteDataStore
        let popupStore = popupConfiguration.websiteDataStore
        let popupHost = popupURL?.host?.lowercased()
        let openerHost = self.url.host?.lowercased()
        let sameStore = openerStore === popupStore
        let samePool = openerWebView.configuration.processPool === popupConfiguration.processPool

        Task { @MainActor in
            let openerCookies = await openerStore.httpCookieStore.allCookiesAsync()
            let popupCookies = await popupStore.httpCookieStore.allCookiesAsync()

            let openerPopupCookieCount = Self.countCookies(in: openerCookies, matchingHost: popupHost)
            let openerSiteCookieCount = Self.countCookies(in: openerCookies, matchingHost: openerHost)
            let popupPopupCookieCount = Self.countCookies(in: popupCookies, matchingHost: popupHost)
            let popupSiteCookieCount = Self.countCookies(in: popupCookies, matchingHost: openerHost)

            print(
                """
                🔐 [AuthDebug] \(reason)
                   openerTab=\(self.id.uuidString.prefix(8)) popupTab=\(popupTab.id.uuidString.prefix(8))
                   openerHost=\(openerHost ?? "nil") popupHost=\(popupHost ?? "nil")
                   openerStore=\(Self.debugDataStoreIdentifier(openerStore)) popupStore=\(Self.debugDataStoreIdentifier(popupStore))
                   sameStore=\(sameStore) sameProcessPool=\(samePool)
                   openerCookiesForPopupHost=\(openerPopupCookieCount) openerCookiesForSite=\(openerSiteCookieCount)
                   popupCookiesForPopupHost=\(popupPopupCookieCount) popupCookiesForSite=\(popupSiteCookieCount)
                """
            )
            Self.writeAuthDiagnostic(
                """
                [AuthDebug] \(reason)
                openerTab=\(self.id.uuidString.prefix(8)) popupTab=\(popupTab.id.uuidString.prefix(8))
                openerHost=\(openerHost ?? "nil") popupHost=\(popupHost ?? "nil")
                openerStore=\(Self.debugDataStoreIdentifier(openerStore)) popupStore=\(Self.debugDataStoreIdentifier(popupStore))
                sameStore=\(sameStore) sameProcessPool=\(samePool)
                openerCookiesForPopupHost=\(openerPopupCookieCount) openerCookiesForSite=\(openerSiteCookieCount)
                popupCookiesForPopupHost=\(popupPopupCookieCount) popupCookiesForSite=\(popupSiteCookieCount)
                """
            )
        }
    }

    private func debugLogOAuthRelay(
        reason: String,
        parentTab: Tab,
        finalURL: URL?
    ) {
        guard let popupWebView = existingWebView,
              let parentWebView = parentTab.existingWebView else { return }
        let popupStore = popupWebView.configuration.websiteDataStore
        let parentStore = parentWebView.configuration.websiteDataStore
        let finalHost = finalURL?.host?.lowercased()
        let parentHost = parentTab.url.host?.lowercased()
        let sameStore = popupStore === parentStore

        Task { @MainActor in
            let popupCookies = await popupStore.httpCookieStore.allCookiesAsync()
            let parentCookies = await parentStore.httpCookieStore.allCookiesAsync()

            print(
                """
                🔐 [AuthDebug] \(reason)
                   popupTab=\(self.id.uuidString.prefix(8)) parentTab=\(parentTab.id.uuidString.prefix(8))
                   finalHost=\(finalHost ?? "nil") parentHost=\(parentHost ?? "nil")
                   popupStore=\(Self.debugDataStoreIdentifier(popupStore)) parentStore=\(Self.debugDataStoreIdentifier(parentStore))
                   sameStore=\(sameStore)
                   popupCookiesForFinalHost=\(Self.countCookies(in: popupCookies, matchingHost: finalHost))
                   popupCookiesForParentHost=\(Self.countCookies(in: popupCookies, matchingHost: parentHost))
                   parentCookiesForFinalHost=\(Self.countCookies(in: parentCookies, matchingHost: finalHost))
                   parentCookiesForParentHost=\(Self.countCookies(in: parentCookies, matchingHost: parentHost))
                   popupCookieSummary=\(Self.cookieDebugSummary(in: popupCookies, matchingHost: finalHost))
                   parentCookieSummary=\(Self.cookieDebugSummary(in: parentCookies, matchingHost: finalHost))
                """
            )
            Self.writeAuthDiagnostic(
                """
                [AuthDebug] \(reason)
                popupTab=\(self.id.uuidString.prefix(8)) parentTab=\(parentTab.id.uuidString.prefix(8))
                finalHost=\(finalHost ?? "nil") parentHost=\(parentHost ?? "nil")
                popupStore=\(Self.debugDataStoreIdentifier(popupStore)) parentStore=\(Self.debugDataStoreIdentifier(parentStore))
                sameStore=\(sameStore)
                popupCookiesForFinalHost=\(Self.countCookies(in: popupCookies, matchingHost: finalHost))
                popupCookiesForParentHost=\(Self.countCookies(in: popupCookies, matchingHost: parentHost))
                parentCookiesForFinalHost=\(Self.countCookies(in: parentCookies, matchingHost: finalHost))
                parentCookiesForParentHost=\(Self.countCookies(in: parentCookies, matchingHost: parentHost))
                popupCookieSummary=\(Self.cookieDebugSummary(in: popupCookies, matchingHost: finalHost))
                parentCookieSummary=\(Self.cookieDebugSummary(in: parentCookies, matchingHost: finalHost))
                """
            )
        }
    }

    private func logOAuthPopupRuntimeState(in webView: WKWebView, phase: String) {
        guard isOAuthFlow else { return }

        let script = """
        (function() {
          try {
            return {
              href: String(window.location.href || ""),
              referrer: String(document.referrer || ""),
              title: String(document.title || ""),
              readyState: String(document.readyState || ""),
              hasOpener: !!window.opener,
              openerClosed: !!(window.opener && window.opener.closed),
              topEqualsSelf: window.top === window.self
            };
          } catch (error) {
            return { error: String(error) };
          }
        })();
        """

        webView.evaluateJavaScript(script) { result, error in
            if let error {
                print("🔐 [AuthDebug] popup-runtime \(phase) failed: \(error.localizedDescription)")
                Self.writeAuthDiagnostic("[AuthDebug] popup-runtime \(phase) failed: \(error.localizedDescription)")
                return
            }

            if let state = result as? [String: Any] {
                print("🔐 [AuthDebug] popup-runtime \(phase): \(state)")
                Self.writeAuthDiagnostic("[AuthDebug] popup-runtime \(phase): \(state)")
            } else {
                print("🔐 [AuthDebug] popup-runtime \(phase): \(String(describing: result))")
                Self.writeAuthDiagnostic("[AuthDebug] popup-runtime \(phase): \(String(describing: result))")
            }
        }
    }

    private func shouldCollectDetailedAuthDiagnostics(for currentURL: URL) -> Bool {
        guard shouldTraceAuth(url: currentURL) else { return false }

        let host = currentURL.host?.lowercased() ?? ""
        let path = currentURL.path.lowercased()

        if shouldLoadOAuthCallbackInParent(currentURL, parentTab: self) {
            return true
        }

        if host == "accounts.google.com" || host.hasSuffix(".accounts.google.com") {
            return true
        }

        if path.contains("oauth") || path.contains("sso") || path.contains("signin") {
            return true
        }

        return false
    }

    private func scheduleAuthPageDiagnosticsIfNeeded(
        in webView: WKWebView,
        currentURL: URL,
        phase: String
    ) {
        guard shouldCollectDetailedAuthDiagnostics(for: currentURL) else { return }

        let key = "\(phase)|\(normalizedOAuthURLString(currentURL))"
        guard !scheduledAuthPageDiagnosticKeys.contains(key) else { return }
        scheduledAuthPageDiagnosticKeys.insert(key)

        let delays: [TimeInterval] = [0.5, 2.0, 5.0]
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak webView] in
                guard let self, let webView else { return }
                guard let liveURL = webView.url,
                      self.oauthURLsMatchIgnoringFragment(liveURL, currentURL) else {
                    return
                }
                self.logDetailedAuthPageDiagnostics(
                    in: webView,
                    currentURL: currentURL,
                    phase: phase,
                    delay: delay
                )
            }
        }
    }

    private func logDetailedAuthPageDiagnostics(
        in webView: WKWebView,
        currentURL: URL,
        phase: String,
        delay: TimeInterval
    ) {
        let script = """
        (function() {
          try {
            const localKeys = (() => {
              try { return Object.keys(window.localStorage || {}).slice(0, 24); }
              catch (error) { return ["error:" + String(error)]; }
            })();

            const sessionKeys = (() => {
              try { return Object.keys(window.sessionStorage || {}).slice(0, 24); }
              catch (error) { return ["error:" + String(error)]; }
            })();

            const resources = performance.getEntriesByType("resource").slice(-16).map((entry) => ({
              name: String(entry.name || ""),
              initiatorType: String(entry.initiatorType || ""),
              duration: Number(entry.duration || 0)
            }));

            const navEntry = performance.getEntriesByType("navigation")[0];

            return {
              href: String(window.location.href || ""),
              title: String(document.title || ""),
              readyState: String(document.readyState || ""),
              bodyPreview: String((document.body && document.body.innerText) || "").slice(0, 240),
              bodyLength: Number(((document.body && document.body.innerText) || "").length || 0),
              cookiePreview: String(document.cookie || "").slice(0, 400),
              localKeys,
              sessionKeys,
              navType: navEntry ? String(navEntry.type || "") : "",
              redirectCount: navEntry ? Number(navEntry.redirectCount || 0) : 0,
              resourceEntries: resources
            };
          } catch (error) {
            return { error: String(error) };
          }
        })();
        """

        webView.evaluateJavaScript(script) { result, error in
            if let error {
                self.logAuthTrace(
                    "auth-page-diagnostic",
                    currentURL: currentURL,
                    extra:
                        "phase=\(phase) delay=\(String(format: "%.1f", delay)) error=\(error.localizedDescription)"
                )
                return
            }

            guard let state = result as? [String: Any] else {
                self.logAuthTrace(
                    "auth-page-diagnostic",
                    currentURL: currentURL,
                    extra:
                        "phase=\(phase) delay=\(String(format: "%.1f", delay)) result=\(String(describing: result))"
                )
                return
            }

            if let error = state["error"] as? String {
                self.logAuthTrace(
                    "auth-page-diagnostic",
                    currentURL: currentURL,
                    extra:
                        "phase=\(phase) delay=\(String(format: "%.1f", delay)) jsError=\(error)"
                )
                return
            }

            let resourceSummary: String = {
                guard let resources = state["resourceEntries"] as? [[String: Any]], !resources.isEmpty else {
                    return "[]"
                }
                let compact = resources.map { entry -> String in
                    let initiator = entry["initiatorType"] as? String ?? "unknown"
                    let name = (entry["name"] as? String ?? "").replacingOccurrences(of: "\n", with: " ")
                    let shortened = name.count > 160 ? String(name.prefix(160)) + "..." : name
                    return "\(initiator):\(shortened)"
                }
                return "[" + compact.joined(separator: ", ") + "]"
            }()

            let localKeys = (state["localKeys"] as? [String] ?? []).joined(separator: ",")
            let sessionKeys = (state["sessionKeys"] as? [String] ?? []).joined(separator: ",")
            let bodyPreview = (state["bodyPreview"] as? String ?? "").replacingOccurrences(of: "\n", with: " ")
            let cookiePreview = (state["cookiePreview"] as? String ?? "").replacingOccurrences(of: "\n", with: " ")

            self.logAuthTrace(
                "auth-page-diagnostic",
                currentURL: currentURL,
                extra:
                    "phase=\(phase) delay=\(String(format: "%.1f", delay)) href=\(state["href"] as? String ?? "") title=\(state["title"] as? String ?? "") readyState=\(state["readyState"] as? String ?? "") navType=\(state["navType"] as? String ?? "") redirects=\(state["redirectCount"] as? Int ?? 0) bodyLength=\(state["bodyLength"] as? Int ?? 0) localKeys=[\(localKeys)] sessionKeys=[\(sessionKeys)] cookiePreview=\(cookiePreview) bodyPreview=\(bodyPreview) resources=\(resourceSummary)"
            )
        }
    }

    private func scheduleSiteOwnedOAuthBridgeIfNeeded(
        in webView: WKWebView,
        currentURL: URL
    ) {
        guard let parentTab =
            oauthParentTabId.flatMap({ parentId in
                browserManager?.tabManager.allTabs().first(where: { $0.id == parentId })
            }),
            let bridgePlan = siteOwnedOAuthBridgePlan(for: currentURL, parentTab: parentTab) else {
            return
        }

        let key = "\(bridgePlan.identifier)|\(normalizedOAuthURLString(currentURL))"
        guard !scheduledSiteOwnedOAuthBridgeKeys.contains(key),
              !completedSiteOwnedOAuthBridgeKeys.contains(key) else {
            return
        }
        scheduledSiteOwnedOAuthBridgeKeys.insert(key)

        let delays: [TimeInterval] = [0.0, 0.15, 0.5, 1.0]
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak webView] in
                guard let self, let webView else { return }
                guard let liveURL = webView.url,
                      self.oauthURLsMatchIgnoringFragment(liveURL, currentURL) else {
                    return
                }

                Task { @MainActor [weak self, weak webView] in
                    guard let self, let webView else { return }
                    await self.performSiteOwnedOAuthBridgeIfNeeded(
                        in: webView,
                        currentURL: currentURL,
                        parentTab: parentTab,
                        bridgePlan: bridgePlan,
                        delay: delay
                    )
                }
            }
        }
    }

    private func siteOwnedOAuthBridgePlan(
        for finalURL: URL,
        parentTab: Tab
    ) -> SiteOwnedOAuthBridgePlan? {
        guard isSameHostOAuthCallback(finalURL: finalURL, parentTab: parentTab),
              let finalHost = finalURL.host?.lowercased(),
              finalHost.hasSuffix("figma.com") else {
            return nil
        }

        let path = finalURL.path.lowercased()
        if path.contains("/finish_google_sso") {
            return SiteOwnedOAuthBridgePlan(
                identifier: "figma-google-sso",
                cookieName: "__Host-google_sso_temp",
                targetHost: finalHost
            )
        }

        return nil
    }

    private func performSiteOwnedOAuthBridgeIfNeeded(
        in webView: WKWebView,
        currentURL: URL,
        parentTab: Tab,
        bridgePlan: SiteOwnedOAuthBridgePlan,
        delay: TimeInterval
    ) async {
        let key = "\(bridgePlan.identifier)|\(normalizedOAuthURLString(currentURL))"
        guard !completedSiteOwnedOAuthBridgeKeys.contains(key) else { return }

        guard let payload = await captureSiteOwnedOAuthBridgePayload(
            in: webView,
            currentURL: currentURL,
            bridgePlan: bridgePlan,
            delay: delay
        ) else {
            return
        }

        guard !payload.encodedCookieValue.isEmpty else {
            if payload.cookieAlreadyPresent {
                completedSiteOwnedOAuthBridgeKeys.insert(key)
                logAuthTrace(
                    "oauth-site-bridge",
                    currentURL: currentURL,
                    extra:
                        "plan=\(bridgePlan.identifier) action=already-present-no-value delay=\(String(format: "%.2f", delay))"
                )
            }
            return
        }

        // Always install into the parent even when the popup can already see
        // the cookie. WKWebView runs opener and popup in separate web content
        // processes, so document.cookie in one is NOT visible in the other.
        completedSiteOwnedOAuthBridgeKeys.insert(key)
        await installSiteOwnedOAuthBridgePayload(
            payload,
            in: webView,
            currentURL: currentURL,
            parentTab: parentTab,
            bridgePlan: bridgePlan
        )
    }

    private func captureSiteOwnedOAuthBridgePayload(
        in webView: WKWebView,
        currentURL: URL,
        bridgePlan: SiteOwnedOAuthBridgePlan,
        delay: TimeInterval
    ) async -> SiteOwnedOAuthBridgePayload? {
        let script = """
        (function() {
          try {
            const initialOptions = window.INITIAL_OPTIONS || self.INITIAL_OPTIONS || {};
            const name = typeof initialOptions.google_sso_name === "string" ? initialOptions.google_sso_name : "";
            const token = typeof initialOptions.google_sso_access_token === "string" ? initialOptions.google_sso_access_token : "";
            const existingCookie = String(document.cookie || "");
            const encodedCookieValue = token.length > 0
              ? encodeURIComponent(JSON.stringify({
                  name,
                  token,
                  tokenType: "access_token"
                }))
              : "";

            return {
              href: String(window.location.href || ""),
              title: String(document.title || ""),
              hasInitialOptions: !!(window.INITIAL_OPTIONS || self.INITIAL_OPTIONS),
              nameLength: name.length,
              tokenLength: token.length,
              cookieAlreadyPresent: existingCookie.includes("\(bridgePlan.cookieName)="),
              cookiePreview: existingCookie.slice(0, 400),
              encodedCookieValue
            };
          } catch (error) {
            return { error: String(error) };
          }
        })();
        """

        do {
            guard let result = try await webView.evaluateJavaScript(script) as? [String: Any] else {
                logAuthTrace(
                    "oauth-site-bridge-snapshot",
                    currentURL: currentURL,
                    extra:
                        "plan=\(bridgePlan.identifier) delay=\(String(format: "%.2f", delay)) result=unreadable"
                )
                return nil
            }

            if let error = result["error"] as? String {
                logAuthTrace(
                    "oauth-site-bridge-snapshot",
                    currentURL: currentURL,
                    extra:
                        "plan=\(bridgePlan.identifier) delay=\(String(format: "%.2f", delay)) error=\(error)"
                )
                return nil
            }

            let payload = SiteOwnedOAuthBridgePayload(
                encodedCookieValue: result["encodedCookieValue"] as? String ?? "",
                cookieAlreadyPresent: result["cookieAlreadyPresent"] as? Bool ?? false,
                hasInitialOptions: result["hasInitialOptions"] as? Bool ?? false,
                nameLength: result["nameLength"] as? Int ?? 0,
                tokenLength: result["tokenLength"] as? Int ?? 0,
                cookiePreview: (result["cookiePreview"] as? String ?? "").replacingOccurrences(of: "\n", with: " "),
                href: result["href"] as? String ?? "",
                title: result["title"] as? String ?? ""
            )

            logAuthTrace(
                "oauth-site-bridge-snapshot",
                currentURL: currentURL,
                extra:
                    "plan=\(bridgePlan.identifier) delay=\(String(format: "%.2f", delay)) hasInitialOptions=\(payload.hasInitialOptions) tokenLength=\(payload.tokenLength) nameLength=\(payload.nameLength) cookieAlreadyPresent=\(payload.cookieAlreadyPresent) title=\(payload.title) href=\(payload.href) cookiePreview=\(payload.cookiePreview)"
            )

            return payload
        } catch {
            logAuthTrace(
                "oauth-site-bridge-snapshot",
                currentURL: currentURL,
                extra:
                    "plan=\(bridgePlan.identifier) delay=\(String(format: "%.2f", delay)) error=\(error.localizedDescription)"
            )
            return nil
        }
    }

    private func installSiteOwnedOAuthBridgePayload(
        _ payload: SiteOwnedOAuthBridgePayload,
        in webView: WKWebView,
        currentURL: URL,
        parentTab: Tab,
        bridgePlan: SiteOwnedOAuthBridgePlan
    ) async {
        guard let cookie = makeSiteOwnedOAuthBridgeCookie(
            name: bridgePlan.cookieName,
            encodedValue: payload.encodedCookieValue,
            host: bridgePlan.targetHost
        ) else {
            logAuthTrace(
                "oauth-site-bridge-install",
                currentURL: currentURL,
                extra: "plan=\(bridgePlan.identifier) error=invalid-cookie"
            )
            return
        }

        let popupStore = webView.configuration.websiteDataStore.httpCookieStore
        let parentStore =
            parentTab.existingWebView?.configuration.websiteDataStore.httpCookieStore
            ?? parentTab.resolveProfile()?.dataStore.httpCookieStore
            ?? BrowserConfiguration.shared.webViewConfiguration.websiteDataStore.httpCookieStore

        await popupStore.setCookieAsync(cookie)
        if parentStore !== popupStore {
            await parentStore.setCookieAsync(cookie)
        }

        let cookieAssignment = "\(bridgePlan.cookieName)=\(payload.encodedCookieValue); path=/; Secure"
        let popupResult = await injectSiteOwnedOAuthCookie(
            cookieAssignment,
            cookieName: bridgePlan.cookieName,
            into: webView
        )
        let parentResult: String
        if let parentWebView = parentTab.existingWebView {
            parentResult = await injectSiteOwnedOAuthCookie(
                cookieAssignment,
                cookieName: bridgePlan.cookieName,
                into: parentWebView
            )
        } else {
            parentResult = "parent-webview-missing"
        }

        let popupCookies = await popupStore.allCookiesAsync()
        let parentCookies = await parentStore.allCookiesAsync()
        let popupHasCookie = popupCookies.contains {
            $0.name == bridgePlan.cookieName && $0.domain.lowercased().contains(bridgePlan.targetHost)
        }
        let parentHasCookie = parentCookies.contains {
            $0.name == bridgePlan.cookieName && $0.domain.lowercased().contains(bridgePlan.targetHost)
        }

        logAuthTrace(
            "oauth-site-bridge-install",
            currentURL: currentURL,
            extra:
                "plan=\(bridgePlan.identifier) tokenLength=\(payload.tokenLength) popupHasCookie=\(popupHasCookie) parentHasCookie=\(parentHasCookie) popupJS=\(popupResult) parentJS=\(parentResult)"
        )
    }

    private func makeSiteOwnedOAuthBridgeCookie(
        name: String,
        encodedValue: String,
        host: String
    ) -> HTTPCookie? {
        guard !encodedValue.isEmpty else { return nil }

        let properties: [HTTPCookiePropertyKey: Any] = [
            .domain: host,
            .path: "/",
            .name: name,
            .value: encodedValue,
            .secure: "TRUE",
            .discard: "TRUE"
        ]

        return HTTPCookie(properties: properties)
    }

    private func injectSiteOwnedOAuthCookie(
        _ cookieAssignment: String,
        cookieName: String,
        into webView: WKWebView
    ) async -> String {
        guard let cookieAssignmentData = try? JSONSerialization.data(withJSONObject: cookieAssignment),
              let cookieAssignmentLiteral = String(data: cookieAssignmentData, encoding: .utf8),
              let cookieNameData = try? JSONSerialization.data(withJSONObject: cookieName),
              let cookieNameLiteral = String(data: cookieNameData, encoding: .utf8) else {
            return "serialization-failed"
        }

        let script = """
        (function() {
          try {
            document.cookie = \(cookieAssignmentLiteral);
            return String(document.cookie || "").includes(\(cookieNameLiteral)) ? "present" : "missing";
          } catch (error) {
            return "error:" + String(error);
          }
        })();
        """

        do {
            let result = try await webView.evaluateJavaScript(script)
            return String(describing: result ?? "nil")
        } catch {
            return "error:\(error.localizedDescription)"
        }
    }

    private func synchronizeCookiesFromPopupToParent(
        parentTab: Tab,
        finalURL: URL?
    ) async {
        guard let popupWebView = existingWebView else { return }

        let popupStore = popupWebView.configuration.websiteDataStore
        let parentStore =
            parentTab.existingWebView?.configuration.websiteDataStore
            ?? parentTab.resolveProfile()?.dataStore
            ?? BrowserConfiguration.shared.webViewConfiguration.websiteDataStore

        guard popupStore !== parentStore else { return }

        let popupHost = oauthProviderHost?.lowercased()
        let parentHost = parentTab.url.host?.lowercased()
        let finalHost = finalURL?.host?.lowercased()
        let candidateHosts = Set([popupHost, parentHost, finalHost].compactMap { $0 }.filter { !$0.isEmpty })

        let popupCookies = await popupStore.httpCookieStore.allCookiesAsync()
        let cookiesToCopy = popupCookies.filter { cookie in
            var cookieDomain = cookie.domain.lowercased()
            if cookieDomain.hasPrefix(".") {
                cookieDomain.removeFirst()
            }

            guard !cookieDomain.isEmpty else { return false }
            return candidateHosts.contains(where: { host in
                host == cookieDomain || host.hasSuffix(".\(cookieDomain)")
            })
        }

        guard !cookiesToCopy.isEmpty else { return }

        for cookie in cookiesToCopy {
            await parentStore.httpCookieStore.setCookieAsync(cookie)
        }

        print(
            """
            🔐 [AuthDebug] copied popup cookies to parent store
               popupTab=\(self.id.uuidString.prefix(8)) parentTab=\(parentTab.id.uuidString.prefix(8))
               copiedCookies=\(cookiesToCopy.count)
               popupStore=\(Self.debugDataStoreIdentifier(popupStore)) parentStore=\(Self.debugDataStoreIdentifier(parentStore))
            """
        )
        Self.writeAuthDiagnostic(
            """
            [AuthDebug] copied popup cookies to parent store
            popupTab=\(self.id.uuidString.prefix(8)) parentTab=\(parentTab.id.uuidString.prefix(8))
            copiedCookies=\(cookiesToCopy.count)
            popupStore=\(Self.debugDataStoreIdentifier(popupStore)) parentStore=\(Self.debugDataStoreIdentifier(parentStore))
            """
        )
    }

    private func captureOAuthStorageSnapshotIfNeeded(
        from popupWebView: WKWebView?,
        finalURL: URL?,
        expectedParentHost: String?
    ) async -> OAuthStorageSnapshot? {
        guard let popupWebView else {
            logAuthTrace(
                "oauth-popup-storage-snapshot",
                currentURL: finalURL ?? url,
                extra: "result=skipped-no-webview"
            )
            return nil
        }

        guard let finalURL,
              let finalHost = finalURL.host?.lowercased() else {
            logAuthTrace(
                "oauth-popup-storage-snapshot",
                currentURL: finalURL ?? url,
                extra: "result=skipped-missing-final-url"
            )
            return nil
        }

        guard let parentHost = expectedParentHost?.lowercased(), !parentHost.isEmpty else {
            logAuthTrace(
                "oauth-popup-storage-snapshot",
                currentURL: finalURL,
                extra: "result=skipped-missing-parent-host"
            )
            return nil
        }

        guard finalHost == parentHost else {
            logAuthTrace(
                "oauth-popup-storage-snapshot",
                currentURL: finalURL,
                extra: "result=skipped-host-mismatch finalHost=\(finalHost) parentHost=\(parentHost)"
            )
            return nil
        }

        let script = """
        (function() {
          try {
            const dump = (storageName) => {
              try {
                const storage = window[storageName];
                if (!storage || typeof storage.length !== "number") {
                  return {
                    values: {},
                    status: "unavailable"
                  };
                }

                const result = {};
                for (let index = 0; index < storage.length; index += 1) {
                  const key = storage.key(index);
                  if (typeof key === "string") {
                    result[key] = String(storage.getItem(key) ?? "");
                  }
                }

                return {
                  values: result,
                  status: "ok"
                };
              } catch (storageError) {
                return {
                  values: {},
                  status: "error:" + String(storageError)
                };
              }
            };

            const localStorageDump = dump("localStorage");
            const sessionStorageDump = dump("sessionStorage");

            return {
              href: String(window.location.href || ""),
              title: String(document.title || ""),
              windowName: String(window.name || ""),
              cookiePreview: String(document.cookie || ""),
              localStorage: localStorageDump.values,
              sessionStorage: sessionStorageDump.values,
              localStorageStatus: localStorageDump.status,
              sessionStorageStatus: sessionStorageDump.status,
              bodyPreview: String((document.body && document.body.innerText) || "").slice(0, 240)
            };
          } catch (error) {
            return { error: String(error) };
          }
        })();
        """

        do {
            guard let result = try await popupWebView.evaluateJavaScript(script) as? [String: Any] else {
                logAuthTrace(
                    "oauth-popup-storage-snapshot",
                    currentURL: finalURL,
                    extra: "result=unreadable"
                )
                return nil
            }

            if let error = result["error"] as? String {
                logAuthTrace(
                    "oauth-popup-storage-snapshot",
                    currentURL: finalURL,
                    extra: "error=\(error)"
                )
                return nil
            }

            let localStorage = Self.stringDictionary(from: result["localStorage"])
            let sessionStorage = Self.stringDictionary(from: result["sessionStorage"])
            let snapshot = OAuthStorageSnapshot(
                href: result["href"] as? String ?? "",
                title: result["title"] as? String ?? "",
                windowName: result["windowName"] as? String ?? "",
                localStorage: localStorage,
                sessionStorage: sessionStorage,
                cookiePreview: result["cookiePreview"] as? String ?? ""
            )

            logAuthTrace(
                "oauth-popup-storage-snapshot",
                currentURL: finalURL,
                extra:
                    "href=\(snapshot.href) title=\(snapshot.title) localStatus=\(result["localStorageStatus"] as? String ?? "unknown") sessionStatus=\(result["sessionStorageStatus"] as? String ?? "unknown") localKeys=\(localStorage.keys.sorted()) sessionKeys=\(sessionStorage.keys.sorted()) cookiePreviewLength=\(snapshot.cookiePreview.count) bodyPreview=\((result["bodyPreview"] as? String ?? "").replacingOccurrences(of: "\n", with: " "))"
            )

            return snapshot
        } catch {
            logAuthTrace(
                "oauth-popup-storage-snapshot",
                currentURL: finalURL,
                extra: "error=\(error.localizedDescription)"
            )
            return nil
        }
    }

    private func applyOAuthStorageSnapshotIfPossible(
        _ snapshot: OAuthStorageSnapshot,
        matching finalURL: URL?
    ) async {
        guard let parentWebView = existingWebView,
              let finalURL,
              let parentHost = url.host?.lowercased(),
              let finalHost = finalURL.host?.lowercased(),
              parentHost == finalHost else {
            return
        }

        var payload: [String: Any] = [
            "windowName": snapshot.windowName,
            "localStorage": snapshot.localStorage,
            "sessionStorage": snapshot.sessionStorage
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let json = String(data: data, encoding: .utf8) else {
            logAuthTrace(
                "oauth-parent-storage-apply",
                currentURL: finalURL,
                extra: "error=payload-serialization"
            )
            return
        }

        let script = """
        (function(snapshot) {
          try {
            const apply = (storage, values) => {
              if (!values || typeof values !== "object") { return 0; }
              let count = 0;
              for (const [key, value] of Object.entries(values)) {
                storage.setItem(key, String(value ?? ""));
                count += 1;
              }
              return count;
            };

            if (typeof snapshot.windowName === "string" && snapshot.windowName.length > 0) {
              window.name = snapshot.windowName;
            }

            const localCount = apply(window.localStorage, snapshot.localStorage);
            const sessionCount = apply(window.sessionStorage, snapshot.sessionStorage);

            return {
              href: String(window.location.href || ""),
              localCount,
              sessionCount,
              windowName: String(window.name || "")
            };
          } catch (error) {
            return { error: String(error) };
          }
        })(\(json));
        """

        do {
            let result = try await parentWebView.evaluateJavaScript(script)
            logAuthTrace(
                "oauth-parent-storage-apply",
                currentURL: finalURL,
                extra: "result=\(String(describing: result))"
            )
        } catch {
            logAuthTrace(
                "oauth-parent-storage-apply",
                currentURL: finalURL,
                extra: "error=\(error.localizedDescription)"
            )
        }
    }

    private static func stringDictionary(from anyValue: Any?) -> [String: String] {
        guard let anyValue else { return [:] }

        if let dictionary = anyValue as? [String: String] {
            return dictionary
        }

        if let dictionary = anyValue as? [String: Any] {
            return dictionary.reduce(into: [:]) { result, item in
                result[item.key] = String(describing: item.value)
            }
        }

        if let dictionary = anyValue as? NSDictionary {
            var result: [String: String] = [:]
            for (key, value) in dictionary {
                guard let keyString = key as? String else { continue }
                result[keyString] = String(describing: value)
            }
            return result
        }

        return [:]
    }

    private static func countCookies(in cookies: [HTTPCookie], matchingHost host: String?) -> Int {
        guard let host = host?.lowercased(), !host.isEmpty else { return 0 }

        return cookies.reduce(into: 0) { count, cookie in
            var cookieDomain = cookie.domain.lowercased()
            if cookieDomain.hasPrefix(".") {
                cookieDomain.removeFirst()
            }

            guard !cookieDomain.isEmpty else { return }
            if host == cookieDomain || host.hasSuffix(".\(cookieDomain)") {
                count += 1
            }
        }
    }

    private static func cookieDebugSummary(in cookies: [HTTPCookie], matchingHost host: String?) -> String {
        guard let host = host?.lowercased(), !host.isEmpty else { return "[]" }

        let filtered = cookies.filter { cookie in
            var cookieDomain = cookie.domain.lowercased()
            if cookieDomain.hasPrefix(".") {
                cookieDomain.removeFirst()
            }

            guard !cookieDomain.isEmpty else { return false }
            return host == cookieDomain || host.hasSuffix(".\(cookieDomain)")
        }

        let summary = filtered
            .sorted { lhs, rhs in
                if lhs.domain == rhs.domain {
                    return lhs.name < rhs.name
                }
                return lhs.domain < rhs.domain
            }
            .prefix(12)
            .map { cookie in
                let flags = "\(cookie.isHTTPOnly ? "H" : "-")\(cookie.isSecure ? "S" : "-")"
                return "\(cookie.name)@\(cookie.domain)[\(flags)]"
            }

        if filtered.count > 12 {
            return "[\(summary.joined(separator: ", ")), +\(filtered.count - 12) more]"
        }

        return "[\(summary.joined(separator: ", "))]"
    }

    private static func authSetCookieNames(from response: HTTPURLResponse) -> [String] {
        let headerEntries = response.allHeaderFields.compactMap { key, value -> String? in
            guard String(describing: key).lowercased() == "set-cookie" else { return nil }
            return String(describing: value)
        }

        guard !headerEntries.isEmpty else { return [] }

        return headerEntries
            .flatMap { entry in
                entry.split(separator: "\n").map(String.init)
            }
            .compactMap { entry in
                let firstSegment = entry.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true).first
                let cookiePair = firstSegment.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard let equalsIndex = cookiePair.firstIndex(of: "="), equalsIndex != cookiePair.startIndex else {
                    return nil
                }
                return String(cookiePair[..<equalsIndex])
            }
    }

    private func logAuthCookieSnapshot(reason: String, webView: WKWebView?, currentURL: URL?) {
        guard let currentURL,
              let host = currentURL.host?.lowercased(),
              let store = webView?.configuration.websiteDataStore else {
            return
        }

        Task { @MainActor in
            let cookies = await store.httpCookieStore.allCookiesAsync()
            let summary = Self.cookieDebugSummary(in: cookies, matchingHost: host)
            let count = Self.countCookies(in: cookies, matchingHost: host)
            let message =
                "🔐 [AuthTrace] \(reason) \(authTraceContext(currentURL: currentURL)) hostCookieCount=\(count) hostCookieSummary=\(summary)"
            print(message)
            Self.writeAuthDiagnostic(message)
        }
    }

    private static func debugDataStoreIdentifier(_ store: WKWebsiteDataStore) -> String {
        if #available(macOS 15.4, *) {
            return store.identifier?.uuidString ?? (store.isPersistent ? "persistent-default" : "nonpersistent")
        }
        return store.isPersistent ? "persistent-default" : "nonpersistent"
    }

    private static func writeAuthDiagnostic(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        authLogQueue.async {
            let data = Data(line.utf8)
            let fileURL = authLogFileURL

            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: data)
                return
            }

            guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                // Logging must never interrupt the login flow.
            }
        }
    }

    private func shouldTraceAuth(url: URL?) -> Bool {
        if isOAuthFlow || isPopupHost {
            return true
        }

        guard let url else { return false }
        if OAuthDetector.isLikelyOAuthPopupURL(url) || OAuthDetector.isLikelyOAuthURL(url) {
            return true
        }

        guard let host = url.host?.lowercased() else { return false }
        if host == "accounts.google.com" || host.hasSuffix(".accounts.google.com") {
            return true
        }
        if host == "figma.com" || host.hasSuffix(".figma.com") {
            return true
        }
        if host == "reddit.com" || host.hasSuffix(".reddit.com") {
            return true
        }
        if let providerHost = oauthProviderHost?.lowercased(),
           host == providerHost || host.hasSuffix(".\(providerHost)") || providerHost.hasSuffix(".\(host)") {
            return true
        }
        if let completionHost = oauthCompletionURLPattern?.lowercased(),
           host == completionHost || host.hasSuffix(".\(completionHost)") || completionHost.hasSuffix(".\(host)") {
            return true
        }

        return false
    }

    private func authTraceContext(currentURL: URL? = nil) -> String {
        let resolvedURL = currentURL?.absoluteString ?? url.absoluteString
        let parent = oauthParentTabId.map { String($0.uuidString.prefix(8)) } ?? "nil"
        let provider = oauthProviderHost ?? "nil"
        let completion = oauthCompletionURLPattern ?? "nil"
        return "tab=\(String(id.uuidString.prefix(8))) popup=\(isPopupHost) oauth=\(isOAuthFlow) parent=\(parent) provider=\(provider) completion=\(completion) url=\(resolvedURL)"
    }

    private func authNavigationTypeDescription(_ navigationType: WKNavigationType) -> String {
        switch navigationType {
        case .linkActivated: return "linkActivated"
        case .formSubmitted: return "formSubmitted"
        case .backForward: return "backForward"
        case .reload: return "reload"
        case .formResubmitted: return "formResubmitted"
        case .other: return "other"
        @unknown default: return "unknown"
        }
    }

    private func logAuthTrace(_ event: String, currentURL: URL? = nil, extra: String = "") {
        guard shouldTraceAuth(url: currentURL) else { return }
        if extra.isEmpty {
            let message = "🔐 [AuthTrace] \(event) \(authTraceContext(currentURL: currentURL))"
            print(message)
            Self.writeAuthDiagnostic(message)
        } else {
            let message = "🔐 [AuthTrace] \(event) \(authTraceContext(currentURL: currentURL)) \(extra)"
            print(message)
            Self.writeAuthDiagnostic(message)
        }
    }

    private func logPopupCreationRequest(
        navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures,
        sourceScheme: String,
        isFromExtension: Bool,
        isLikelyOAuthPopup: Bool
    ) {
        guard let destinationURL = navigationAction.request.url else { return }

        let sourceURL = navigationAction.sourceFrame.request.url?.absoluteString ?? "nil"
        let targetFrameDescription: String
        if let targetFrame = navigationAction.targetFrame {
            targetFrameDescription = targetFrame.isMainFrame ? "main-frame" : "sub-frame"
        } else {
            targetFrameDescription = "nil"
        }

        let width = windowFeatures.width?.stringValue ?? "nil"
        let height = windowFeatures.height?.stringValue ?? "nil"
        logAuthTrace(
            "popup-request",
            currentURL: destinationURL,
            extra:
                "sourceURL=\(sourceURL) sourceScheme=\(sourceScheme) navType=\(authNavigationTypeDescription(navigationAction.navigationType)) targetFrame=\(targetFrameDescription) isFromExtension=\(isFromExtension) isLikelyOAuthPopup=\(isLikelyOAuthPopup) windowWidth=\(width) windowHeight=\(height)"
        )
    }

    // MARK: - Peek Detection

    private func shouldRedirectToPeek(url: URL) -> Bool {
        // Always redirect to Peek if Option key is down (for any URL)
        if isOptionKeyDown {
            return true
        }

        // Check if this is an external domain URL
        guard let currentHost = self.url.host,
            let newHost = url.host
        else { return false }

        // If hosts are different, it's an external URL
        if currentHost != newHost {
            return true
        }

        return false
    }

}

// MARK: - WKUIDelegate
extension Tab: WKUIDelegate {
    public func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard let bm = browserManager else { return nil }
        let sourceScheme = navigationAction.sourceFrame.request.url?.scheme?.lowercased() ?? ""
        let isFromExtension = sourceScheme == "webkit-extension" || sourceScheme == "safari-web-extension"
        let isLikelyOAuthPopup =
            !isFromExtension
            && (navigationAction.request.url.map { isLikelyOAuthOrExternalWindow(url: $0, windowFeatures: windowFeatures) } ?? false)

        logPopupCreationRequest(
            navigationAction: navigationAction,
            windowFeatures: windowFeatures,
            sourceScheme: sourceScheme,
            isFromExtension: isFromExtension,
            isLikelyOAuthPopup: isLikelyOAuthPopup
        )
        
        if let url = navigationAction.request.url,
           shouldSuppressPopupCreation(for: url) {
            print("↩️ [Tab] Suppressing duplicate popup creation for modified link: \(url.absoluteString)")
            logAuthTrace("popup-request-suppressed", currentURL: url)
            return nil
        }

        if let url = navigationAction.request.url,
           shouldReuseCurrentTabForPopupNavigation(
                destinationURL: url,
                navigationAction: navigationAction,
                windowFeatures: windowFeatures
           ) {
            print("↩️ [Tab] Reusing current tab for Google account switch flow: \(url.absoluteString)")
            var request = navigationAction.request
            request.cachePolicy = .reloadIgnoringLocalCacheData
            self.url = url
            self.loadingState = .didStartProvisionalNavigation
            webView.load(request)
            Task { @MainActor in
                await fetchAndSetFavicon(for: url)
            }
            logAuthTrace("popup-reused-current-tab", currentURL: url)
            return nil
        }

        if shouldOpenPopupNavigationAsChildTab(
            navigationAction: navigationAction,
            isFromExtension: isFromExtension,
            isLikelyOAuthPopup: isLikelyOAuthPopup
        ),
           let url = navigationAction.request.url,
           let windowState = sourceWindowState(for: webView),
           let newTab = bm.createNewTab(in: windowState, url: url.absoluteString) {
            bm.tabManager.attachTab(newTab, asChildOf: self)
            print("↪️ [Tab] Opened blank-target link as child tab: \(url.absoluteString)")
            return nil
        }

        // For OAuth popups, use the MiniBrowser approach: create a WKWebView
        // with the UNMODIFIED WebKit-provided configuration. Any modifications
        // (data store, process pool, message handlers, UA) can break
        // window.opener and cause layer tree crashes.
        if isLikelyOAuthPopup,
           let url = navigationAction.request.url {
            logAuthTrace("popup-minibrowser-style", currentURL: url)

            let popupWebView = WKWebView(frame: CGRect(x: 0, y: 0, width: 500, height: 700), configuration: configuration)
            popupWebView.isInspectable = true

            let popupWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 500, height: 700),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            popupWindow.isReleasedWhenClosed = false
            popupWindow.center()
            popupWindow.title = "Sign In"
            popupWindow.contentView = popupWebView

            // Watch for auth completion and auto-hide after delay
            let openerHost = self.url.host?.lowercased() ?? ""
            let observer = OAuthPopupObserver(
                webView: popupWebView,
                window: popupWindow,
                openerHost: openerHost,
                popupHost: url.host?.lowercased() ?? ""
            )
            popupWebView.uiDelegate = observer
            popupWindow.delegate = observer
            popupWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)

            // Hold references so they don't get deallocated
            objc_setAssociatedObject(self, "oauthPopupWindow", popupWindow, .OBJC_ASSOCIATION_RETAIN)
            objc_setAssociatedObject(self, "oauthPopupObserver", observer, .OBJC_ASSOCIATION_RETAIN)

            return popupWebView
        }


        // Site-created popup windows must never be redirected to a custom
        // miniwindow when the page expects a real `window.open` result.
        // Providers like Google/Figma rely on the returned popup handle and
        // `window.opener` to finish SSO, write session state, and close the
        // popup. Returning a real WKWebView here preserves that contract.

        // Force the popup onto the opener's exact browsing session. If the popup
        // ends up on a different data store or process pool, OAuth cookies can
        // complete inside the popup but never become visible to the opener tab.
        // That manifests as "login succeeded in the popup, parent page stayed
        // logged out" across sites like Figma, Reddit, and Google-backed auth.
        //
        // WebKit hands us a popup configuration here, but it is safer to align
        // the mutable session pieces with the opener before instantiating the
        // returned WKWebView.

        // For real site-created popups, create a detached popup session instead
        // of a sidebar tab. This preserves native popup semantics without
        // polluting the workspace tree.

        // Create a detached tab model to own the popup webview and its delegates.
        let newTab = Tab(
            url: navigationAction.request.url ?? URL(string: "about:blank")!,
            name: "New Tab",
            favicon: "globe",
            spaceId: nil,
            index: 0,
            browserManager: bm
        )
        newTab.isPopupHost = true
        if isLikelyOAuthPopup {
            newTab.isOAuthFlow = true
            newTab.oauthParentTabId = self.id
            newTab.oauthProviderHost = navigationAction.request.url?.host?.lowercased()
            newTab.oauthCompletionURLPattern = self.url.host?.lowercased()
            newTab.oauthReturnURL = self.url
            newTab.oauthInitialURL = navigationAction.request.url

            if let providerHost = newTab.oauthProviderHost {
                bm.oauthAllowDomain(providerHost)
            }

            // Keep the opener temporarily relaxed so the post-auth refresh does
            // not immediately run back under stricter third-party storage rules.
            bm.trackingProtectionManager.disableTemporarily(for: self, duration: 15 * 60, reload: false)
        }

        logAuthTrace(
            "popup-tab-created",
            currentURL: navigationAction.request.url,
            extra:
                "newTab=\(String(newTab.id.uuidString.prefix(8))) popupHost=\(newTab.oauthProviderHost ?? "nil") openerURL=\(self.url.absoluteString)"
        )

        alignPopupConfigurationWithOpener(
            configuration,
            openerWebView: webView,
            popupURL: navigationAction.request.url,
            popupTab: newTab
        )

        let newWebView = FocusableWKWebView(frame: .zero, configuration: configuration)
        newWebView.underPageBackgroundColor = .white

        // Set up the new webView with the same delegates and settings as the current tab
        newWebView.navigationDelegate = newTab
        newWebView.uiDelegate = newTab
        newWebView.allowsBackForwardNavigationGestures = true
        newWebView.allowsMagnification = true

        // Set the owning tab reference
        newWebView.owningTab = newTab

        // Store the webView in the new tab
        newTab._webView = newWebView

        // Set up message handlers
        // Remove any existing handlers first to avoid duplicates
        newWebView.configuration.userContentController.removeScriptMessageHandler(
            forName: "linkHover")
        newWebView.configuration.userContentController.removeScriptMessageHandler(
            forName: "commandHover")
        newWebView.configuration.userContentController.removeScriptMessageHandler(
            forName: "commandClick")
        newWebView.configuration.userContentController.removeScriptMessageHandler(
            forName: "pipStateChange")
        newWebView.configuration.userContentController.removeScriptMessageHandler(
            forName: "mediaStateChange_\(newTab.id.uuidString)")
        newWebView.configuration.userContentController.removeScriptMessageHandler(
            forName: "backgroundColor_\(newTab.id.uuidString)")
        newWebView.configuration.userContentController.removeScriptMessageHandler(
            forName: "historyStateDidChange")
        newWebView.configuration.userContentController.removeScriptMessageHandler(
            forName: "SocketIdentity")

        // Now add the handlers
        newWebView.configuration.userContentController.add(newTab, name: "linkHover")
        newWebView.configuration.userContentController.add(newTab, name: "commandHover")
        newWebView.configuration.userContentController.add(newTab, name: "commandClick")
        newWebView.configuration.userContentController.add(newTab, name: "pipStateChange")
        newWebView.configuration.userContentController.add(
            newTab, name: "mediaStateChange_\(newTab.id.uuidString)")
        newWebView.configuration.userContentController.add(
            newTab, name: "backgroundColor_\(newTab.id.uuidString)")
        newWebView.configuration.userContentController.add(newTab, name: "historyStateDidChange")
        newWebView.configuration.userContentController.add(newTab, name: "SocketIdentity")

        // Don't set customUserAgent on popup - let the config's
        // applicationNameForUserAgent produce the correct dynamic Safari UA.

        // Configure preferences
        newWebView.configuration.preferences.isFraudulentWebsiteWarningEnabled = true
        newWebView.configuration.preferences.javaScriptCanOpenWindowsAutomatically = true

        // Popup auth windows may inherit the opener's content blockers and
        // third-party storage restrictions from the supplied WebKit
        // configuration. Re-run our shields setup against the popup tab so
        // OAuth flows actually get the relaxed policy intended by `isOAuthFlow`.
        bm.trackingProtectionManager.configureNewWebView(newWebView, for: newTab)

        // Do not manually load the popup request here. WebKit will drive the
        // navigation into the returned popup WKWebView, which preserves opener
        // semantics and avoids duplicate popup requests.
        if let url = navigationAction.request.url, url.scheme != nil,
            url.absoluteString != "about:blank"
        {
            newTab.url = url
            if let host = url.host, !host.isEmpty {
                newTab.name = host
            }
        }

        logAuthTrace(
            "popup-presented",
            currentURL: navigationAction.request.url,
            extra:
                "newTab=\(String(newTab.id.uuidString.prefix(8))) popupStore=\(Self.debugDataStoreIdentifier(newWebView.configuration.websiteDataStore)) sameProcessPool=\(webView.configuration.processPool === newWebView.configuration.processPool)"
        )

        bm.popupWindowManager.present(webView: newWebView, tab: newTab, windowFeatures: windowFeatures)

        return newWebView
    }

    // MARK: - OAuth Tab Helpers
    
    /// Sets up message handlers for an OAuth popup tab
    private func setupOAuthTabMessageHandlers(for tab: Tab, webView: WKWebView) {
        let userContentController = webView.configuration.userContentController
        
        // Remove any existing handlers first
        let handlerNames = ["linkHover", "commandHover", "commandClick", "pipStateChange",
                           "mediaStateChange_\(tab.id.uuidString)",
                           "backgroundColor_\(tab.id.uuidString)",
                           "historyStateDidChange", "SocketIdentity"]
        
        for handlerName in handlerNames {
            userContentController.removeScriptMessageHandler(forName: handlerName)
        }
        
        // Add handlers for the OAuth tab
        userContentController.add(tab, name: "linkHover")
        userContentController.add(tab, name: "commandHover")
        userContentController.add(tab, name: "commandClick")
        userContentController.add(tab, name: "pipStateChange")
        userContentController.add(tab, name: "mediaStateChange_\(tab.id.uuidString)")
        userContentController.add(tab, name: "backgroundColor_\(tab.id.uuidString)")
        userContentController.add(tab, name: "historyStateDidChange")
        userContentController.add(tab, name: "SocketIdentity")
    }
    

    /// Observes the popup webview's URL. When it navigates back to the
    /// opener's domain (callback complete), hides the window and closes
    /// after a delay to avoid the macOS 26 layer tree crash.
    /// Watches popup URL via KVO. When the popup navigates back to the
    /// opener's domain and finishes loading, hides the window.
    private class OAuthPopupObserver: NSObject, WKUIDelegate, NSWindowDelegate {
        private var urlObservation: NSKeyValueObservation?
        private var loadObservation: NSKeyValueObservation?
        private weak var window: NSWindow?
        private let openerHost: String
        private let popupHost: String
        private var callbackDetected = false
        private var didHide = false

        init(webView: WKWebView, window: NSWindow, openerHost: String, popupHost: String) {
            self.window = window
            self.openerHost = openerHost
            self.popupHost = popupHost
            super.init()
            urlObservation = webView.observe(\.url, options: [.new]) { [weak self] wv, _ in
                guard let self,
                      !self.callbackDetected,
                      let url = wv.url,
                      let host = url.host?.lowercased() else {
                    return
                }

                let returnedToOpener =
                    host == self.openerHost
                    || host.hasSuffix(".\(self.openerHost)")

                let leftProviderDomain =
                    !self.popupHost.isEmpty
                    && host != self.popupHost
                    && !host.hasSuffix(".\(self.popupHost)")
                    && !self.popupHost.hasSuffix(".\(host)")

                let noLongerLooksLikeOAuth =
                    !OAuthDetector.isLikelyOAuthPopupURL(url)
                    && !OAuthDetector.isLikelyOAuthURL(url)

                guard returnedToOpener || (leftProviderDomain && noLongerLooksLikeOAuth) else {
                    return
                }

                self.callbackDetected = true
                self.urlObservation?.invalidate()
                self.loadObservation = wv.observe(\.isLoading, options: [.new]) { [weak self] wv, _ in
                    guard let self, !self.didHide, !wv.isLoading else { return }
                    self.dismissPopup(after: 0.6)
                }
            }
        }

        func webViewDidClose(_ webView: WKWebView) {
            dismissPopup(after: 0)
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            dismissPopup(after: 0)
            return false
        }

        private func dismissPopup(after delay: TimeInterval) {
            guard !didHide else { return }
            didHide = true
            urlObservation?.invalidate()
            loadObservation?.invalidate()

            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let window = self?.window else { return }
                window.orderOut(nil)
            }
        }

        deinit { urlObservation?.invalidate(); loadObservation?.invalidate() }
    }

    /// Checks if a URL indicates OAuth completion and handles the flow
    private func checkOAuthCompletion(url: URL) {
        guard isOAuthFlow, oauthParentTabId != nil,
              browserManager != nil else { return }
        
        let urlString = url.absoluteString.lowercased()
        let host = url.host?.lowercased() ?? ""
        
        // Check for OAuth success indicators
        let successIndicators = ["code=", "access_token=", "id_token=", "oauth_token=",
                                "oauth_verifier=", "session_state=", "samlresponse="]
        
        // Check for OAuth error indicators
        let errorIndicators = ["error=", "access_denied", "invalid_request", "denied"]
        
        let isSuccess = successIndicators.contains { urlString.contains($0) }
        let isError = errorIndicators.contains { urlString.contains($0) }
        
        // Check if this is a redirect back to the original domain (not the OAuth provider)
        if let providerHost = oauthProviderHost, !host.contains(providerHost),
           (isSuccess || isError || !OAuthDetector.isLikelyOAuthURL(url)) {
            let success = !isError
            print("🔐 [Tab] OAuth callback reached: success=\(success), waiting for site-driven popup completion")

            let parentTab =
                oauthParentTabId.flatMap { parentId in
                    browserManager?.tabManager.allTabs().first(where: { $0.id == parentId })
                }

            // Do not force-close the popup here. Many providers rely on the
            // callback page to run JavaScript against `window.opener`, persist
            // session state, and then close itself. Closing as soon as the URL
            // looks "done" can interrupt the final postMessage/storage handoff.
            if let popupWebView = existingWebView {
                logOAuthPopupRuntimeState(in: popupWebView, phase: "callback")
            }

            // When the popup loaded the callback on the same host as the parent,
            // the auth code was already consumed by the popup's request. Do NOT
            // try to load the same callback URL in the parent (it will fail with
            // a used code). Instead just reload the parent so it picks up the
            // session cookies that were written by the popup.
            if success,
               let parentTab,
               isSameHostOAuthCallback(finalURL: url, parentTab: parentTab) {
                didHandleOAuthCompletion = true
                logAuthTrace(
                    "oauth-same-host-completion",
                    currentURL: url,
                    extra:
                        "action=defer-to-site parentTab=\(String(parentTab.id.uuidString.prefix(8)))"
                )
                // Do NOT reload the parent. The opener page has a JS polling
                // loop that detects a temporary cookie written by the callback
                // page. Reloading would destroy that polling context.
                return
            }

            // Some providers complete the auth callback in the popup but never
            // hand state back to the opener inside WKWebView. Relay the final
            // callback URL immediately so the parent can finish the flow under
            // the newly written cookie/session state, while still letting the
            // popup close itself naturally if the site wants to.
            if success {
                print("🔐 [Tab] Proactively relaying OAuth callback URL to parent: \(url.absoluteString)")
                didHandleOAuthCompletion = true
                Task { @MainActor [weak self, weak popupWebView = existingWebView] in
                    guard let self else { return }
                    let expectedParentHost =
                        self.oauthReturnURL?.host?.lowercased()
                        ?? self.oauthCompletionURLPattern?.lowercased()
                    if let popupWebView, let expectedParentHost {
                        self.cachedOAuthStorageSnapshot = await self.captureOAuthStorageSnapshotIfNeeded(
                            from: popupWebView,
                            finalURL: url,
                            expectedParentHost: expectedParentHost
                        )
                    }
                    self.relayOAuthCompletionToParent(
                        finalURL: url,
                        success: true,
                        alreadyMarkedHandled: true
                    )
                }
            }
        }
    }

    private func relayOAuthCompletionToParent(
        finalURL: URL?,
        success: Bool,
        alreadyMarkedHandled: Bool = false
    ) {
        guard isOAuthFlow,
              let parentTabId = oauthParentTabId,
              let bm = browserManager,
              let parentTab = bm.tabManager.allTabs().first(where: { $0.id == parentTabId }) else {
            return
        }

        guard alreadyMarkedHandled || !didHandleOAuthCompletion else {
            return
        }
        if !alreadyMarkedHandled {
            didHandleOAuthCompletion = true
        }
        logAuthTrace(
            "relayOAuthCompletionToParent",
            currentURL: finalURL ?? existingWebView?.url ?? url,
            extra:
                "success=\(success) parentTab=\(String(parentTab.id.uuidString.prefix(8))) finalURL=\(finalURL?.absoluteString ?? "nil")"
        )

        DispatchQueue.main.async { [weak bm] in
            bm?.tabManager.setActiveTab(parentTab)
            self.debugLogOAuthRelay(reason: "oauth-relay", parentTab: parentTab, finalURL: finalURL)

            guard success else { return }

            Task { @MainActor in
                await self.synchronizeCookiesFromPopupToParent(parentTab: parentTab, finalURL: finalURL)
                let storageSnapshot: OAuthStorageSnapshot?
                if let cachedOAuthStorageSnapshot = self.cachedOAuthStorageSnapshot {
                    storageSnapshot = cachedOAuthStorageSnapshot
                } else {
                    storageSnapshot = await self.captureOAuthStorageSnapshotIfNeeded(
                        from: self.existingWebView,
                        finalURL: finalURL,
                        expectedParentHost: parentTab.url.host?.lowercased()
                    )
                }
                self.cachedOAuthStorageSnapshot = nil
                if let storageSnapshot {
                    await parentTab.applyOAuthStorageSnapshotIfPossible(
                        storageSnapshot,
                        matching: finalURL
                    )
                }

                let finalHost = finalURL?.host?.lowercased()
                let parentHost = parentTab.url.host?.lowercased()
                let isSameHostCallback =
                    finalHost != nil
                    && parentHost != nil
                    && finalHost == parentHost

                if let finalURL,
                   self.shouldLoadOAuthCallbackInParent(finalURL, parentTab: parentTab) {
                    let returnURL = self.resolveOAuthReturnURL(for: parentTab, finalURL: finalURL)
                    let reason = isSameHostCallback ? "same-host-callback-url" : "callback-url"
                    self.logAuthTrace(
                        "relay-parent-action",
                        currentURL: finalURL,
                        extra:
                            "action=loadURLFresh parentTab=\(String(parentTab.id.uuidString.prefix(8))) reason=\(reason) returnURL=\(returnURL?.absoluteString ?? "nil")"
                    )
                    parentTab.scheduleOAuthReturnAfterCallback(callbackURL: finalURL, returnURL: returnURL)
                    parentTab.loadURLFresh(finalURL)
                } else if isSameHostCallback {
                    let returnURL = self.resolveOAuthReturnURL(for: parentTab, finalURL: finalURL)
                    self.logAuthTrace(
                        "relay-parent-action",
                        currentURL: finalURL ?? parentTab.url,
                        extra:
                            "action=loadURLFresh parentTab=\(String(parentTab.id.uuidString.prefix(8))) reason=same-host-popup-completed returnURL=\(returnURL?.absoluteString ?? "nil")"
                    )
                    parentTab.clearPendingOAuthReturn(reason: "same-host-popup-completed")
                    if let returnURL {
                        parentTab.loadURLFresh(returnURL)
                    } else {
                        self.forceRefreshParentAfterOAuth(parentTab, browserManager: bm)
                    }
                } else {
                    self.logAuthTrace(
                        "relay-parent-action",
                        currentURL: finalURL ?? parentTab.url,
                        extra:
                            "action=forceRefreshParentAfterOAuth parentTab=\(String(parentTab.id.uuidString.prefix(8)))"
                    )
                    self.forceRefreshParentAfterOAuth(parentTab, browserManager: bm)
                }
            }
        }
    }

    private func resolveOAuthReturnURL(for parentTab: Tab, finalURL: URL?) -> URL? {
        let candidates = [oauthReturnURL, parentTab.url]

        for candidate in candidates {
            guard let candidate,
                  let scheme = candidate.scheme?.lowercased(),
                  ["http", "https"].contains(scheme) else {
                continue
            }

            if let finalURL, oauthURLsMatchIgnoringFragment(candidate, finalURL) {
                continue
            }

            return candidate
        }

        guard let finalURL,
              let scheme = finalURL.scheme,
              let host = finalURL.host,
              !host.isEmpty else {
            return nil
        }

        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        return components.url
    }

    func scheduleOAuthReturnAfterCallback(callbackURL: URL, returnURL: URL?) {
        clearPendingOAuthReturn(reason: "replace-pending")
        pendingOAuthCallbackURL = callbackURL
        pendingOAuthReturnURL = returnURL
        logAuthTrace(
            "oauth-parent-callback-pending",
            currentURL: callbackURL,
            extra: "returnURL=\(returnURL?.absoluteString ?? "nil")"
        )
    }

    private func handlePendingOAuthReturnIfNeeded(afterLoading loadedURL: URL) {
        guard let callbackURL = pendingOAuthCallbackURL else { return }

        guard oauthURLsMatchIgnoringFragment(loadedURL, callbackURL) else {
            clearPendingOAuthReturn(reason: "navigated-away")
            return
        }

        guard let returnURL = pendingOAuthReturnURL,
              !oauthURLsMatchIgnoringFragment(returnURL, callbackURL) else {
            clearPendingOAuthReturn(reason: "no-distinct-return-url")
            return
        }

        pendingOAuthReturnWorkItem?.cancel()

        let sameHostCallback =
            callbackURL.host?.lowercased() == returnURL.host?.lowercased()
        let delay: TimeInterval = sameHostCallback ? 2.0 : 1.8
        let expectedCallbackURL = callbackURL
        let targetURL = returnURL
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            guard self.oauthURLsMatchIgnoringFragment(self.url, expectedCallbackURL) else {
                self.clearPendingOAuthReturn(reason: "callback-already-left")
                return
            }

            self.logAuthTrace(
                "oauth-parent-post-callback",
                currentURL: expectedCallbackURL,
                extra: "action=loadURLFresh target=\(targetURL.absoluteString)"
            )
            self.clearPendingOAuthReturn(reason: "followup-navigation")
            self.loadURLFresh(targetURL)
        }

        pendingOAuthReturnWorkItem = workItem
        logAuthTrace(
            "oauth-parent-callback-scheduled",
            currentURL: callbackURL,
            extra: "delay=\(String(format: "%.2f", delay)) target=\(targetURL.absoluteString)"
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func clearPendingOAuthReturn(reason: String) {
        if pendingOAuthCallbackURL != nil || pendingOAuthReturnURL != nil || pendingOAuthReturnWorkItem != nil {
            logAuthTrace(
                "oauth-parent-callback-cleared",
                currentURL: pendingOAuthCallbackURL ?? pendingOAuthReturnURL ?? url,
                extra: "reason=\(reason)"
            )
        }
        pendingOAuthReturnWorkItem?.cancel()
        pendingOAuthReturnWorkItem = nil
        pendingOAuthCallbackURL = nil
        pendingOAuthReturnURL = nil
    }

    private func oauthURLsMatchIgnoringFragment(_ lhs: URL, _ rhs: URL) -> Bool {
        normalizedOAuthURLString(lhs) == normalizedOAuthURLString(rhs)
    }

    private func normalizedOAuthURLString(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.fragment = nil
        return components.string ?? url.absoluteString
    }

    private func shouldLoadOAuthCallbackInParent(_ finalURL: URL, parentTab: Tab) -> Bool {
        // When the popup loaded the callback on the same host, the auth code
        // is already consumed. Don't try to load it in the parent again.
        if isSameHostOAuthCallback(finalURL: finalURL, parentTab: parentTab) {
            return false
        }

        guard let scheme = finalURL.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else {
            return false
        }

        let urlString = finalURL.absoluteString.lowercased()
        let path = finalURL.path.lowercased()
        let finalHost = finalURL.host?.lowercased()
        let parentHost = parentTab.url.host?.lowercased()

        let successIndicators = [
            "code=",
            "access_token=",
            "id_token=",
            "oauth_token=",
            "oauth_verifier=",
            "session_state=",
            "samlresponse="
        ]
        let errorIndicators = [
            "error=",
            "access_denied",
            "invalid_request",
            "denied"
        ]
        let callbackPathMarkers = [
            "/finish_",
            "/callback",
            "/oauth",
            "/sso",
            "/auth/callback"
        ]

        let hasAuthIndicators =
            successIndicators.contains(where: { urlString.contains($0) })
            || errorIndicators.contains(where: { urlString.contains($0) })
        let hasCallbackPath = callbackPathMarkers.contains(where: { path.contains($0) })
        let isSameHostAsParent = finalHost == parentHost

        if hasAuthIndicators {
            return true
        }

        if isSameHostAsParent && hasCallbackPath {
            return true
        }

        if let providerHost = self.oauthProviderHost,
           let finalHost,
           !finalHost.contains(providerHost.lowercased()) {
            return true
        }

        return false
    }

    /// Returns true when the popup completed the callback on the same host as
    /// the parent. In this case the auth code was already consumed by the popup
    /// and we should NOT try to load the callback URL in the parent (the code
    /// is single-use). Instead the parent just needs a reload to pick up the
    /// session cookies that were written by the popup.
    private func isSameHostOAuthCallback(finalURL: URL, parentTab: Tab) -> Bool {
        guard let finalHost = finalURL.host?.lowercased(),
              let parentHost = parentTab.url.host?.lowercased() else {
            return false
        }
        return finalHost == parentHost
    }

    private func forceRefreshParentAfterOAuth(_ parentTab: Tab, browserManager bm: BrowserManager?) {
        let parentTabId = parentTab.id
        let refreshDelays: [TimeInterval] = [0, 0.75, 1.5]
        logAuthTrace(
            "forceRefreshParentAfterOAuth",
            currentURL: parentTab.url,
            extra:
                "parentTab=\(String(parentTab.id.uuidString.prefix(8))) delays=\(refreshDelays.map { String(format: "%.2f", $0) }.joined(separator: ","))"
        )

        for delay in refreshDelays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak bm] in
                bm?.reloadTabFromOriginAcrossWindows(parentTabId)
            }
        }
    }

    func handlePopupWindowClosed() {
        guard isPopupHost,
              isOAuthFlow,
              !didHandleOAuthCompletion else { return }

        let parentTab =
            oauthParentTabId.flatMap { parentId in
                browserManager?.tabManager.allTabs().first(where: { $0.id == parentId })
            }

        let finalURL = existingWebView?.url ?? url
        let finalHost = finalURL.host?.lowercased() ?? ""
        let providerHost = oauthProviderHost?.lowercased() ?? ""
        let urlString = finalURL.absoluteString.lowercased()
        let successIndicators = ["code=", "access_token=", "id_token=", "oauth_token=",
                                "oauth_verifier=", "session_state=", "samlresponse="]

        let looksComplete =
            (!providerHost.isEmpty && !finalHost.contains(providerHost))
            || successIndicators.contains(where: { urlString.contains($0) })

        let didNavigateAwayFromInitialURL =
            oauthInitialURL?.absoluteString != nil
            && oauthInitialURL?.absoluteString != finalURL.absoluteString
        let shouldRefreshParentOnClose = looksComplete || oauthDidProgress || didNavigateAwayFromInitialURL

        logAuthTrace(
            "handlePopupWindowClosed",
            currentURL: finalURL,
            extra:
                "looksComplete=\(looksComplete) oauthDidProgress=\(oauthDidProgress) didNavigateAwayFromInitialURL=\(didNavigateAwayFromInitialURL) shouldRefreshParentOnClose=\(shouldRefreshParentOnClose)"
        )

        if shouldRefreshParentOnClose {
            if looksComplete {
                print("🔐 [Tab] Popup window closed after auth completion, relaying to parent")
                relayOAuthCompletionToParent(finalURL: finalURL, success: true)
            } else {
                print("🔐 [Tab] Popup window closed after auth progress, refreshing parent tab")
                relayOAuthCompletionToParent(finalURL: nil, success: true)
            }
        }
    }
    
    private func handleMiniWindowAuthCompletion(success: Bool, finalURL: URL?) {
        print(
            "🪟 [Tab] Popup OAuth flow completed: success=\(success), finalURL=\(finalURL?.absoluteString ?? "nil")"
        )

        if success {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.forceRefreshParentAfterOAuth(self, browserManager: self.browserManager)
            }
        } else {
            print("🪟 [Tab] Popup OAuth authentication failed")
        }
    }

    public func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = "JavaScript Alert"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        if let window = webView.window {
            alert.beginSheetModal(for: window) { _ in
                completionHandler()
            }
        } else {
            completionHandler()
        }
    }

    public func webViewDidClose(_ webView: WKWebView) {
        if isPopupHost {
            logAuthTrace("webViewDidClose", currentURL: webView.url)
            handlePopupWindowClosed()
            browserManager?.popupWindowManager.closePopup(for: id)
        }
    }

    public func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = "JavaScript Confirm"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        if let window = webView.window {
            alert.beginSheetModal(for: window) { result in
                completionHandler(result == .alertFirstButtonReturn)
            }
        } else {
            completionHandler(false)
        }
    }

    public func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = "JavaScript Prompt"
        alert.informativeText = prompt
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        textField.stringValue = defaultText ?? ""
        alert.accessoryView = textField

        if let window = webView.window {
            alert.beginSheetModal(for: window) { result in
                completionHandler(result == .alertFirstButtonReturn ? textField.stringValue : nil)
            }
        } else {
            completionHandler(nil)
        }
    }

    // MARK: - File Upload Support
    public func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {

        let openPanel = NSOpenPanel()
        openPanel.allowsMultipleSelection = parameters.allowsMultipleSelection
        openPanel.canChooseDirectories = parameters.allowsDirectories
        openPanel.canChooseFiles = true
        openPanel.resolvesAliases = true
        openPanel.title = "Choose File"
        openPanel.prompt = "Choose"

        // Ensure we're on the main thread for UI operations
        DispatchQueue.main.async {
            if let window = webView.window {
                // Present as sheet if we have a window
                openPanel.beginSheetModal(for: window) { response in
                    print("📁 [Tab] Open panel sheet completed with response: \(response)")
                    if response == .OK {
                        print(
                            "📁 [Tab] User selected files: \(openPanel.urls.map { $0.lastPathComponent })"
                        )
                        completionHandler(openPanel.urls)
                    } else {
                        print("📁 [Tab] User cancelled file selection")
                        completionHandler(nil)
                    }
                }
            } else {
                // Fall back to modal presentation
                openPanel.begin { response in
                    print("📁 [Tab] Open panel modal completed with response: \(response)")
                    if response == .OK {
                        print(
                            "📁 [Tab] User selected files: \(openPanel.urls.map { $0.lastPathComponent })"
                        )
                        completionHandler(openPanel.urls)
                    } else {
                        print("📁 [Tab] User cancelled file selection")
                        completionHandler(nil)
                    }
                }
            }
        }
    }

    // MARK: - Full-Screen Video Support
    @available(macOS 10.15, *)
    public func webView(
        _ webView: WKWebView,
        enterFullScreenForVideoWith completionHandler: @escaping (Bool, Error?) -> Void
    ) {
        print("🎬 [Tab] Entering full-screen for video - delegate method called!")

        // Get the window containing this webView
        guard let window = webView.window else {
            print("❌ [Tab] No window found for full-screen")
            completionHandler(
                false,
                NSError(
                    domain: "Tab", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "No window available for full-screen"]))
            return
        }

        print("🎬 [Tab] Found window: \(window), entering full-screen...")

        // Enter full-screen mode
        DispatchQueue.main.async {
            window.toggleFullScreen(nil)
            print("🎬 [Tab] Full-screen toggle called")
        }

        // Call completion handler immediately - WebKit will handle the actual full-screen transition
        completionHandler(true, nil)
    }

    @available(macOS 10.15, *)
    public func webView(
        _ webView: WKWebView,
        exitFullScreenWith completionHandler: @escaping (Bool, Error?) -> Void
    ) {
        print("🎬 [Tab] Exiting full-screen for video - delegate method called!")

        // Get the window containing this webView
        guard let window = webView.window else {
            print("❌ [Tab] No window found for exiting full-screen")
            completionHandler(
                false,
                NSError(
                    domain: "Tab", code: -1,
                    userInfo: [
                        NSLocalizedDescriptionKey: "No window available for exiting full-screen"
                    ]))
            return
        }

        print("🎬 [Tab] Found window: \(window), exiting full-screen...")

        // Exit full-screen mode
        DispatchQueue.main.async {
            window.toggleFullScreen(nil)
            print("🎬 [Tab] Full-screen exit toggle called")
        }

        // Call completion handler immediately - WebKit will handle the actual full-screen transition
        completionHandler(true, nil)
    }

    // MARK: - Media Capture Authorization

    /// Handle requests for camera/microphone capture authorization
    @available(macOS 13.0, *)
    public func webView(
        _ webView: WKWebView,
        requestMediaCaptureAuthorization type: WKMediaCaptureType,
        for origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        print(
            "🔐 [Tab] Media capture authorization requested for type: \(type.rawValue) from origin: \(origin)"
        )

        decisionHandler(.grant)
    }
}

// MARK: - Find in Page
extension Tab {
    typealias FindResult = Result<(matchCount: Int, currentIndex: Int), Error>
    typealias FindCompletion = @Sendable (FindResult) -> Void

    func findInPage(_ text: String, completion: @escaping FindCompletion) {
        // Use the WebView that's actually visible in the current window
        let targetWebView: WKWebView?
        if let browserManager = browserManager,
            let activeWindowId = browserManager.windowRegistry?.activeWindow?.id
        {
            targetWebView = browserManager.getWebView(for: self.id, in: activeWindowId)
        } else {
            targetWebView = _webView
        }

        guard let webView = targetWebView else {
            completion(
                .failure(
                    NSError(
                        domain: "Tab", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "WebView not available"])))
            return
        }

        // First clear any existing highlights
        clearFindInPage()

        // If text is empty, return no matches
        guard !text.isEmpty else {
            completion(.success((matchCount: 0, currentIndex: 0)))
            return
        }

        // Use JavaScript to search and highlight text
        let escapedText = text.replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")

        let script = """
            (function() {
                // Check if document is ready
                if (!document.body) {
                    return { matchCount: 0, currentIndex: 0, error: 'Document not ready' };
                }

                // Remove existing highlights
                var existingHighlights = document.querySelectorAll('.socket-find-highlight');
                existingHighlights.forEach(function(el) {
                    var parent = el.parentNode;
                    parent.replaceChild(document.createTextNode(el.textContent), el);
                    parent.normalize();
                });

                if ('\(escapedText)' === '') {
                    return { matchCount: 0, currentIndex: 0 };
                }

                var searchText = '\(escapedText)';
                var matchCount = 0;
                var currentIndex = 0;

                // Create a tree walker to find text nodes
                var walker = document.createTreeWalker(
                    document.body,
                    NodeFilter.SHOW_TEXT,
                    {
                        acceptNode: function(node) {
                            // Skip script and style elements
                            var parent = node.parentElement;
                            if (parent && (parent.tagName === 'SCRIPT' || parent.tagName === 'STYLE')) {
                                return NodeFilter.FILTER_REJECT;
                            }
                            return NodeFilter.FILTER_ACCEPT;
                        }
                    }
                );

                var textNodes = [];
                var node;
                while (node = walker.nextNode()) {
                    textNodes.push(node);
                }

                // Search and highlight
                textNodes.forEach(function(textNode) {
                    var text = textNode.textContent;
                    if (text && text.length > 0) {
                        var regex = new RegExp('(' + searchText.replace(/[.*+?^${}()|[\\]\\\\]/g, '\\\\$&') + ')', 'gi');
                        var matches = text.match(regex);

                        if (matches && matches.length > 0) {
                            matchCount += matches.length;
                            var highlightedHTML = text.replace(regex, '<span class="socket-find-highlight" style="background-color: yellow; color: black;">$1</span>');

                            var wrapper = document.createElement('div');
                            wrapper.innerHTML = highlightedHTML;

                            var parent = textNode.parentNode;
                            while (wrapper.firstChild) {
                                parent.insertBefore(wrapper.firstChild, textNode);
                            }
                            parent.removeChild(textNode);
                        }
                    }
                });

                // Scroll to first match
                var firstHighlight = document.querySelector('.socket-find-highlight');
                if (firstHighlight) {
                    firstHighlight.scrollIntoView({ behavior: 'smooth', block: 'center' });
                    firstHighlight.style.backgroundColor = 'orange';
                }

                return { matchCount: matchCount, currentIndex: matchCount > 0 ? 1 : 0 };
            })();
            """

        webView.evaluateJavaScript(script) { result, error in
            if let error = error {
                print("Find JavaScript error: \(error.localizedDescription)")
                completion(.failure(error))
                return
            }

            print("Find JavaScript result: \(String(describing: result))")

            if let dict = result as? [String: Any],
                let matchCount = dict["matchCount"] as? Int,
                let currentIndex = dict["currentIndex"] as? Int
            {
                print("Find found \(matchCount) matches, current index: \(currentIndex)")
                completion(.success((matchCount: matchCount, currentIndex: currentIndex)))
            } else {
                print("Find result parsing failed, returning 0 matches")
                completion(.success((matchCount: 0, currentIndex: 0)))
            }
        }
    }

    func findNextInPage(completion: @escaping FindCompletion) {
        // Use the WebView that's actually visible in the current window
        let targetWebView: WKWebView?
        if let browserManager = browserManager,
            let activeWindowId = browserManager.windowRegistry?.activeWindow?.id
        {
            targetWebView = browserManager.getWebView(for: self.id, in: activeWindowId)
        } else {
            targetWebView = _webView
        }

        guard let webView = targetWebView else {
            completion(
                .failure(
                    NSError(
                        domain: "Tab", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "WebView not available"])))
            return
        }

        let script = """
            (function() {
                var highlights = document.querySelectorAll('.socket-find-highlight');
                if (highlights.length === 0) {
                    return { matchCount: 0, currentIndex: 0 };
                }

                // Find current active highlight
                var currentActive = document.querySelector('.socket-find-highlight.active');
                var currentIndex = 0;

                if (currentActive) {
                    // Remove active class from current
                    currentActive.classList.remove('active');
                    currentActive.style.backgroundColor = 'yellow';

                    // Find next highlight
                    var nextIndex = Array.from(highlights).indexOf(currentActive) + 1;
                    if (nextIndex >= highlights.length) {
                        nextIndex = 0; // Wrap to beginning
                    }
                    currentIndex = nextIndex + 1;
                } else {
                    // No active highlight, make first one active
                    currentIndex = 1;
                }

                // Set new active highlight
                var activeIndex = currentIndex - 1;
                if (activeIndex >= 0 && activeIndex < highlights.length) {
                    var activeHighlight = highlights[activeIndex];
                    activeHighlight.classList.add('active');
                    activeHighlight.style.backgroundColor = 'orange';
                    activeHighlight.scrollIntoView({ behavior: 'smooth', block: 'center' });
                }

                return { matchCount: highlights.length, currentIndex: currentIndex };
            })();
            """

        webView.evaluateJavaScript(script) { result, error in
            if let error = error {
                completion(.failure(error))
                return
            }

            if let dict = result as? [String: Any],
                let matchCount = dict["matchCount"] as? Int,
                let currentIndex = dict["currentIndex"] as? Int
            {
                completion(.success((matchCount: matchCount, currentIndex: currentIndex)))
            } else {
                completion(.success((matchCount: 0, currentIndex: 0)))
            }
        }
    }

    func findPreviousInPage(completion: @escaping FindCompletion) {
        // Use the WebView that's actually visible in the current window
        let targetWebView: WKWebView?
        if let browserManager = browserManager,
            let activeWindowId = browserManager.windowRegistry?.activeWindow?.id
        {
            targetWebView = browserManager.getWebView(for: self.id, in: activeWindowId)
        } else {
            targetWebView = _webView
        }

        guard let webView = targetWebView else {
            completion(
                .failure(
                    NSError(
                        domain: "Tab", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "WebView not available"])))
            return
        }

        let script = """
            (function() {
                var highlights = document.querySelectorAll('.socket-find-highlight');
                if (highlights.length === 0) {
                    return { matchCount: 0, currentIndex: 0 };
                }

                // Find current active highlight
                var currentActive = document.querySelector('.socket-find-highlight.active');
                var currentIndex = 0;

                if (currentActive) {
                    // Remove active class from current
                    currentActive.classList.remove('active');
                    currentActive.style.backgroundColor = 'yellow';

                    // Find previous highlight
                    var prevIndex = Array.from(highlights).indexOf(currentActive) - 1;
                    if (prevIndex < 0) {
                        prevIndex = highlights.length - 1; // Wrap to end
                    }
                    currentIndex = prevIndex + 1;
                } else {
                    // No active highlight, make last one active
                    currentIndex = highlights.length;
                }

                // Set new active highlight
                var activeIndex = currentIndex - 1;
                if (activeIndex >= 0 && activeIndex < highlights.length) {
                    var activeHighlight = highlights[activeIndex];
                    activeHighlight.classList.add('active');
                    activeHighlight.style.backgroundColor = 'orange';
                    activeHighlight.scrollIntoView({ behavior: 'smooth', block: 'center' });
                }

                return { matchCount: highlights.length, currentIndex: currentIndex };
            })();
            """

        webView.evaluateJavaScript(script) { result, error in
            if let error = error {
                completion(.failure(error))
                return
            }

            if let dict = result as? [String: Any],
                let matchCount = dict["matchCount"] as? Int,
                let currentIndex = dict["currentIndex"] as? Int
            {
                completion(.success((matchCount: matchCount, currentIndex: currentIndex)))
            } else {
                completion(.success((matchCount: 0, currentIndex: 0)))
            }
        }
    }

    func clearFindInPage() {
        // Use the WebView that's actually visible in the current window
        let targetWebView: WKWebView?
        if let browserManager = browserManager,
            let activeWindowId = browserManager.windowRegistry?.activeWindow?.id
        {
            targetWebView = browserManager.getWebView(for: self.id, in: activeWindowId)
        } else {
            targetWebView = _webView
        }

        guard let webView = targetWebView else { return }

        let script = """
            (function() {
                var highlights = document.querySelectorAll('.socket-find-highlight');
                highlights.forEach(function(el) {
                    var parent = el.parentNode;
                    parent.replaceChild(document.createTextNode(el.textContent), el);
                    parent.normalize();
                });
            })();
            """

        webView.evaluateJavaScript(script) { _, _ in }
    }
}

// MARK: - Hashable & Equatable
extension Tab {
    public static func == (lhs: Tab, rhs: Tab) -> Bool {
        return lhs.id == rhs.id
    }

    public override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? Tab else { return false }
        return self.id == other.id
    }

    public override var hash: Int {
        return id.hashValue
    }
}

extension Tab {
    func deliverContextMenuPayload(_ payload: WebContextMenuPayload?) {
        print("🔽 [Tab] deliverContextMenuPayload called, payload exists: \(payload != nil)")
        pendingContextMenuPayload = payload
        if let webView = _webView as? FocusableWKWebView {
            print("🔽 [Tab] Calling webView.contextMenuPayloadDidUpdate")
            webView.contextMenuPayloadDidUpdate(payload)
        } else {
            print("🔽 [Tab] WARNING: _webView is nil or not FocusableWKWebView")
        }
    }
}

// MARK: - NSColor Extension
extension NSColor {
    convenience init?(hex: String) {
        var hexString = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if hexString.hasPrefix("#") {
            hexString.removeFirst()
        }

        guard hexString.count == 6 else { return nil }

        var rgbValue: UInt64 = 0
        guard Scanner(string: hexString).scanHexInt64(&rgbValue) else { return nil }

        let red = CGFloat((rgbValue & 0xFF0000) >> 16) / 255.0
        let green = CGFloat((rgbValue & 0x00FF00) >> 8) / 255.0
        let blue = CGFloat(rgbValue & 0x0000FF) / 255.0

        self.init(red: red, green: green, blue: blue, alpha: 1.0)
    }
}

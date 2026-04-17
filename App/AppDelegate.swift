//
//  AppDelegate.swift
//  Socket
//
//  Application lifecycle delegate handling app termination, URL events, and Sparkle updates
//

import AppKit
import OSLog
import Sparkle

/// Handles application-level lifecycle events and coordinates app termination
///
/// Key responsibilities:
/// - **URL Handling**: Opens external URLs (e.g., from other apps, custom URL schemes)
/// - **Mouse Button Events**: Maps mouse buttons 2/3/4 to command palette, back, and forward
/// - **App Termination**: Coordinates graceful shutdown with data persistence
/// - **Sparkle Updates**: Integrates with Sparkle framework for auto-updates
///
/// The termination flow uses async persistence to avoid MainActor deadlocks:
/// 1. Returns `.terminateLater` immediately
/// 2. Persists tab snapshots atomically
/// 3. Saves SwiftData context
/// 4. Cleans up WKWebView processes
/// 5. Replies with terminate approval
class AppDelegate: NSObject, NSApplicationDelegate, SPUUpdaterDelegate {
    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Socket", category: "AppTermination")

    /// Update channel: "stable" or "nightly"
    static let updateChannelKey = "settings.updateChannel"
    private static let stableFeedURL = "https://socket-browser.github.io/socket/appcast.xml"
    private static let nightlyFeedURL = "https://socket-browser.github.io/socket/appcast-nightly.xml"

    // TEMPORARY: Reference to BrowserManager for coordinating browser operations
    // TODO: Replace with direct access to independent managers (TabManager, etc.)
    weak var browserManager: BrowserManager?

    // Window registry for accessing active window state
    weak var windowRegistry: WindowRegistry?

    // MCP Manager reference for cleanup on termination
    var mcpManager: MCPManager?

    private let urlEventClass = AEEventClass(kInternetEventClass)
    private let urlEventID = AEEventID(kAEGetURL)
    private var mouseEventMonitor: Any?
    private let userDefaults = UserDefaults.standard
    private var pendingURLs: [URL] = []
    


    // MARK: - Sparkle Updates

    /// Sparkle updater controller for automatic app updates
    lazy var updaterController: SPUStandardUpdaterController = {
        return SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
    }()

    // MARK: - Application Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupURLEventHandling()
        setupMouseButtonHandling()
        let didFinishOnboarding = userDefaults.bool(forKey: "settings.didFinishOnboarding")
        DispatchQueue.main.async { [weak self] in
            self?.surfacePrimaryWindow(didFinishOnboarding: didFinishOnboarding)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.surfacePrimaryWindow(didFinishOnboarding: didFinishOnboarding)
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if flag {
            surfacePrimaryWindow(
                didFinishOnboarding: userDefaults.bool(forKey: "settings.didFinishOnboarding")
            )
            return true
        }

        if let window = sender.windows.first {
            configure(window: window, didFinishOnboarding: true)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return true
        }

        return false
    }

    private func surfacePrimaryWindow(didFinishOnboarding: Bool) {
        guard let window = NSApplication.shared.windows.first else { return }
        configure(window: window, didFinishOnboarding: didFinishOnboarding)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)

        if !didFinishOnboarding {
            NSApp.hideOtherApplications(nil)
        }
    }

    private func configure(window: NSWindow, didFinishOnboarding: Bool) {
        // Always hide titlebar immediately to prevent flash during transitions
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbar?.isVisible = false
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true

        if !didFinishOnboarding {
            window.setContentSize(NSSize(width: 1200, height: 720))
            window.center()
        }
    }

    /// Registers handler for external URL events (e.g., clicking links from other apps)
    private func setupURLEventHandling() {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: urlEventClass,
            andEventID: urlEventID
        )
    }

    /// Sets up global mouse button event monitoring for extra physical mouse buttons
    ///
    /// Many mice have extra buttons beyond left/right click. This maps them to browser actions:
    /// - **Button 2** (middle click/scroll wheel button): Open command palette
    /// - **Button 3** (typically a side button labeled "Back"): Navigate back in history
    /// - **Button 4** (typically a side button labeled "Forward"): Navigate forward in history
    ///
    /// This is common in browsers - side buttons on gaming/office mice are often used for navigation.
    private func setupMouseButtonHandling() {
        mouseEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) {
            [weak self] event in
            guard let self = self,
                  let manager = self.browserManager,
                  let registry = self.windowRegistry else { return event }

            // Mouse events are delivered on the main thread, so we can safely assume main actor isolation
            MainActor.assumeIsolated {
                switch event.buttonNumber {
                case 2:  // Middle mouse button
                    registry.activeWindow?.commandPalette?.open()
                case 3:  // Back button
                    guard
                        let windowState = registry.activeWindow,
                        let currentTab = manager.currentTab(for: windowState),
                        let webView = manager.getWebView(for: currentTab.id, in: windowState.id)
                    else {
                        return
                    }
                    webView.goBack()
                case 4:  // Forward button
                    guard
                        let windowState = registry.activeWindow,
                        let currentTab = manager.currentTab(for: windowState),
                        let webView = manager.getWebView(for: currentTab.id, in: windowState.id)
                    else {
                        return
                    }
                    webView.goForward()
                default:
                    break
                }
            }
            return event
        }
    }

    /// Handles URLs opened from external sources (e.g., Finder, other apps)
    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach { handleIncoming(url: $0) }
    }

    // MARK: - Application Termination

    /// Initiates async termination process to avoid MainActor deadlocks
    ///
    /// Returns `.terminateLater` immediately, then performs async cleanup:
    /// 1. Phase 1: Atomic snapshot persistence (non-blocking)
    /// 2. Phase 2: SwiftData context save
    /// 3. Phase 3: WKWebView process cleanup
    ///
    /// - Returns: Always returns `.terminateLater` to handle termination asynchronously
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let reason = NSAppleEventManager.shared()
            .currentAppleEvent?
            .attributeDescriptor(forKeyword: kAEQuitReason)

        switch reason?.enumCodeValue {
        case nil:
            handleTermination(sender: sender, shouldTerminate: true)
        default:
            handleTermination(sender: sender, shouldTerminate: true)
        }

        return .terminateLater
    }

    /// Performs async termination tasks on MainActor
    ///
    /// This method executes the three-phase shutdown process:
    /// - **Phase 1**: Atomic tab snapshot persistence
    /// - **Phase 2**: SwiftData context save
    /// - **Phase 3**: WebView cleanup
    ///
    /// Timing is logged for each phase to monitor performance.
    private func handleTermination(sender: NSApplication, shouldTerminate: Bool) {
        AppDelegate.log.info(
            "applicationShouldTerminate: returning terminateLater and starting async persistence")

        Task { @MainActor in
            guard shouldTerminate else {
                sender.reply(toApplicationShouldTerminate: false)
                return
            }

            // Minimal fallback if BrowserManager is unavailable
            guard let manager = browserManager else {
                // Attempt a best-effort save via shared persistence container
                do {
                    let ctx = Persistence.shared.container.mainContext
                    try ctx.save()
                    AppDelegate.log.info("Fallback save without BrowserManager succeeded")
                } catch {
                    AppDelegate.log.error(
                        "Fallback save without BrowserManager failed: \(String(describing: error))"
                    )
                }
                sender.reply(toApplicationShouldTerminate: true)
                return
            }

            let overallStart = CFAbsoluteTimeGetCurrent()
            AppDelegate.log.info("Termination task started on MainActor")

            // Phase 1: Atomic snapshot persistence (non-throwing Bool)
            let persistStart = CFAbsoluteTimeGetCurrent()
            let atomic: Bool = await manager.tabManager.persistSnapshotAwaitingResult()
            let pdt = CFAbsoluteTimeGetCurrent() - persistStart
            AppDelegate.log.info(
                "Atomic persistence \(atomic ? "succeeded" : "did not run; fallback used") in \(String(format: "%.3f", pdt))s"
            )

            // Phase 2: Ensure SwiftData changes are committed
            let contextSaveStart = CFAbsoluteTimeGetCurrent()
            do {
                try manager.modelContext.save()
                let sdt = CFAbsoluteTimeGetCurrent() - contextSaveStart
                AppDelegate.log.info("Context save completed in \(String(format: "%.3f", sdt))s")
            } catch {
                let sdt = CFAbsoluteTimeGetCurrent() - contextSaveStart
                AppDelegate.log.error(
                    "Context save failed in \(String(format: "%.3f", sdt))s: \(String(describing: error))"
                )
            }

            // Phase 3: Graceful cleanup
            manager.cleanupAllTabs()
            AppDelegate.log.info("Cleanup completed; WKWebView processes terminated")

            // Phase 3b: Tear down the extension subsystem while we're still on
            // MainActor. deinit can't safely unload WKWebExtensionContexts.
            if #available(macOS 15.4, *) {
                ExtensionManager.shared.shutdownSync()
            }

            let total = CFAbsoluteTimeGetCurrent() - overallStart
            AppDelegate.log.info(
                "Termination task finished in \(String(format: "%.3f", total))s; replying to terminate"
            )
            sender.reply(toApplicationShouldTerminate: true)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Keep minimal to avoid MainActor deadlocks; main work happens in applicationShouldTerminate
        AppDelegate.log.info("applicationWillTerminate called")

        // Stop MCP child processes synchronously (blocking up to 5 seconds)
        mcpManager?.stopAllSync()
    }

    // MARK: - External URL Handling

    /// Handles URL events from AppleScript/AppleEvents
    @objc private func handleGetURLEvent(
        _ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor
    ) {
        guard let stringValue = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
            let url = URL(string: stringValue)
        else {
            return
        }
        handleIncoming(url: url)
    }

    /// Routes incoming external URLs to the browser manager
    private func handleIncoming(url: URL) {
        Task { @MainActor [weak self] in
            self?.routeIncomingURL(url)
        }
    }

    @MainActor
    private func routeIncomingURL(_ url: URL) {
        guard let manager = browserManager else {
            AppDelegate.log.info("Queuing external URL until browser startup is ready: \(url.absoluteString, privacy: .public)")
            pendingURLs.append(url)
            return
        }

        let prefersExternalView = manager.socketSettings?.openExternalLinksInMiniWindow == true
        if !prefersExternalView, windowRegistry?.allWindows.isEmpty != false {
            AppDelegate.log.info("Queuing external URL until a browser window is registered: \(url.absoluteString, privacy: .public)")
            pendingURLs.append(url)
            return
        }

        Task { @MainActor in
            manager.presentExternalURL(url)
        }
    }

    /// Opens any URLs that arrived before BrowserManager wiring completed.
    func drainPendingURLs() {
        guard !pendingURLs.isEmpty else { return }
        let urls = pendingURLs
        pendingURLs.removeAll()
        urls.forEach { handleIncoming(url: $0) }
    }
}

// MARK: - Sparkle Delegate

extension AppDelegate {
    /// Called when Sparkle finds a valid update
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        Task { @MainActor in
            browserManager?.handleUpdaterFoundValidUpdate(item)
        }
    }

    /// Called when Sparkle finishes downloading an update
    func updater(_ updater: SPUUpdater, didFinishDownloadingUpdate item: SUAppcastItem) {
        Task { @MainActor in
            browserManager?.handleUpdaterFinishedDownloading(item)
        }
    }

    /// Called when no update is found
    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor in
            browserManager?.handleUpdaterDidNotFindUpdate()
        }
    }

    /// Called when user cancels the update download
    func userDidCancelDownload(_ updater: SPUUpdater) {
        Task { @MainActor in
            browserManager?.handleUpdaterAbortedUpdate()
        }
    }

    /// Called when update process encounters an error
    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        Task { @MainActor in
            browserManager?.handleUpdaterAbortedUpdate()
        }
    }

    /// Called when update is ready to install on quit
    func updater(
        _ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationInvocation: @escaping () -> Void
    ) {
        Task { @MainActor in
            browserManager?.handleUpdaterWillInstallOnQuit(item)
        }
    }

    // MARK: - Sparkle Multi-Channel Feed

    func feedURLString(for updater: SPUUpdater) -> String? {
        let channel = UserDefaults.standard.string(forKey: Self.updateChannelKey) ?? "stable"
        return channel == "nightly" ? Self.nightlyFeedURL : Self.stableFeedURL
    }
}

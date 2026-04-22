import SwiftUI
import AppKit
import WebKit

struct TabCompositorView: NSViewRepresentable {
    let browserManager: BrowserManager
    @Environment(BrowserWindowState.self) private var windowState

    final class Coordinator {
        var installedTabId: UUID?
        weak var installedWebView: WKWebView?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.appearance = systemContentAppearance()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Appearance flips are cheap; always reapply so light/dark sync stays correct.
        nsView.appearance = systemContentAppearance()
        updateCompositor(nsView, coordinator: context.coordinator)
    }

    private func updateCompositor(_ containerView: NSView, coordinator: Coordinator) {
        // Resolve the target tab + webview. If there's nothing to show, detach
        // whatever is currently installed and stop.
        guard let currentTabId = windowState.currentTabId,
              let currentTab = browserManager.tabsForDisplay(in: windowState).first(where: { $0.id == currentTabId }),
              !currentTab.isUnloaded else {
            if let installed = coordinator.installedWebView {
                installed.removeFromSuperview()
            }
            coordinator.installedTabId = nil
            coordinator.installedWebView = nil
            return
        }

        let targetWebView = getOrCreateWebView(for: currentTab, in: windowState.id)

        // Fast path: the exact same webview is already mounted for the right tab.
        // `updateNSView` fires on any BrowserWindowState change (sidebar toggle,
        // toolbar click, profile tick, etc.) — tearing the webview out of the view
        // hierarchy every time forces AppKit to re-layout and WebKit to re-sync
        // its compositing surfaces. Skip the churn unless something actually moved.
        if coordinator.installedTabId == currentTabId,
           coordinator.installedWebView === targetWebView,
           targetWebView.superview === containerView {
            // Keep frame / appearance in sync in case the container resized.
            if targetWebView.frame != containerView.bounds {
                targetWebView.frame = containerView.bounds
            }
            targetWebView.appearance = systemContentAppearance()
            return
        }

        // Different tab or different webview instance: swap.
        if let installed = coordinator.installedWebView, installed !== targetWebView {
            installed.removeFromSuperview()
        }

        targetWebView.frame = containerView.bounds
        targetWebView.autoresizingMask = [.width, .height]
        // Window-level preferredColorScheme (driven by sidebar gradient) forces
        // NSAppearance.darkAqua on windows with dark-perceived gradients. That
        // bleeds into WebKit's native form controls (checkboxes, radios) so they
        // render dark-mode on light pages — e.g. GitHub checkboxes as black
        // squares. Pin the webview to the *system* appearance instead.
        targetWebView.appearance = systemContentAppearance()
        if targetWebView.superview !== containerView {
            containerView.addSubview(targetWebView)
        }
        targetWebView.isHidden = false

        coordinator.installedTabId = currentTabId
        coordinator.installedWebView = targetWebView
    }

    private func systemContentAppearance() -> NSAppearance? {
        let isDark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        return NSAppearance(named: isDark ? .darkAqua : .aqua)
    }

    private func getOrCreateWebView(for tab: Tab, in windowId: UUID) -> WKWebView {
        // Check if we already have a web view for this tab in this window
        if let existingWebView = browserManager.getWebView(for: tab.id, in: windowId) {
            return existingWebView
        }

        // Create a new web view for this tab in this window
        return browserManager.createWebView(for: tab.id, in: windowId)
    }
}

// MARK: - Tab Compositor Manager
@MainActor
class TabCompositorManager: ObservableObject {
    private var unloadTimers: [UUID: Timer] = [:]
    private var lastAccessTimes: [UUID: Date] = [:]
    
    // Default unload timeout (5 minutes)
    var unloadTimeout: TimeInterval = 300
    
    init() {
        // Listen for timeout changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTimeoutChange),
            name: .tabUnloadTimeoutChanged,
            object: nil
        )
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    @objc private func handleTimeoutChange(_ notification: Notification) {
        if let timeout = notification.userInfo?["timeout"] as? TimeInterval {
            setUnloadTimeout(timeout)
        }
    }
    
    func setUnloadTimeout(_ timeout: TimeInterval) {
        self.unloadTimeout = timeout
        // Restart timers with new timeout
        restartAllTimers()
    }
    
    func markTabAccessed(_ tabId: UUID) {
        lastAccessTimes[tabId] = Date()
        restartTimer(for: tabId)
    }
    
    func unloadTab(_ tab: Tab) {
        print("🔄 [Compositor] Unloading tab: \(tab.name)")

        // Stop any existing timer
        unloadTimers[tab.id]?.invalidate()
        unloadTimers.removeValue(forKey: tab.id)
        lastAccessTimes.removeValue(forKey: tab.id)

        // Unload the webview
        tab.unloadWebView()

        // The coordinator caches a webview per (tabId, windowId). Without clearing it,
        // reactivation returns the torn-down reference and renders blank.
        browserManager?.webViewCoordinator?.removeAllWebViews(for: tab)
    }
    
    func loadTab(_ tab: Tab) {
        print("🔄 [Compositor] Loading tab: \(tab.name)")
        
        // Mark as accessed
        markTabAccessed(tab.id)
        
        // Load the webview if needed
        tab.loadWebViewIfNeeded()
    }
    
    private func restartTimer(for tabId: UUID) {
        // Cancel existing timer
        unloadTimers[tabId]?.invalidate()
        
        // Create new timer
        let timer = Timer.scheduledTimer(withTimeInterval: unloadTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.handleTabTimeout(tabId)
            }
        }
        unloadTimers[tabId] = timer
    }
    
    private func restartAllTimers() {
        // Cancel all existing timers
        unloadTimers.values.forEach { $0.invalidate() }
        unloadTimers.removeAll()
        
        // Restart timers for all accessed tabs
        for tabId in lastAccessTimes.keys {
            restartTimer(for: tabId)
        }
    }
    
    private func handleTabTimeout(_ tabId: UUID) {
        guard let tab = findTab(by: tabId) else { return }

        #if DEBUG
        // Skip auto-unload in Debug builds. It nukes logged-in sessions during
        // local development (every Gmail/GitHub tab goes back to login), and
        // we restart the app often enough that memory pressure isn't a concern.
        // Production builds still unload idle tabs after the normal timeout.
        restartTimer(for: tabId)
        return
        #else
        // Don't unload if it's the current tab
        if tab.id == tabId && tab.isCurrentTab {
            restartTimer(for: tabId)
            return
        }

        // Don't unload if tab has playing media
        if tab.hasPlayingVideo || tab.hasPlayingAudio || tab.hasAudioContent {
            restartTimer(for: tabId)
            return
        }

        unloadTab(tab)
        #endif
    }
    
    private func findTab(by id: UUID) -> Tab? {
        guard let browserManager = browserManager else { return nil }
        return browserManager.tabManager.allTabs().first { $0.id == id }
    }

    private func findTabByWebView(_ webView: WKWebView) -> Tab? {
        guard let browserManager = browserManager else { return nil }
        return browserManager.tabManager.allTabs().first { $0.webView === webView }
    }
    
    // MARK: - Public Interface
    func updateTabVisibility(currentTabId: UUID?) {
        guard let browserManager = browserManager,
              let coordinator = browserManager.webViewCoordinator else { return }
        for (windowId, _) in coordinator.compositorContainers() {
            guard let windowState = browserManager.windowRegistry?.windows[windowId] else { continue }
            browserManager.refreshCompositor(for: windowState)
        }
    }
    
    /// Update tab visibility for a specific window
    func updateTabVisibility(for windowState: BrowserWindowState) {
        browserManager?.refreshCompositor(for: windowState)
    }
    
    // MARK: - Dependencies
    weak var browserManager: BrowserManager?
}

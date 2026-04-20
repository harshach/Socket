//
//  ExternalMiniWindowManager.swift
//  Socket
//
//  Created by Jonathan Caudill on 26/08/2025.
//

import SwiftUI
import WebKit
import AppKit
import Combine

struct MiniWindowSpaceDestination: Identifiable, Hashable {
    let id: UUID
    let name: String
    /// Profile attached to the space. When the user picks this destination in
    /// the toolbar, the mini window's WebView is recreated under this profile
    /// so the current page is live-reloaded against that profile's cookies.
    let profileId: UUID?
    let profileName: String?
    let isCurrent: Bool

    var menuTitle: String {
        if let profileName, !profileName.isEmpty {
            return "\(name)  •  \(profileName)"
        }
        return name
    }
}

@MainActor
final class MiniWindowSession: ObservableObject, Identifiable {
    let id = UUID()
    /// Profile the WebView is currently rendering under. `@Published` so
    /// `MiniWindowWebView` can react to destination changes and recreate the
    /// WKWebView with the new profile's `WKWebsiteDataStore`.
    @Published private(set) var profile: Profile?
    /// Profile at creation time — restored when user picks the "Current space"
    /// entry after having switched to another destination.
    private let originalProfile: Profile?
    let originName: String
    let currentSpaceLabel: String
    let currentSpaceProfileName: String?
    let availableDestinations: [MiniWindowSpaceDestination]
    private let adoptCurrentSpaceHandler: (MiniWindowSession) -> Void
    private let adoptDestinationHandler: (MiniWindowSession, MiniWindowSpaceDestination) -> Void
    private let alwaysUseExternalViewHandler: (Bool) -> Void
    private let authCompletionHandler: ((Bool, URL?) -> Void)?

    @Published var currentURL: URL
    @Published var title: String
    @Published var isLoading: Bool = true
    @Published var estimatedProgress: Double = 0
    @Published var isAuthComplete: Bool = false
    @Published var authSuccess: Bool = false
    @Published var toolbarColor: NSColor?
    @Published var alwaysUseExternalView: Bool
    @Published var selectedDestinationId: UUID?

    /// Weak ref so the WebView coordinator can reach KeyboardShortcutManager
    /// to report when an editable web element is focused — without that, app
    /// shortcuts fire while the user is typing into the mini window's WKWebView.
    weak var browserManager: BrowserManager?

    init(
        url: URL,
        profile: Profile?,
        originName: String,
        currentSpaceLabel: String,
        currentSpaceProfileName: String?,
        availableDestinations: [MiniWindowSpaceDestination],
        alwaysUseExternalView: Bool,
        adoptCurrentSpaceHandler: @escaping (MiniWindowSession) -> Void,
        adoptDestinationHandler: @escaping (MiniWindowSession, MiniWindowSpaceDestination) -> Void,
        alwaysUseExternalViewHandler: @escaping (Bool) -> Void,
        authCompletionHandler: ((Bool, URL?) -> Void)? = nil
    ) {
        self.profile = profile
        self.originalProfile = profile
        self.originName = originName
        self.currentSpaceLabel = currentSpaceLabel
        self.currentSpaceProfileName = currentSpaceProfileName
        self.availableDestinations = availableDestinations
        self.alwaysUseExternalView = alwaysUseExternalView
        self.adoptCurrentSpaceHandler = adoptCurrentSpaceHandler
        self.adoptDestinationHandler = adoptDestinationHandler
        self.alwaysUseExternalViewHandler = alwaysUseExternalViewHandler
        self.authCompletionHandler = authCompletionHandler
        self.currentURL = url
        self.title = url.absoluteString
        self.selectedDestinationId = nil
    }

    func adopt() {
        adoptCurrentSpaceHandler(self)
    }

    func adopt(to destination: MiniWindowSpaceDestination) {
        adoptDestinationHandler(self, destination)
    }

    func openSelectedDestination() {
        if let selectedDestination {
            adopt(to: selectedDestination)
        } else {
            adopt()
        }
    }

    func selectCurrentSpace() {
        selectedDestinationId = nil
        // Restore the profile the mini window was opened under so the WebView
        // reloads under the original identity.
        profile = originalProfile
    }

    func selectDestination(_ destination: MiniWindowSpaceDestination) {
        selectedDestinationId = destination.id
        // Swap in the destination's profile. `MiniWindowWebView` reacts to
        // this and recreates the WKWebView so cookies/session match.
        if let pid = destination.profileId,
           let bm = browserManager,
           let newProfile = bm.profileManager.profiles.first(where: { $0.id == pid }) {
            profile = newProfile
        } else {
            profile = originalProfile
        }
    }

    var selectedDestination: MiniWindowSpaceDestination? {
        availableDestinations.first(where: { $0.id == selectedDestinationId })
    }

    var selectedDestinationLabel: String {
        selectedDestination?.name ?? currentSpaceLabel
    }

    var selectedDestinationMenuTitle: String {
        selectedDestination?.menuTitle ?? currentSpaceMenuTitle
    }

    var currentSpaceMenuTitle: String {
        if let currentSpaceProfileName, !currentSpaceProfileName.isEmpty {
            return "\(currentSpaceLabel)  •  \(currentSpaceProfileName)"
        }
        return currentSpaceLabel
    }

    func isSelected(_ destination: MiniWindowSpaceDestination) -> Bool {
        selectedDestinationId == destination.id
    }

    func setAlwaysUseExternalView(_ value: Bool) {
        alwaysUseExternalView = value
        alwaysUseExternalViewHandler(value)
    }

    func toggleAlwaysUseExternalView() {
        setAlwaysUseExternalView(!alwaysUseExternalView)
    }

    func updateNavigationState(url: URL?, title: String?) {
        if let url { currentURL = url }
        if let title, !title.isEmpty { self.title = title }
    }

    func updateLoading(isLoading: Bool) {
        self.isLoading = isLoading
    }

    func updateProgress(_ progress: Double) {
        estimatedProgress = progress
    }
    
    func updateToolbarColor(hexString: String?) {
        guard let trimmed = hexString?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.isEmpty == false else {
            toolbarColor = nil
            return
        }

        if let color = NSColor(hex: trimmed) {
            toolbarColor = color.usingColorSpace(.sRGB)
        } else {
            toolbarColor = nil
        }
    }
    
    func updateToolbarColor(fromPixelColor color: NSColor) {
        toolbarColor = color
    }
    
    func completeAuth(success: Bool, finalURL: URL? = nil) {
        isAuthComplete = true
        authSuccess = success
        if let finalURL = finalURL {
            currentURL = finalURL
        }
        authCompletionHandler?(success, finalURL)
        
        // Don't auto-adopt - let the user decide when to adopt the window
        // The authentication completion is communicated back to the original tab
        // but the mini window stays open for the user to manually adopt if desired
    }

    func cancelAuthDueToClose() {
        guard !isAuthComplete else { return }
        authCompletionHandler?(false, nil)
    }
}

@MainActor
final class ExternalMiniWindowManager {
    private struct SessionEntry {
        let controller: MiniBrowserWindowController
    }

    private weak var browserManager: BrowserManager?
    private var sessions: [UUID: SessionEntry] = [:]

    func attach(browserManager: BrowserManager) {
        self.browserManager = browserManager
    }

    func present(
        url: URL,
        profile: Profile? = nil,
        preferredWindowId: UUID? = nil,
        sourceWindowFrame: NSRect? = nil,
        authCompletionHandler: ((Bool, URL?) -> Void)? = nil
    ) {
        guard let browserManager else { return }
        let resolvedProfile = profile ?? browserManager.currentProfile
        let preferredWindow = preferredBrowserWindow(explicitWindowId: preferredWindowId)
        let resolvedSourceWindowFrame =
            sourceWindowFrame
            ?? preferredWindow?.window?.frame
            ?? fallbackVisibleBrowserWindowFrame()
        let fallbackSpace = resolvedCurrentSpace(
            preferredWindowId: preferredWindow?.id,
            fallbackSpaceId: nil
        ) ?? browserManager.tabManager.currentSpace ?? browserManager.tabManager.spaces.first
        let originWindowId = preferredWindow?.id
        let profileLookup = Dictionary(
            uniqueKeysWithValues: browserManager.profileManager.profiles.map { ($0.id, $0.name) }
        )
        let destinations = browserManager.tabManager.spaces.map { space in
            MiniWindowSpaceDestination(
                id: space.id,
                name: space.name,
                profileId: space.profileId,
                profileName: space.profileId.flatMap { profileLookup[$0] },
                isCurrent: space.id == fallbackSpace?.id
            )
        }
        let session = MiniWindowSession(
            url: url,
            profile: resolvedProfile,
            originName: resolvedProfile?.name ?? "Default",
            currentSpaceLabel: fallbackSpace?.name ?? "Current Space",
            currentSpaceProfileName: fallbackSpace?.profileId.flatMap { profileLookup[$0] },
            availableDestinations: destinations.filter { $0.id != fallbackSpace?.id },
            alwaysUseExternalView: browserManager.socketSettings?.openExternalLinksInMiniWindow == true,
            adoptCurrentSpaceHandler: { [weak self] session in
                self?.adoptIntoCurrentSpace(
                    session: session,
                    preferredWindowId: preferredWindow?.id,
                    fallbackSpaceId: fallbackSpace?.id
                )
            },
            adoptDestinationHandler: { [weak self] session, destination in
                self?.adopt(
                    session: session,
                    intoSpaceId: destination.id,
                    preferredWindowId: preferredWindow?.id
                )
            },
            alwaysUseExternalViewHandler: { [weak browserManager] value in
                browserManager?.socketSettings?.openExternalLinksInMiniWindow = value
            },
            authCompletionHandler: authCompletionHandler
        )
        session.browserManager = browserManager

        let controller = MiniBrowserWindowController(
            session: session,
            adoptAction: { [weak session] in session?.openSelectedDestination() },
            onClose: { [weak self] session in
                session.cancelAuthDueToClose()
                self?.sessions[session.id] = nil
                self?.restoreBrowserFocus(preferredWindowId: originWindowId)
            },
            gradientColorManager: browserManager.gradientColorManager,
            sourceWindowFrame: resolvedSourceWindowFrame
        )

        sessions[session.id] = SessionEntry(controller: controller)
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func preferredBrowserWindow(explicitWindowId: UUID? = nil) -> BrowserWindowState? {
        guard let browserManager else { return nil }

        if let explicitWindowId,
           let explicitWindow = browserManager.windowRegistry?.windows[explicitWindowId] {
            return explicitWindow
        }

        if let keyWindow = NSApp.keyWindow,
           let matchedWindow = browserManager.windowRegistry?.allWindows.first(where: { $0.window === keyWindow }) {
            return matchedWindow
        }

        if let activeWindow = browserManager.windowRegistry?.activeWindow,
           activeWindow.window != nil {
            return activeWindow
        }

        if let mainWindow = NSApp.mainWindow,
           let matchedWindow = browserManager.windowRegistry?.allWindows.first(where: { $0.window === mainWindow }) {
            return matchedWindow
        }

        if let visibleWindow = visibleBrowserWindows().first {
            return visibleWindow
        }

        if let attachedWindow = browserManager.windowRegistry?.allWindows.first(where: { $0.window != nil }) {
            return attachedWindow
        }

        return browserManager.windowRegistry?.allWindows.first
    }

    private func fallbackVisibleBrowserWindowFrame() -> NSRect? {
        if let visibleBrowserFrame = visibleBrowserWindows().first?.window?.frame {
            return visibleBrowserFrame
        }

        if let keyWindow = NSApp.keyWindow,
           keyWindow.isVisible,
           keyWindow.className == NSWindow.className() {
            return keyWindow.frame
        }

        if let mainWindow = NSApp.mainWindow,
           mainWindow.isVisible,
           mainWindow.className == NSWindow.className() {
            return mainWindow.frame
        }

        if let orderedWindow = NSApp.orderedWindows.first(where: {
            $0.isVisible
                && !$0.isMiniaturized
                && $0.level == .normal
                && $0 !== NSApp.keyWindow
        }) {
            return orderedWindow.frame
        }

        return nil
    }

    private func visibleBrowserWindows() -> [BrowserWindowState] {
        guard let browserManager else { return [] }

        return browserManager.windowRegistry?.allWindows
            .filter { windowState in
                guard let window = windowState.window else { return false }
                return window.isVisible && !window.isMiniaturized
            }
            .sorted { lhs, rhs in
                guard let lhsWindow = lhs.window, let rhsWindow = rhs.window else { return false }

                if lhsWindow.isKeyWindow != rhsWindow.isKeyWindow {
                    return lhsWindow.isKeyWindow && !rhsWindow.isKeyWindow
                }

                if lhsWindow.isMainWindow != rhsWindow.isMainWindow {
                    return lhsWindow.isMainWindow && !rhsWindow.isMainWindow
                }

                let lhsArea = lhsWindow.frame.width * lhsWindow.frame.height
                let rhsArea = rhsWindow.frame.width * rhsWindow.frame.height
                return lhsArea > rhsArea
            } ?? []
    }

    private func resolvedCurrentSpace(
        preferredWindowId: UUID?,
        fallbackSpaceId: UUID?
    ) -> Space? {
        guard let browserManager else { return nil }

        if let preferredWindowId,
           let preferredWindow = browserManager.windowRegistry?.windows[preferredWindowId],
           let currentSpaceId = preferredWindow.currentSpaceId,
           let preferredSpace = browserManager.tabManager.spaces.first(where: { $0.id == currentSpaceId }) {
            return preferredSpace
        }

        if let fallbackSpaceId,
           let fallbackSpace = browserManager.tabManager.spaces.first(where: { $0.id == fallbackSpaceId }) {
            return fallbackSpace
        }

        return browserManager.tabManager.currentSpace ?? browserManager.tabManager.spaces.first
    }

    private func resolveTargetWindow(
        preferredWindowId: UUID?,
        createIfNeeded: Bool = true,
        attemptsRemaining: Int = 4,
        completion: @escaping (BrowserWindowState?) -> Void
    ) {
        if let browserManager,
           let preferredWindowId,
           let preferredWindow = browserManager.windowRegistry?.windows[preferredWindowId] {
            completion(preferredWindow)
            return
        }

        if let preferredWindow = preferredBrowserWindow() {
            completion(preferredWindow)
            return
        }

        if createIfNeeded, let browserManager {
            browserManager.createNewWindow()
        }

        guard attemptsRemaining > 0 else {
            completion(preferredBrowserWindow())
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.resolveTargetWindow(
                preferredWindowId: preferredWindowId,
                createIfNeeded: false,
                attemptsRemaining: attemptsRemaining - 1,
                completion: completion
            )
        }
    }

    private func restoreBrowserFocus(preferredWindowId: UUID?) {
        guard let browserManager else { return }

        DispatchQueue.main.async { [weak self, weak browserManager] in
            guard let self, let browserManager else { return }

            let targetWindow =
                preferredWindowId.flatMap { browserManager.windowRegistry?.windows[$0] }
                ?? self.preferredBrowserWindow(explicitWindowId: preferredWindowId)
                ?? browserManager.windowRegistry?.activeWindow

            guard let targetWindow else { return }

            NSApp.activate(ignoringOtherApps: true)
            targetWindow.window?.makeKeyAndOrderFront(nil)
            targetWindow.window?.orderFrontRegardless()
            browserManager.windowRegistry?.setActive(targetWindow)
            browserManager.restoreWebViewFocus(in: targetWindow)
        }
    }

    private func adoptIntoCurrentSpace(
        session: MiniWindowSession,
        preferredWindowId: UUID?,
        fallbackSpaceId: UUID?
    ) {
        guard let browserManager else { return }

        let targetSpace =
            resolvedCurrentSpace(
                preferredWindowId: preferredWindowId,
                fallbackSpaceId: fallbackSpaceId
            ) ?? browserManager.tabManager.spaces.first

        resolveTargetWindow(preferredWindowId: preferredWindowId) { [weak self] targetWindow in
            self?.open(session: session, in: targetSpace, targetWindow: targetWindow)
        }
    }

    private func adopt(
        session: MiniWindowSession,
        intoSpaceId spaceId: UUID,
        preferredWindowId: UUID?
    ) {
        guard let browserManager else { return }
        let targetSpace = browserManager.tabManager.spaces.first(where: { $0.id == spaceId })

        resolveTargetWindow(preferredWindowId: preferredWindowId) { [weak self] targetWindow in
            self?.open(session: session, in: targetSpace, targetWindow: targetWindow)
        }
    }

    private func open(
        session: MiniWindowSession,
        in targetSpace: Space?,
        targetWindow: BrowserWindowState?
    ) {
        guard let browserManager else { return }

        if let targetWindow, let targetSpace {
            browserManager.setActiveSpace(targetSpace, in: targetWindow)
            let newTab = browserManager.tabManager.createNewTab(
                url: session.currentURL.absoluteString,
                in: targetSpace
            )
            browserManager.selectTab(newTab, in: targetWindow)
            targetWindow.window?.makeKeyAndOrderFront(nil)
            targetWindow.window?.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
        } else if let targetWindow {
            _ = browserManager.createNewTab(in: targetWindow, url: session.currentURL.absoluteString)
            targetWindow.window?.makeKeyAndOrderFront(nil)
            targetWindow.window?.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
        } else {
            let newTab = browserManager.tabManager.createNewTab(
                url: session.currentURL.absoluteString,
                in: targetSpace
            )
            browserManager.tabManager.setActiveTab(newTab)
            NSApp.activate(ignoringOtherApps: true)
        }

        sessions[session.id]?.controller.close()
        sessions[session.id] = nil
    }
}

@MainActor
final class PopupWindowManager {
    private struct SessionEntry {
        let controller: PopupWindowController
        let tab: Tab
    }

    private weak var browserManager: BrowserManager?
    private var sessions: [UUID: SessionEntry] = [:]

    func attach(browserManager: BrowserManager) {
        self.browserManager = browserManager
    }

    func present(webView: WKWebView, tab: Tab, windowFeatures: WKWindowFeatures) {
        let size = preferredSize(from: windowFeatures)
        let controller = PopupWindowController(
            tab: tab,
            webView: webView,
            initialSize: size,
            onClose: { [weak self, weak tab] tabId in
                tab?.handlePopupWindowClosed()
                self?.sessions[tabId] = nil
            }
        )

        sessions[tab.id] = SessionEntry(controller: controller, tab: tab)
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func closePopup(for tabId: UUID) {
        guard let session = sessions[tabId] else { return }
        sessions[tabId] = nil
        session.controller.close()
    }
    private func preferredSize(from windowFeatures: WKWindowFeatures) -> NSSize {
        let defaultWidth: CGFloat = 520
        let defaultHeight: CGFloat = 720

        let width = max(420, CGFloat(windowFeatures.width?.doubleValue ?? defaultWidth))
        let height = max(520, CGFloat(windowFeatures.height?.doubleValue ?? defaultHeight))
        return NSSize(width: width, height: height)
    }
}

@MainActor
private final class PopupWindowController: NSWindowController, NSWindowDelegate {
    private let tab: Tab
    private let webView: WKWebView
    private let onClose: (UUID) -> Void
    private var titleObservation: NSKeyValueObservation?
    private var urlObservation: NSKeyValueObservation?
    private var titleUpdateCancellable: AnyCancellable?

    init(tab: Tab, webView: WKWebView, initialSize: NSSize, onClose: @escaping (UUID) -> Void) {
        self.tab = tab
        self.webView = webView
        self.onClose = onClose

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isReleasedWhenClosed = false
        window.center()

        let container = NSView(frame: NSRect(origin: .zero, size: initialSize))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        super.init(window: window)

        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
        window.contentView = container
        window.delegate = self
        updateWindowTitle()
        observePopupState()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        window?.makeFirstResponder(webView)
    }

    func windowWillClose(_ notification: Notification) {
        titleObservation?.invalidate()
        urlObservation?.invalidate()
        titleUpdateCancellable?.cancel()
        onClose(tab.id)
    }

    private func observePopupState() {
        titleObservation = webView.observe(\.title, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                self?.updateWindowTitle()
            }
        }

        urlObservation = webView.observe(\.url, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                self?.updateWindowTitle()
            }
        }

        titleUpdateCancellable = tab.objectWillChange.sink { [weak self] in
            Task { @MainActor in
                self?.updateWindowTitle()
            }
        }
    }

    private func updateWindowTitle() {
        let title = webView.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let title, !title.isEmpty {
            window?.title = title
            return
        }

        if let host = webView.url?.host, !host.isEmpty {
            window?.title = host
            return
        }

        window?.title = tab.name
    }
}

// MARK: - Mini Browser Window Controller

@MainActor
final class MiniBrowserWindowController: NSWindowController, NSWindowDelegate {
    private let session: MiniWindowSession
    private let adoptAction: () -> Void
    private let onClose: (MiniWindowSession) -> Void
    private let gradientColorManager: GradientColorManager
    private let requestedFrame: NSRect
    private var keyMonitor: Any?

    init(
        session: MiniWindowSession,
        adoptAction: @escaping () -> Void,
        onClose: @escaping (MiniWindowSession) -> Void,
        gradientColorManager: GradientColorManager,
        sourceWindowFrame: NSRect?
    ) {
        self.session = session
        self.adoptAction = adoptAction
        self.onClose = onClose
        self.gradientColorManager = gradientColorManager
        self.requestedFrame = sourceWindowFrame ?? NSRect(x: 0, y: 0, width: 1180, height: 820)

        let contentView = MiniBrowserWindowView(
            session: session,
            adoptAction: adoptAction,
            dismissAction: { [weak session] in
                guard let session else { return }
                onClose(session)
            }
        )
        .environmentObject(gradientColorManager)

        let hostingView = NSHostingView(rootView: contentView)
        hostingView.frame = NSRect(origin: .zero, size: requestedFrame.size)
        hostingView.autoresizingMask = [.width, .height]
        let window = NSWindow(
            contentRect: requestedFrame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 760, height: 560)
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.contentView = hostingView
        window.setFrame(requestedFrame, display: false)
        if sourceWindowFrame == nil {
            window.center()
        }

        super.init(window: window)

        window.delegate = self
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.setFrame(requestedFrame, display: false)
        window?.makeKeyAndOrderFront(sender)
        installKeyMonitorIfNeeded()
    }

    func windowWillClose(_ notification: Notification) {
        removeKeyMonitor()
        onClose(session)
    }

    private func installKeyMonitorIfNeeded() {
        guard keyMonitor == nil else { return }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  let window = self.window,
                  window.isKeyWindow else {
                return event
            }

            let modifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifierFlags.isEmpty,
                  let key = event.charactersIgnoringModifiers?.lowercased() else {
                return event
            }

            switch key {
            case "d":
                self.closeWindow()
                return nil
            case "o":
                adoptAction()
                return nil
            default:
                if event.keyCode == 2 {
                    self.closeWindow()
                    return nil
                }

                if event.keyCode == 31 {
                    adoptAction()
                    return nil
                }

                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    private func closeWindow() {
        guard let window else { return }
        window.close()
    }
}

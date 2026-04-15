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

@MainActor
final class MiniWindowSession: ObservableObject, Identifiable {
    let id = UUID()
    let profile: Profile?
    let originName: String
    private let targetSpaceResolver: () -> String
    private let adoptHandler: (MiniWindowSession) -> Void
    private let authCompletionHandler: ((Bool, URL?) -> Void)?

    @Published var currentURL: URL
    @Published var title: String
    @Published var isLoading: Bool = true
    @Published var estimatedProgress: Double = 0
    @Published var isAuthComplete: Bool = false
    @Published var authSuccess: Bool = false
    @Published var toolbarColor: NSColor?

    init(
        url: URL,
        profile: Profile?,
        originName: String,
        targetSpaceResolver: @escaping () -> String,
        adoptHandler: @escaping (MiniWindowSession) -> Void,
        authCompletionHandler: ((Bool, URL?) -> Void)? = nil
    ) {
        self.profile = profile
        self.originName = originName
        self.targetSpaceResolver = targetSpaceResolver
        self.adoptHandler = adoptHandler
        self.authCompletionHandler = authCompletionHandler
        self.currentURL = url
        self.title = url.absoluteString
    }

    var targetSpaceName: String { targetSpaceResolver() }

    func adopt() {
        adoptHandler(self)
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
        authCompletionHandler: ((Bool, URL?) -> Void)? = nil
    ) {
        guard let browserManager else { return }
        let resolvedProfile = profile ?? browserManager.currentProfile
        let session = MiniWindowSession(
            url: url,
            profile: resolvedProfile,
            originName: resolvedProfile?.name ?? "Default",
            targetSpaceResolver: { [weak browserManager] in
                // Try to get the current space, or fall back to the first available space
                if let currentSpace = browserManager?.tabManager.currentSpace {
                    return currentSpace.name
                } else if let firstSpace = browserManager?.tabManager.spaces.first {
                    return firstSpace.name
                } else {
                    return "Current Space"
                }
            },
            adoptHandler: { [weak self] session in
                self?.adopt(session: session)
            },
            authCompletionHandler: authCompletionHandler
        )

        let controller = MiniBrowserWindowController(
            session: session,
            adoptAction: { [weak session] in session?.adopt() },
            onClose: { [weak self] session in
                session.cancelAuthDueToClose()
                self?.sessions[session.id] = nil
            },
            gradientColorManager: browserManager.gradientColorManager
        )

        sessions[session.id] = SessionEntry(controller: controller)
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func adopt(session: MiniWindowSession) {
        guard let browserManager else { return }

        // Find the target space - try current space first, then fall back to space name matching
        let targetSpace = browserManager.tabManager.currentSpace ??
                         browserManager.tabManager.spaces.first { $0.name == session.targetSpaceName } ??
                         browserManager.tabManager.spaces.first

        let newTab = browserManager.tabManager.createNewTab(url: session.currentURL.absoluteString, in: targetSpace)
        browserManager.tabManager.setActiveTab(newTab)

        // If this is the first window opening, set this as the active space for the browser manager
        if browserManager.tabManager.currentSpace == nil, let space = targetSpace {
            browserManager.tabManager.setActiveSpace(space)
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

    init(session: MiniWindowSession, adoptAction: @escaping () -> Void, onClose: @escaping (MiniWindowSession) -> Void, gradientColorManager: GradientColorManager) {
        self.session = session
        self.adoptAction = adoptAction
        self.onClose = onClose
        self.gradientColorManager = gradientColorManager

        let contentView = MiniBrowserWindowView(
            session: session,
            adoptAction: adoptAction,
            dismissAction: { [weak session] in
                guard let session else { return }
                onClose(session)
            }
        )
        .environmentObject(gradientColorManager)

        let hostingController = NSHostingController(rootView: contentView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.center()
        window.contentViewController = hostingController

        super.init(window: window)

        window.delegate = self
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
    }

    func windowWillClose(_ notification: Notification) {
        onClose(session)
    }
}

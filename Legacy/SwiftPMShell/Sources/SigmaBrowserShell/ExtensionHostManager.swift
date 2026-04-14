import AppKit
import BrowserCore
import Foundation
import WebKit

@MainActor
final class ExtensionHostManager: NSObject {
    fileprivate let store: WorkspaceStore
    fileprivate let shellStore: BrowserShellStore
    fileprivate var observerToken: UUID?

    weak var windowController: MainWindowController?
    weak var pageRepository: BrowserPageRepository?
    private var runtimeBox: AnyObject?

    init(store: WorkspaceStore, shellStore: BrowserShellStore) {
        self.store = store
        self.shellStore = shellStore
        super.init()
        observerToken = shellStore.observe { [weak self] _ in
            self?.reloadEnabledExtensionsIfNeeded()
        }
    }

    func configure(_ configuration: WKWebViewConfiguration) {
        if #available(macOS 15.4, *) {
            configuration.webExtensionController = runtime().controller
        }
    }

    func importExtension(from resourceURL: URL) async {
        guard #available(macOS 15.4, *) else {
            let descriptor = ExtensionDescriptor(
                id: resourceURL.lastPathComponent,
                displayName: resourceURL.deletingPathExtension().lastPathComponent,
                version: "Unsupported on this macOS",
                resourceURLString: resourceURL.absoluteString,
                enabled: false,
                pinned: false,
                requestedPermissions: [],
                requestedMatches: [],
                lastError: "Web extension hosting requires macOS 15.4 or newer."
            )
            shellStore.upsertExtension(descriptor)
            return
        }

        do {
            let webExtension = try await WKWebExtension(resourceBaseURL: resourceURL)
            let descriptor = ExtensionDescriptor(
                id: webExtension.displayName ?? resourceURL.lastPathComponent,
                displayName: webExtension.displayName ?? resourceURL.deletingPathExtension().lastPathComponent,
                version: webExtension.version ?? "0",
                resourceURLString: resourceURL.absoluteString,
                enabled: true,
                pinned: false,
                requestedPermissions: webExtension.requestedPermissions.map(\.rawValue).sorted(),
                requestedMatches: webExtension.allRequestedMatchPatterns.map(\.string).sorted(),
                lastError: webExtension.errors.first?.localizedDescription
            )
            shellStore.upsertExtension(descriptor)
            await loadExtension(descriptor)
        } catch {
            let descriptor = ExtensionDescriptor(
                id: resourceURL.lastPathComponent,
                displayName: resourceURL.deletingPathExtension().lastPathComponent,
                version: "0",
                resourceURLString: resourceURL.absoluteString,
                enabled: false,
                pinned: false,
                requestedPermissions: [],
                requestedMatches: [],
                lastError: error.localizedDescription
            )
            shellStore.upsertExtension(descriptor)
        }
    }

    private func reloadEnabledExtensionsIfNeeded() {
        guard #available(macOS 15.4, *) else {
            return
        }
        let runtime = runtime()

        let enabledIDs = Set(shellStore.orderedExtensions().filter(\.enabled).map(\.id))
        for (id, context) in runtime.contextsByID where !enabledIDs.contains(id) {
            try? runtime.controller.unload(context)
            runtime.contextsByID[id] = nil
        }

        Task { @MainActor in
            for descriptor in shellStore.orderedExtensions() where descriptor.enabled && runtime.contextsByID[descriptor.id] == nil {
                await self.loadExtension(descriptor)
            }
        }
    }

    @available(macOS 15.4, *)
    private func loadExtension(_ descriptor: ExtensionDescriptor) async {
        let runtime = runtime()
        guard runtime.contextsByID[descriptor.id] == nil,
              let resourceURL = descriptor.resourceURL else {
            return
        }

        do {
            let webExtension = try await WKWebExtension(resourceBaseURL: resourceURL)
            let context = WKWebExtensionContext(for: webExtension)
            context.uniqueIdentifier = descriptor.id
            context.isInspectable = true
            try runtime.controller.load(context)
            runtime.contextsByID[descriptor.id] = context
        } catch {
            var failed = descriptor
            failed.enabled = false
            failed.lastError = error.localizedDescription
            shellStore.upsertExtension(failed)
        }
    }

    @available(macOS 15.4, *)
    fileprivate func currentWindowWrapper() -> ShellWebExtensionWindow {
        ShellWebExtensionWindow(manager: self)
    }

    @available(macOS 15.4, *)
    fileprivate func tabWrapper(for pageID: UUID) -> ShellWebExtensionTab {
        ShellWebExtensionTab(pageID: pageID, manager: self)
    }

    @available(macOS 15.4, *)
    fileprivate func allTabs() -> [ShellWebExtensionTab] {
        store.flattenedPages().map { tabWrapper(for: $0.id) }
    }

    @available(macOS 15.4, *)
    private func runtime() -> Runtime {
        if let runtime = runtimeBox as? Runtime {
            return runtime
        }
        let runtime = Runtime()
        runtime.controller.delegate = self
        runtimeBox = runtime
        return runtime
    }
}

@available(macOS 15.4, *)
@MainActor
private final class Runtime: NSObject {
    let controller: WKWebExtensionController
    var contextsByID: [String: WKWebExtensionContext] = [:]

    override init() {
        self.controller = WKWebExtensionController()
        super.init()
    }
}

@available(macOS 15.4, *)
extension ExtensionHostManager: WKWebExtensionControllerDelegate {
    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        [currentWindowWrapper()]
    }

    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        currentWindowWrapper()
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewTabUsing configuration: WKWebExtension.TabConfiguration,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void
    ) {
        let targetURL = configuration.url ?? URL(string: "https://www.apple.com")!
        let parentPageID = (configuration.parentTab as? ShellWebExtensionTab)?.pageID
        let newPageID: UUID?
        if let parentPageID {
            newPageID = store.openChildPage(from: parentPageID, url: targetURL, targetPane: .main)
        } else {
            newPageID = store.openPage(url: targetURL, targetPane: .main)
        }

        guard let pageID = newPageID else {
            completionHandler(nil, NSError(domain: "SigmaBrowserShell.Extensions", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create a page for the extension request."]))
            return
        }

        let tab = tabWrapper(for: pageID)
        controller.didOpenTab(tab)
        controller.didActivateTab(tab)
        completionHandler(tab, nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewWindowUsing configuration: WKWebExtension.WindowConfiguration,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionWindow)?, (any Error)?) -> Void
    ) {
        let urls = configuration.tabURLs.isEmpty ? [URL(string: "https://www.apple.com")!] : configuration.tabURLs
        for url in urls {
            _ = store.openPage(url: url, targetPane: .main)
        }
        completionHandler(currentWindowWrapper(), nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openOptionsPageFor extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        if let url = extensionContext.optionsPageURL {
            _ = store.openPage(url: url, targetPane: .main)
        }
        completionHandler(nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissions permissions: Set<WKWebExtension.Permission>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void
    ) {
        completionHandler(permissions, nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionToAccess urls: Set<URL>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<URL>, Date?) -> Void
    ) {
        completionHandler(urls, nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void
    ) {
        completionHandler(matchPatterns, nil)
    }
}

@available(macOS 15.4, *)
private final class ShellWebExtensionWindow: NSObject, WKWebExtensionWindow {
    weak var manager: ExtensionHostManager?

    init(manager: ExtensionHostManager) {
        self.manager = manager
    }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        manager?.allTabs() ?? []
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        guard let manager,
              let pageID = manager.store.selectedPageID(for: manager.store.paneState.focusedPane) else {
            return nil
        }
        return manager.tabWrapper(for: pageID)
    }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType {
        .normal
    }

    func isPrivate(for context: WKWebExtensionContext) -> Bool {
        manager?.store.activeWorkspace()?.profileMode == .isolated
    }

    func screenFrame(for context: WKWebExtensionContext) -> CGRect {
        manager?.windowController?.window?.screen?.visibleFrame ?? .null
    }

    func frame(for context: WKWebExtensionContext) -> CGRect {
        manager?.windowController?.window?.frame ?? .null
    }

    func focus(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        manager?.windowController?.showWindow(nil)
        completionHandler(nil)
    }
}

@available(macOS 15.4, *)
private final class ShellWebExtensionTab: NSObject, WKWebExtensionTab {
    let pageID: UUID
    weak var manager: ExtensionHostManager?

    init(pageID: UUID, manager: ExtensionHostManager) {
        self.pageID = pageID
        self.manager = manager
    }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        manager?.currentWindowWrapper()
    }

    func parentTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        guard let manager,
              let parentID = manager.store.page(for: pageID)?.parentID else {
            return nil
        }
        return manager.tabWrapper(for: parentID)
    }

    func webView(for context: WKWebExtensionContext) -> WKWebView? {
        manager?.pageRepository?.webView(for: pageID)
    }

    func title(for context: WKWebExtensionContext) -> String? {
        manager?.store.page(for: pageID)?.displayTitleOverride ?? manager?.store.page(for: pageID)?.title
    }

    func url(for context: WKWebExtensionContext) -> URL? {
        manager?.store.page(for: pageID)?.url
    }

    func isPinned(for context: WKWebExtensionContext) -> Bool {
        manager?.store.page(for: pageID)?.isPinned ?? false
    }

    func setPinned(_ pinned: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        manager?.store.setPagePinned(pageID, isPinned: pinned)
        completionHandler(nil)
    }

    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        manager?.store.selectPage(pageID)
        manager?.store.openURLInCurrentContext(url)
        completionHandler(nil)
    }

    func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        manager?.pageRepository?.webView(for: pageID)?.reload()
        completionHandler(nil)
    }

    func goBack(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        manager?.pageRepository?.webView(for: pageID)?.goBack()
        completionHandler(nil)
    }

    func goForward(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        manager?.pageRepository?.webView(for: pageID)?.goForward()
        completionHandler(nil)
    }

    func activate(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        manager?.store.selectPage(pageID)
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        manager?.store.closePage(pageID)
        completionHandler(nil)
    }
}

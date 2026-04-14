import AppKit
import BrowserCore
import WebKit

@MainActor
final class MainWindowController: NSWindowController {
    private let store: WorkspaceStore
    private let shellStore: BrowserShellStore
    private let sessionManager: BrowserSessionManager
    private let persistenceController: BrowserPersistenceController
    private let shellPersistenceController: BrowserShellPersistenceController
    private let downloadManager: DownloadManager
    private let extensionHostManager: ExtensionHostManager
    private let pageRepository: BrowserPageRepository
    private let shortcutRegistry: ShortcutRegistry

    private let rootSplitViewController = NSSplitViewController()
    private let sidebarViewController: SidebarViewController
    private let browserContentViewController: ContentSplitViewController
    private let addressBarView = AddressBarView(frame: .init(x: 0, y: 0, width: 760, height: 54))
    private let lazySearchController = LazySearchOverlayController()
    private let downloadsPopover = NSPopover()
    private let extensionsPopover = NSPopover()
    private lazy var keyboardRouter = KeyboardCommandRouter(
        store: store,
        shortcutRegistry: shortcutRegistry,
        handler: self,
        pageRepository: pageRepository
    )

    private var observerToken: UUID?
    private var shellObserverToken: UUID?
    private var settingsWindowController: SettingsWindowController?
    private var cheatSheetWindowController: CheatSheetWindowController?

    init(
        store: WorkspaceStore,
        shellStore: BrowserShellStore,
        sessionManager: BrowserSessionManager,
        persistenceController: BrowserPersistenceController,
        shellPersistenceController: BrowserShellPersistenceController
    ) {
        self.store = store
        self.shellStore = shellStore
        self.sessionManager = sessionManager
        self.persistenceController = persistenceController
        self.shellPersistenceController = shellPersistenceController
        self.downloadManager = DownloadManager(shellStore: shellStore)
        self.extensionHostManager = ExtensionHostManager(store: store, shellStore: shellStore)
        self.shortcutRegistry = ShortcutRegistry(shellStore: shellStore)
        self.pageRepository = BrowserPageRepository(
            store: store,
            shellStore: shellStore,
            sessionManager: sessionManager,
            downloadManager: downloadManager
        )
        self.sidebarViewController = SidebarViewController(store: store, shellStore: shellStore)
        self.browserContentViewController = ContentSplitViewController(store: store, pageRepository: pageRepository)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1500, height: 940),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Sigma Browser Shell"
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.titlebarAppearsTransparent = true
        super.init(window: window)

        extensionHostManager.windowController = self
        extensionHostManager.pageRepository = pageRepository
        sessionManager.configurationHandler = { [weak extensionHostManager] configuration in
            extensionHostManager?.configure(configuration)
        }

        configureWindow()
        configureAddressBar()
        configurePopovers()
        configureLauncher()
        wireCallbacks()
        observerToken = store.observe { [weak self] store in
            self?.handleStoreChange(store)
        }
        shellObserverToken = shellStore.observe { [weak self] shellStore in
            self?.handleShellStoreChange(shellStore)
        }
        keyboardRouter.install()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func presentMainWindow() {
        guard let window else {
            return
        }

        showWindow(nil)
        positionAndActivate(window)
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else {
                return
            }
            self.positionAndActivate(window)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self, weak window] in
            guard let self, let window else {
                return
            }
            self.positionAndActivate(window)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self, weak window] in
            guard let self, let window else {
                return
            }
            self.positionAndActivate(window)
        }
    }

    private func configureWindow() {
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarViewController)
        sidebarItem.minimumThickness = 300
        sidebarItem.maximumThickness = 420
        sidebarItem.canCollapse = true

        let contentItem = NSSplitViewItem(viewController: browserContentViewController)
        rootSplitViewController.addSplitViewItem(sidebarItem)
        rootSplitViewController.addSplitViewItem(contentItem)

        window?.contentViewController = rootSplitViewController
        window?.minSize = NSSize(width: 1200, height: 760)
        window?.backgroundColor = NSColor(calibratedWhite: 0.10, alpha: 1)
        window?.titlebarSeparatorStyle = .none
        window?.collectionBehavior = [.moveToActiveSpace, .canJoinAllSpaces, .fullScreenAuxiliary]

        let toolbar = NSToolbar(identifier: "MainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window?.toolbar = toolbar
    }

    private func placeWindowOnActiveScreen(_ window: NSWindow) {
        guard let screen = NSScreen.main ?? window.screen ?? NSScreen.screens.first else {
            return
        }

        let visibleFrame = screen.visibleFrame.insetBy(dx: 28, dy: 28)
        var frame = window.frame
        frame.size.width = min(frame.width, visibleFrame.width)
        frame.size.height = min(frame.height, visibleFrame.height)
        frame.origin.x = visibleFrame.minX + floor((visibleFrame.width - frame.width) / 2)
        frame.origin.y = visibleFrame.minY + floor((visibleFrame.height - frame.height) / 2)
        window.setFrame(frame, display: true)
    }

    private func positionAndActivate(_ window: NSWindow) {
        placeWindowOnActiveScreen(window)
        window.alphaValue = 1
        window.deminiaturize(nil)
        window.isReleasedWhenClosed = false
        window.setIsVisible(true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        window.collectionBehavior = [.moveToActiveSpace, .canJoinAllSpaces, .fullScreenAuxiliary]
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
    }

    private func configureAddressBar() {
        addressBarView.onOpenLauncher = { [weak self] in
            self?.presentLazySearch(targetMode: .main)
        }
        addressBarView.onSubmit = { [weak self] value in
            self?.openQuery(value, targetMode: .replaceCurrent)
        }
        addressBarView.onReloadOrStop = { [weak self] in
            guard let self else {
                return
            }
            let pageID = self.store.selectedPageID(for: self.store.paneState.focusedPane)
            let runtime = self.shellStore.pageRuntimeState(for: pageID)
            if runtime.isLoading {
                self.pageRepository.stopLoading(in: self.store.paneState.focusedPane)
            } else {
                self.pageRepository.reload(in: self.store.paneState.focusedPane)
            }
        }
    }

    private func configurePopovers() {
        downloadsPopover.behavior = .transient
        downloadsPopover.contentSize = NSSize(width: 420, height: 340)
        downloadsPopover.contentViewController = DownloadsViewController(
            shellStore: shellStore,
            downloadManager: downloadManager
        )

        extensionsPopover.behavior = .transient
        extensionsPopover.contentSize = NSSize(width: 440, height: 360)
        extensionsPopover.contentViewController = ExtensionsViewController(
            shellStore: shellStore,
            extensionHostManager: extensionHostManager
        )
    }

    private func configureLauncher() {
        lazySearchController.itemProvider = { [weak self] query, targetMode in
            guard let self else {
                return []
            }
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowercased = trimmed.lowercased()
            var items: [LazySearchItem] = []

            for page in self.store.flattenedPages()
            where trimmed.isEmpty
                || page.page.title.lowercased().contains(lowercased)
                || page.page.urlString.lowercased().contains(lowercased) {
                items.append(LazySearchItem(
                    title: page.page.displayTitleOverride ?? page.page.title,
                    subtitle: page.page.urlString
                ) { [weak self] in
                    self?.store.selectPage(page.id, in: targetMode == .split ? .split : nil)
                })
            }

            for workspace in self.store.orderedWorkspaces()
            where trimmed.isEmpty || workspace.title.lowercased().contains(lowercased) {
                items.append(LazySearchItem(
                    title: "Workspace: \(workspace.title)",
                    subtitle: workspace.kind.rawValue
                ) { [weak self] in
                    self?.store.selectWorkspace(workspace.id)
                })
            }

            let commandItems: [(String, String, ShortcutAction)] = [
                ("Open Downloads", "Tool", .showDownloads),
                ("Open Extensions", "Tool", .showExtensions),
                ("Open Settings", "Tool", .showSettings),
                ("Create Workspace", "Workspace", .createWorkspace),
                ("Show Reminders", "Tool", .showReminders),
                ("Show Cheat Sheet", "Tool", .showCheatSheet),
            ]

            for command in commandItems where trimmed.isEmpty || command.0.lowercased().contains(lowercased) {
                items.append(LazySearchItem(title: command.0, subtitle: command.1) { [weak self] in
                    self?.performShortcutAction(command.2)
                })
            }

            return items
        }

        lazySearchController.onRawQuery = { [weak self] query, targetMode in
            self?.openQuery(query, targetMode: targetMode)
        }
    }

    private func wireCallbacks() {
        sidebarViewController.onCreateWorkspace = { [weak self] in
            self?.promptForWorkspace()
        }
        sidebarViewController.onEditWorkspace = { [weak self] workspaceID in
            self?.promptToEditWorkspace(workspaceID: workspaceID)
        }
        sidebarViewController.onCreatePage = { [weak self] targetPane in
            self?.presentLazySearch(targetMode: targetPane == .split ? .split : .main)
        }
        sidebarViewController.onWorkspaceSelected = { [weak self] workspaceID in
            self?.store.selectWorkspace(workspaceID)
        }
        sidebarViewController.onPageSelected = { [weak self] pageID in
            self?.store.selectPage(pageID)
        }
    }

    private func handleStoreChange(_ store: WorkspaceStore) {
        pageRepository.reconcileLivePages()
        persistenceController.save(snapshot: store.snapshot())
        syncAddressField()
        updateWindowSubtitle()
    }

    private func handleShellStoreChange(_ shellStore: BrowserShellStore) {
        shellPersistenceController.save(snapshot: shellStore.snapshot())
        syncAddressField()
    }

    private func syncAddressField() {
        guard let pageID = store.selectedPageID(for: store.paneState.focusedPane),
              let page = store.page(for: pageID) else {
            addressBarView.setDisplayedValue("")
            addressBarView.setLoadingState(isLoading: false, progress: 0)
            return
        }

        addressBarView.setDisplayedValue(page.urlString)
        let runtime = shellStore.pageRuntimeState(for: pageID)
        addressBarView.setLoadingState(isLoading: runtime.isLoading, progress: runtime.estimatedProgress)
    }

    private func updateWindowSubtitle() {
        let activeWorkspace = store.activeWorkspace()?.title ?? "No Workspace"
        let mode = store.isInsertMode ? "Insert" : "Command"
        window?.subtitle = "\(activeWorkspace) · \(mode) Mode"
    }

    private func openQuery(_ value: String, targetMode: LauncherTargetMode) {
        guard let url = URLInputNormalizer.normalize(value) else {
            return
        }

        switch targetMode {
        case .main:
            _ = store.openPage(url: url, targetPane: .main)
        case .split:
            if let parent = store.selectedPageID(for: store.paneState.focusedPane) {
                _ = store.openChildPage(from: parent, url: url, targetPane: .split)
            } else {
                _ = store.openPage(url: url, targetPane: .split)
            }
        case .replaceCurrent:
            store.openURLInCurrentContext(url)
        }
    }

    private func presentLazySearch(targetMode: LauncherTargetMode) {
        guard let parentView = window?.contentViewController?.view else {
            return
        }
        lazySearchController.present(on: parentView, targetMode: targetMode)
    }

    private func promptForWorkspace() {
        let count = store.orderedWorkspaces().count
        let draft = WorkspaceEditorDraft(
            title: "Workspace \(count + 1)",
            iconGlyph: WorkspaceStore.suggestedWorkspaceIcon(orderIndex: count),
            profileMode: .shared,
            startURL: "https://www.apple.com"
        )

        PromptPresenter.presentWorkspaceEditor(
            title: "New Workspace",
            message: "Choose a name, icon, and browsing profile for this workspace.",
            draft: draft,
            includeStartURL: true,
            for: window
        ) { [weak self] result in
            guard let self else {
                return
            }

            let normalizedURL = URLInputNormalizer.normalize(result.startURL) ?? URL(string: "https://www.apple.com")!
            let trimmedTitle = result.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let workspaceTitle = trimmedTitle.isEmpty ? "Workspace \(self.store.orderedWorkspaces().count + 1)" : trimmedTitle
            _ = self.store.createWorkspace(
                title: workspaceTitle,
                iconGlyph: result.iconGlyph,
                profileMode: result.profileMode,
                initialURL: normalizedURL
            )
        }
    }

    private func promptToEditWorkspace(workspaceID: UUID) {
        guard let workspace = store.workspace(for: workspaceID) else {
            return
        }

        let draft = WorkspaceEditorDraft(
            title: workspace.title,
            iconGlyph: workspace.iconGlyph,
            profileMode: workspace.profileMode,
            startURL: ""
        )

        PromptPresenter.presentWorkspaceEditor(
            title: "Edit Workspace",
            message: "Update the workspace icon, title, and browsing profile.",
            draft: draft,
            includeStartURL: false,
            for: window
        ) { [weak self] result in
            guard let self else {
                return
            }

            let trimmedTitle = result.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let workspaceTitle = trimmedTitle.isEmpty ? workspace.title : trimmedTitle
            self.store.updateWorkspace(
                workspaceID,
                title: workspaceTitle,
                iconGlyph: result.iconGlyph,
                profileMode: result.profileMode
            )
        }
    }

    func showDownloadsPopover(_ sender: Any?) {
        guard let anchorView = toolbarView(for: ToolbarItemID.downloads) ?? window?.contentView else {
            return
        }
        let rect = NSRect(x: max(anchorView.bounds.width - 80, 0), y: anchorView.bounds.height - 6, width: 1, height: 1)
        downloadsPopover.show(relativeTo: rect, of: anchorView, preferredEdge: .maxY)
    }

    func showExtensionsPopover(_ sender: Any?) {
        guard let anchorView = toolbarView(for: ToolbarItemID.extensions) ?? window?.contentView else {
            return
        }
        let rect = NSRect(x: max(anchorView.bounds.width - 140, 0), y: anchorView.bounds.height - 6, width: 1, height: 1)
        extensionsPopover.show(relativeTo: rect, of: anchorView, preferredEdge: .maxY)
    }

    func showSettingsWindow() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(
                store: store,
                shellStore: shellStore,
                shortcutRegistry: shortcutRegistry,
                extensionHostManager: extensionHostManager
            )
        }
        settingsWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showCheatSheetWindow() {
        if cheatSheetWindowController == nil {
            cheatSheetWindowController = CheatSheetWindowController(shortcutRegistry: shortcutRegistry)
        }
        cheatSheetWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openQuickSearchWorkspace() {
        guard let quickSearchWorkspace = store.orderedWorkspaces().first(where: { $0.kind == .quickSearch }) else {
            return
        }
        store.selectWorkspace(quickSearchWorkspace.id)
        presentLazySearch(targetMode: .replaceCurrent)
    }

    private func openReminderPrompt() {
        PromptPresenter.presentSheet(
            title: "Create Reminder",
            message: "Add a short reminder to the workspace shell.",
            placeholder: "Follow up on this page",
            for: window
        ) { [weak self] value in
            guard let self else {
                return
            }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return
            }
            self.shellStore.addReminder(title: trimmed)
        }
    }

    private func showPasswordSurface() {
        let alert = NSAlert()
        alert.messageText = "Passwords"
        alert.informativeText = "Use the system password manager and AutoFill while the browser shell owns navigation, workspaces, and shortcuts."
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window!) { _ in }
    }

    private func showRemindersSurface() {
        let reminders = shellStore.snapshot().reminders
        let alert = NSAlert()
        alert.messageText = "Reminders"
        alert.informativeText = reminders.isEmpty
            ? "No reminders yet."
            : reminders.map { "\($0.isDone ? "✓" : "•") \($0.title)" }.joined(separator: "\n")
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window!) { _ in }
    }

    private func showFeedbackPrompt() {
        PromptPresenter.presentSheet(
            title: "Share Feedback",
            message: "Capture product feedback from the shell.",
            placeholder: "What should feel more like SigmaOS?",
            for: window
        ) { [weak self] value in
            guard let self else {
                return
            }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return
            }
            self.shellStore.addReminder(title: "Feedback: \(trimmed)")
        }
    }

    private func toolbarView(for identifier: NSToolbarItem.Identifier) -> NSView? {
        window?.toolbar?.items.first(where: { $0.itemIdentifier == identifier })?.view
    }

    @objc private func goBack(_ sender: Any?) {
        pageRepository.goBack(in: store.paneState.focusedPane)
    }

    @objc private func goForward(_ sender: Any?) {
        pageRepository.goForward(in: store.paneState.focusedPane)
    }

    @objc private func toggleSplit(_ sender: Any?) {
        store.toggleSplit()
    }

    @objc private func showDownloads(_ sender: Any?) {
        showDownloadsPopover(sender)
    }

    @objc private func showExtensions(_ sender: Any?) {
        showExtensionsPopover(sender)
    }

    @objc private func showSettings(_ sender: Any?) {
        showSettingsWindow()
    }

    @objc func openNewPageFromMenu(_ sender: Any?) {
        presentLazySearch(targetMode: .main)
    }

    @objc func openSettingsFromMenu(_ sender: Any?) {
        showSettingsWindow()
    }

    @objc func openDownloadsFromMenu(_ sender: Any?) {
        showDownloadsPopover(sender)
    }

    @objc func openExtensionsFromMenu(_ sender: Any?) {
        showExtensionsPopover(sender)
    }

    @objc func openCheatSheetFromMenu(_ sender: Any?) {
        showCheatSheetWindow()
    }
}

extension MainWindowController: ShortcutActionHandling {
    func performShortcutAction(_ action: ShortcutAction) {
        switch action {
        case .showCheatSheet:
            showCheatSheetWindow()
        case .showCommandLine, .openLazySearch, .openLazySearchSlash, .openLazySearchCommandT:
            presentLazySearch(targetMode: .main)
        case .openLazySearchInSplit:
            presentLazySearch(targetMode: .split)
        case .replaceCurrentPage:
            presentLazySearch(targetMode: .replaceCurrent)
        case .searchHistory:
            presentLazySearch(targetMode: .main)
        case .openQuickSearchWorkspace:
            openQuickSearchWorkspace()
        case .createWorkspace:
            promptForWorkspace()
        case .editWorkspace:
            if let workspaceID = store.activeWorkspaceID {
                promptToEditWorkspace(workspaceID: workspaceID)
            }
        case .deleteWorkspace:
            if let workspaceID = store.activeWorkspaceID, store.orderedWorkspaces().count > 1 {
                store.deleteWorkspace(workspaceID)
            }
        case .selectPreviousWorkspace:
            store.selectWorkspaceRelative(offset: -1)
        case .selectNextWorkspace:
            store.selectWorkspaceRelative(offset: 1)
        case .selectWorkspace1:
            store.selectWorkspace(at: 0)
        case .selectWorkspace2:
            store.selectWorkspace(at: 1)
        case .selectWorkspace3:
            store.selectWorkspace(at: 2)
        case .selectWorkspace4:
            store.selectWorkspace(at: 3)
        case .selectWorkspace5:
            store.selectWorkspace(at: 4)
        case .selectWorkspace6:
            store.selectWorkspace(at: 5)
        case .selectWorkspace7:
            store.selectWorkspace(at: 6)
        case .selectWorkspace8:
            store.selectWorkspace(at: 7)
        case .selectWorkspace9:
            store.selectWorkspace(at: 8)
        case .selectPreviousPage:
            store.selectRelativePage(offset: -1, in: store.paneState.focusedPane)
        case .selectNextPage:
            store.selectRelativePage(offset: 1, in: store.paneState.focusedPane)
        case .movePageUp:
            if let pageID = store.selectedPageID(for: store.paneState.focusedPane) {
                store.movePage(pageID, direction: .up)
            }
        case .movePageDown:
            if let pageID = store.selectedPageID(for: store.paneState.focusedPane) {
                store.movePage(pageID, direction: .down)
            }
        case .indentPage:
            if let pageID = store.selectedPageID(for: store.paneState.focusedPane) {
                store.indentPage(pageID)
            }
        case .outdentPage:
            if let pageID = store.selectedPageID(for: store.paneState.focusedPane) {
                store.outdentPage(pageID)
            }
        case .closePage:
            store.closeSelectedPage()
        case .togglePageDone:
            if let pageID = store.selectedPageID(for: store.paneState.focusedPane) {
                store.setPageLocked(pageID, isLocked: !(store.page(for: pageID)?.isLocked ?? false))
            }
        case .showMovePage:
            if let pageID = store.selectedPageID(for: store.paneState.focusedPane) {
                store.setPageDisplayTitle(pageID, displayTitle: store.page(for: pageID)?.title)
            }
        case .showSnoozePage:
            if let pageID = store.selectedPageID(for: store.paneState.focusedPane) {
                store.setPageSnoozed(pageID, isSnoozed: !(store.page(for: pageID)?.isSnoozed ?? false))
            }
        case .toggleFocusMode:
            if let sidebarItem = rootSplitViewController.splitViewItems.first {
                sidebarItem.animator().isCollapsed = !sidebarItem.isCollapsed
            }
        case .enterInsertMode:
            store.setInsertMode(true)
        case .exitInsertMode:
            store.setInsertMode(false)
        case .focusOtherPane:
            let nextPane: BrowserPaneFocus = store.paneState.focusedPane == .main && store.paneState.splitPageID != nil ? .split : .main
            store.focusPane(nextPane)
        case .goBack:
            pageRepository.goBack(in: store.paneState.focusedPane)
        case .goForward:
            pageRepository.goForward(in: store.paneState.focusedPane)
        case .toggleSplit:
            store.toggleSplit()
        case .openFocusedPageInSplit:
            store.openSelectedPageInSplit()
        case .closeSplit:
            store.closeSplit()
        case .selectPreviousSplitPage:
            store.selectRelativePage(offset: -1, in: .split)
        case .selectNextSplitPage:
            store.selectRelativePage(offset: 1, in: .split)
        case .closeSplitPage:
            store.closeSelectedPage(in: .split)
        case .moveSplitPage:
            if let pageID = store.selectedPageID(for: .split) {
                store.movePage(pageID, direction: .down)
            }
        case .snoozeSplitPage:
            if let pageID = store.selectedPageID(for: .split) {
                store.setPageSnoozed(pageID, isSnoozed: !(store.page(for: pageID)?.isSnoozed ?? false))
            }
        case .reloadSplitPage:
            pageRepository.reload(in: .split)
        case .showExtensions:
            showExtensionsPopover(nil)
        case .openPinnedExtensions:
            showExtensionsPopover(nil)
        case .showPasswords, .openPasswordSettings:
            showPasswordSurface()
        case .showReminders:
            showRemindersSurface()
        case .createReminder:
            openReminderPrompt()
        case .showDownloads:
            showDownloadsPopover(nil)
        case .showSettings:
            showSettingsWindow()
        case .showFeedback:
            showFeedbackPrompt()
        }
    }
}

extension MainWindowController: NSToolbarDelegate {
    fileprivate enum ToolbarItemID {
        static let back = NSToolbarItem.Identifier("toolbar.back")
        static let forward = NSToolbarItem.Identifier("toolbar.forward")
        static let address = NSToolbarItem.Identifier("toolbar.address")
        static let split = NSToolbarItem.Identifier("toolbar.split")
        static let downloads = NSToolbarItem.Identifier("toolbar.downloads")
        static let extensions = NSToolbarItem.Identifier("toolbar.extensions")
        static let settings = NSToolbarItem.Identifier("toolbar.settings")
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            ToolbarItemID.back,
            ToolbarItemID.forward,
            ToolbarItemID.address,
            ToolbarItemID.split,
            ToolbarItemID.downloads,
            ToolbarItemID.extensions,
            ToolbarItemID.settings,
            .flexibleSpace,
        ]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            ToolbarItemID.back,
            ToolbarItemID.forward,
            .flexibleSpace,
            ToolbarItemID.address,
            .flexibleSpace,
            ToolbarItemID.split,
            ToolbarItemID.extensions,
            ToolbarItemID.downloads,
            ToolbarItemID.settings,
        ]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case ToolbarItemID.back:
            return makeToolbarItem(itemIdentifier, symbolName: "chevron.left", label: "Back", action: #selector(goBack(_:)))
        case ToolbarItemID.forward:
            return makeToolbarItem(itemIdentifier, symbolName: "chevron.right", label: "Forward", action: #selector(goForward(_:)))
        case ToolbarItemID.split:
            return makeToolbarItem(itemIdentifier, symbolName: "rectangle.split.2x1", label: "Split", action: #selector(toggleSplit(_:)))
        case ToolbarItemID.downloads:
            return makeToolbarItem(itemIdentifier, symbolName: "arrow.down.circle", label: "Downloads", action: #selector(showDownloads(_:)))
        case ToolbarItemID.extensions:
            return makeToolbarItem(itemIdentifier, symbolName: "puzzlepiece.extension", label: "Extensions", action: #selector(showExtensions(_:)))
        case ToolbarItemID.settings:
            return makeToolbarItem(itemIdentifier, symbolName: "gearshape", label: "Settings", action: #selector(showSettings(_:)))
        case ToolbarItemID.address:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            if addressBarView.constraints.isEmpty {
                addressBarView.widthAnchor.constraint(greaterThanOrEqualToConstant: 560).isActive = true
                addressBarView.widthAnchor.constraint(lessThanOrEqualToConstant: 860).isActive = true
            }
            item.view = addressBarView
            return item
        default:
            return nil
        }
    }

    private func makeToolbarItem(
        _ identifier: NSToolbarItem.Identifier,
        symbolName: String,
        label: String,
        action: Selector
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.paletteLabel = label
        item.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: label)
        item.target = self
        item.action = action
        return item
    }
}

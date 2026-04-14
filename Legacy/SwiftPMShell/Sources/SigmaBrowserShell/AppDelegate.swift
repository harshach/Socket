import AppKit
import BrowserCore
import Carbon.HIToolbox

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: MainWindowController?
    private var persistenceController = BrowserPersistenceController()
    private var shellPersistenceController = BrowserShellPersistenceController()
    private var store: WorkspaceStore?
    private var shellStore: BrowserShellStore?
    private var sessionManager = BrowserSessionManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()

        let snapshot = persistenceController.load() ?? WorkspaceStore.defaultSnapshot()
        let store = WorkspaceStore(snapshot: snapshot)
        let shellSnapshot = shellPersistenceController.load() ?? ShellStateSnapshot.default()
        let shellStore = BrowserShellStore(snapshot: shellSnapshot)
        self.store = store
        self.shellStore = shellStore

        let windowController = MainWindowController(
            store: store,
            shellStore: shellStore,
            sessionManager: sessionManager,
            persistenceController: persistenceController,
            shellPersistenceController: shellPersistenceController
        )
        self.windowController = windowController
        windowController.presentMainWindow()
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleIncomingURL(event:replyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard let store, let shellStore else {
            return
        }
        persistenceController.save(snapshot: store.snapshot())
        shellPersistenceController.save(snapshot: shellStore.snapshot())
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        windowController?.presentMainWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        windowController?.presentMainWindow()
        return true
    }

    private func buildMainMenu() {
        let mainMenu = NSMenu()
        NSApp.mainMenu = mainMenu

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        let appName = ProcessInfo.processInfo.processName

        appMenu.addItem(withTitle: "About \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettingsFromMenu(_:)), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h").keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let browserMenuItem = NSMenuItem()
        mainMenu.addItem(browserMenuItem)
        let browserMenu = NSMenu(title: "Browser")
        browserMenuItem.submenu = browserMenu

        browserMenu.addItem(withTitle: "New Page", action: #selector(openNewPageFromMenu(_:)), keyEquivalent: "t").target = self
        browserMenu.addItem(withTitle: "Downloads", action: #selector(showDownloadsFromMenu(_:)), keyEquivalent: "D").target = self
        browserMenu.items.last?.keyEquivalentModifierMask = [.command, .shift]
        browserMenu.addItem(withTitle: "Extensions", action: #selector(showExtensionsFromMenu(_:)), keyEquivalent: "e").target = self
        browserMenu.items.last?.keyEquivalentModifierMask = [.command, .option]
        browserMenu.addItem(withTitle: "Cheat Sheet", action: #selector(showCheatSheetFromMenu(_:)), keyEquivalent: "C").target = self
        browserMenu.items.last?.keyEquivalentModifierMask = [.command, .shift]

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
    }

    @objc private func handleIncomingURL(event: NSAppleEventDescriptor, replyEvent: NSAppleEventDescriptor) {
        guard let rawURL = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URLInputNormalizer.normalize(rawURL),
              let store else {
            return
        }

        store.openURLInCurrentContext(url, targetPane: .main)
        windowController?.presentMainWindow()
    }

    @objc private func showSettingsFromMenu(_ sender: Any?) {
        windowController?.openSettingsFromMenu(sender)
    }

    @objc private func openNewPageFromMenu(_ sender: Any?) {
        windowController?.openNewPageFromMenu(sender)
    }

    @objc private func showDownloadsFromMenu(_ sender: Any?) {
        windowController?.openDownloadsFromMenu(sender)
    }

    @objc private func showExtensionsFromMenu(_ sender: Any?) {
        windowController?.openExtensionsFromMenu(sender)
    }

    @objc private func showCheatSheetFromMenu(_ sender: Any?) {
        windowController?.openCheatSheetFromMenu(sender)
    }
}

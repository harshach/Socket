import AppKit
import BrowserCore

@MainActor
final class KeyboardCommandRouter {
    private let store: WorkspaceStore
    private let shortcutRegistry: ShortcutRegistry
    private weak var handler: ShortcutActionHandling?
    private let pageRepository: BrowserPageRepository
    private var eventMonitor: Any?

    init(
        store: WorkspaceStore,
        shortcutRegistry: ShortcutRegistry,
        handler: ShortcutActionHandling,
        pageRepository: BrowserPageRepository
    ) {
        self.store = store
        self.shortcutRegistry = shortcutRegistry
        self.handler = handler
        self.pageRepository = pageRepository
    }

    func install() {
        guard eventMonitor == nil else {
            return
        }

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard NSApp.keyWindow?.isMainWindow == true else {
            return event
        }

        if shouldBypassShortcuts(for: event) {
            return event
        }

        let context = ShortcutContext(isInsertMode: store.isInsertMode)
        guard let action = shortcutRegistry.action(matching: event, context: context) else {
            return event
        }

        if action == .exitInsertMode {
            store.setInsertMode(false)
            return nil
        }

        handler?.performShortcutAction(action)
        return nil
    }

    private func shouldBypassShortcuts(for event: NSEvent) -> Bool {
        if store.isInsertMode {
            return false
        }

        guard let firstResponder = NSApp.keyWindow?.firstResponder else {
            return false
        }

        if firstResponder is NSTextView {
            return true
        }

        return false
    }
}

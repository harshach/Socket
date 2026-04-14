import AppKit
import BrowserCore
import WebKit

@MainActor
final class BrowserPageRepository {
    private let store: WorkspaceStore
    private let shellStore: BrowserShellStore
    private let sessionManager: BrowserSessionManager
    private let downloadManager: DownloadManager
    private let residency = PageResidencyController(maxLivePages: 8)
    private var controllersByPageID: [UUID: BrowserWebViewController] = [:]

    init(store: WorkspaceStore, shellStore: BrowserShellStore, sessionManager: BrowserSessionManager, downloadManager: DownloadManager) {
        self.store = store
        self.shellStore = shellStore
        self.sessionManager = sessionManager
        self.downloadManager = downloadManager
    }

    func controller(for pageID: UUID, pane: BrowserPaneFocus) -> BrowserWebViewController {
        if let existing = controllersByPageID[pageID] {
            existing.updatePane(pane)
            residency.touch(pageID)
            return existing
        }

        let controller = BrowserWebViewController(
            pageID: pageID,
            pane: pane,
            store: store,
            shellStore: shellStore,
            sessionManager: sessionManager,
            downloadManager: downloadManager
        )
        controllersByPageID[pageID] = controller
        residency.touch(pageID)
        reconcileLivePages()
        return controller
    }

    func reconcileLivePages() {
        residency.touch(store.paneState.mainPageID)
        residency.touch(store.paneState.splitPageID)
        let protectedIDs = Set([store.paneState.mainPageID, store.paneState.splitPageID].compactMap { $0 })
        let evicted = residency.reconcile(protectedIDs: protectedIDs)
        for pageID in evicted {
            guard let controller = controllersByPageID.removeValue(forKey: pageID) else {
                continue
            }
            controller.prepareForSuspension()
        }
    }

    func goBack(in pane: BrowserPaneFocus) {
        guard let pageID = store.selectedPageID(for: pane),
              let controller = controllersByPageID[pageID] else {
            return
        }
        controller.goBack()
    }

    func goForward(in pane: BrowserPaneFocus) {
        guard let pageID = store.selectedPageID(for: pane),
              let controller = controllersByPageID[pageID] else {
            return
        }
        controller.goForward()
    }

    func reload(in pane: BrowserPaneFocus) {
        guard let pageID = store.selectedPageID(for: pane),
              let controller = controllersByPageID[pageID] else {
            return
        }
        controller.webView?.reload()
    }

    func stopLoading(in pane: BrowserPaneFocus) {
        guard let pageID = store.selectedPageID(for: pane),
              let controller = controllersByPageID[pageID] else {
            return
        }
        controller.webView?.stopLoading()
    }

    func webView(for pageID: UUID) -> WKWebView? {
        controllersByPageID[pageID]?.webView
    }
}

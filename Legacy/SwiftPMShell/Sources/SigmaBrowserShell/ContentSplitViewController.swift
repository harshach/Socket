import AppKit
import BrowserCore

@MainActor
final class ContentSplitViewController: NSSplitViewController {
    private let store: WorkspaceStore
    private let pageRepository: BrowserPageRepository
    private let mainPaneViewController: BrowserPaneViewController
    private let splitPaneViewController: BrowserPaneViewController
    private var observerToken: UUID?

    init(store: WorkspaceStore, pageRepository: BrowserPageRepository) {
        self.store = store
        self.pageRepository = pageRepository
        self.mainPaneViewController = BrowserPaneViewController(pane: .main, store: store, pageRepository: pageRepository)
        self.splitPaneViewController = BrowserPaneViewController(pane: .split, store: store, pageRepository: pageRepository)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        let mainItem = NSSplitViewItem(viewController: mainPaneViewController)
        mainItem.minimumThickness = 500
        let splitItem = NSSplitViewItem(viewController: splitPaneViewController)
        splitItem.minimumThickness = 320

        addSplitViewItem(mainItem)
        addSplitViewItem(splitItem)
        observerToken = store.observe { [weak self] store in
            self?.updateLayout(with: store)
        }
    }

    private func updateLayout(with store: WorkspaceStore) {
        splitViewItems[safe: 1]?.isCollapsed = store.paneState.splitPageID == nil
        guard store.paneState.splitPageID != nil else {
            return
        }

        let totalWidth = splitView.bounds.width
        let splitWidth = max(320, totalWidth * CGFloat(store.paneState.splitProportion))
        let mainWidth = max(500, totalWidth - splitWidth)
        splitView.setPosition(mainWidth, ofDividerAt: 0)
    }

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        guard let splitItem = splitViewItems[safe: 1], !splitItem.isCollapsed else {
            return
        }
        let totalWidth = splitView.bounds.width
        guard totalWidth > 0 else {
            return
        }
        let splitWidth = splitItem.viewController.view.frame.width
        store.setSplitProportion(Double(splitWidth / totalWidth))
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

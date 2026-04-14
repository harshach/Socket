import AppKit
import BrowserCore

@MainActor
final class BrowserPaneViewController: NSViewController {
    private let pane: BrowserPaneFocus
    private let store: WorkspaceStore
    private let pageRepository: BrowserPageRepository

    private let contentContainerView = NSView()
    private let placeholderStack = NSStackView()
    private let placeholderTitle = NSTextField(labelWithString: "")
    private let placeholderSubtitle = NSTextField(labelWithString: "")

    private var currentPageID: UUID?
    private var currentChildController: NSViewController?
    private var observerToken: UUID?

    init(pane: BrowserPaneFocus, store: WorkspaceStore, pageRepository: BrowserPageRepository) {
        self.pane = pane
        self.store = store
        self.pageRepository = pageRepository
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1).cgColor

        contentContainerView.translatesAutoresizingMaskIntoConstraints = false
        contentContainerView.wantsLayer = true
        contentContainerView.layer?.cornerRadius = pane == .split ? 16 : 0
        contentContainerView.layer?.masksToBounds = true
        contentContainerView.layer?.backgroundColor = NSColor(calibratedWhite: 0.13, alpha: 1).cgColor
        contentContainerView.layer?.borderWidth = pane == .split ? 1 : 0
        contentContainerView.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
        view.addSubview(contentContainerView)

        placeholderStack.orientation = .vertical
        placeholderStack.spacing = 8
        placeholderStack.alignment = .centerX
        placeholderStack.translatesAutoresizingMaskIntoConstraints = false
        contentContainerView.addSubview(placeholderStack)

        placeholderTitle.font = .systemFont(ofSize: 26, weight: .bold)
        placeholderTitle.textColor = .white
        placeholderSubtitle.font = .systemFont(ofSize: 13, weight: .medium)
        placeholderSubtitle.textColor = NSColor.white.withAlphaComponent(0.45)
        placeholderStack.addArrangedSubview(placeholderTitle)
        placeholderStack.addArrangedSubview(placeholderSubtitle)

        NSLayoutConstraint.activate([
            contentContainerView.topAnchor.constraint(equalTo: view.topAnchor, constant: pane == .split ? 12 : 0),
            contentContainerView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: pane == .split ? 12 : 0),
            contentContainerView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: pane == .split ? -12 : 0),
            contentContainerView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: pane == .split ? -12 : 0),

            placeholderStack.centerXAnchor.constraint(equalTo: contentContainerView.centerXAnchor),
            placeholderStack.centerYAnchor.constraint(equalTo: contentContainerView.centerYAnchor),
        ])

        let clickGesture = NSClickGestureRecognizer(target: self, action: #selector(focusThisPane))
        view.addGestureRecognizer(clickGesture)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observerToken = store.observe { [weak self] store in
            self?.refresh(with: store)
        }
    }

    @objc private func focusThisPane() {
        store.focusPane(pane)
    }

    private func refresh(with store: WorkspaceStore) {
        let focused = store.paneState.focusedPane == pane
        contentContainerView.layer?.borderColor = focused
            ? NSColor.systemBlue.withAlphaComponent(0.45).cgColor
            : NSColor.white.withAlphaComponent(0.08).cgColor

        let pageID = store.selectedPageID(for: pane)
        guard let pageID, let _ = store.page(for: pageID) else {
            swapInPlaceholder()
            return
        }

        if currentPageID != pageID || currentChildController == nil {
            currentPageID = pageID
            let controller = pageRepository.controller(for: pageID, pane: pane)
            swapInChild(controller)
        }
    }

    private func swapInChild(_ childController: NSViewController) {
        currentChildController?.view.removeFromSuperview()
        currentChildController?.removeFromParent()

        addChild(childController)
        let childView = childController.view
        childView.translatesAutoresizingMaskIntoConstraints = false
        contentContainerView.addSubview(childView, positioned: .below, relativeTo: placeholderStack)
        NSLayoutConstraint.activate([
            childView.topAnchor.constraint(equalTo: contentContainerView.topAnchor),
            childView.leadingAnchor.constraint(equalTo: contentContainerView.leadingAnchor),
            childView.trailingAnchor.constraint(equalTo: contentContainerView.trailingAnchor),
            childView.bottomAnchor.constraint(equalTo: contentContainerView.bottomAnchor),
        ])

        contentContainerView.layer?.backgroundColor = NSColor.white.cgColor
        placeholderStack.isHidden = true
        currentChildController = childController
    }

    private func swapInPlaceholder() {
        currentChildController?.view.removeFromSuperview()
        currentChildController?.removeFromParent()
        currentChildController = nil
        currentPageID = nil
        contentContainerView.layer?.backgroundColor = NSColor(calibratedWhite: 0.13, alpha: 1).cgColor
        placeholderTitle.stringValue = pane == .main ? "Open a page" : "New Side Page"
        placeholderSubtitle.stringValue = pane == .main ? "Use Space, /, or Cmd+T to search and open." : "Use Shift+Space or the split button to open side-by-side."
        placeholderStack.isHidden = false
    }
}

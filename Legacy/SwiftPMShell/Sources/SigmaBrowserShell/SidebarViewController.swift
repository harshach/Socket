import AppKit
import BrowserCore

@MainActor
final class SidebarViewController: NSViewController {
    var onWorkspaceSelected: ((UUID) -> Void)?
    var onPageSelected: ((UUID) -> Void)?
    var onCreateWorkspace: (() -> Void)?
    var onEditWorkspace: ((UUID) -> Void)?
    var onCreatePage: ((BrowserPaneFocus) -> Void)?

    private let store: WorkspaceStore
    private let shellStore: BrowserShellStore
    private var observerToken: UUID?
    private var shellObserverToken: UUID?

    private let railContainer = NSView()
    private let detailContainer = NSView()
    private let workspaceButtonStack = NSStackView()
    private let pageStackView = NSStackView()
    private let pageScrollView = NSScrollView()
    private let pageStackHost = FlippedView()
    private let footerContainer = NSView()
    private let footerDivider = NSBox()
    private let newPageRow = NewPageRowView()
    private let footerHintLabel = NSTextField(labelWithString: "Preferences: Cmd+,")

    private let workspaceIconBadge = NSTextField(labelWithString: "🛝")
    private let workspaceTitleLabel = NSTextField(labelWithString: "Playground")
    private let workspaceMetaLabel = NSTextField(labelWithString: "Shared profile")
    private let pageSectionLabel = NSTextField(labelWithString: "Pages")
    private let statusLabel = NSTextField(labelWithString: "")
    private let addWorkspaceButton = WorkspaceRailButton(iconGlyph: "+", selected: false)
    private let editWorkspaceButton = NSButton()

    init(store: WorkspaceStore, shellStore: BrowserShellStore) {
        self.store = store
        self.shellStore = shellStore
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.sidebarBackground.cgColor

        railContainer.wantsLayer = true
        railContainer.layer?.backgroundColor = NSColor.sidebarRail.cgColor
        railContainer.translatesAutoresizingMaskIntoConstraints = false

        detailContainer.wantsLayer = true
        detailContainer.layer?.backgroundColor = NSColor.sidebarPanel.cgColor
        detailContainer.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(railContainer)
        view.addSubview(detailContainer)

        NSLayoutConstraint.activate([
            railContainer.topAnchor.constraint(equalTo: view.topAnchor),
            railContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            railContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            railContainer.widthAnchor.constraint(equalToConstant: 76),

            detailContainer.topAnchor.constraint(equalTo: view.topAnchor),
            detailContainer.leadingAnchor.constraint(equalTo: railContainer.trailingAnchor),
            detailContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            detailContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        buildRailUI()
        buildDetailUI()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observerToken = store.observe { [weak self] store in
            self?.refresh(with: store)
        }
        shellObserverToken = shellStore.observe { [weak self] _ in
            guard let self else {
                return
            }
            self.refresh(with: self.store)
        }
    }

    @objc private func createWorkspace() {
        onCreateWorkspace?()
    }

    @objc private func createPage() {
        onCreatePage?(.main)
    }

    @objc private func editActiveWorkspace() {
        guard let workspaceID = store.activeWorkspaceID else {
            return
        }
        onEditWorkspace?(workspaceID)
    }

    @objc private func selectWorkspaceFromButton(_ sender: WorkspaceRailButton) {
        guard let workspaceID = sender.workspaceID else {
            return
        }
        onWorkspaceSelected?(workspaceID)
    }

    private func buildRailUI() {
        workspaceButtonStack.orientation = .vertical
        workspaceButtonStack.alignment = .centerX
        workspaceButtonStack.spacing = 14
        workspaceButtonStack.translatesAutoresizingMaskIntoConstraints = false
        railContainer.addSubview(workspaceButtonStack)

        addWorkspaceButton.target = self
        addWorkspaceButton.action = #selector(createWorkspace)
        addWorkspaceButton.toolTip = "Create workspace"
        addWorkspaceButton.translatesAutoresizingMaskIntoConstraints = false
        railContainer.addSubview(addWorkspaceButton)

        NSLayoutConstraint.activate([
            workspaceButtonStack.topAnchor.constraint(equalTo: railContainer.topAnchor, constant: 24),
            workspaceButtonStack.centerXAnchor.constraint(equalTo: railContainer.centerXAnchor),
            workspaceButtonStack.leadingAnchor.constraint(equalTo: railContainer.leadingAnchor, constant: 8),
            workspaceButtonStack.trailingAnchor.constraint(equalTo: railContainer.trailingAnchor, constant: -8),

            addWorkspaceButton.bottomAnchor.constraint(equalTo: railContainer.bottomAnchor, constant: -22),
            addWorkspaceButton.centerXAnchor.constraint(equalTo: railContainer.centerXAnchor),
            addWorkspaceButton.widthAnchor.constraint(equalToConstant: 48),
            addWorkspaceButton.heightAnchor.constraint(equalToConstant: 48),
        ])
    }

    private func buildDetailUI() {
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.addSubview(header)

        let iconBubble = NSView()
        iconBubble.wantsLayer = true
        iconBubble.layer?.backgroundColor = NSColor.sidebarAccent.cgColor
        iconBubble.layer?.cornerRadius = 16
        iconBubble.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(iconBubble)

        workspaceIconBadge.font = .systemFont(ofSize: 30)
        workspaceIconBadge.translatesAutoresizingMaskIntoConstraints = false
        iconBubble.addSubview(workspaceIconBadge)

        workspaceTitleLabel.font = .systemFont(ofSize: 23, weight: .bold)
        workspaceTitleLabel.textColor = .white
        workspaceTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(workspaceTitleLabel)

        workspaceMetaLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        workspaceMetaLabel.textColor = NSColor.white.withAlphaComponent(0.58)
        workspaceMetaLabel.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(workspaceMetaLabel)

        editWorkspaceButton.bezelStyle = .texturedRounded
        editWorkspaceButton.isBordered = false
        editWorkspaceButton.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Edit workspace")
        editWorkspaceButton.contentTintColor = NSColor.white.withAlphaComponent(0.65)
        editWorkspaceButton.target = self
        editWorkspaceButton.action = #selector(editActiveWorkspace)
        editWorkspaceButton.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(editWorkspaceButton)

        pageSectionLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        pageSectionLabel.textColor = NSColor.white.withAlphaComponent(0.58)
        pageSectionLabel.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.addSubview(pageSectionLabel)

        pageStackView.orientation = .vertical
        pageStackView.alignment = .width
        pageStackView.spacing = 8
        pageStackView.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        pageStackView.translatesAutoresizingMaskIntoConstraints = false

        pageStackHost.translatesAutoresizingMaskIntoConstraints = false
        pageStackHost.addSubview(pageStackView)

        NSLayoutConstraint.activate([
            pageStackView.topAnchor.constraint(equalTo: pageStackHost.topAnchor),
            pageStackView.leadingAnchor.constraint(equalTo: pageStackHost.leadingAnchor),
            pageStackView.trailingAnchor.constraint(equalTo: pageStackHost.trailingAnchor),
            pageStackView.bottomAnchor.constraint(equalTo: pageStackHost.bottomAnchor),
            pageStackView.widthAnchor.constraint(equalTo: pageStackHost.widthAnchor),
            pageStackHost.widthAnchor.constraint(equalTo: pageScrollView.contentView.widthAnchor),
        ])

        pageScrollView.drawsBackground = false
        pageScrollView.hasVerticalScroller = true
        pageScrollView.autohidesScrollers = true
        pageScrollView.scrollerStyle = .overlay
        pageScrollView.documentView = pageStackHost
        pageScrollView.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.addSubview(pageScrollView)

        footerContainer.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.addSubview(footerContainer)

        footerDivider.boxType = .custom
        footerDivider.borderWidth = 0
        footerDivider.fillColor = NSColor.white.withAlphaComponent(0.08)
        footerDivider.translatesAutoresizingMaskIntoConstraints = false
        footerContainer.addSubview(footerDivider)

        newPageRow.onSelect = { [weak self] in
            self?.onCreatePage?(.main)
        }
        newPageRow.translatesAutoresizingMaskIntoConstraints = false
        footerContainer.addSubview(newPageRow)

        footerHintLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        footerHintLabel.textColor = NSColor.white.withAlphaComponent(0.34)
        footerHintLabel.translatesAutoresizingMaskIntoConstraints = false
        footerContainer.addSubview(footerHintLabel)

        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = NSColor.white.withAlphaComponent(0.42)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        footerContainer.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: detailContainer.topAnchor, constant: 24),
            header.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor, constant: 18),
            header.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor, constant: -18),

            iconBubble.topAnchor.constraint(equalTo: header.topAnchor),
            iconBubble.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            iconBubble.widthAnchor.constraint(equalToConstant: 58),
            iconBubble.heightAnchor.constraint(equalToConstant: 58),
            iconBubble.bottomAnchor.constraint(equalTo: header.bottomAnchor),

            workspaceIconBadge.centerXAnchor.constraint(equalTo: iconBubble.centerXAnchor),
            workspaceIconBadge.centerYAnchor.constraint(equalTo: iconBubble.centerYAnchor),

            workspaceTitleLabel.topAnchor.constraint(equalTo: iconBubble.topAnchor, constant: 6),
            workspaceTitleLabel.leadingAnchor.constraint(equalTo: iconBubble.trailingAnchor, constant: 14),
            workspaceTitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: editWorkspaceButton.leadingAnchor, constant: -8),

            workspaceMetaLabel.topAnchor.constraint(equalTo: workspaceTitleLabel.bottomAnchor, constant: 4),
            workspaceMetaLabel.leadingAnchor.constraint(equalTo: workspaceTitleLabel.leadingAnchor),
            workspaceMetaLabel.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor, constant: -18),

            editWorkspaceButton.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            editWorkspaceButton.centerYAnchor.constraint(equalTo: workspaceTitleLabel.centerYAnchor),
            editWorkspaceButton.widthAnchor.constraint(equalToConstant: 28),
            editWorkspaceButton.heightAnchor.constraint(equalToConstant: 28),

            pageSectionLabel.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 18),
            pageSectionLabel.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor, constant: 22),
            pageSectionLabel.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor, constant: -18),

            pageScrollView.topAnchor.constraint(equalTo: pageSectionLabel.bottomAnchor, constant: 12),
            pageScrollView.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor, constant: 14),
            pageScrollView.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor, constant: -12),
            pageScrollView.bottomAnchor.constraint(equalTo: footerContainer.topAnchor, constant: -10),

            footerContainer.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor, constant: 14),
            footerContainer.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor, constant: -14),
            footerContainer.bottomAnchor.constraint(equalTo: detailContainer.bottomAnchor, constant: -18),

            footerDivider.topAnchor.constraint(equalTo: footerContainer.topAnchor),
            footerDivider.leadingAnchor.constraint(equalTo: footerContainer.leadingAnchor, constant: 4),
            footerDivider.trailingAnchor.constraint(equalTo: footerContainer.trailingAnchor, constant: -4),
            footerDivider.heightAnchor.constraint(equalToConstant: 1),

            newPageRow.topAnchor.constraint(equalTo: footerDivider.bottomAnchor, constant: 10),
            newPageRow.leadingAnchor.constraint(equalTo: footerContainer.leadingAnchor),
            newPageRow.trailingAnchor.constraint(equalTo: footerContainer.trailingAnchor),

            footerHintLabel.topAnchor.constraint(equalTo: newPageRow.bottomAnchor, constant: 10),
            footerHintLabel.leadingAnchor.constraint(equalTo: footerContainer.leadingAnchor, constant: 6),
            footerHintLabel.trailingAnchor.constraint(equalTo: footerContainer.trailingAnchor, constant: -6),

            statusLabel.topAnchor.constraint(equalTo: footerHintLabel.bottomAnchor, constant: 4),
            statusLabel.leadingAnchor.constraint(equalTo: footerHintLabel.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: footerContainer.trailingAnchor, constant: -6),
            statusLabel.bottomAnchor.constraint(equalTo: footerContainer.bottomAnchor),
        ])
    }

    private func refresh(with store: WorkspaceStore) {
        refreshWorkspaceRail(with: store)
        refreshWorkspaceHeader(with: store)
        refreshPageRows(with: store)

        let mode = store.isInsertMode ? "Insert mode" : "Command mode"
        let profile = store.activeWorkspace()?.profileMode == .isolated ? "Isolated cookies" : "Shared cookies"
        let focus = store.paneState.focusedPane == .split ? "Split focused" : "Main focused"
        statusLabel.stringValue = "\(mode) · \(focus) · \(profile)"
    }

    private func refreshWorkspaceRail(with store: WorkspaceStore) {
        workspaceButtonStack.arrangedSubviews.forEach { subview in
            workspaceButtonStack.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }

        for workspace in store.orderedWorkspaces() {
            let button = WorkspaceRailButton(iconGlyph: workspace.iconGlyph, selected: workspace.id == store.activeWorkspaceID)
            button.workspaceID = workspace.id
            button.toolTip = workspace.title
            button.target = self
            button.action = #selector(selectWorkspaceFromButton(_:))
            workspaceButtonStack.addArrangedSubview(button)
            button.widthAnchor.constraint(equalToConstant: 48).isActive = true
            button.heightAnchor.constraint(equalToConstant: 48).isActive = true
        }
    }

    private func refreshWorkspaceHeader(with store: WorkspaceStore) {
        guard let workspace = store.activeWorkspace() else {
            workspaceIconBadge.stringValue = "🧩"
            workspaceTitleLabel.stringValue = "No Workspace"
            workspaceMetaLabel.stringValue = "Create a workspace to get started"
            editWorkspaceButton.isHidden = true
            return
        }

        workspaceIconBadge.stringValue = workspace.iconGlyph
        workspaceTitleLabel.stringValue = workspace.title
        workspaceTitleLabel.lineBreakMode = .byTruncatingTail
        let visibility = workspace.isSharedWorkspace ? "Shared" : "Personal"
        let profile = workspace.profileMode == .isolated ? "isolated" : "shared"
        let kindTitle: String
        switch workspace.kind {
        case .regular:
            kindTitle = "Regular"
        case .quickSearch:
            kindTitle = "Quick Search"
        case .sharedWithMe:
            kindTitle = "Shared with me"
        }
        workspaceMetaLabel.stringValue = "\(kindTitle) · \(visibility) · \(profile)"
        workspaceMetaLabel.lineBreakMode = .byTruncatingTail
        editWorkspaceButton.isHidden = false
    }

    private func refreshPageRows(with store: WorkspaceStore) {
        pageStackView.arrangedSubviews.forEach { subview in
            pageStackView.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }

        let flattenedPages = store.flattenedPages()
        if flattenedPages.isEmpty {
            let placeholder = NSTextField(labelWithString: "No pages in this workspace")
            placeholder.font = .systemFont(ofSize: 13, weight: .medium)
            placeholder.textColor = NSColor.white.withAlphaComponent(0.45)
            pageStackView.addView(placeholder, in: .top)
        } else {
            for flattened in flattenedPages {
                let isSelected = flattened.id == store.selectedPageID(for: store.paneState.focusedPane)
                let row = PageRowView(
                    page: flattened.page,
                    depth: flattened.depth,
                    isSelected: isSelected,
                    focusedPane: store.paneState.focusedPane,
                    favicon: shellStore.favicon(for: flattened.page.url)
                )
                row.onSelect = { [weak self] pageID in
                    self?.onPageSelected?(pageID)
                }
                pageStackView.addView(row, in: .top)
            }
        }

        pageStackHost.layoutSubtreeIfNeeded()
    }
}

private final class WorkspaceRailButton: NSButton {
    var workspaceID: UUID?

    init(iconGlyph: String, selected: Bool) {
        super.init(frame: .zero)
        wantsLayer = true
        isBordered = false
        bezelStyle = .regularSquare
        title = iconGlyph
        font = .systemFont(ofSize: 27)
        layer?.cornerRadius = 14
        layer?.backgroundColor = selected ? NSColor.sidebarAccent.cgColor : NSColor.clear.cgColor
        setButtonType(.momentaryChange)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class PageRowView: NSControl {
    var onSelect: ((UUID) -> Void)?
    private let pageID: UUID

    init(page: PageNode, depth: Int, isSelected: Bool, focusedPane: BrowserPaneFocus, favicon: FaviconRecord?) {
        self.pageID = page.id
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.backgroundColor = PageRowView.backgroundColor(isSelected: isSelected, focusedPane: focusedPane).cgColor
        translatesAutoresizingMaskIntoConstraints = false

        let container = NSStackView()
        container.orientation = .horizontal
        container.alignment = .centerY
        container.spacing = 10
        container.translatesAutoresizingMaskIntoConstraints = false
        addSubview(container)

        let indent = NSView()
        indent.translatesAutoresizingMaskIntoConstraints = false
        indent.widthAnchor.constraint(equalToConstant: CGFloat(depth * 16)).isActive = true
        container.addArrangedSubview(indent)

        if !page.childIDs.isEmpty {
            let disclosure = NSImageView()
            disclosure.image = NSImage(
                systemSymbolName: "chevron.down",
                accessibilityDescription: nil
            )?.withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
            disclosure.contentTintColor = NSColor.white.withAlphaComponent(0.38)
            disclosure.translatesAutoresizingMaskIntoConstraints = false
            disclosure.widthAnchor.constraint(equalToConstant: 10).isActive = true
            container.addArrangedSubview(disclosure)
        } else {
            let spacer = NSView()
            spacer.translatesAutoresizingMaskIntoConstraints = false
            spacer.widthAnchor.constraint(equalToConstant: 10).isActive = true
            container.addArrangedSubview(spacer)
        }

        container.addArrangedSubview(PageRowView.makeIconView(for: page, favicon: favicon))

        let labels = NSStackView()
        labels.orientation = .vertical
        labels.spacing = 1

        let titleLabel = NSTextField(labelWithString: page.displayTitleOverride ?? page.title)
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = isSelected ? .white : NSColor.white.withAlphaComponent(0.90)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1

        let subtitleLabel = NSTextField(labelWithString: page.url?.host(percentEncoded: false) ?? page.urlString)
        subtitleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        subtitleLabel.textColor = isSelected ? NSColor.white.withAlphaComponent(0.72) : NSColor.white.withAlphaComponent(0.38)
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.maximumNumberOfLines = 1

        labels.addArrangedSubview(titleLabel)
        labels.addArrangedSubview(subtitleLabel)
        container.addArrangedSubview(labels)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 52),
            container.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            container.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            container.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            container.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        onSelect?(pageID)
    }

    private static func backgroundColor(isSelected: Bool, focusedPane: BrowserPaneFocus) -> NSColor {
        guard isSelected else {
            return .clear
        }
        switch focusedPane {
        case .main:
            return .selectedPageBackground
        case .split:
            return .selectedSplitBackground
        }
    }

    private static func makeIconView(for page: PageNode, favicon: FaviconRecord?) -> NSView {
        if let favicon, let data = favicon.pngData, let image = NSImage(data: data) {
            let imageView = NSImageView()
            imageView.image = image
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.wantsLayer = true
            imageView.layer?.cornerRadius = 4
            imageView.layer?.masksToBounds = true
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.widthAnchor.constraint(equalToConstant: 18).isActive = true
            imageView.heightAnchor.constraint(equalToConstant: 18).isActive = true
            return imageView
        }

        let iconBubble = NSView()
        iconBubble.wantsLayer = true
        iconBubble.layer?.cornerRadius = 9
        iconBubble.layer?.backgroundColor = NSColor.pageIconBubble.cgColor
        iconBubble.translatesAutoresizingMaskIntoConstraints = false
        iconBubble.widthAnchor.constraint(equalToConstant: 18).isActive = true
        iconBubble.heightAnchor.constraint(equalToConstant: 18).isActive = true

        let iconLabel = NSTextField(labelWithString: favicon?.monogram ?? siteGlyph(for: page))
        iconLabel.font = .systemFont(ofSize: 10, weight: .bold)
        iconLabel.textColor = .white
        iconLabel.alignment = .center
        iconLabel.translatesAutoresizingMaskIntoConstraints = false
        iconBubble.addSubview(iconLabel)

        NSLayoutConstraint.activate([
            iconLabel.centerXAnchor.constraint(equalTo: iconBubble.centerXAnchor),
            iconLabel.centerYAnchor.constraint(equalTo: iconBubble.centerYAnchor),
        ])
        return iconBubble
    }

    private static func siteGlyph(for page: PageNode) -> String {
        guard let host = page.url?.host(percentEncoded: false)?.lowercased() else {
            return String(page.title.prefix(1)).uppercased()
        }
        return String(host.prefix(1)).uppercased()
    }
}

private final class NewPageRowView: NSControl {
    var onSelect: (() -> Void)?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.backgroundColor = NSColor.clear.cgColor
        translatesAutoresizingMaskIntoConstraints = false

        let icon = NSTextField(labelWithString: "+")
        icon.font = .systemFont(ofSize: 24, weight: .light)
        icon.textColor = NSColor.white.withAlphaComponent(0.42)
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)

        let label = NSTextField(labelWithString: "New Page")
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = NSColor.white.withAlphaComponent(0.42)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 40),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            icon.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 14),
            label.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        onSelect?()
    }
}

private extension NSColor {
    static let sidebarBackground = NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.11, alpha: 1)
    static let sidebarRail = NSColor(calibratedRed: 0.11, green: 0.09, blue: 0.08, alpha: 1)
    static let sidebarPanel = NSColor(calibratedRed: 0.14, green: 0.15, blue: 0.16, alpha: 1)
    static let sidebarAccent = NSColor(calibratedRed: 0.35, green: 0.21, blue: 0.16, alpha: 1)
    static let sidebarButton = NSColor(calibratedRed: 0.23, green: 0.24, blue: 0.26, alpha: 1)
    static let selectedPageBackground = NSColor(calibratedRed: 0.45, green: 0.29, blue: 0.22, alpha: 1)
    static let selectedSplitBackground = NSColor(calibratedRed: 0.18, green: 0.31, blue: 0.52, alpha: 1)
    static let pageIconBubble = NSColor(calibratedRed: 0.24, green: 0.25, blue: 0.28, alpha: 1)
}

private final class FlippedView: NSView {
    override var isFlipped: Bool {
        true
    }
}

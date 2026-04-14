import AppKit
import BrowserCore

@MainActor
final class SettingsWindowController: NSWindowController {
    init(
        store: WorkspaceStore,
        shellStore: BrowserShellStore,
        shortcutRegistry: ShortcutRegistry,
        extensionHostManager: ExtensionHostManager
    ) {
        let controller = BrowserSettingsTabViewController(
            store: store,
            shellStore: shellStore,
            shortcutRegistry: shortcutRegistry,
            extensionHostManager: extensionHostManager
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 640),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.contentViewController = controller
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

@MainActor
private final class BrowserSettingsTabViewController: NSTabViewController {
    init(
        store: WorkspaceStore,
        shellStore: BrowserShellStore,
        shortcutRegistry: ShortcutRegistry,
        extensionHostManager: ExtensionHostManager
    ) {
        super.init(nibName: nil, bundle: nil)

        addTabViewItem(makeItem("General", viewController: GeneralSettingsViewController(store: store)))
        addTabViewItem(makeItem("Workspaces", viewController: WorkspaceSettingsViewController(store: store)))
        addTabViewItem(makeItem("Downloads", viewController: DownloadSettingsViewController(shellStore: shellStore)))
        addTabViewItem(makeItem("Extensions", viewController: ExtensionsViewController(shellStore: shellStore, extensionHostManager: extensionHostManager)))
        addTabViewItem(makeItem("Shortcuts", viewController: ShortcutSettingsViewController(shortcutRegistry: shortcutRegistry, shellStore: shellStore)))
        tabStyle = .toolbar
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func makeItem(_ title: String, viewController: NSViewController) -> NSTabViewItem {
        let item = NSTabViewItem(viewController: viewController)
        item.label = title
        return item
    }
}

private final class GeneralSettingsViewController: NSViewController {
    private let store: WorkspaceStore

    init(store: WorkspaceStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 26, left: 26, bottom: 26, right: 26)

        let title = NSTextField(labelWithString: "Browser shell")
        title.font = .systemFont(ofSize: 24, weight: .bold)

        let subtitle = NSTextField(labelWithString: "Sigma-like AppKit shell on top of WKWebView. The sidebar is the only tab surface, command mode is the default, and split view lives in the top toolbar.")
        subtitle.lineBreakMode = .byWordWrapping
        subtitle.maximumNumberOfLines = 0

        let mode = NSTextField(labelWithString: store.isInsertMode ? "Current mode: Insert" : "Current mode: Command")
        let split = NSTextField(labelWithString: store.paneState.splitPageID == nil ? "Split: Hidden" : "Split: Visible")

        stack.addArrangedSubview(title)
        stack.addArrangedSubview(subtitle)
        stack.addArrangedSubview(mode)
        stack.addArrangedSubview(split)
        view = stack
    }
}

private final class WorkspaceSettingsViewController: NSViewController {
    private let store: WorkspaceStore
    private let stack = NSStackView()
    private var observerToken: UUID?

    init(store: WorkspaceStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        stack.orientation = .vertical
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        view = stack
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observerToken = store.observe { [weak self] _ in
            self?.refresh()
        }
    }

    private func refresh() {
        stack.arrangedSubviews.forEach { subview in
            stack.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }

        for workspace in store.orderedWorkspaces() {
            let label = NSTextField(labelWithString: "\(workspace.iconGlyph)  \(workspace.title) · \(workspace.kind.rawValue) · \(workspace.profileMode.rawValue)")
            label.font = .systemFont(ofSize: 13, weight: .medium)
            stack.addArrangedSubview(label)
        }
    }
}

private final class DownloadSettingsViewController: NSViewController {
    private let shellStore: BrowserShellStore
    private let pathLabel = NSTextField(labelWithString: "")
    private let clearPopup = NSPopUpButton()
    private let safeFilesButton = NSButton(checkboxWithTitle: "Open “safe” files after downloading", target: nil, action: nil)
    private var observerToken: UUID?

    init(shellStore: BrowserShellStore) {
        self.shellStore = shellStore
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)

        let chooseButton = NSButton(title: "Choose download folder…", target: self, action: #selector(chooseFolder))
        chooseButton.bezelStyle = .rounded

        clearPopup.addItems(withTitles: DownloadClearPolicy.allCases.map(\.displayTitle))
        clearPopup.target = self
        clearPopup.action = #selector(changeClearPolicy)

        safeFilesButton.target = self
        safeFilesButton.action = #selector(toggleSafeFiles)

        stack.addArrangedSubview(NSTextField(labelWithString: "Download location"))
        stack.addArrangedSubview(pathLabel)
        stack.addArrangedSubview(chooseButton)
        stack.addArrangedSubview(NSTextField(labelWithString: "Remove download list items"))
        stack.addArrangedSubview(clearPopup)
        stack.addArrangedSubview(safeFilesButton)
        view = stack
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observerToken = shellStore.observe { [weak self] _ in
            self?.refresh()
        }
    }

    private func refresh() {
        pathLabel.stringValue = shellStore.settings.downloadDirectoryPath
        if let index = DownloadClearPolicy.allCases.firstIndex(of: shellStore.settings.downloadClearPolicy) {
            clearPopup.selectItem(at: index)
        }
        safeFilesButton.state = shellStore.settings.openSafeFilesAutomatically ? .on : .off
    }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        shellStore.setDownloadDirectoryPath(url.path)
    }

    @objc private func changeClearPolicy() {
        let selected = DownloadClearPolicy.allCases[max(0, clearPopup.indexOfSelectedItem)]
        shellStore.setDownloadClearPolicy(selected)
    }

    @objc private func toggleSafeFiles() {
        shellStore.setOpenSafeFilesAutomatically(safeFilesButton.state == .on)
    }
}

private final class ShortcutSettingsViewController: NSViewController {
    private let shortcutRegistry: ShortcutRegistry
    private let shellStore: BrowserShellStore
    private let stackView = NSStackView()
    private var observerToken: UUID?

    init(shortcutRegistry: ShortcutRegistry, shellStore: BrowserShellStore) {
        self.shortcutRegistry = shortcutRegistry
        self.shellStore = shellStore
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView()
        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(buttonRow)

        let importButton = NSButton(title: "Import…", target: self, action: #selector(importOverrides))
        let exportButton = NSButton(title: "Export…", target: self, action: #selector(exportOverrides))
        let resetButton = NSButton(title: "Reset defaults", target: self, action: #selector(resetOverrides))
        buttonRow.addArrangedSubview(importButton)
        buttonRow.addArrangedSubview(exportButton)
        buttonRow.addArrangedSubview(resetButton)

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scrollView)

        stackView.orientation = .vertical
        stackView.spacing = 8
        stackView.translatesAutoresizingMaskIntoConstraints = false
        let documentView = NSView()
        documentView.addSubview(stackView)
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView

        NSLayoutConstraint.activate([
            buttonRow.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            buttonRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),

            scrollView.topAnchor.constraint(equalTo: buttonRow.bottomAnchor, constant: 14),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            stackView.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 14),
            stackView.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 18),
            stackView.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -18),
            stackView.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -18),
            stackView.widthAnchor.constraint(equalTo: documentView.widthAnchor, constant: -36),
        ])

        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observerToken = shellStore.observe { [weak self] _ in
            self?.refresh()
        }
    }

    private func refresh() {
        stackView.arrangedSubviews.forEach { subview in
            stackView.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }

        for definition in shortcutRegistry.definitions() {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 10

            let title = NSTextField(labelWithString: "\(definition.category) · \(definition.title)")
            title.font = .systemFont(ofSize: 12, weight: .medium)
            title.setContentHuggingPriority(.defaultLow, for: .horizontal)

            let field = NSTextField(string: shortcutRegistry.bindingString(for: definition.action))
            field.placeholderString = definition.defaultBinding
            field.target = self
            field.action = #selector(updateShortcut(_:))
            field.identifier = NSUserInterfaceItemIdentifier(definition.action.rawValue)
            field.widthAnchor.constraint(equalToConstant: 140).isActive = true

            row.addArrangedSubview(title)
            row.addArrangedSubview(field)
            stackView.addArrangedSubview(row)
        }
    }

    @objc private func updateShortcut(_ sender: NSTextField) {
        guard let actionID = sender.identifier?.rawValue,
              let action = ShortcutAction(rawValue: actionID) else {
            return
        }
        shortcutRegistry.setOverride(sender.stringValue, for: action)
    }

    @objc private func importOverrides() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        try? shortcutRegistry.importOverrides(from: url)
    }

    @objc private func exportOverrides() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "sigma-shortcuts.json"
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        try? shortcutRegistry.exportOverrides(to: url)
    }

    @objc private func resetOverrides() {
        shortcutRegistry.resetOverrides()
    }
}

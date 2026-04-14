import AppKit

@MainActor
final class ExtensionsViewController: NSViewController {
    private let shellStore: BrowserShellStore
    private let extensionHostManager: ExtensionHostManager
    private let stackView = NSStackView()
    private var observerToken: UUID?

    init(shellStore: BrowserShellStore, extensionHostManager: ExtensionHostManager) {
        self.shellStore = shellStore
        self.extensionHostManager = extensionHostManager
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1).cgColor

        let importButton = NSButton(title: "Import Web Extension", target: self, action: #selector(importExtension))
        importButton.bezelStyle = .rounded
        importButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(importButton)

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        stackView.orientation = .vertical
        stackView.spacing = 10
        stackView.translatesAutoresizingMaskIntoConstraints = false

        let documentView = NSView()
        documentView.addSubview(stackView)
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView

        NSLayoutConstraint.activate([
            importButton.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),
            importButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),

            scrollView.topAnchor.constraint(equalTo: importButton.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            stackView.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 14),
            stackView.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 14),
            stackView.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -14),
            stackView.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -14),
            stackView.widthAnchor.constraint(equalTo: documentView.widthAnchor, constant: -28),
        ])
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

        let descriptors = shellStore.orderedExtensions()
        if descriptors.isEmpty {
            let label = NSTextField(labelWithString: "No extensions imported")
            label.font = .systemFont(ofSize: 14, weight: .medium)
            label.textColor = NSColor.white.withAlphaComponent(0.65)
            stackView.addArrangedSubview(label)
            return
        }

        for descriptor in descriptors {
            stackView.addArrangedSubview(ExtensionRowView(
                descriptor: descriptor,
                enabledHandler: { [weak self] enabled in
                    self?.shellStore.setExtensionEnabled(descriptor.id, enabled: enabled)
                },
                pinHandler: { [weak self] pinned in
                    self?.shellStore.setExtensionPinned(descriptor.id, pinned: pinned)
                },
                removeHandler: { [weak self] in
                    self?.shellStore.removeExtension(descriptor.id)
                }
            ))
        }
    }

    @objc private func importExtension() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = []
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        Task { @MainActor in
            await extensionHostManager.importExtension(from: url)
        }
    }
}

private final class ExtensionRowView: NSView {
    private let enabledHandler: (Bool) -> Void
    private let pinHandler: (Bool) -> Void
    private let removeHandler: () -> Void

    init(
        descriptor: ExtensionDescriptor,
        enabledHandler: @escaping (Bool) -> Void,
        pinHandler: @escaping (Bool) -> Void,
        removeHandler: @escaping () -> Void
    ) {
        self.enabledHandler = enabledHandler
        self.pinHandler = pinHandler
        self.removeHandler = removeHandler
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.04).cgColor

        let title = NSTextField(labelWithString: descriptor.displayName)
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.textColor = .white
        title.translatesAutoresizingMaskIntoConstraints = false
        addSubview(title)

        let subtitleText = descriptor.lastError ?? "v\(descriptor.version)"
        let subtitle = NSTextField(labelWithString: subtitleText)
        subtitle.font = .systemFont(ofSize: 11, weight: .medium)
        subtitle.textColor = descriptor.lastError == nil ? NSColor.white.withAlphaComponent(0.55) : .systemRed
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        addSubview(subtitle)

        let enabledButton = NSButton(checkboxWithTitle: "Enabled", target: self, action: #selector(toggleEnabled(_:)))
        enabledButton.state = descriptor.enabled ? .on : .off
        enabledButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(enabledButton)

        let pinButton = NSButton(checkboxWithTitle: "Pinned", target: self, action: #selector(togglePinned(_:)))
        pinButton.state = descriptor.pinned ? .on : .off
        pinButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pinButton)

        let removeButton = NSButton(title: "Remove", target: self, action: #selector(removeExtension))
        removeButton.isBordered = false
        removeButton.contentTintColor = .secondaryLabelColor
        removeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(removeButton)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 94),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),

            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: title.trailingAnchor),

            enabledButton.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            enabledButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),

            pinButton.leadingAnchor.constraint(equalTo: enabledButton.trailingAnchor, constant: 18),
            pinButton.centerYAnchor.constraint(equalTo: enabledButton.centerYAnchor),

            removeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            removeButton.centerYAnchor.constraint(equalTo: enabledButton.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func toggleEnabled(_ sender: NSButton) {
        enabledHandler(sender.state == .on)
    }

    @objc private func togglePinned(_ sender: NSButton) {
        pinHandler(sender.state == .on)
    }

    @objc private func removeExtension() {
        removeHandler()
    }
}

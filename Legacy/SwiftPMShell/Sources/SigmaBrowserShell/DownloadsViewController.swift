import AppKit

@MainActor
final class DownloadsViewController: NSViewController {
    private let shellStore: BrowserShellStore
    private let downloadManager: DownloadManager
    private let stackView = NSStackView()
    private var observerToken: UUID?

    init(shellStore: BrowserShellStore, downloadManager: DownloadManager) {
        self.shellStore = shellStore
        self.downloadManager = downloadManager
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

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        stackView.orientation = .vertical
        stackView.spacing = 10
        stackView.translatesAutoresizingMaskIntoConstraints = false

        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stackView)
        scrollView.documentView = documentView

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
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

        let items = shellStore.orderedDownloads()
        if items.isEmpty {
            let label = NSTextField(labelWithString: "No downloads yet")
            label.font = .systemFont(ofSize: 14, weight: .medium)
            label.textColor = NSColor.white.withAlphaComponent(0.65)
            stackView.addArrangedSubview(label)
            return
        }

        for item in items {
            stackView.addArrangedSubview(DownloadRowView(item: item, revealHandler: { [weak self] in
                self?.downloadManager.revealDownload(item.id)
            }, removeHandler: { [weak self] in
                self?.shellStore.removeDownload(item.id)
            }))
        }
    }
}

private final class DownloadRowView: NSView {
    private let revealHandler: () -> Void
    private let removeHandler: () -> Void

    init(item: DownloadItem, revealHandler: @escaping () -> Void, removeHandler: @escaping () -> Void) {
        self.revealHandler = revealHandler
        self.removeHandler = removeHandler
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.04).cgColor

        let titleLabel = NSTextField(labelWithString: item.suggestedFilename)
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let subtitle = item.destinationPath ?? item.sourceURLString
        let subtitleLabel = NSTextField(labelWithString: subtitle)
        subtitleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        subtitleLabel.textColor = NSColor.white.withAlphaComponent(0.55)
        subtitleLabel.lineBreakMode = .byTruncatingMiddle
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        let progress = NSProgressIndicator()
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.doubleValue = item.progress
        progress.translatesAutoresizingMaskIntoConstraints = false

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        if item.state == .finished {
            let revealButton = NSButton(title: "Reveal", target: self, action: #selector(reveal))
            revealButton.isBordered = false
            revealButton.contentTintColor = .white
            buttonRow.addArrangedSubview(revealButton)
        }

        let removeButton = NSButton(title: "Remove", target: self, action: #selector(removeDownload))
        removeButton.isBordered = false
        removeButton.contentTintColor = .secondaryLabelColor
        buttonRow.addArrangedSubview(removeButton)

        addSubview(titleLabel)
        addSubview(subtitleLabel)
        addSubview(progress)
        addSubview(buttonRow)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 88),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            progress.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 10),
            progress.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            buttonRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            buttonRow.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func reveal() {
        revealHandler()
    }

    @objc private func removeDownload() {
        removeHandler()
    }
}

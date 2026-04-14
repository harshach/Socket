import AppKit

enum LauncherTargetMode {
    case main
    case split
    case replaceCurrent
}

final class LazySearchItem: NSObject {
    let title: String
    let subtitle: String
    let action: @MainActor () -> Void

    init(title: String, subtitle: String, action: @escaping @MainActor () -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.action = action
    }
}

@MainActor
final class LazySearchOverlayController: NSViewController, NSSearchFieldDelegate {
    var itemProvider: ((String, LauncherTargetMode) -> [LazySearchItem])?
    var onRawQuery: ((String, LauncherTargetMode) -> Void)?

    private let dimView = NSVisualEffectView()
    private let cardView = NSVisualEffectView()
    private let field = NSSearchField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()

    private var items: [LazySearchItem] = []
    private var targetMode: LauncherTargetMode = .main

    override func loadView() {
        view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isHidden = true

        dimView.material = .underWindowBackground
        dimView.blendingMode = .behindWindow
        dimView.state = .active
        dimView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(dimView)

        cardView.material = .hudWindow
        cardView.state = .active
        cardView.wantsLayer = true
        cardView.layer?.cornerRadius = 24
        cardView.layer?.borderWidth = 1
        cardView.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
        cardView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(cardView)

        field.placeholderString = "Find anything"
        field.font = .systemFont(ofSize: 18, weight: .semibold)
        field.focusRingType = .none
        field.delegate = self
        field.target = self
        field.action = #selector(activateFromField)
        field.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(field)

        let titleColumn = NSTableColumn(identifier: .init("title"))
        titleColumn.resizingMask = .autoresizingMask
        tableView.addTableColumn(titleColumn)
        tableView.headerView = nil
        tableView.rowHeight = 46
        tableView.backgroundColor = .clear
        tableView.intercellSpacing = NSSize(width: 0, height: 6)
        tableView.selectionHighlightStyle = .regular
        tableView.delegate = self
        tableView.dataSource = self

        scrollView.drawsBackground = false
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(scrollView)

        NSLayoutConstraint.activate([
            dimView.topAnchor.constraint(equalTo: view.topAnchor),
            dimView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dimView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dimView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            cardView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            cardView.topAnchor.constraint(equalTo: view.topAnchor, constant: 86),
            cardView.widthAnchor.constraint(equalToConstant: 720),
            cardView.heightAnchor.constraint(equalToConstant: 420),

            field.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 22),
            field.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 22),
            field.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -22),

            scrollView.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 18),
            scrollView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 18),
            scrollView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -18),
            scrollView.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -18),
        ])
    }

    func present(on parentView: NSView, targetMode: LauncherTargetMode, seedQuery: String = "") {
        if view.superview == nil {
            parentView.addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: parentView.topAnchor),
                view.leadingAnchor.constraint(equalTo: parentView.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: parentView.trailingAnchor),
                view.bottomAnchor.constraint(equalTo: parentView.bottomAnchor),
            ])
        }

        self.targetMode = targetMode
        view.isHidden = false
        field.stringValue = seedQuery
        reloadItems()
        parentView.window?.makeFirstResponder(field)
    }

    func dismiss() {
        view.isHidden = true
    }

    @objc private func textChanged() {
        reloadItems()
    }

    func controlTextDidChange(_ obj: Notification) {
        reloadItems()
    }

    private func reloadItems() {
        items = itemProvider?(field.stringValue, targetMode) ?? []
        tableView.reloadData()
        if !items.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    private func activateSelection() {
        if tableView.selectedRow >= 0, tableView.selectedRow < items.count {
            items[tableView.selectedRow].action()
        } else {
            onRawQuery?(field.stringValue, targetMode)
        }
        dismiss()
    }

    @objc private func activateFromField() {
        activateSelection()
    }
}

extension LazySearchOverlayController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("lazySearchCell")
        let view = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? NSTableCellView()
        view.identifier = identifier

        view.subviews.forEach { $0.removeFromSuperview() }

        let titleLabel = NSTextField(labelWithString: items[row].title)
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let subtitleLabel = NSTextField(labelWithString: items[row].subtitle)
        subtitleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        subtitleLabel.textColor = NSColor.white.withAlphaComponent(0.55)
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(titleLabel)
        view.addSubview(subtitleLabel)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            titleLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
        ])
        return view
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        // no-op
    }

    func tableView(_ tableView: NSTableView, didDoubleClickRow row: Int) {
        activateSelection()
    }

    override func cancelOperation(_ sender: Any?) {
        dismiss()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 {
            activateSelection()
            return
        }
        if event.keyCode == 53 {
            dismiss()
            return
        }
        super.keyDown(with: event)
    }
}

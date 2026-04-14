import AppKit

@MainActor
final class CheatSheetWindowController: NSWindowController {
    init(shortcutRegistry: ShortcutRegistry) {
        let controller = CheatSheetViewController(shortcutRegistry: shortcutRegistry)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 720),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Shortcuts Cheat Sheet"
        window.contentViewController = controller
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class CheatSheetViewController: NSViewController {
    private let shortcutRegistry: ShortcutRegistry

    init(shortcutRegistry: ShortcutRegistry) {
        self.shortcutRegistry = shortcutRegistry
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 22, bottom: 22, right: 22)

        let grouped = Dictionary(grouping: shortcutRegistry.definitions(), by: \.category)
        for category in grouped.keys.sorted() {
            let header = NSTextField(labelWithString: category)
            header.font = .systemFont(ofSize: 17, weight: .bold)
            stack.addArrangedSubview(header)

            for definition in grouped[category, default: []] {
                let row = NSStackView()
                row.orientation = .horizontal
                row.distribution = .fillEqually

                let title = NSTextField(labelWithString: definition.title)
                title.font = .systemFont(ofSize: 13, weight: .medium)
                let binding = NSTextField(labelWithString: shortcutRegistry.bindingString(for: definition.action))
                binding.alignment = .right
                binding.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
                row.addArrangedSubview(title)
                row.addArrangedSubview(binding)
                stack.addArrangedSubview(row)
            }
        }

        scrollView.documentView = stack
        view = scrollView
    }
}

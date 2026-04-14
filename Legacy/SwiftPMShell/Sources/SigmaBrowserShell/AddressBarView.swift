import AppKit

@MainActor
final class AddressBarView: NSView {
    var onSubmit: ((String) -> Void)?
    var onOpenLauncher: (() -> Void)?
    var onReloadOrStop: (() -> Void)?

    private let capsuleView = NSVisualEffectView()
    private let leadingButton = NSButton()
    private let textField = NSTextField()
    private let trailingButton = NSButton()
    private let progressRing = ProgressRingView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setDisplayedValue(_ value: String) {
        if let editor = textField.currentEditor(), window?.firstResponder === editor {
            return
        }
        textField.stringValue = value
    }

    func focusTextField() {
        window?.makeFirstResponder(textField)
    }

    func setLoadingState(isLoading: Bool, progress: Double) {
        progressRing.progress = progress
        progressRing.isHidden = !isLoading
        let symbolName = isLoading ? "xmark" : "arrow.clockwise"
        trailingButton.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
    }

    private func buildUI() {
        translatesAutoresizingMaskIntoConstraints = false

        capsuleView.material = .hudWindow
        capsuleView.state = .active
        capsuleView.wantsLayer = true
        capsuleView.layer?.cornerRadius = 18
        capsuleView.layer?.borderWidth = 1
        capsuleView.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
        capsuleView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(capsuleView)

        leadingButton.isBordered = false
        leadingButton.image = NSImage(systemSymbolName: "rectangle.leftthird.inset.filled", accessibilityDescription: "Launcher")
        leadingButton.contentTintColor = NSColor.white.withAlphaComponent(0.78)
        leadingButton.target = self
        leadingButton.action = #selector(openLauncher)
        leadingButton.translatesAutoresizingMaskIntoConstraints = false
        capsuleView.addSubview(leadingButton)

        textField.isBordered = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.font = .systemFont(ofSize: 21, weight: .semibold)
        textField.textColor = .white
        textField.placeholderString = "Search or enter address"
        textField.alignment = .center
        textField.target = self
        textField.action = #selector(submit)
        textField.translatesAutoresizingMaskIntoConstraints = false
        capsuleView.addSubview(textField)

        progressRing.translatesAutoresizingMaskIntoConstraints = false
        progressRing.isHidden = true
        capsuleView.addSubview(progressRing)

        trailingButton.isBordered = false
        trailingButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Reload")
        trailingButton.contentTintColor = .white
        trailingButton.target = self
        trailingButton.action = #selector(reloadOrStop)
        trailingButton.translatesAutoresizingMaskIntoConstraints = false
        capsuleView.addSubview(trailingButton)

        NSLayoutConstraint.activate([
            capsuleView.topAnchor.constraint(equalTo: topAnchor),
            capsuleView.leadingAnchor.constraint(equalTo: leadingAnchor),
            capsuleView.trailingAnchor.constraint(equalTo: trailingAnchor),
            capsuleView.bottomAnchor.constraint(equalTo: bottomAnchor),
            capsuleView.heightAnchor.constraint(equalToConstant: 54),

            leadingButton.leadingAnchor.constraint(equalTo: capsuleView.leadingAnchor, constant: 14),
            leadingButton.centerYAnchor.constraint(equalTo: capsuleView.centerYAnchor),
            leadingButton.widthAnchor.constraint(equalToConstant: 28),
            leadingButton.heightAnchor.constraint(equalToConstant: 28),

            trailingButton.trailingAnchor.constraint(equalTo: capsuleView.trailingAnchor, constant: -14),
            trailingButton.centerYAnchor.constraint(equalTo: capsuleView.centerYAnchor),
            trailingButton.widthAnchor.constraint(equalToConstant: 28),
            trailingButton.heightAnchor.constraint(equalToConstant: 28),

            progressRing.centerXAnchor.constraint(equalTo: trailingButton.centerXAnchor),
            progressRing.centerYAnchor.constraint(equalTo: trailingButton.centerYAnchor),
            progressRing.widthAnchor.constraint(equalToConstant: 28),
            progressRing.heightAnchor.constraint(equalToConstant: 28),

            textField.leadingAnchor.constraint(equalTo: leadingButton.trailingAnchor, constant: 10),
            textField.trailingAnchor.constraint(equalTo: trailingButton.leadingAnchor, constant: -10),
            textField.centerYAnchor.constraint(equalTo: capsuleView.centerYAnchor),
        ])
    }

    @objc private func openLauncher() {
        onOpenLauncher?()
    }

    @objc private func reloadOrStop() {
        onReloadOrStop?()
    }

    @objc private func submit() {
        onSubmit?(textField.stringValue)
    }
}

private final class ProgressRingView: NSView {
    var progress: Double = 0 {
        didSet {
            needsDisplay = true
        }
    }

    override var isHidden: Bool {
        didSet {
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !isHidden else {
            return
        }

        let rect = bounds.insetBy(dx: 3, dy: 3)
        let backgroundPath = NSBezierPath(ovalIn: rect)
        NSColor.white.withAlphaComponent(0.10).setStroke()
        backgroundPath.lineWidth = 2
        backgroundPath.stroke()

        let startAngle: CGFloat = 90
        let endAngle: CGFloat = startAngle - (360 * CGFloat(progress))
        let progressPath = NSBezierPath()
        progressPath.appendArc(withCenter: NSPoint(x: bounds.midX, y: bounds.midY), radius: rect.width / 2, startAngle: startAngle, endAngle: endAngle, clockwise: true)
        progressPath.lineWidth = 2.5
        NSColor.systemTeal.setStroke()
        progressPath.stroke()
    }
}

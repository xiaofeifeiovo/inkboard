import AppKit

/// A small floating status pill shown over the top of the canvas: a hint, a spinner while an AI
/// request runs, or the result, with an optional button (取消, 在 Finder 中显示, …).
final class StatusBanner: NSVisualEffectView {
    enum Style {
        case info, progress, success
    }

    private let spinner = NSProgressIndicator()
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let button = NSButton(title: "", target: nil, action: nil)
    private var buttonAction: (() -> Void)?
    private var hideWork: DispatchWorkItem?

    init() {
        super.init(frame: .zero)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        isHidden = true

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)

        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        button.bezelStyle = .rounded
        button.controlSize = .small
        button.target = self
        button.action = #selector(buttonClicked)

        let stack = NSStackView(views: [spinner, icon, label, button])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 7, left: 12, bottom: 7, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(lessThanOrEqualToConstant: 640),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var text: String { label.stringValue }

    /// Shows `text`, replacing whatever was shown. `autoHide` is in seconds.
    func show(_ text: String, style: Style, button title: String? = nil, action: (() -> Void)? = nil,
              autoHide: TimeInterval? = nil) {
        hideWork?.cancel()
        hideWork = nil
        label.stringValue = text
        toolTip = text

        // A stopped spinner is invisible but would still take room in the stack.
        spinner.isHidden = style != .progress
        if style == .progress { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        switch style {
        case .info:
            icon.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
            icon.contentTintColor = .secondaryLabelColor
        case .success:
            icon.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
            icon.contentTintColor = .systemGreen
        case .progress:
            icon.image = nil
        }
        icon.isHidden = icon.image == nil

        button.title = title ?? ""
        button.isHidden = title == nil
        buttonAction = action
        isHidden = false

        if let autoHide {
            let work = DispatchWorkItem { [weak self] in self?.hide() }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + autoHide, execute: work)
        }
    }

    func hide() {
        hideWork?.cancel()
        hideWork = nil
        spinner.stopAnimation(nil)
        buttonAction = nil
        isHidden = true
    }

    @objc private func buttonClicked() {
        buttonAction?()
    }
}

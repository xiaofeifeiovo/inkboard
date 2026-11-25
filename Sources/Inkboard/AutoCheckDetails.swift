import AppKit
import InkboardCore

/// 详情 of a 自动检查 box: each issue (severity, summary, detail, related blocks) and what the AI
/// read, so the user can tell a misread from a real mistake. Shown in an NSPopover; the text can
/// be selected and copied.
final class AutoCheckDetailsViewController: NSViewController {
    private let check: BlockCheck

    init(check: BlockCheck) {
        self.check = check
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private static let width: CGFloat = 380
    private static let maxHeight: CGFloat = 420

    override func loadView() {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 10))
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.textStorage?.setAttributedString(Self.text(for: check))

        // Size to the text, up to a maximum (then it scrolls).
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        let used = textView.layoutManager?.usedRect(for: textView.textContainer!).height ?? 100
        let height = min(Self.maxHeight, ceil(used) + 2 * textView.textContainerInset.height)
        textView.frame.size.height = max(height, ceil(used) + 2 * textView.textContainerInset.height)

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: Self.width, height: height))
        scroll.hasVerticalScroller = used + 24 > Self.maxHeight
        scroll.drawsBackground = false
        scroll.documentView = textView
        view = scroll
        preferredContentSize = scroll.frame.size
    }

    static func text(for check: BlockCheck) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let body = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let small = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 4
        func add(_ text: String, font: NSFont = body, color: NSColor = .labelColor) {
            result.append(NSAttributedString(string: text, attributes: [
                .font: font, .foregroundColor: color, .paragraphStyle: paragraph,
            ]))
        }

        let issues = check.issues.sorted { $0.severity > $1.severity }
        for (i, issue) in issues.enumerated() {
            if i > 0 { add("\n") }
            let isError = issue.severity == .error
            add(isError ? "错误" : "不准确", font: .boldSystemFont(ofSize: NSFont.systemFontSize),
                color: isError ? .systemRed : .systemOrange)
            add("  " + issue.summary + "\n", font: .boldSystemFont(ofSize: NSFont.systemFontSize))
            if !issue.detail.isEmpty { add(issue.detail + "\n") }
            if !issue.related.isEmpty {
                add("相关：" + issue.related.joined(separator: "、") + "\n", font: small, color: .secondaryLabelColor)
            }
        }
        if !check.reading.isEmpty {
            if !issues.isEmpty { add("\n") }
            add("AI 读到的内容（\(check.tag)）：\n", font: small, color: .secondaryLabelColor)
            add(check.reading + "\n", font: .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular))
        }
        return result
    }
}

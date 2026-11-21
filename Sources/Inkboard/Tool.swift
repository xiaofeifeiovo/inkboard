import AppKit

enum Tool: Int, CaseIterable {
    case pen, eraser, lasso, insertSpace

    var title: String {
        switch self {
        case .pen: return "钢笔"
        case .eraser: return "橡皮擦"
        case .lasso: return "套索选择"
        case .insertSpace: return "插入空间"
        }
    }

    /// Single-key shortcut, handled by the canvas.
    var shortcut: String {
        switch self {
        case .pen: return "p"
        case .eraser: return "e"
        case .lasso: return "l"
        case .insertSpace: return "s"
        }
    }

    var image: NSImage {
        let candidates: [String]
        switch self {
        case .pen: candidates = ["pencil.tip", "pencil"]
        case .eraser: candidates = ["eraser", "xmark.circle"]
        case .lasso: candidates = ["lasso", "selection.pin.in.out"]
        case .insertSpace: candidates = ["arrow.up.and.line.horizontal.and.arrow.down", "arrow.up.and.down"]
        }
        for name in candidates {
            if let image = NSImage(systemSymbolName: name, accessibilityDescription: title) { return image }
        }
        return NSImage(size: NSSize(width: 16, height: 16))
    }
}

/// Pen width presets (nominal diameter in canvas units).
enum PenWidth: Int, CaseIterable {
    case fine, medium, bold

    var value: CGFloat {
        switch self {
        case .fine: return 1.6
        case .medium: return 2.6
        case .bold: return 4.5
        }
    }

    var title: String {
        switch self {
        case .fine: return "细"
        case .medium: return "中"
        case .bold: return "粗"
        }
    }

    var dotSize: CGFloat {
        switch self {
        case .fine: return 5
        case .medium: return 8
        case .bold: return 11
        }
    }
}

import Foundation
import InkboardCore

/// 设置 → 分块方式 (UserDefaults `layout.segmentationMode`, `SegmentationMode.rawValue`).
///
/// The mode reaches `InkLayout` through `InkLayout.defaultOptions.useGroups` (on in「AI 辅助」:
/// blocks follow `Board.groups`), set at launch (`apply()`) and on every change, before
/// `didChange` is posted. Every window then segments again: the 显示分块 overlay, 自动检查
/// (`AutoChecker.layoutDidChange`), and the 转换 menu's 识别分块类型 / AI 识别分块 item.
/// Work done off the main thread takes `layoutOptions` with it instead of reading the global.
enum LayoutSettings {
    static let modeKey = "layout.segmentationMode"
    static let didChange = Notification.Name("InkboardLayoutSettingsDidChange")

    /// Modes that can be chosen now (专用墨迹分块模型 is shown, disabled, as 即将支持).
    static func isAvailable(_ mode: SegmentationMode) -> Bool {
        mode != .model
    }

    static func title(_ mode: SegmentationMode) -> String {
        switch mode {
        case .geometric: return "本地计算"
        case .aiAssisted: return "AI 辅助"
        case .model: return "专用墨迹分块模型（即将支持）"
        }
    }

    static var segmentationMode: SegmentationMode {
        get {
            let stored = UserDefaults.standard.string(forKey: modeKey).flatMap(SegmentationMode.init(rawValue:))
            guard let stored, isAvailable(stored) else { return .geometric }
            return stored
        }
        set {
            guard isAvailable(newValue), newValue != segmentationMode else { return }
            UserDefaults.standard.set(newValue.rawValue, forKey: modeKey)
            apply()
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    /// Makes `InkLayout.analyze` follow the stored mode (at launch, and after every change).
    static func apply() {
        InkLayout.defaultOptions.useGroups = segmentationMode == .aiAssisted
        MainMenu.updateSegmentationItem()
    }

    /// The options of the current mode, for segmenting off the main thread.
    static var layoutOptions: InkLayout.Options { InkLayout.defaultOptions }

    /// 转换 menu title of the AI request that improves the segmentation in this mode.
    static var recognizeTitle: String {
        segmentationMode == .aiAssisted ? "AI 识别分块" : "识别分块类型（文字 / 公式 / 图）"
    }
}

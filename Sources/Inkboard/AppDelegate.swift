import AppKit
import InkboardCore

/// Documents (windows, saving, Open Recent, restoring windows at launch) are run by
/// NSDocumentController using BoardDocument, as declared in Support/Info.plist.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// AI requests go to the backend chosen in 设置: an ACP agent (Antigravity's `agy acp` by
    /// default) or an OpenAI-compatible API. Settings are re-read for every request.
    static let transcriber = AITranscriber { try AISettings.current.transcriberSettings() }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Set before launch finishes so NSDocumentController finds the Open Recent menu.
        NSApp.mainMenu = MainMenu.build()
        LayoutSettings.apply()   // 分块方式 → InkLayout.defaultOptions, before any document opens
        // Deliver every tablet sample instead of merging them; keeps fast strokes smooth.
        NSEvent.isMouseCoalescingEnabled = false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if #available(macOS 14, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Self.transcriber.shutdown()
    }

    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.showWindow(sender)
    }

    /// 显示 → 显示点格 (applies to every window).
    @objc func toggleDotGrid(_ sender: Any?) {
        CanvasView.showsDotGrid.toggle()
    }

    /// 显示 → 显示分块 (applies to every window).
    @objc func toggleBlocks(_ sender: Any?) {
        CanvasView.showsBlocks.toggle()
    }

    /// 转换 / 自动检查 menu → 自动重新检查改过的块 (applies to every window).
    @objc func toggleAutoRecheck(_ sender: Any?) {
        AutoRecheckSetting.isOn.toggle()
    }

    /// Called at launch when no window was restored, and when the Dock icon is clicked with no windows open.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        !LegacyBoard.importIfPresent()
    }
}

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleDotGrid(_:)) {
            menuItem.state = CanvasView.showsDotGrid ? .on : .off
        }
        if menuItem.action == #selector(toggleBlocks(_:)) {
            menuItem.state = CanvasView.showsBlocks ? .on : .off
        }
        if menuItem.action == #selector(toggleAutoRecheck(_:)) {
            menuItem.state = AutoRecheckSetting.isOn ? .on : .off
        }
        return true
    }
}

/// Before the file system existed, the app kept one board in
/// ~/Library/Application Support/Inkboard/board.json. On the first launch after the upgrade
/// it opens as an untitled document (so the user can save it anywhere), and the old file is
/// renamed rather than deleted.
enum LegacyBoard {
    static let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Inkboard", isDirectory: true)
        .appendingPathComponent("board.json")

    /// Returns true when a legacy board was found and opened.
    static func importIfPresent() -> Bool {
        guard let data = try? Data(contentsOf: url),
              let board = try? BoardStore.decode(data) else { return false }

        let imported = url.deletingLastPathComponent().appendingPathComponent("board.imported.json")
        do {
            if FileManager.default.fileExists(atPath: imported.path) {
                try FileManager.default.removeItem(at: imported)
            }
            try FileManager.default.moveItem(at: url, to: imported)
        } catch {
            NSLog("Inkboard: could not rename legacy board: \(error)")
            return false   // leave it in place rather than risk importing twice
        }
        guard !board.isEmpty else { return false }

        let document = BoardDocument(importing: board)
        NSDocumentController.shared.addDocument(document)
        document.makeWindowControllers()
        document.showWindows()
        return true
    }
}

import AppKit
import InkboardCore

/// Documents (windows, saving, Open Recent, restoring windows at launch) are run by
/// NSDocumentController using BoardDocument, as declared in Support/Info.plist.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Replace with a real implementation to enable AI → Markdown (see Transcription.swift).
    static let transcriber: HandwritingTranscriber = UnconfiguredTranscriber()

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Set before launch finishes so NSDocumentController finds the Open Recent menu.
        NSApp.mainMenu = MainMenu.build()
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

    /// Called at launch when no window was restored, and when the Dock icon is clicked with no windows open.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        !LegacyBoard.importIfPresent()
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
              let strokes = try? BoardStore.decode(data) else { return false }

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
        guard !strokes.isEmpty else { return false }

        let document = BoardDocument(importing: strokes)
        NSDocumentController.shared.addDocument(document)
        document.makeWindowControllers()
        document.showWindows()
        return true
    }
}

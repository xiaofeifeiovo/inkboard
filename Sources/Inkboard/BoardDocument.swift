import AppKit
import InkboardCore

/// One `.inkboard` file. NSDocument supplies save / open / duplicate / rename / move,
/// Open Recent, autosave-in-place, version browsing and the "unsaved changes" prompts.
///
/// The canvas edits its own copy of the board; every committed edit (and undo/redo) is
/// mirrored into `board` here, which is what gets written. Edits register undo on the
/// document's undo manager, and that is what marks the document as edited.
@objc(BoardDocument)   // stable class name for NSDocumentClass in Info.plist
final class BoardDocument: NSDocument {
    /// Must match UTExportedTypeDeclarations / CFBundleDocumentTypes in Support/Info.plist.
    static let typeIdentifier = "local.inkboard.board"

    private(set) var board = Board()
    /// 自动检查 results, fixed pages and the switch. Not part of `board`: results arrive
    /// asynchronously and stay out of undo; changes mark the document edited directly.
    private(set) var autoCheck = AutoCheckState()

    /// Where 自动检查 requests go (replaceable for testing the UI without real requests).
    static var makeCheckService: () -> AutoCheckService = { AppDelegate.transcriber }

    private var boardWindowController: MainWindowController? {
        windowControllers.first as? MainWindowController
    }

    override class var autosavesInPlace: Bool { true }

    /// Starts an untitled document pre-filled with a board (used to import the pre-file-system board).
    convenience init(importing board: Board) {
        self.init()
        fileType = Self.typeIdentifier
        self.board = board
        updateChangeCount(.changeDone)   // so it is autosaved and the user is asked where to keep it
    }

    override func makeWindowControllers() {
        let controller = MainWindowController(transcriber: AppDelegate.transcriber, checkService: Self.makeCheckService())
        addWindowController(controller)
        controller.load(board, autoCheck: autoCheck)
        controller.canvas.onContentChange = { [weak self, weak controller] in
            guard let self, let canvas = controller?.canvas else { return }
            self.board = canvas.board
        }
        controller.onAutoCheckStateChange = { [weak self] state in
            guard let self, state != self.autoCheck else { return }
            self.autoCheck = state
            self.updateChangeCount(.changeDone)   // not undoable, so no undo registration marks it
        }
    }

    // MARK: - Reading & writing

    override func data(ofType typeName: String) throws -> Data {
        try BoardStore.encode(board, autoCheck: autoCheck)
    }

    override func read(from data: Data, ofType typeName: String) throws {
        let loaded: Board
        do {
            loaded = try BoardStore.decode(data)
        } catch {
            throw CocoaError(.fileReadCorruptFile, userInfo: [
                NSLocalizedDescriptionKey: "这个文件不是有效的 Inkboard 手绘文件，或者已经损坏。",
                NSUnderlyingErrorKey: error,
            ])
        }
        board = loaded
        autoCheck = BoardStore.decodeAutoCheck(data, board: loaded)
        // Revert / restoring an older version re-reads an already open document.
        boardWindowController?.load(loaded, autoCheck: autoCheck)
    }
}

import Foundation
import FileExplorer

/// Reading a file into the open document, and putting the undo stacks in step around it. Kept out
/// of `ContentView`, which a test can't build, so the sequence can be run by a test.
///
/// The order is the whole content of this function. `NSTextView` registers undo by character
/// range in the buffer the edit was made against, and `PlainTextEditor.updateNSView` hands the view
/// its text and its undo manager read from one render pass. So:
///
/// 0. ``EditorUndoStore/adopt(_:)`` — on the very first load only — makes the buffer's storage
///    the store's, so step 1 lets go of the storage the buffer is actually listening to.
/// 1. ``EditorUndoStore/remember(text:)`` files the outgoing stack against the text it is being
///    parted FROM — the last moment its registrations and that text are known to agree.
/// 2. The buffer is replaced.
/// 3. ``EditorUndoStore/activate(path:text:)`` asks for the incoming document's stack against what
///    ACTUALLY loaded, so a stack that no longer fits is dropped rather than handed back.
/// 4. ``EditorBuffer/follow(_:)`` hands the buffer the text storage kept beside that stack: the
///    storage the stack's actions edit, and what the text view is re-pointed at. Step 1 stopped
///    the outgoing storage listening, so the load in step 2 wrote only the buffer.
///
/// Get 1 and 2 the wrong way round and the outgoing stack is filed against the incoming text, which
/// makes its fingerprint agree next time and hands a stale stack to a buffer it does not fit. Leave
/// 3 out and the new document is handed the old one's manager. Either way a later ⌘Z splices
/// characters out of the wrong document, or throws `NSRangeException` and takes the window down with
/// every unsaved buffer in it. Leave 4 out and the text view goes on showing the outgoing document's
/// storage beside the incoming document's stack.
///
/// **Nothing here may suspend.** All four steps run in one main-actor turn, so SwiftUI can't render
/// between them and show one document's text beside another's undo manager. If the read ever moves
/// off the main actor, the `await` belongs before step 2, and steps 2 to 4 must stay one
/// synchronous block. Callers also read the document straight after this returns,
/// `owePaneSelection` included.
enum EditorDocumentLoad {

    /// Reads `path` into `document` and moves the undo stacks with it.
    ///
    /// - Returns: what the read did, so the caller can act on a refusal without re-reading the
    ///   document to find out.
    @MainActor
    @discardableResult
    static func run(path: String, document: EditorDocument, undoStore: EditorUndoStore,
                    log: (String) -> Void) -> EditorFileStore.OpenResult {
        // On the first load the buffer and the store each have a storage; from here on, one.
        undoStore.adopt(document.buffer.source)
        // `opening`: the file coming in is never the one evicted to make room.
        undoStore.remember(text: document.text, opening: path)
        undoStore.forgetMissingFiles()
        // One call, not open-then-hand-over, so the encoding the file was read in travels with its
        // text and a save doesn't transcode it. See `EditorFileStore.load`.
        let result = EditorFileStore.load(path: path, into: document)
        undoStore.activate(path: document.path, text: document.text)
        document.buffer.follow(undoStore.source)
        log(Self.logLine(path: path, result: result))
        return result
    }

    /// One line per load, whatever the read did, so a refusal is as visible in the log as a success.
    /// Separate from ``run(path:document:undoStore:log:)`` so a test can check the wording without
    /// a load.
    static func logLine(path: String, result: EditorFileStore.OpenResult) -> String {
        switch result {
        case .refused(let reason): return "Editor could not open \(path) — \(reason)"
        case .readOnly(let reason): return "Editor opened \(path) read-only — \(reason)"
        case .opened: return "Editor opened \(path)"
        }
    }
}

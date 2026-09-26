import Foundation
import FileExplorer

/// Reading a file into the open document, and putting the undo stacks in step around it.
///
/// **Extracted for `EditorDocumentClose`'s reason, and it applies here harder.** That type says it
/// plainly: `ContentView` cannot be built in a test, so an act written inline there is an act
/// nothing executes. This one is the act with the crash in it — so the sequence lived in
/// `ContentView.loadIntoEditor` with four callers, a comment explaining why the order matters, and
/// no test that could run it. What stood in for one was a copy of the three calls in a test file,
/// which pins a transcription rather than the code.
///
/// **The order is the whole content of this function.** `NSTextView` registers undo by character
/// RANGE in the buffer the edit was made against, and `PlainTextEditor.updateNSView` hands the view
/// its text and its undo manager read from one render pass. So:
///
/// 1. ``EditorUndoStore/remember(text:)`` files the outgoing stack against the text it is being
///    parted FROM — the last moment its registrations and that text are known to agree.
/// 2. The buffer is replaced.
/// 3. ``EditorUndoStore/activate(path:text:)`` asks for the incoming document's stack against what
///    ACTUALLY loaded, so a stack that no longer fits is dropped rather than handed back.
///
/// Get 1 and 2 the wrong way round and the outgoing stack is filed against the incoming text, which
/// makes its fingerprint agree next time and hands a stale stack to a buffer it does not fit. Leave
/// 3 out and the new document is handed the old one's manager. Either way a later ⌘Z splices
/// characters out of the wrong document, or throws `NSRangeException` and takes the window down with
/// every unsaved buffer in it.
///
/// **Nothing here suspends, and that is load-bearing rather than incidental.** All three steps run
/// in one main-actor turn, so SwiftUI cannot render between them and no pass can see one document's
/// text beside another's undo manager. If the read is ever moved off the main actor, the `await`
/// belongs BEFORE step 2 — while the buffer and the stack are both still the outgoing document's —
/// and steps 2 and 3 must stay in a single synchronous block. Four callers also read the document
/// straight after this returns, `owePaneSelection` included.
enum EditorDocumentLoad {

    /// Reads `path` into `document` and moves the undo stacks with it.
    ///
    /// - Returns: what the read did, so the caller can act on a refusal without re-reading the
    ///   document to find out.
    @MainActor
    @discardableResult
    static func run(path: String, document: EditorDocument, undoStore: EditorUndoStore,
                    log: (String) -> Void) -> EditorFileStore.OpenResult {
        undoStore.remember(text: document.text)
        undoStore.forgetMissingFiles()
        // One call, not open-then-hand-over: the encoding a file was read in travels with the text
        // it produced, which is what stops a save transcoding it. See `EditorFileStore.load`.
        let result = EditorFileStore.load(path: path, into: document)
        undoStore.activate(path: document.path, text: document.text)
        log(Self.logLine(path: path, result: result))
        return result
    }

    /// One line per load, whatever the read did — so a refusal is as visible in the log as a
    /// success. Separate from ``run(path:document:undoStore:log:)`` so its wording can be asserted
    /// without performing a load.
    static func logLine(path: String, result: EditorFileStore.OpenResult) -> String {
        switch result {
        case .refused(let reason): return "Editor could not open \(path) — \(reason)"
        case .readOnly(let reason): return "Editor opened \(path) read-only — \(reason)"
        case .opened: return "Editor opened \(path)"
        }
    }
}

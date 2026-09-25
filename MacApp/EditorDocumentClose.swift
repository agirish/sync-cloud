import Foundation
import FileExplorer

/// Putting the open document away (TE46) — the header's × and File ▸ Close Document.
///
/// **There was no way to do this at all.** A document stayed open until another one replaced it;
/// File ▸ Close is gone because ⌘W is Close Tab (see the `.saveItem` note in `SyncCloudApp`), and
/// nothing took its place. This is the act both doors share, as one function a test can run with a
/// real document, a real undo store and a real pane selection — `ContentView` cannot be built in a
/// test, so a close written inline there would be a close nothing executes.
///
/// **What it deliberately does NOT move**: the pane's folder, the workspace, the "Just the text"
/// bit, the naming row. A close is about the document; everything around it stays where it was.
enum EditorDocumentClose {

    /// Whether the two doors are offered: Edit on screen, with a document in it.
    ///
    /// **Not `EditorVerbs.isOffered`**, which also refuses a refused document. A file that could not
    /// be opened — cloud-only, too large, not text — still has a caption on screen and a name in the
    /// header, and putting that away is exactly what somebody looking at a refusal wants to do. Edit
    /// must be the WORKSPACE, for the verbs' reason: the document outlives a workspace switch, and a
    /// Close Document live from Browse would put away something nobody is looking at.
    static func isOffered(workspace: Workspace, hasDocument: Bool) -> Bool {
        workspace == .editor && hasDocument
    }

    /// What the left pane's selection becomes once `path` is closed, or `nil` to leave it alone.
    ///
    /// **Cleared when it names exactly the closed file, and that is what lets a click reopen it.**
    /// With the pane open, Edit opens a file when the pane's selection CHANGES to it (TE41's
    /// `.onChange(of: selectedLeftPaths)`). Left alone, the selection would go on naming the file
    /// just closed, and clicking that same row would set the same selection — no change, no open.
    /// Any other selection is the user's and is not touched: clicking the closed file's row from
    /// there changes it anyway.
    ///
    /// Compared as standardized paths, so a trailing slash or a doubled separator cannot leave the
    /// selection standing.
    static func paneSelection(afterClosing path: String, selection: Set<String>) -> Set<String>? {
        guard selection.count == 1, let only = selection.first,
              (only as NSString).standardizingPath == (path as NSString).standardizingPath else { return nil }
        return []
    }

    /// Settle, then unload. Returns whether the document was closed.
    ///
    /// **Settled first, and a `false` from it means nothing happens** — the same contract every
    /// route out of a document honours (`openInEditor`, `handOffToEditor`, `createTextFile`). With
    /// autosave on, the settle is a flush that says nothing; with it off or stopped on a dirty
    /// buffer, it is the Save / Don't Save / Cancel question, and Cancel keeps the document open.
    ///
    /// **The undo stack is put away the way a file switch puts it away** — remembered against the
    /// text it is parted from, then a fresh stack for the empty editor — so reopening the file
    /// hands its history back exactly as switching to it would.
    ///
    /// One log line whichever way it ends, as `handOffToEditor` does.
    @MainActor
    @discardableResult
    static func run(document: EditorDocument, undoStore: EditorUndoStore,
                    settle: () -> Bool,
                    paneSelection: () -> Set<String>,
                    setPaneSelection: (Set<String>) -> Void,
                    log: (String) -> Void) -> Bool {
        guard let path = document.path else { return false }
        guard settle() else {
            log("Editor close of \(path) cancelled — the open document was kept")
            return false
        }
        undoStore.remember(text: document.text)
        document.close()
        undoStore.activate(path: nil, text: "")
        if let next = Self.paneSelection(afterClosing: path, selection: paneSelection()) {
            setPaneSelection(next)
        }
        log("Editor closed \(path)")
        return true
    }
}

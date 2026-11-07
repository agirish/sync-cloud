import Foundation
import Events
import FileExplorer

/// Putting the open document away: the header's × and File ▸ Close Document. (⌘W is Close Tab;
/// see the `.saveItem` note in `SyncCloudApp`.) The act both share, kept out of `ContentView` so a
/// test can run it with a real document, undo store and pane selection.
///
/// It leaves the pane's folder, the workspace, the "Just the text" bit and the naming row alone: a
/// close is about the document.
enum EditorDocumentClose {

    /// Whether the two doors are offered: Edit on screen, with a document in it.
    ///
    /// Not `EditorVerbs.isOffered`, which also excludes a refused document: a file that couldn't be
    /// opened still shows a caption and a name, and closing it is what its reader wants. Edit must
    /// be on screen because the document outlives a workspace switch, and closing it from Browse
    /// would put away something nobody is looking at.
    static func isOffered(workspace: Workspace, hasDocument: Bool) -> Bool {
        workspace == .editor && hasDocument
    }

    /// What the left pane's selection becomes once `path` is closed, or `nil` to leave it alone.
    ///
    /// Cleared when it names exactly the closed file, so a click can reopen it: Edit opens a file
    /// when the selection changes to it (`.onChange(of: selectedLeftPaths)`), and re-clicking a
    /// still-selected row changes nothing. Any other selection is the user's and is left alone.
    /// Compared as standardized paths, so a trailing or doubled slash can't leave it standing.
    static func paneSelection(afterClosing path: String, selection: Set<String>) -> Set<String>? {
        guard selection.count == 1, let only = selection.first,
              (only as NSString).standardizingPath == (path as NSString).standardizingPath else { return nil }
        return []
    }

    /// Settle, then unload. Returns whether the document was closed.
    ///
    /// Settled first, and a `false` means nothing happens, the contract every route out of a
    /// document keeps (`openInEditor`, `handOffToEditor`, `createTextFile`). With autosave on the
    /// settle is a silent flush; off or stopped on a dirty buffer, it is the Save / Don't Save /
    /// Cancel question, and Cancel keeps the document open.
    ///
    /// The undo stack is put away as a file switch does (remembered against the outgoing text, then
    /// a fresh stack), so reopening the file hands its history back; the text storage moves with it,
    /// as in `EditorDocumentLoad` step 4. One log line whichever way it ends.
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
        document.buffer.follow(undoStore.source)
        if let next = Self.paneSelection(afterClosing: path, selection: paneSelection()) {
            setPaneSelection(next)
        }
        // Straight to the log, not through `log`: a close of a document autosave never wrote
        // keeps the one line its callers expect.
        if let tally = EditorAutosaveTally.closeOut(path) { Logger.shared.info(tally) }
        log("Editor closed \(path)")
        return true
    }

    /// Settling before the window closes, which leaves the document open: ⌘W on the last browse
    /// tab. Returns whether the window may close.
    ///
    /// The document outlives the window, so a "Don't Save" must reload the file from disk, as
    /// Reload from Disk does; dropping only the undo history would bring the discarded typing back
    /// when the window reopens. A settle that lets the window go leaves the document clean unless
    /// the typing was discarded, so "still dirty" is read as the discard.
    @MainActor
    static func settleForWindowClose(document: EditorDocument, settle: () -> Bool,
                                     reload: (String) -> Void) -> Bool {
        guard settle() else { return false }
        if document.isDirty, let path = document.path { reload(path) }
        return true
    }
}

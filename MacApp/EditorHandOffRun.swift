import Foundation
import Events
import FileExplorer
import Sync

/// **The hand-off: "Open in Edit" from any door, anywhere in the app** — as one act a test can run.
///
/// `ContentView.handOffToEditor` supplies the window's pieces; this is the order they run in, and
/// the one place each outcome is logged. It is a type of its own for the reason
/// `EditorDocumentClose` is: `ContentView` cannot be built in a test, so an act written inline there
/// is an act nothing executes — and the pane half of this one is exactly what has to be measured
/// against a real `FileSyncManager`.
///
/// **The question comes first, and nothing moves until it is answered.** The unsaved-changes prompt
/// used to run last, inside `openInEditor`, after the pane had been re-rooted and the workspace
/// switched — so answering *Cancel* to "save your changes?" left the user in the Editor, the pane
/// moved to a folder they had not asked for, and the old dirty document still on screen. Cancel has
/// to mean nothing happened.
///
/// Then: point the folder before switching workspace, so the rail lists the right folder on its
/// first render rather than listing the previous one and re-listing a frame later. Open last,
/// through `load` — the buffer is already settled, so re-asking would be a second prompt to keep in
/// step with the first.
///
/// Editing always *happens* in the editor workspace. This is the ⌘4 move a user could make by hand,
/// made for them: one writable surface, so dirty state, undo and the save circuit live in exactly
/// one place.
@MainActor
enum EditorHandOffRun {

    /// What the hand-off does to the left pane — the one thing its doors disagree about.
    enum Pane: Equatable {
        /// Re-root the left pane on the file's folder, so the rail and the pane list where the
        /// document lives. Every door but one.
        case followsTheFile
        /// **Leave the left pane exactly where it is** — Compare's list of differences (TE31's
        /// fixup). There the left pane IS one half of the comparison the list is showing: re-rooting
        /// it re-scopes the comparison, re-runs its scan and clears the session's "Ignore in
        /// comparison" entries (`focusOn` → `clearSessionIgnoredPaths`), so the row you acted from
        /// would vanish under you along with every row you had set aside. The header's location
        /// ("in <folder>") says where the file lives, and is the door that moves the pane there.
        case staysPut
    }

    /// How a hand-off ended — every one of them writes exactly one line saying so.
    enum Outcome: Equatable {
        /// The file was open already, and readable: Edit is shown, nothing else moves.
        case alreadyOpen
        /// The settle was answered Cancel: nothing moved at all.
        case cancelled
        /// The file was loaded (opened, read-only, or refused — `load` logs which).
        case opened
    }

    /// Whether opening `path` is anything but a no-op: it is not the open document, or the last
    /// attempt at it was refused — the same guard the rail's `openInEditor` makes.
    ///
    /// A refused file is let through on purpose: a cloud-only file downloaded in Finder, or one
    /// that was too large and has since been trimmed, is a second click away from opening, and an
    /// early return used to swallow it and leave the stale refusal on screen.
    nonisolated static func opens(_ path: String, openDocument: String?, isRefused: Bool) -> Bool {
        path != openDocument || isRefused
    }

    /// Runs the hand-off.
    ///
    /// - Parameters:
    ///   - paneRoot: the left source's root, `~` expanded — what `focusOn`'s relative path is
    ///     relative to.
    ///   - paneFolder: the folder the left pane shows now (`ContentView.editorFolder`), read only
    ///     when the answer is needed.
    ///   - settle: `settleEditorDocument()` — a `false` means nothing happens.
    ///   - showEdit: switches to the Edit workspace when it is not already on screen.
    ///   - load: `loadIntoEditor(path:)`, which logs the load's own outcome.
    @discardableResult
    static func run(_ path: String, pane: Pane,
                    syncManager: FileSyncManager, paneRoot: String,
                    openDocument: String?, isRefused: Bool,
                    paneFolder: () -> String,
                    settle: () -> Bool,
                    showEdit: () -> Void,
                    load: (String) -> Void,
                    log: (String) -> Void) -> Outcome {
        guard opens(path, openDocument: openDocument, isRefused: isRefused) else {
            // Already open and readable: just go there. Nothing to settle, nothing to move.
            //
            // **Logged, because every other outcome of a hand-off is.** `loadIntoEditor` writes one
            // line for opened / read-only / refused, and this exit and the cancelled settle below
            // were the two that wrote nothing — so a report of "I pressed ⌘O and nothing happened"
            // had no line to find. Each hand-off leaves exactly one line whichever way it ends.
            log("Editor hand-off: \(path) is already open — showing Edit")
            showEdit()
            return .alreadyOpen
        }
        guard settle() else {
            log("Editor hand-off to \(path) cancelled — the open document was kept")
            return .cancelled
        }
        switch pane {
        case .followsTheFile:
            let folder = (path as NSString).deletingLastPathComponent
            // **The LEFT pane, whichever pane the row was in.** It took the row's side for a
            // while, which sounds more careful and is not: `editorFolder` reads the left pane and
            // only the left pane, so handing off a row from the right pane re-rooted a pane the
            // editor never shows — resetting its column stack and pushing a history entry in the
            // user's OTHER source — while the rail went on listing the left pane's folder and ⌘N
            // went on creating files there. One pane is read, so one pane is moved. Nothing to do
            // when it is already there: `focusOn` is not free.
            if !folder.isEmpty, folder != paneFolder() {
                focusPane(on: folder, root: paneRoot, syncManager: syncManager)
            }
        case .staysPut:
            // Its own line, so a report of "Open in Edit didn't take me to the folder" from Compare
            // finds the decision rather than a silence.
            log("Editor hand-off: \(path) opened without moving the left pane — it stays on \(paneFolder())")
        }
        showEdit()
        load(path)
        return .opened
    }

    /// Points a pane at an absolute folder, the way the folder sidebar does.
    ///
    /// **`focusOn` takes a path RELATIVE to whatever root the pane is on**, which is the trap this
    /// exists to avoid: handing it an absolute path resolves it against the root and lands the pane
    /// somewhere real and wrong. A folder outside the pane's current root is refused rather than
    /// guessed at — the file is still opened, it is the rail that will be showing a different
    /// folder, and that is a smaller surprise than silently switching the user's source.
    ///
    /// - Returns: `false` when the folder is not under the pane's root.
    @discardableResult
    static func focusPane(on folder: String, root: String, syncManager: FileSyncManager,
                          isLeft: Bool = true) -> Bool {
        guard !root.isEmpty else { return false }
        guard let relative = PaneLogic.relativePath(of: folder, under: root) else {
            Logger.shared.info("Editor hand-off: \(folder) is outside the pane's root — leaving the pane where it is")
            return false
        }
        syncManager.focusOn(relativePath: relative, isLeft: isLeft)
        return true
    }
}

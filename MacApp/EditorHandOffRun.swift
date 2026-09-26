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

    /// How a hand-off ended — every one of them writes one line saying so: this act's own for the
    /// first two, the load's (`loadIntoEditor`: opened, read-only or refused) for the third. A
    /// `.staysPut` hand-off adds one line before the load naming the decision to leave the pane,
    /// worded as a decision — the load's line is the one that says whether the file opened.
    enum Outcome: Equatable {
        /// The file was open already, and readable: Edit is shown, nothing else moves.
        case alreadyOpen
        /// The settle was answered Cancel: nothing moved at all.
        case cancelled
        /// The file was loaded (opened, read-only, or refused — `load` logs which).
        case opened
    }

    /// Whether opening `path` is anything but a no-op: it is not the open document, or the last
    /// attempt at it was refused. **The one guard both routes ask** — the rail's `openInEditor` and
    /// every hand-off — so "already open" cannot come to mean two things.
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
    ///   - paneFolder: the folder the left pane will show IN EDIT (`ContentView.leftPaneFolder(in:
    ///     .editor)`), read only when the answer is needed. **Edit's, not the workspace on screen
    ///     now:** the hand-off starts in Browse, Compare or Organize, and Browse keeps its own view
    ///     mode — so a Browse pane drawing Columns at R › A answers `R/A` while the same pane in a
    ///     Tree-mode Edit shows `R`. Asking the screen's folder took "already there" for `R/A`,
    ///     skipped the re-root, and landed Edit on `R` with the document's debt dropped
    ///     (2026-09-25).
    ///   - settle: `settleEditorDocument()` — a `false` means nothing happens.
    ///   - endNaming: puts away ⌘N's naming row. **Every hand-off that is not cancelled lands on a
    ///     document**, so a naming row left open by an earlier ⌘N — the user then left Edit and
    ///     chose a file elsewhere — must not sit over it with its field taking the keyboard.
    ///     `openInEditor` does the same for the rail's click.
    ///   - showEdit: switches to the Edit workspace when it is not already on screen.
    ///   - load: `loadIntoEditor(path:)`, which logs the load's own outcome.
    @discardableResult
    static func run(_ path: String, pane: Pane,
                    syncManager: FileSyncManager, paneRoot: String,
                    openDocument: String?, isRefused: Bool,
                    paneFolder: () -> String,
                    settle: () -> Bool,
                    endNaming: () -> Void,
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
            endNaming()
            showEdit()
            return .alreadyOpen
        }
        guard settle() else {
            log("Editor hand-off to \(path) cancelled — the open document was kept")
            return .cancelled
        }
        endNaming()
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
            // finds the decision rather than a silence. **Worded as the decision, not the result**:
            // it is written before the load, and a file the editor then refuses must not have a
            // line saying it "opened" above the line saying it could not be.
            log("Editor hand-off to \(path) leaves the left pane on \(paneFolder()) — Compare's list of differences does not move it")
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
    /// The LEFT pane, always — see `run`'s note on why one pane is read and one is moved.
    ///
    /// - Returns: `false` when the folder is not under the pane's root.
    @discardableResult
    static func focusPane(on folder: String, root: String, syncManager: FileSyncManager) -> Bool {
        guard !root.isEmpty else { return false }
        guard let relative = PaneLogic.relativePath(of: folder, under: root) else {
            Logger.shared.info("Editor hand-off: \(folder) is outside the pane's root — leaving the pane where it is")
            return false
        }
        syncManager.focusOn(relativePath: relative, isLeft: true)
        return true
    }
}

/// **Reveal in Browse — Edit's way back out**, from the header's file name and from a rail row's
/// menu, as one act a test can run against a real `FileSyncManager`.
///
/// **The pane breadcrumb's route, computed for BROWSE's view mode** — `navigatePane`, the route the
/// header's location doors take (`EditorLocationDoors`) — and nothing at all when Browse already
/// shows the folder. It used to re-root the pane (`focusOn`) whatever Browse was showing, and that
/// was wrong both ways a pane can be drawn:
/// - **Columns drilled to scope › A › B, revealing a file in B**: a re-root at B — the column stack
///   reset, a history entry pushed, the session's "Ignore in comparison" entries cleared and a
///   refresh sent, to arrive at the folder the pane was already showing.
/// - **Edit in Tree, Browse in Columns with its stack parked deeper**: `focusOn` of the scope the
///   Tree shows is a no-op, so Browse opened on the parked, deeper folder, and the file's owed
///   selection was dropped — the notes' "lands with the file selected" was false.
/// Through `navigatePane`, a folder inside the scope is a browse move of the column stack (no
/// re-scope, no scan), a folder above it or any folder in Tree is a re-root — exactly what the
/// pane's own breadcrumb does for that folder in that mode.
@MainActor
enum EditorRevealInBrowse {

    /// Which of the two doors was used — each writes its own line, so a report of "Reveal in
    /// Browse went somewhere odd" can say which one was pressed.
    enum Door: Equatable {
        /// The header's file name (its right-click menu) — always the open document.
        case header
        /// A Text Files rail row's right-click menu — any row, open or not.
        case railRow

        var name: String {
            switch self {
            case .header: return "the header's file name"
            case .railRow: return "a rail row's menu"
            }
        }
    }

    /// **The whole act, in its order**: the pane moved as Browse draws it (`movePane`), then the
    /// switch to Browse, then the owed selection (TE47).
    ///
    /// **The order is the point.** A debt records the workspace on screen at the moment it is owed
    /// (`ContentView.PaneSelectionDebt`), and a debt from another workspace is dropped. Owed
    /// before the switch it would belong to Edit and be dropped on arrival in Browse — the file not
    /// selected, and the notes' "Reveal in Browse lands with the file selected too" false. Owed
    /// after it, the rule reads Browse's pane, where a selection opens nothing, so a rail row's
    /// file that is not the open document is selected too.
    static func reveal(_ path: String, from door: Door, syncManager: FileSyncManager,
                       sourceRoot: String, drawsColumns: Bool,
                       links: PathBoundary.LinkedFolders = PathBoundary.discoveredLinkedFolders,
                       showBrowse: () -> Void, owe: (String) -> Void, log: (String) -> Void) {
        movePane(to: path, from: door, syncManager: syncManager, sourceRoot: sourceRoot,
                 drawsColumns: drawsColumns, links: links, log: log)
        showBrowse()
        owe(path)
    }

    /// Moves the left pane, as Browse draws it, to the folder of `path` — or leaves it, when Browse
    /// already shows that folder or the folder is outside the left source. One `.info` line either
    /// way, naming the door. The workspace switch and the owed selection are the caller's.
    ///
    /// - Parameters:
    ///   - sourceRoot: the left source's root, `~` expanded.
    ///   - drawsColumns: whether BROWSE draws the left pane as columns (`browseViewMode`), which is
    ///     not necessarily what the pane on screen in Edit draws.
    static func movePane(to path: String, from door: Door, syncManager: FileSyncManager,
                         sourceRoot: String, drawsColumns: Bool,
                         links: PathBoundary.LinkedFolders = PathBoundary.discoveredLinkedFolders,
                         log: (String) -> Void) {
        let folder = (path as NSString).deletingLastPathComponent
        guard !folder.isEmpty, !sourceRoot.isEmpty,
              let target = PaneLogic.relativePath(of: folder, under: sourceRoot, links: links) else {
            log("Reveal in Browse from \(door.name): \(path) is outside the left source — Browse stays where it is")
            return
        }
        guard syncManager.paneLocation(isLeft: true, drawsColumns: drawsColumns) != target else {
            log("Reveal in Browse from \(door.name): \(path) — Browse already shows its folder")
            return
        }
        log("Reveal in Browse from \(door.name): \(path) — Browse moves to \(folder)")
        syncManager.navigatePane(isLeft: true, toCombinedPath: target, drawsColumns: drawsColumns)
    }
}

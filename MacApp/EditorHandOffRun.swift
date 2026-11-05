import Foundation
import Events
import FileExplorer
import Sync
import Dashboard

/// The hand-off: "Open in Edit" from any door in the app, as one act a test can run against a
/// real `FileSyncManager`. `ContentView.handOffToEditor` supplies the window's pieces; this is
/// their order, and the one place each outcome is logged.
///
/// The unsaved-changes question comes first and nothing moves until it is answered, so Cancel
/// means nothing happened. Then the folder is pointed before the workspace switch, so the rail's
/// first render lists the right folder. Open is last, through `load`; the buffer is already
/// settled, so it doesn't ask again. Editing always happens in Edit, so dirty state, undo and saving
/// live in one place.
@MainActor
enum EditorHandOffRun {

    /// What the hand-off does to the left pane — the one thing its doors disagree about.
    enum Pane: Equatable {
        /// Take the left pane to the file's folder, by tab, on whichever source holds it
        /// (`EditorTabFollow`). From Browse and Edit, and for a launch from Finder.
        case followsTheFile
        /// The same, but only on the left pane's own source: from Compare's file panes and
        /// Organize, whose comparison, ignored items and results belong to that source and would be
        /// reset by adopting another. A folder on another source opens the file and leaves the pane.
        case followsOnItsSource
        /// Leave the left pane where it is: from Compare's list of differences, and for a file
        /// opened from Finder while Compare or a guided review is on screen (`ExternalOpen.pane`).
        /// The left pane is half the comparison, and re-rooting it re-runs the scan and clears the
        /// session's "Ignore in comparison" entries (`focusOn` → `clearSessionIgnoredPaths`), so the
        /// row acted from would vanish. The header's location ("in <folder>") moves the pane there.
        case staysPut
    }

    /// How a hand-off ended. Each writes one line: this act's own for the first two, the load's
    /// (`loadIntoEditor`: opened, read-only or refused) for the third. A `.staysPut` hand-off adds a
    /// line before the load naming the decision to leave the pane.
    enum Outcome: Equatable {
        /// The file was open already, and readable: Edit is shown, nothing else moves.
        case alreadyOpen
        /// The settle was answered Cancel: nothing moved at all.
        case cancelled
        /// The file was loaded (opened, read-only, or refused — `load` logs which).
        case opened
    }

    /// Whether opening `path` is anything but a no-op: it is not the open document, or the last
    /// attempt at it was refused. The one guard both the rail's `openInEditor` and every hand-off
    /// ask, so "already open" means one thing. A refused file is let through so a second click can
    /// open it once it is downloaded or trimmed, rather than leaving the stale refusal.
    nonisolated static func opens(_ path: String, openDocument: String?, isRefused: Bool) -> Bool {
        path != openDocument || isRefused
    }

    /// Runs the hand-off.
    ///
    /// - Parameters:
    ///   - paneRoot: the left source's root, `~` expanded — what `focusOn`'s relative path is
    ///     relative to.
    ///   - paneFolder: the folder the left pane will show in Edit (`ContentView.leftPaneFolder(in:
    ///     .editor)`), read only when needed. Edit's, not the screen's: Browse keeps its own view
    ///     mode, so a Columns pane at R › A answers `R/A` while Tree-mode Edit shows `R`, and
    ///     asking the screen would skip a needed re-root.
    ///   - settle: `settleEditorDocument()`; a `false` means nothing happens.
    ///   - endNaming: puts away ⌘N's naming row, so one left open by an earlier ⌘N doesn't sit over
    ///     the document with its field taking the keyboard. `openInEditor` does the same.
    ///   - showEdit: switches to the Edit workspace when it is not already on screen.
    ///   - load: `loadIntoEditor(path:)`, which logs the load's own outcome.
    ///   - followFolder: how the pane goes to the file's folder when it isn't showing it; the app
    ///     passes ``EditorTabFollow``. `nil` uses the in-place re-root of
    ///     ``focusPane(on:root:syncManager:)``, which the order tests drive. Called after the
    ///     settle, so a Cancel moves nothing.
    @discardableResult
    static func run(_ path: String, pane: Pane,
                    syncManager: FileSyncManager, paneRoot: String,
                    openDocument: String?, isRefused: Bool,
                    paneFolder: () -> String,
                    settle: () -> Bool,
                    endNaming: () -> Void,
                    showEdit: () -> Void,
                    load: (String) -> Void,
                    log: (String) -> Void,
                    followFolder: ((String) -> Void)? = nil) -> Outcome {
        guard opens(path, openDocument: openDocument, isRefused: isRefused) else {
            // Already open and readable: just go there, with nothing to settle or move. Logged,
            // so every hand-off leaves one line whichever way it ends.
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
        case .followsTheFile, .followsOnItsSource:
            let folder = (path as NSString).deletingLastPathComponent
            // The left pane, whichever pane the row was in: `editorFolder` reads only the left
            // pane, so moving the right one would disturb a pane Edit never shows while the rail
            // and ⌘N stay on the left. Skipped when already there, since `focusOn` isn't free.
            if !folder.isEmpty, folder != paneFolder() {
                if let followFolder {
                    followFolder(folder)
                } else {
                    focusPane(on: folder, root: paneRoot, syncManager: syncManager)
                }
            }
        case .staysPut:
            // Its own line, so "Open in Edit didn't take me to the folder" finds the decision in the
            // log. Worded as the decision, not the result: it comes before the load, which may yet
            // refuse the file.
            log("Editor hand-off to \(path) leaves the left pane on \(paneFolder()) — it is half of the comparison, so the hand-off does not move it")
        }
        showEdit()
        load(path)
        return .opened
    }

    /// What an in-app "Open in Edit" does to the left pane, pressed in `workspace`. From Browse and
    /// Edit it follows the file by tab, to any source. From Compare, Organize, or during a guided
    /// review, it follows only on the pane's own source (`Pane.followsOnItsSource`). Compare's list
    /// of differences passes `.staysPut` itself.
    nonisolated static func pane(forDoorIn workspace: Workspace, isReviewing: Bool) -> Pane {
        (workspace == .browse || workspace == .editor) && !isReviewing ? .followsTheFile : .followsOnItsSource
    }

    /// Points the left pane at an absolute folder, the way the folder sidebar does (see `run` for
    /// why always the left).
    ///
    /// **`focusOn` takes a path relative to the pane's root**; an absolute path would resolve
    /// against the root and land somewhere real and wrong. A folder outside the root is refused,
    /// not guessed at. Reaching another source is `EditorTabFollow`'s job, by opening a tab.
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

/// Where the file pane goes when Edit opens a file from somewhere else: the tab already showing
/// its folder, or a new one, on whichever source holds it. The tab you were in keeps its place, so
/// three notes from three folders give three tabs, not one tab that moved twice.
///
/// "Already showing" is asked of the active tab's own location (scope and column stack joined),
/// not the folder Edit draws. They differ when Browse is in Columns and Edit in Tree; then the
/// tab is already there and only Edit's view moves, in place.
///
/// Pure, over plain values, so each answer is a test; `ContentView.followFolderInTabs` acts on it.
enum EditorTabFollow {

    /// A tab, as far as this question needs one: which, where its root is, where it is under it,
    /// and on which source.
    struct Tab: Equatable {
        var id: UUID
        var root: String
        var location: String
        var providerId = ""
    }

    enum Decision: Equatable {
        /// The active tab is at this folder; only Edit's view of it differs, so re-root that.
        case inPlace
        /// Another open tab is already at this folder.
        case switchTo(UUID)
        /// No tab is: open one, at this source and path.
        case open(ExternalOpen.SourceRoute)
        /// No configured source holds the folder, or, when keeping its source, the pane's doesn't.
        /// The file still opens; the pane stays.
        case nowhere
    }

    /// - Parameters:
    ///   - keepsSource: `Pane.followsOnItsSource`: only tabs on the active tab's source are
    ///     candidates, and a new tab opens there when the folder is under its root; anywhere else is
    ///     `.nowhere`.
    ///   - relative: the folder under a root, or `nil` when it isn't under it;
    ///     `PaneLogic.relativePath(of:under:)`, which follows iCloud Drive's linked Desktop and
    ///     Documents, injected so the rule runs without a disk.
    ///   - route: the source that owns the folder, for a new tab: `ExternalOpen.route`.
    static func decide(folder: String, active: Tab, others: [Tab], keepsSource: Bool = false,
                       relative: (_ folder: String, _ root: String) -> String?,
                       route: (String) -> ExternalOpen.SourceRoute?) -> Decision {
        func isAt(_ tab: Tab) -> Bool {
            guard !tab.root.isEmpty, let here = relative(folder, tab.root) else { return false }
            return SidebarSourceModel.isSameFolder(here, tab.location)
        }
        if isAt(active) { return .inPlace }
        let candidates = keepsSource ? others.filter { $0.providerId == active.providerId } : others
        if let tab = candidates.first(where: isAt) { return .switchTo(tab.id) }
        guard keepsSource else { return route(folder).map(Decision.open) ?? .nowhere }
        guard !active.root.isEmpty, let here = relative(folder, active.root) else { return .nowhere }
        return .open(ExternalOpen.SourceRoute(providerId: active.providerId, relativePath: here))
    }

    /// Whether Edit still has to be re-rooted at `folder` once the pane's tab is there. Tree lists a
    /// tab's scope, not its column stack, so a tab at the folder by its stack still has Edit listing
    /// the scope, and is re-rooted in place. In Columns Edit shows the stack, so nothing moves.
    ///
    /// - Parameters:
    ///   - editShows: the folder Edit draws now: `ContentView.leftPaneFolder(in: .editor)`.
    ///   - root: the live tab's source root. A folder not under it means the move didn't happen (a
    ///     refused or abandoned tab verb), so there is nothing to re-root.
    static func needsRerootInPlace(folder: String, editShows: String, root: String,
                                   relative: (_ folder: String, _ root: String) -> String?) -> Bool {
        guard !root.isEmpty, let wanted = relative(folder, root) else { return false }
        guard let shown = relative(editShows, root) else { return true }
        return !SidebarSourceModel.isSameFolder(shown, wanted)
    }
}

/// Reveal in Browse, Edit's way back out: from the header's file name, a rail row's menu and
/// other doors, as one act a test can run against a real `FileSyncManager`.
///
/// It takes the pane breadcrumb's route, `navigatePane` (as `EditorLocationDoors` does), computed
/// for Browse's view mode, and does nothing when Browse already shows the folder. A folder inside
/// the scope is a move of the column stack (no re-scope, no scan); a folder above it, or any folder
/// in Tree, is a re-root. A plain `focusOn` re-root would reset the column stack and clear the
/// session's ignores to arrive where the pane already was, or, with Edit in Tree and Browse in
/// Columns, leave Browse on a deeper folder without the file selected.
@MainActor
enum EditorRevealInBrowse {

    /// Which door was used. Each writes its own line, so "Reveal in Browse went somewhere odd" can
    /// say which one was pressed.
    enum Door: Equatable {
        /// The header's file name (its right-click menu) — always the open document.
        case header
        /// A Text Files rail row's right-click menu — any row, open or not.
        case railRow
        /// The PDF tools' banner — the copy a tool just wrote.
        case pdfToolBanner
        /// Save as PDF's banner — the PDFs a run just saved.
        case saveAsPDFBanner
        /// A message's row in Activity's Recent — the files a result named.
        case activity

        var name: String {
            switch self {
            case .header: return "the header's file name"
            case .railRow: return "a rail row's menu"
            case .pdfToolBanner: return "the PDF tools' banner"
            case .saveAsPDFBanner: return "the Save as PDF banner"
            case .activity: return "Activity’s Recent"
            }
        }
    }

    /// The copies a batch's Reveal selects beside the first: those in the first copy's folder, in
    /// the batch's order, each once. The pane shows only that folder, so a copy written elsewhere
    /// can't be selected with it.
    static func companions(of copies: [String]) -> [String] {
        guard let first = copies.first else { return [] }
        let folder = PaneBrowsePath.normalized((first as NSString).deletingLastPathComponent)
        var seen: Set<String> = [first]
        return copies.dropFirst().filter {
            PaneBrowsePath.normalized(($0 as NSString).deletingLastPathComponent) == folder
                && seen.insert($0).inserted
        }
    }

    /// The whole act, in order: the pane moved as Browse draws it (`movePane`), the switch to
    /// Browse, then the owed selection.
    ///
    /// The order matters. A debt records the workspace on screen when it is owed
    /// (`ContentView.PaneSelectionDebt`), and a debt from another workspace is dropped, so owing it
    /// before the switch would leave the file unselected. Owed after, the rule reads Browse's pane,
    /// where a selection opens nothing.
    static func reveal(_ path: String, from door: Door, syncManager: FileSyncManager,
                       sourceRoot: String, drawsColumns: Bool,
                       links: PathBoundary.LinkedFolders = PathBoundary.discoveredLinkedFolders,
                       showBrowse: () -> Void, owe: (String) -> Void, log: (String) -> Void) {
        movePane(to: path, from: door, syncManager: syncManager, sourceRoot: sourceRoot,
                 drawsColumns: drawsColumns, links: links, log: log)
        showBrowse()
        owe(path)
    }

    /// Why Browse can't show `path`, or `nil` when it can: the rail row menu's and the header's
    /// reason for greying Reveal in Browse. Browse shows the left source, so a file outside it
    /// (from Compare's right side, or another source) would be switched to and left unselected.
    static let outsideBrowseReason = "Not in the source Browse shows"

    static func refusal(for path: String, sourceRoot: String,
                        links: PathBoundary.LinkedFolders = PathBoundary.discoveredLinkedFolders) -> String? {
        browseTarget(for: path, sourceRoot: sourceRoot, links: links) == nil ? outsideBrowseReason : nil
    }

    /// The pane target of `path`'s folder in the left source, or `nil` outside it. The reveal and
    /// its greying both read this, so the item is never live where the act goes nowhere.
    static func browseTarget(for path: String, sourceRoot: String,
                             links: PathBoundary.LinkedFolders = PathBoundary.discoveredLinkedFolders) -> String? {
        let folder = (path as NSString).deletingLastPathComponent
        guard !folder.isEmpty, !sourceRoot.isEmpty else { return nil }
        return PaneLogic.relativePath(of: folder, under: sourceRoot, links: links)
    }

    /// Moves the left pane, as Browse draws it, to the folder of `path`, or leaves it when Browse
    /// already shows that folder or it is outside the left source. One `.info` line either way,
    /// naming the door. The workspace switch and the owed selection are the caller's.
    ///
    /// - Parameters:
    ///   - sourceRoot: the left source's root, `~` expanded.
    ///   - drawsColumns: whether Browse draws the left pane as columns (`browseViewMode`), which
    ///     may differ from what Edit's pane draws.
    static func movePane(to path: String, from door: Door, syncManager: FileSyncManager,
                         sourceRoot: String, drawsColumns: Bool,
                         links: PathBoundary.LinkedFolders = PathBoundary.discoveredLinkedFolders,
                         log: (String) -> Void) {
        let folder = (path as NSString).deletingLastPathComponent
        guard let target = browseTarget(for: path, sourceRoot: sourceRoot, links: links) else {
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

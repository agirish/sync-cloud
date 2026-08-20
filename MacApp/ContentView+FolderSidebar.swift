import SwiftUI
import Dashboard
import Events
import Design

/// **Browse's remembered-folders sidebar** — the host half. The column itself is
/// `Dashboard.FolderSidebarView`; what lives here is where its rows come from and what a click does.
extension ContentView {

    /// The provider root the sidebar's two lists are keyed by — Browse's pane is the left one.
    ///
    /// Expanded, matching `FolderJumpStore.key(forRoot:)`, which expands before keying: a folder
    /// source is stored with its `~` intact and the two spellings never met, which is the defect
    /// that comment records.
    /// Whether the column is on screen — the one rule, so `browseLayout`'s `if` and the refresh's
    /// guard cannot come to disagree about it.
    var folderSidebarIsShowing: Bool {
        FolderSidebarModel.isShowing(isBrowse: selectedWorkspace == .browse,
                                     preference: browseSidebarVisible)
    }

    var folderSidebarRoot: String {
        (settings.path(for: leftProviderId) as NSString).expandingTildeInPath
    }

    /// Re-reads both lists and checks them against the disk.
    ///
    /// Called from the four places the answer can change rather than from `body` — see
    /// `folderSidebarRows`' own note for why a `stat` does not belong in a render.
    func refreshFolderSidebarRows() {
        // **Only where there is a sidebar to fill.** The refresh `stat`s the provider root, and the
        // triggers that call it — the left pane moving, and the store publishing — fire on every
        // workspace: sitting in Compare with the sidebar switched off would still have paid a
        // blocking `stat` per pane move, for a column that is not on screen.
        guard folderSidebarIsShowing else { return }
        let root = folderSidebarRoot
        guard !root.isEmpty else {
            folderSidebarRows = []
            return
        }
        let remembered = Self.reachableFolders(
            recents: FolderJumpStore.shared.recentPaths(forRoot: root),
            pinned: FolderJumpStore.shared.pinnedPaths(forRoot: root), under: root)
        // The provider's own name qualifies a top-level folder whose leaf collides with a deeper
        // one — see `FolderSidebarModel.rows(_:rootName:)`.
        folderSidebarRows = FolderSidebarModel.rows(
            remembered,
            rootName: settings.availableProviders.first(where: { $0.id == leftProviderId })?.displayName ?? "")
    }

    /// The column, with the pane's current folder marked.
    var folderSidebar: some View {
        FolderSidebarView(
            rows: folderSidebarRows,
            currentRelativePath: syncManager.paneLocation(
                isLeft: true, drawsColumns: resolvedViewMode(isLeft: true) == .columns),
            accent: glassHue.accentColor,
            onOpen: { row, inNewTab in openFolderSidebarRow(row, inNewTab: inNewTab) },
            onTogglePin: { row in toggleFolderSidebarPin(row) })
    }

    /// A plain click re-scopes the pane; ⌘ opens the folder in a new tab.
    ///
    /// **`focusOn` and not a column drill**, which is the same choice the ⌘K palette makes
    /// (`revealInSourcePane`): a jump from a remembered list is a change of *where the pane is*,
    /// not a step through the stack the breadcrumb is walking. Sending it through the stack would
    /// leave the breadcrumb describing a route the user never took.
    func openFolderSidebarRow(_ row: FolderSidebarRow, inNewTab: Bool) {
        guard FolderSidebarModel.canOpen(row) else { return }
        let root = folderSidebarRoot
        // Not supposed to be reachable — a rootless pane has no rows — but that is exactly the
        // claim a log line is for, and `revealInSourcePane` sets the precedent: a row the user
        // watched do nothing is worse than one that says why in the log.
        guard !root.isEmpty else {
            Logger.shared.warning("Sidebar: nowhere to open \(row.relativePath) — the pane has no source path")
            return
        }
        if inNewTab {
            openInNewTab(absolutePath: (root as NSString).appendingPathComponent(row.relativePath),
                         isLeft: true)
        } else {
            syncManager.focusOn(relativePath: row.relativePath, isLeft: true)
        }
    }

    /// Pins an unpinned row, unpins a pinned one — the same toggle the pane header's jump menu and
    /// the breadcrumb offer, through the same store call, so the three cannot disagree.
    ///
    /// Refreshes immediately rather than waiting for the store's publish: the write is synchronous
    /// and this is the one change the user is watching for.
    func toggleFolderSidebarPin(_ row: FolderSidebarRow) {
        let root = folderSidebarRoot
        guard !root.isEmpty else { return }
        FolderJumpStore.shared.togglePin(root: root, relativePath: row.relativePath, name: row.name)
        refreshFolderSidebarRows()
    }
}

import SwiftUI
import Dashboard
import Design

/// **Browse's remembered-folders sidebar** — the host half. The column itself is
/// `Dashboard.FolderSidebarView`; what lives here is where its rows come from and what a click does.
extension ContentView {

    /// The provider root the sidebar's two lists are keyed by — Browse's pane is the left one.
    ///
    /// Expanded, matching `FolderJumpStore.key(forRoot:)`, which expands before keying: a folder
    /// source is stored with its `~` intact and the two spellings never met, which is the defect
    /// that comment records.
    var folderSidebarRoot: String {
        (settings.path(for: leftProviderId) as NSString).expandingTildeInPath
    }

    /// Re-reads both lists and checks them against the disk.
    ///
    /// Called from the four places the answer can change rather than from `body` — see
    /// `folderSidebarRows`' own note for why a `stat` does not belong in a render.
    func refreshFolderSidebarRows() {
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
        guard !root.isEmpty else { return }
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

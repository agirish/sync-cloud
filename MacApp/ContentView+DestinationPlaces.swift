import Design
import Foundation
import Dashboard
import FileExplorer
import Sync

/// The window sidebar's lists, handed to the Move picker: Favorites, Locations and Recents, in the
/// sidebar's order and from the rows it draws (`folderSidebarRows`, `folderSidebarShortcutRows`,
/// `folderSidebarLocationRows`), so the picker never offers a different list from the one beside
/// it. FileExplorer cannot read Dashboard's stores itself.
extension ContentView {
    func destinationPlaceSections() -> [DestinationPlaceSection] {
        let sources = destinationPlaceSources()
        let favorites = folderSidebarShortcutRows.compactMap { place(for: $0, sources: sources) }
            + FolderSidebarModel.rows(folderSidebarRows, in: .pinned).compactMap { place(for: $0, sources: sources) }
        // The Trash is a place to look, not a place to file into.
        let locations = folderSidebarLocationRows.filter { $0.band != .trash }.compactMap { place(for: $0, sources: sources) }
        let recents = FolderSidebarModel.rows(folderSidebarRows, in: .recents).compactMap { place(for: $0, sources: sources) }
        // Headed as the sidebar heads it: Recents, or Revisited / Frequent in those modes, which
        // show a different list under the same section.
        return DestinationPlaceSection.deduplicated([
            DestinationPlaceSection(title: "Favorites", places: favorites),
            DestinationPlaceSection(title: "Locations", places: locations),
            DestinationPlaceSection(title: folderSidebarRecentsMode.rawValue, places: recents),
        ])
    }

    /// Every source the picker can root at, expanded. A source whose root is the startup disk ("/")
    /// is left out: "/" normalizes to no root at all, and as an owner it would claim every folder
    /// on the Mac and re-root the columns at nothing.
    func destinationPlaceSources() -> [(name: String, root: String)] {
        folderSidebarProviders
            .map { (name: $0.displayName, root: PaneBrowsePath.normalized(($0.rootPath as NSString).expandingTildeInPath)) }
            .filter { !$0.root.isEmpty }
    }

    /// A favorite or recent folder: its root is the source it was visited in, joined through
    /// `PathBoundary` so an iCloud folder under Documents comes back in `~/Documents` spelling.
    private func place(for row: FolderSidebarRow, sources: [(name: String, root: String)]) -> DestinationPlace? {
        guard let source = sources.first(where: { FolderJumpStore.key(forRoot: $0.root) == row.root }) else { return nil }
        return DestinationPlace(name: row.name,
                                path: PathBoundary.join(root: source.root, relative: row.relativePath),
                                root: source.root, rootName: source.name,
                                detail: row.detail ?? row.sourceName, symbol: "folder")
    }

    /// A location or a standard place. It browses under the source that holds it most closely — its
    /// own, when it is a source's root (a folder source at `~/Documents/Clients` is Clients, not
    /// iCloud through the link) — or as its own root when no source holds it.
    private func place(for row: SidebarSourceRow, sources: [(name: String, root: String)]) -> DestinationPlace? {
        let path = PaneBrowsePath.normalized(row.absolutePath)
        guard !path.isEmpty, row.isAvailable else { return nil }
        let owner = DestinationPlace.closestOwner(of: path, among: sources)
        return DestinationPlace(name: row.name, path: path,
                                root: owner?.root ?? path, rootName: owner?.name ?? row.name,
                                detail: nil, symbol: row.symbol)
    }

    /// The source a move's destination belongs to, for its Recent Moves. The picker reaches every
    /// source, and `DestinationRecents.record` keeps only folders inside the root it is given, so a
    /// Dropbox destination filed under the iCloud item's root would be dropped.
    func destinationRecentsRoot(for destination: String, requestRoot: String) -> String {
        DestinationPlace.closestOwner(of: PaneBrowsePath.normalized(destination), among: destinationPlaceSources())?.root
            ?? requestRoot
    }
}

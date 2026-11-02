import Foundation
import Dashboard
import FileExplorer
import Sync

/// **The window sidebar's lists, handed to the Move picker** — Favorites, Recents, Locations, in
/// the sidebar's own order and from the very rows it draws (`folderSidebarRows`,
/// `folderSidebarShortcutRows`, `folderSidebarLocationRows`), so the picker never offers a
/// different list from the one beside it. FileExplorer cannot read Dashboard's stores itself.
extension ContentView {
    func destinationPlaceSections() -> [DestinationPlaceSection] {
        let providers = folderSidebarProviders
        let favorites = folderSidebarShortcutRows.compactMap(place(for:))
            + FolderSidebarModel.rows(folderSidebarRows, in: .pinned).map { place(for: $0, providers: providers) }
        let recents = FolderSidebarModel.rows(folderSidebarRows, in: .recents).map { place(for: $0, providers: providers) }
        // The Trash is a place to look, not a place to file into.
        let locations = folderSidebarLocationRows.filter { $0.band != .trash }.compactMap(place(for:))
        return [DestinationPlaceSection(title: "Favorites", places: favorites),
                DestinationPlaceSection(title: "Recents", places: recents),
                DestinationPlaceSection(title: "Locations", places: locations)]
            .filter { !$0.places.isEmpty }
    }

    /// A favorite or recent folder: its root is the source it was visited in, joined through
    /// `PathBoundary` so an iCloud folder under Documents comes back in `~/Documents` spelling.
    private func place(for row: FolderSidebarRow, providers: [CloudProvider]) -> DestinationPlace {
        let provider = providers.first {
            FolderJumpStore.key(forRoot: ($0.rootPath as NSString).expandingTildeInPath) == row.root
        }
        let root = provider.map { ($0.rootPath as NSString).expandingTildeInPath } ?? row.root
        return DestinationPlace(name: row.name,
                                path: PathBoundary.join(root: root, relative: row.relativePath),
                                root: root,
                                rootName: provider?.displayName ?? (root as NSString).lastPathComponent,
                                detail: row.detail ?? row.sourceName,
                                symbol: "folder")
    }

    /// A location or a standard place. It browses under the source that holds it (Documents under
    /// iCloud), or as its own root when no source does. The startup disk is left out: its root,
    /// "/", is no root the picker's columns can draw.
    private func place(for row: SidebarSourceRow) -> DestinationPlace? {
        let path = PaneBrowsePath.normalized(row.absolutePath)
        guard !path.isEmpty, row.isAvailable else { return nil }
        let owner = folderSidebarProviders
            .map { (name: $0.displayName, root: ($0.rootPath as NSString).expandingTildeInPath) }
            .filter { PathBoundary.relativize(path, under: $0.root) != nil }
            .max { $0.root.count < $1.root.count }
        return DestinationPlace(name: row.name, path: path,
                                root: owner?.root ?? path,
                                rootName: owner?.name ?? row.name,
                                detail: nil,
                                symbol: row.symbol)
    }
}

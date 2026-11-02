import Foundation
import Sync

/// One folder the Move picker's left column offers: a sidebar favorite, a recent, a location, or
/// one of the Here rows above the item.
///
/// Carries the root it browses under, because the sidebar's lists span every source: a Dropbox
/// recent picked from an iCloud item's picker re-roots the columns at Dropbox, and its breadcrumbs
/// read from "Dropbox", not from `/Users`.
public struct DestinationPlace: Identifiable, Equatable, Sendable {
    public let name: String
    /// Absolute path, in the spelling the panes use (`~/Documents/…` for iCloud's Documents).
    public let path: String
    /// The source root the columns browse when this place is picked.
    public let root: String
    /// That root's display name — the first breadcrumb.
    public let rootName: String
    /// A second line: where it is, or what it is ("up one").
    public let detail: String?
    /// SF Symbol name.
    public let symbol: String

    public var id: String { path }

    public init(name: String, path: String, root: String, rootName: String, detail: String? = nil,
                symbol: String = "folder") {
        self.name = name
        self.path = PaneBrowsePath.normalized(path)
        self.root = PaneBrowsePath.normalized(root)
        self.rootName = rootName
        self.detail = detail
        self.symbol = symbol
    }
}

/// One headed group of places — the sidebar's Favorites, Recents and Locations, in its order.
public struct DestinationPlaceSection: Identifiable, Equatable, Sendable {
    public let title: String
    public let places: [DestinationPlace]
    public var id: String { title }

    public init(title: String, places: [DestinationPlace]) {
        self.title = title
        self.places = places
    }
}

public extension DestinationPicker {
    /// **The Here rows: the item's own folder, then up one, then up two**, stopping at the root.
    ///
    /// Most moves are short — into a folder beside the item, or up a level — so the folders the
    /// item sits in lead the column. Walked by relative path and re-joined through `PathBoundary`,
    /// not by deleting path components: above `~/Documents` the real parent is `~`, which is not
    /// in iCloud Drive at all; through the link it is iCloud Drive itself.
    nonisolated static func hereRows(itemFolder: String, root: String, rootName: String,
                         links: PathBoundary.LinkedFolders = PathBoundary.discoveredLinkedFolders) -> [DestinationPlace] {
        let normalizedRoot = PaneBrowsePath.normalized(root)
        guard let relative = PathBoundary.relativize(PaneBrowsePath.normalized(itemFolder),
                                                     under: normalizedRoot, links: links) else { return [] }
        var components = relative.split(separator: "/").map(String.init)
        let details = ["now here", "up one", "up two"]
        var rows: [DestinationPlace] = []
        while rows.count < details.count {
            let path = PathBoundary.join(root: normalizedRoot, relative: components.joined(separator: "/"), links: links)
            let name = components.last ?? rootName
            rows.append(DestinationPlace(name: name, path: path, root: normalizedRoot, rootName: rootName,
                                         detail: details[rows.count],
                                         symbol: rows.isEmpty ? "smallcircle.filled.circle" : "arrow.up"))
            guard !components.isEmpty else { break }
            components.removeLast()
        }
        return rows
    }
}

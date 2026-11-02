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

    /// **The source that holds `path` most closely**: the one it is the root of, else the one it
    /// sits fewest levels inside. Not the longest root string — iCloud's container path is long,
    /// and through its Documents link it "holds" a folder source at `~/Documents/Clients` too, which
    /// re-rooted that source's own row at iCloud.
    public static func closestOwner(of path: String, among sources: [(name: String, root: String)],
                                    links: PathBoundary.LinkedFolders = PathBoundary.discoveredLinkedFolders)
        -> (name: String, root: String)? {
        sources
            .compactMap { source -> (source: (name: String, root: String), depth: Int)? in
                guard !source.root.isEmpty,
                      let relative = PathBoundary.relativize(path, under: source.root, links: links) else { return nil }
                return (source, relative.split(separator: "/").count)
            }
            .min { $0.depth < $1.depth }?
            .source
    }
}

/// One headed group of places — the sidebar's Favorites, Locations and Recents, in its order.
public struct DestinationPlaceSection: Identifiable, Equatable, Sendable {
    public let title: String
    public let places: [DestinationPlace]
    public var id: String { title }

    public init(title: String, places: [DestinationPlace]) {
        self.title = title
        self.places = places
    }

    /// Each folder once, where it first appears, and empty sections dropped — as the sidebar drops
    /// a recent already shown under Favorites or Locations. Two rows with one path were two rows
    /// with one id: the rail's highlight settled on whichever registered last.
    public static func deduplicated(_ sections: [DestinationPlaceSection],
                                    excluding taken: Set<String> = []) -> [DestinationPlaceSection] {
        var seen = taken
        return sections.compactMap { section in
            let places = section.places.filter { seen.insert($0.path).inserted }
            return places.isEmpty ? nil : DestinationPlaceSection(title: section.title, places: places)
        }
    }
}

public extension DestinationPicker {
    /// **The Here rows: the item's own folder, then up one, then up two — and the source's root**,
    /// always last, so the root keeps a row of its own wherever the item sits.
    ///
    /// Most moves are short — into a folder beside the item, or up a level — so the folders the
    /// item sits in lead the column. Walked by relative path and re-joined through `PathBoundary`,
    /// not by deleting path components: above `~/Documents` the real parent is `~`, which is not
    /// in iCloud Drive at all; through the link it is iCloud Drive itself.
    ///
    /// When the items are NOT in `itemFolder` (a loose file filed in from Downloads opens on the
    /// File Into root; a selection can span folders) there is no "now here" to claim: the root row
    /// alone.
    nonisolated static func hereRows(itemFolder: String, root: String, rootName: String, itemsAreHere: Bool = true,
                                     links: PathBoundary.LinkedFolders = PathBoundary.discoveredLinkedFolders) -> [DestinationPlace] {
        let normalizedRoot = PaneBrowsePath.normalized(root)
        guard !normalizedRoot.isEmpty else { return [] }
        let rootRow = DestinationPlace(name: rootName, path: normalizedRoot, root: normalizedRoot, rootName: rootName,
                                       detail: itemsAreHere ? "top" : nil, symbol: "externaldrive.connected.to.line.below")
        guard itemsAreHere,
              let relative = PathBoundary.relativize(PaneBrowsePath.normalized(itemFolder),
                                                     under: normalizedRoot, links: links) else { return [rootRow] }
        var components = relative.split(separator: "/").map(String.init)
        let details = ["now here", "up one", "up two"]
        var rows: [DestinationPlace] = []
        while rows.count < details.count, !components.isEmpty {
            let path = PathBoundary.join(root: normalizedRoot, relative: components.joined(separator: "/"), links: links)
            rows.append(DestinationPlace(name: components.last ?? rootName, path: path, root: normalizedRoot,
                                         rootName: rootName, detail: details[rows.count],
                                         symbol: rows.isEmpty ? "smallcircle.filled.circle" : "arrow.up"))
            components.removeLast()
        }
        // The root, last — with the detail of its rung when it is one of the three.
        let rung = rows.count < details.count ? details[rows.count] : "top"
        rows.append(DestinationPlace(name: rootName, path: normalizedRoot, root: normalizedRoot, rootName: rootName,
                                     detail: rung, symbol: rows.isEmpty ? "smallcircle.filled.circle" : "externaldrive.connected.to.line.below"))
        return rows
    }
}

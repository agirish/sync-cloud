import Foundation

/// Absolute directory path → the rows a Columns column lists for it, built once per publish.
///
/// A column needs the children of an arbitrary folder, by path. `PaneRow.children` can answer by
/// recursion, but a column stack asking per column per render would walk the tree repeatedly on
/// the main thread, which can freeze the app (see `PaneTree`). This flattens the walk to one pass
/// per publish, so a column costs a dictionary lookup, as `DiffStatusIndex` does for badges.
///
/// Equality follows `PaneTree`'s: `version` is the pane's publish counter, bumped by the published
/// property's own `didSet` on every assignment, so equal `(side, version)` means the same published
/// array by construction, not a hash that could collide. `treeRoot` joins them because the root's
/// own children are keyed here too, and re-rooting changes what this index means without
/// necessarily changing the tree's identity.
public struct PaneChildrenIndex: Equatable, Sendable {
    /// Which pane's counter `version` came from. See `PaneTree.Side`.
    public let side: PaneTree.Side
    /// The pane's publish counter at the moment the index was built.
    public let version: Int
    /// Absolute path of the folder whose children are the pane's top-level rows.
    public let treeRoot: String

    /// Every directory in the tree → its child rows. Directories with no children map to `[]`, so
    /// membership answers `isDirectory` without a second map. Files are absent.
    private let childrenByPath: [String: [PaneRow]]
    /// Every directory the walk reported but did not read: a shallow-pass cap, a cycle guard, or a
    /// directory the OS refused.
    ///
    /// Kept beside the children because they can't express it: `childrenByPath` maps an empty
    /// directory and an unwalked one both to `[]`, and a column reading only that map would say
    /// "Empty", a claim the walk never made. `DestinationFolderListing` carries the same fact for
    /// the destination picker.
    private let unexploredPaths: Set<String>

    /// Builds the index for one published tree.
    ///
    /// - Parameters:
    ///   - tree: The pane's stamped tree.
    ///   - treeRoot: Absolute path of the folder whose children are `tree.rows`: the pane's
    ///     `currentPath`, the provider root joined with its focused relative path.
    ///   - links: The table a column composes its first component through: the machine's own
    ///     everywhere but a test, and the one `PaneBrowsePath` reads by default. The index and the
    ///     columns must use the same table, or they disagree about a linked folder's path.
    public init(tree: PaneTree, treeRoot: String,
                links: PathBoundary.LinkedFolders = PathBoundary.discoveredLinkedFolders) {
        self.side = tree.side
        self.version = tree.version
        // Native, so the root's own rows are checked against bytes it holds rather than ones a bridged
        // string materializes per row (`FileSyncManager.nativePath`); the bytes are the same.
        self.treeRoot = String(decoding: Array(PaneBrowsePath.normalized(treeRoot).utf8), as: UTF8.self)

        var map: [String: [PaneRow]] = [:]
        var unexplored: Set<String> = []
        map[self.treeRoot] = tree.rows
        Self.index(tree.rows, in: self.treeRoot,
                   linked: PathBoundary.linkedFolders(atRoot: self.treeRoot, in: links),
                   into: &map, unexplored: &unexplored)
        childrenByPath = map
        unexploredPaths = unexplored
    }

    /// Keys every directory by the path a column composes for it (`PaneBrowsePath.step`, from the
    /// tree root down through each row's name), the only path anything asks with.
    ///
    /// Not by the row's id: the walk doesn't always spell a node as its parent plus its name.
    /// Below a folder symlink, and under a root reached through one (`/var/…` lists
    /// `/private/var/…`), `contentsOfDirectory(at:)` hands back where the link leads; above iCloud
    /// Drive's container, the linked `Documents` is listed as `~/Documents`. Keyed by id, those
    /// columns would ask for paths the index never heard of, and the next republish would prune the
    /// stack. And a folder the tree holds twice (`~/Dropbox` and where it leads) carries one id on
    /// both routes, so keyed by id one route's column would list the other's copy.
    ///
    /// Where the walk did spell the row as parent plus name, almost everywhere, the key is the
    /// row's id as it is: no allocation, and a string the walk already made native
    /// (`FileSyncManager.nativePath`).
    ///
    /// Directories are recognised from `info.isDirectory`, not `children != nil`: the projection
    /// keeps `nil` for a leaf and `[]` for an empty directory, and a directory that arrived without
    /// children must still read as one, or `pruned` would treat it as deleted and walk the user back
    /// out of a folder that exists.
    private static func index(_ rows: [PaneRow], in directory: String, linked: [String: String],
                              into map: inout [String: [PaneRow]], unexplored: inout Set<String>) {
        for row in rows {
            guard row.info.isDirectory || row.children != nil else { continue }
            let path = columnPath(of: row.node.id, in: directory, linked: linked)
            if row.info.isDirectory {
                map[path] = row.children ?? []
                if row.node.isUnexplored == true { unexplored.insert(path) }
            }
            if let children = row.children {
                index(children, in: path, linked: [:], into: &map, unexplored: &unexplored)
            }
        }
    }

    /// The path a column composes for the row `id` lists in `directory` (`PaneBrowsePath.step`),
    /// answered with `id` itself when the walk spelled the row that way, byte for byte.
    ///
    /// `linked` is non-empty only for the tree root's own rows, which is where `step` reads it.
    private static func columnPath(of id: String, in directory: String, linked: [String: String]) -> String {
        if linked.isEmpty || linked[String(TreeShape.leaf(of: id))] == nil, continues(id, directory) {
            return id
        }
        return PaneBrowsePath.step(from: directory, into: TreeShape.leaf(of: id), atRoot: !linked.isEmpty,
                                   linked: linked)
    }

    /// Whether `id` is `directory`, a separator and one name, byte for byte: `step`'s composition,
    /// checked without making it.
    ///
    /// On the bytes in place, with one `memcmp`: this runs for every directory on every publish,
    /// and the generic `utf8.starts(with:)` doubles the whole build (measured in Release).
    /// Strings without contiguous UTF-8 (a bridged one) take
    /// that generic comparison, which says the same.
    private static func continues(_ id: String, _ directory: String) -> Bool {
        let slash = UInt8(ascii: "/")
        let answer = id.utf8.withContiguousStorageIfAvailable { idBytes in
            directory.utf8.withContiguousStorageIfAvailable { directoryBytes -> Bool in
                let count = directoryBytes.count
                guard idBytes.count > count + 1, idBytes[count] == slash,
                      !idBytes[(count + 1)...].contains(slash) else { return false }
                guard let idBase = idBytes.baseAddress, let directoryBase = directoryBytes.baseAddress else {
                    return count == 0
                }
                return memcmp(idBase, directoryBase, count) == 0
            }
        }
        if let answer = answer ?? nil { return answer }
        let count = directory.utf8.count
        let name = TreeShape.leaf(of: id)
        return id.utf8.count == count + 1 + name.utf8.count && id.utf8.starts(with: directory.utf8)
    }

    /// Whether the walk reported `path` as a directory without reading what is in it.
    ///
    /// False for anything this index has never heard of, which is the safe direction: an unknown
    /// path is not a claim that a folder went unread.
    public func isUnexplored(atPath path: String) -> Bool {
        unexploredPaths.contains(PaneBrowsePath.normalized(path))
    }

    /// Rows for the column rooted at `path`; `nil` when the path is not a directory in this tree.
    /// The tree root itself answers with the pane's top-level rows.
    public func children(atPath path: String) -> [PaneRow]? {
        childrenByPath[PaneBrowsePath.normalized(path)]
    }

    /// Whether `path` is a directory in this tree. The tree root counts.
    public func isDirectory(atPath path: String) -> Bool {
        childrenByPath[PaneBrowsePath.normalized(path)] != nil
    }

    /// An index over nothing, for previews and for a pane with no tree yet.
    public static func empty(side: PaneTree.Side) -> PaneChildrenIndex {
        PaneChildrenIndex(tree: PaneTree(side: side, version: 0, nodes: [], rows: []), treeRoot: "")
    }

    /// Deliberately ignores the map: see the note on the type.
    public static func == (lhs: PaneChildrenIndex, rhs: PaneChildrenIndex) -> Bool {
        lhs.side == rhs.side && lhs.version == rhs.version && lhs.treeRoot == rhs.treeRoot
    }
}

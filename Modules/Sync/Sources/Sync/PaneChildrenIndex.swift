import Foundation

/// Absolute directory path → the rows a Columns column lists for it, built once per publish.
///
/// A column needs one thing the tree view never did: the children of an arbitrary folder, by path.
/// `PaneRow.children` can answer that by recursion, but a column stack asking it per column per
/// render walks the tree repeatedly on the main thread — the exact shape that put 16.9 s of
/// `FileNode.__derived_struct_equals` on the main thread and froze the app for 17 seconds (see
/// `PaneTree`). This flattens the walk to one pass per publish, so a column costs a dictionary
/// lookup, and mirrors what `DiffStatusIndex` already does for badge status.
///
/// Equality follows `PaneTree`'s: `version` is the pane's publish counter, bumped by the published
/// property's own `didSet` on every assignment, so equal `(side, version)` means the same published
/// array by construction — not a hash that could collide. `treeRoot` joins them because the root's
/// own children are keyed here too, and re-rooting the pane changes what this index means without
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
    /// Every directory the walk reported but did not read — a shallow-pass cap, a cycle guard, or a
    /// directory the OS refused.
    ///
    /// **Kept beside the children because the children cannot express it.** `childrenByPath` maps a
    /// directory with nothing in it to `[]` and a directory nobody has walked yet to `[]` as well,
    /// so a column reading only that map has to guess — and it guessed "Empty", which is a claim the
    /// walk never made. `FileSyncManager` logs the same distinction from the other side ("shown as
    /// unexplored, not empty"), and `DestinationFolderListing` already carries it for the
    /// destination picker's columns; this is the pane's half of the same fact.
    private let unexploredPaths: Set<String>

    /// Builds the index for one published tree.
    ///
    /// - Parameters:
    ///   - tree: The pane's stamped tree.
    ///   - treeRoot: Absolute path of the folder whose children are `tree.rows` — the pane's
    ///     `currentPath`, i.e. provider root joined with its focused relative path.
    public init(tree: PaneTree, treeRoot: String) {
        self.side = tree.side
        self.version = tree.version
        self.treeRoot = PaneBrowsePath.normalized(treeRoot)

        var map: [String: [PaneRow]] = [:]
        var unexplored: Set<String> = []
        map[self.treeRoot] = tree.rows
        Self.index(tree.rows, into: &map, unexplored: &unexplored)
        childrenByPath = map
        unexploredPaths = unexplored
    }

    /// Keys every directory by its own absolute path.
    ///
    /// Directories are recognised from `info.isDirectory`, not from `children != nil`: the
    /// projection preserves `nil` for a leaf and `[]` for an empty directory, and a directory that
    /// somehow arrived without children must still read as a directory — otherwise `pruned` would
    /// treat it as deleted and silently walk the user back out of a folder that exists.
    private static func index(_ rows: [PaneRow], into map: inout [String: [PaneRow]],
                              unexplored: inout Set<String>) {
        for row in rows {
            if row.info.isDirectory {
                map[row.node.id] = row.children ?? []
                if row.node.isUnexplored == true { unexplored.insert(row.node.id) }
            }
            if let children = row.children {
                index(children, into: &map, unexplored: &unexplored)
            }
        }
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

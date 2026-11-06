import Foundation

/// A published pane tree paired with the stamp of the publish that produced it, plus the
/// cheap-to-compare row projection the pane's outline renders.
///
/// `FileNode` has a compiler-derived `==` and stores `children: [FileNode]?`, so comparing two
/// nodes recurses through their whole subtrees, comparing strings at every node. A pane can hold
/// ~40,000 nodes, so anything holding a `FileNode` graph in a SwiftUI view pays an O(subtree)
/// compare on the main thread whenever SwiftUI asks "did this change?", and a changed tree (the
/// refresh after a copy) can freeze the app for seconds in this chain:
///
///     AGGraphSetOutputValue → AG::LayoutDescriptor::compare → AGDispatchEquatable
///       → Array<FileNode>.== → FileNode.__derived_struct_equals → …recursing
///
/// (`Array.==` short-circuits on shared copy-on-write storage, so an unchanged tree costs nothing.)
///
/// So nothing that reaches a view stores a raw `FileNode` graph:
///   - `PaneTree` (this type): the whole tree, compared by stamp alone.
///   - `PaneRow`: one node plus its children, compared by (stamp, path) alone. This is what
///     `OutlineGroup` iterates; handing it the raw `[FileNode]` would put the deep compare back.
///   - `FileRowInfo`: the five scalars a row renders, with no `children` at all.
///
/// Comparing only the stamp is exact: `version` is the pane's `publishedLeftTreeVersion` /
/// `publishedRightTreeVersion`, which the published property's own `didSet` bumps on every
/// assignment, so equal `side` and `version` mean the same published array by construction.
/// Unlike a content hash, it can't collide. The converse (equal contents, new stamp) only
/// re-renders needlessly, and `applyFilters()` assigns only when the tree changed.
///
/// **Always build these through `FileSyncManager.leftPaneTree` / `.rightPaneTree`**: a
/// hand-picked `version` would silently defeat the invariant above.
public struct PaneTree: Equatable, Sendable {
    /// Which pane's counter `version` came from. The panes keep independent counters (so an
    /// overlapping load of one can't invalidate the other's verdict; see `applyFilters`), which
    /// often sit at the same integer, so a bare version means something only with its side.
    public enum Side: Sendable, Equatable {
        case left
        case right

        /// The other pane. Used wherever a per-side fact has to travel with a pane swap.
        public var opposite: Side { self == .left ? .right : .left }
    }

    public let side: Side
    /// The pane's publish counter at the moment `nodes` was read. See the type's note on why
    /// this must come from the manager rather than being chosen by the caller.
    public let version: Int
    /// The published tree itself. Prefer the accessors below, and `rows` for anything that
    /// reaches a view: handing this array to a SwiftUI collection brings the deep compare back.
    public let nodes: [FileNode]
    /// `nodes` projected into stamped, cheap-to-compare rows. This is what the pane's
    /// `OutlineGroup` iterates. Built once per publish and cached by the manager.
    public let rows: [PaneRow]

    /// Full initializer, used by `FileSyncManager` so the row projection can be cached across
    /// accesses rather than rebuilt per render.
    public init(side: Side, version: Int, nodes: [FileNode], rows: [PaneRow]) {
        self.side = side
        self.version = version
        self.nodes = nodes
        self.rows = rows
    }

    /// Convenience for tests and previews: derives the row projection on the spot, walking the
    /// whole tree. Production code goes through the manager's cached accessors.
    public init(side: Side, version: Int, nodes: [FileNode]) {
        self.init(side: side, version: version, nodes: nodes,
                  rows: PaneRow.project(nodes, side: side, version: version))
    }

    /// Deliberately ignores `nodes` and `rows`: the whole point of the type. See the note above
    /// for why the stamp is an exact stand-in for the contents.
    public static func == (lhs: PaneTree, rhs: PaneTree) -> Bool {
        lhs.side == rhs.side && lhs.version == rhs.version
    }

    // MARK: - Convenience so callers need not reach for `nodes`

    public var isEmpty: Bool { nodes.isEmpty }

    /// Resolves selected paths against this tree, pruned of nodes already covered by a selected
    /// ancestor — the same call every transfer entry point makes.
    public func selectedNodes(at paths: Set<String>) -> [FileNode] {
        nodes.findNodes(at: paths).pruneNestedNodes()
    }
}

/// One node of a published pane tree, tagged with that tree's stamp, carrying its children so a
/// SwiftUI `OutlineGroup` can walk it, but comparing as `(side, version, path)` so equality never
/// walks it.
///
/// Equality is exact for the same reason `PaneTree`'s is: within one published tree a path
/// identifies exactly one node with fixed contents, and changing those contents requires a
/// republish, which advances the stamp. So equal stamp + equal path ⇒ equal node, without ever
/// looking at `children`.
public struct PaneRow: Identifiable, Equatable, Sendable {
    public let side: PaneTree.Side
    public let version: Int
    /// The underlying node. Consumers that must call into the file layer (the row context menu's
    /// delegate handlers all take `FileNode`) use this; rendering uses `info`.
    public let node: FileNode
    /// The flat scalars a row renders, so `FileRowView` need not hold a `FileNode` at all.
    public let info: FileRowInfo
    /// `nil` for a leaf, `[]` for an empty directory: `OutlineGroup` decides the disclosure
    /// triangle from it, so the projection must keep it exactly as `FileNode.children` had it.
    public let children: [PaneRow]?

    /// Matches `FileNode.id` (the absolute path), so outline identity is unchanged by the
    /// projection and rows keep their expansion state across a republish.
    public var id: String { node.id }

    public init(side: PaneTree.Side, version: Int, node: FileNode, children: [PaneRow]?) {
        self.side = side
        self.version = version
        self.node = node
        self.info = FileRowInfo(node)
        self.children = children
    }

    /// Deliberately ignores everything but the path: see the note above.
    public static func == (lhs: PaneRow, rhs: PaneRow) -> Bool {
        lhs.side == rhs.side && lhs.version == rhs.version && lhs.node.id == rhs.node.id
    }

    /// Projects a published tree. `nil`/`[]` children are preserved exactly (see `children`).
    public static func project(_ nodes: [FileNode], side: PaneTree.Side, version: Int) -> [PaneRow] {
        nodes.map { node in
            PaneRow(side: side, version: version, node: node,
                    children: node.children.map { project($0, side: side, version: version) })
        }
    }
}

/// The scalars one pane row renders. Deliberately flat: a row needs none of `FileNode`'s graph,
/// and holding the node would keep a folder's whole subtree reachable from the view, where one
/// added field or relaxed `==` would silently bring back the recursive comparison.
public struct FileRowInfo: Equatable, Sendable {
    public let id: String
    public let name: String
    public let isDirectory: Bool
    public let modificationDate: Date?
    public let fileSize: Int?

    public init(_ node: FileNode) {
        self.id = node.id
        self.name = node.name
        self.isDirectory = node.isDirectory
        self.modificationDate = node.modificationDate
        self.fileSize = node.fileSize
    }
}

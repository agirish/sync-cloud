import Foundation

/// A published pane tree paired with the stamp of the publish that produced it, plus the
/// cheap-to-compare row projection the pane's outline renders.
///
/// **The problem.** `FileNode` is `Hashable` with a compiler-derived `==`, and it stores
/// `children: [FileNode]?`, so comparing two nodes recurses through their entire subtrees,
/// comparing a `String` id, name and kind at every one. A pane routinely holds ~40,000 nodes.
/// Anything holding a `FileNode` (or an array of them) in a SwiftUI view therefore pays an
/// O(subtree) comparison on the main thread every time SwiftUI asks "did this change?":
///
///     AGGraphSetOutputValue → AG::LayoutDescriptor::compare → AGDispatchEquatable
///       → Array<FileNode>.== → FileNode.__derived_struct_equals → …recursing
///
/// A `sample` of a real post-copy freeze put 12,745 ms of main-thread time in exactly that chain,
/// with `_stringCompareSlow` as the hottest leaf and the main thread 100% busy for 16.9 s.
///
/// Note `Array.==` short-circuits when both sides share copy-on-write storage, so an UNCHANGED
/// tree costs nothing. The full walk lands only when the tree genuinely changed — which is
/// precisely the post-copy refresh this was hurting.
///
/// **The fix.** Nothing that reaches a view stores a raw `FileNode` graph:
///   - `PaneTree` (this type) — the whole tree, compared by stamp alone.
///   - `PaneRow` — one node plus its children, compared by (stamp, path) alone. This is what
///     `OutlineGroup` iterates; handing it the raw `[FileNode]` put the deep compare straight
///     back into the view graph even with `PaneTree` in place, which is exactly what happened on
///     the first attempt and left 2,869 ms behind.
///   - `FileRowInfo` — the five scalars a row actually renders, with no `children` at all.
///
/// **Why comparing only the stamp is exact, not an approximation.** `version` is the pane's
/// `publishedLeftTreeVersion` / `publishedRightTreeVersion`, which the published property's own
/// `didSet` bumps on *every* assignment. Two values carrying the same `side` and `version` are
/// therefore the same published array by construction — there is no way to reach a second,
/// different tree without the counter having moved. Unlike a content hash, this cannot collide.
///
/// The converse (equal contents, different stamp) merely re-renders when it need not have, and
/// `applyFilters()` assigns only when the tree genuinely changed, so it does not arise in practice.
///
/// Always build these through `FileSyncManager.leftPaneTree` / `.rightPaneTree`; a hand-picked
/// `version` would silently defeat the invariant above.
public struct PaneTree: Equatable, Sendable {
    /// Which pane's counter `version` came from.
    ///
    /// This is **not** defensive decoration: the two panes keep genuinely independent counters
    /// (so an overlapping load of one pane cannot invalidate the other's verdict — see
    /// `applyFilters`), and `SortConfigRaceTests` pins them as per-pane *counts*. Both panes
    /// therefore sit at the same integer most of the time, and a bare version is only meaningful
    /// alongside the side that minted it.
    public enum Side: Sendable {
        case left
        case right
    }

    public let side: Side
    /// The pane's publish counter at the moment `nodes` was read. See the type's note on why
    /// this must come from the manager rather than being chosen by the caller.
    public let version: Int
    /// The published tree itself. Prefer the accessors below, and prefer `rows` for anything that
    /// reaches a view — handing this array to a SwiftUI collection re-creates the original bug.
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

    /// Convenience for tests and previews: derives the row projection on the spot. Production
    /// code goes through the manager's cached accessors — this walks the whole tree.
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
/// SwiftUI `OutlineGroup` can walk it — but comparing as `(side, version, path)` so walking it is
/// never what equality costs.
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
    /// `nil` for a leaf, `[]` for an empty directory — the distinction `OutlineGroup` uses to
    /// decide whether a row gets a disclosure triangle, so the projection must preserve it
    /// exactly as `FileNode.children` expressed it.
    public let children: [PaneRow]?

    /// Matches `FileNode.id` (the absolute path), so outline identity is unchanged by the
    /// projection — rows keep their expansion state across a republish exactly as before.
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
/// and holding the node itself kept a folder's whole subtree reachable from the view — one field
/// added later, or one relaxed `==`, and the recursive comparison would silently return.
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

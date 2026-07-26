import Foundation

/// A published pane tree paired with the stamp of the publish that produced it.
///
/// This exists purely to keep SwiftUI from deep-comparing a pane tree on the main thread.
/// `FileNode` is `Hashable` with a compiler-derived `==`, and it stores `children: [FileNode]?`,
/// so comparing two nodes recurses through their entire subtrees, comparing a `String` id, name
/// and kind at every one. A pane routinely holds ~40,000 nodes.
///
/// That cost is unavoidable in `applyFilters()`, which deliberately pays it on a detached task
/// (see its `publishedLeftTreeVersion` comment) — but SwiftUI pays it AGAIN, on the main thread,
/// every time a view whose stored properties include a tree has its body output compared:
///
///     AGGraphSetOutputValue → AG::LayoutDescriptor::compare → AGDispatchEquatable
///       → Array<FileNode>.== → FileNode.__derived_struct_equals → …recursing
///
/// A `sample` of a copy that changed the right pane put 10,852 of 22,710 main-thread samples in
/// exactly that chain, with the main thread 100% busy for 16.9 s and `_stringCompareSlow` as the
/// hottest leaf. Boxing the tree here turns that comparison into one `Int` compare.
///
/// **Why comparing only the stamp is exact, not an approximation.** `version` is the pane's
/// `publishedLeftTreeVersion` / `publishedRightTreeVersion`, which the published property's own
/// `didSet` bumps on *every* assignment. Two values carrying the same `side` and `version` are
/// therefore the same published array by construction — there is no way to reach a second,
/// different tree without the counter having moved. Unlike a content hash, this cannot collide.
///
/// The converse (equal contents, different stamp) merely re-renders when it need not have, and
/// the only unguarded writer is `resetNavigation`'s `if !leftTree.isEmpty { leftTree = [] }` —
/// itself no-op-guarded. `applyFilters()` assigns only when the tree genuinely changed.
///
/// Always build these through `FileSyncManager.leftPaneTree` / `.rightPaneTree`; a hand-picked
/// `version` would silently defeat the invariant above.
public struct PaneTree: Equatable, Sendable {
    /// Which pane's counter `version` came from. The two panes keep independent counters (so an
    /// overlapping load of one pane can't invalidate the other's verdict), which means a bare
    /// version is only meaningful alongside its side. SwiftUI compares a stored property against
    /// its own previous value, so it would never actually pit `tree` against `otherTree` — this
    /// is here so that a future caller who does pair them can't be silently wrong.
    public enum Side: Sendable {
        case left
        case right
    }

    public let side: Side
    /// The pane's publish counter at the moment `nodes` was read. See the type's note on why
    /// this must come from the manager rather than being chosen by the caller.
    public let version: Int
    public let nodes: [FileNode]

    public init(side: Side, version: Int, nodes: [FileNode]) {
        self.side = side
        self.version = version
        self.nodes = nodes
    }

    /// Deliberately ignores `nodes`: the whole point of the type. See the note above for why the
    /// stamp is an exact stand-in for the contents.
    public static func == (lhs: PaneTree, rhs: PaneTree) -> Bool {
        lhs.side == rhs.side && lhs.version == rhs.version
    }
}

/// One node of a published pane tree, tagged with the same stamp — `PaneTree`'s per-row sibling.
///
/// `PaneTree` stopped SwiftUI deep-comparing the *whole* tree, but the row and menu views still
/// stored a bare `FileNode`, and a **directory** node carries its entire subtree in `children`.
/// A pane shows many folder rows, each view holding one, so the recursive compare came straight
/// back per row: a `sample` after the `PaneTree` fix still put **2,162 ms** of main-thread time in
/// `FileNode`-equality subtrees, spread over many ~167 ms entry points — one per row-ish view.
///
/// Equality is `(side, version, id)`. That is exact for the same reason `PaneTree`'s is: within
/// one published tree a path identifies exactly one node with fixed contents, and any change to
/// those contents requires a republish, which advances the stamp. So equal stamp + equal path ⇒
/// equal node, without looking at `children`.
///
/// Build these from the pane's `PaneTree` (`PaneTree.row(_:)`) so the stamp always matches the
/// tree the node actually came from.
public struct RowNode: Equatable, Sendable {
    public let side: PaneTree.Side
    /// The publish stamp of the tree this node was taken from. See `PaneTree.version`.
    public let version: Int
    public let node: FileNode

    public init(side: PaneTree.Side, version: Int, node: FileNode) {
        self.side = side
        self.version = version
        self.node = node
    }

    /// Deliberately ignores everything but the node's path: see the note above.
    public static func == (lhs: RowNode, rhs: RowNode) -> Bool {
        lhs.side == rhs.side && lhs.version == rhs.version && lhs.node.id == rhs.node.id
    }
}

extension PaneTree {
    /// Tags one of this tree's nodes with this tree's stamp. Using the tree's own `side`/`version`
    /// is what makes `RowNode`'s identity-only equality exact — a node stamped with a tree it did
    /// not come from could compare equal to a different node at the same path.
    public func row(_ node: FileNode) -> RowNode {
        RowNode(side: side, version: version, node: node)
    }
}

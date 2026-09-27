import Sync

/// A pane's selection resolved to its nodes once per selection, however many row menus ask.
///
/// **Why the menus ask at all.** SwiftUI builds a row's `.contextMenu` with the row: `FileContextMenu`'s
/// body runs every time its row renders in a shown window, not only when the menu opens — sampled
/// inside each row's `NSHostingView.layout`. And every visible row re-renders on every click, in BOTH
/// panes — the selection is an input of the clicked pane's menus, and the
/// other pane's menus take it as `otherSelection`. Each body used to walk a pane tree of tens of
/// thousands of nodes to resolve it: `resolvedSelection` for the row itself, and on the two-pane
/// surfaces up to two more walks of the other pane's tree ("Copy '…' from ⟨pane⟩" and the
/// cross-pane Compare item). Sampled 2026-09-27 in the real app while clicking through Columns:
/// 277 of the 281 samples spent in those menus were the walks (CP9).
///
/// Two changes remove them, and this type is the second:
/// - A row OUTSIDE the selection acts on itself alone, and a row cut from the very tree being
///   searched already IS that tree's node at its path (`PaneRow`'s stamp), so it needs no walk at
///   all. That is nearly every row on every click — see `FileContextMenu.menuNodes`.
/// - A row INSIDE the selection, and every row's look at the other pane's selection, needs the
///   selection resolved — the same answer for every row that asks. This walks once per (tree,
///   selection) and hands every later asker the same nodes.
///
/// Keyed on the tree's stamp exactly as `PaneTree.==` is: equal side and version are the same
/// published tree, so a hit cannot return another tree's nodes. One entry per side, so a pane's
/// own selection and the other pane's never evict each other.
///
/// An entry holds nodes, and a node holds its subtree, so an entry kept after its selection emptied
/// would keep a tree the pane has since replaced alive. It is let go when that side's selection is
/// asked about empty: the other pane's by `nodes(at:in:)`, the pane's own by `FileContextMenu.menuNodes`.
@MainActor
final class PaneSelectionResolver {
    private struct Entry {
        let version: Int
        let selection: Set<String>
        let nodes: [FileNode]
    }

    private var left: Entry?
    private var right: Entry?

    /// How many times this resolver has walked a tree. The answers are a walk's answers by
    /// construction; the number of walks is the whole point, so it is what the tests count.
    private(set) var walks = 0

    /// `nonisolated` so `@State`'s initializer — which runs outside the actor — can build one.
    nonisolated init() {}

    /// `tree.selectedNodes(at: selection)`: the selection's nodes, pruned of any whose ancestor is
    /// also selected — walking `tree` only the first time this (tree, selection) is asked about.
    func nodes(at selection: Set<String>, in tree: PaneTree) -> [FileNode] {
        guard !selection.isEmpty else {
            release(tree.side)
            return []
        }
        if let entry = tree.side == .left ? left : right,
           entry.version == tree.version, entry.selection == selection {
            return entry.nodes
        }
        walks += 1
        let entry = Entry(version: tree.version, selection: selection,
                          nodes: tree.selectedNodes(at: selection))
        if tree.side == .left { left = entry } else { right = entry }
        return entry.nodes
    }

    /// Lets go of `side`'s entry — its selection is empty, and the nodes it holds need not outlive it.
    func release(_ side: PaneTree.Side) {
        if side == .left { left = nil } else { right = nil }
    }
}

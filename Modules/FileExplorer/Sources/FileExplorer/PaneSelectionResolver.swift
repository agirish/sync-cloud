import Sync

/// A pane's selection resolved to its nodes once per selection, however many row menus ask.
///
/// SwiftUI builds a row's `.contextMenu` with the row, so `FileContextMenu`'s body runs on every
/// render of every visible row, in both panes, on every click, and resolving the selection walks a
/// tree of tens of thousands of nodes. A row outside the selection acts on itself and needs no walk
/// (`FileContextMenu.menuNodes`). A row inside it, and every row's look at the other pane's
/// selection (`otherSelection`), needs the same resolved answer: this walks once per (tree,
/// selection) and hands every later asker the same nodes.
///
/// Keyed on the tree's stamp as `PaneTree.==` is, so a hit can't return another tree's nodes. One
/// entry per side, so the two panes' selections never evict each other. A node holds its subtree,
/// so an entry kept after its selection emptied would keep a replaced tree alive: it is let go when
/// that side's selection is asked about empty, by `nodes(at:in:)` or `FileContextMenu.menuNodes`.
@MainActor
final class PaneSelectionResolver {
    private struct Entry {
        let version: Int
        let selection: Set<String>
        let nodes: [FileNode]
    }

    private var left: Entry?
    private var right: Entry?

    /// How many times this resolver has walked a tree: the number the tests count, since saving
    /// walks is the point.
    private(set) var walks = 0

    /// `nonisolated` so `@State`'s initializer — which runs outside the actor — can build one.
    nonisolated init() {}

    /// `tree.selectedNodes(at: selection)`: the selection's nodes, pruned of any whose ancestor is
    /// also selected, walking `tree` only the first time this (tree, selection) is asked about.
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

    /// Lets go of `side`'s entry: its selection is empty, and its nodes need not outlive it.
    func release(_ side: PaneTree.Side) {
        if side == .left { left = nil } else { right = nil }
    }
}

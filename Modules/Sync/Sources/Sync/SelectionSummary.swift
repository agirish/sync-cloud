import Foundation

/// The "N selected · SIZE" summary shown on a pane's contextual action bar. Sizes come entirely
/// from the in-memory tree the scan already built — no filesystem I/O — so it's free to compute per
/// render: a file contributes its own size; a folder contributes the recursive sum of the files
/// under it. Kept pure so the byte math is unit-tested without a view.
public enum SelectionSummary {

    /// "12 selected · 340 MB", or just "12 selected" when nothing has a known size (e.g. a lone
    /// empty folder). The count is always the number of selected nodes — the size is a best-effort
    /// total on top of it, never a replacement for the count.
    public static func text(for nodes: [FileNode]) -> String {
        let label = "\(nodes.count) selected"
        let bytes = totalBytes(of: nodes)
        return bytes > 0 ? "\(label) · \(FileSyncManager.formatBytes(bytes))" : label
    }

    /// Recursive byte total over a selection. Symlinks are skipped (their `fileSize` mirrors a
    /// target that may already be counted in the tree, so adding it would double-count), and a
    /// folder whose children weren't fully walked (`isUnexplored`) can only *undercount* — the
    /// total is therefore a floor, which is the honest thing for a glanceable summary.
    public static func totalBytes(of nodes: [FileNode]) -> Int {
        nodes.reduce(0) { $0 + totalBytes(of: $1) }
    }

    static func totalBytes(of node: FileNode) -> Int {
        if node.isSymbolicLink == true { return 0 }
        if node.isDirectory {
            return (node.children ?? []).reduce(0) { $0 + totalBytes(of: $1) }
        }
        return node.fileSize ?? 0
    }
}

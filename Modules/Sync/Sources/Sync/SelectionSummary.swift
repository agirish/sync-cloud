import Foundation

/// The "N selected · SIZE" summary on a pane's contextual action bar. Sizes come from the scan's
/// in-memory tree, with no filesystem I/O, so it is free per render: a file adds its size, a folder
/// the sum of the files under it. Pure, so the byte math is tested without a view.
public enum SelectionSummary {

    /// "12 selected · 340 MB", or "12 selected" when nothing has a known size (a lone empty
    /// folder). The count is always the number of selected nodes; the size is a best-effort total
    /// beside it.
    public static func text(for nodes: [FileNode]) -> String {
        let label = "\(nodes.count) selected"
        let bytes = totalBytes(of: nodes)
        return bytes > 0 ? "\(label) · \(FileSyncManager.formatBytes(bytes))" : label
    }

    /// Recursive byte total over a selection, a floor. Symlinks are skipped (their target may
    /// already be counted), and a folder not fully walked (`isUnexplored`) can only undercount.
    /// Nested selections are pruned first, so a folder and a file inside it don't count those bytes
    /// twice; `text(for:)` still counts every selected node, matching what's highlighted.
    public static func totalBytes(of nodes: [FileNode]) -> Int {
        nodes.pruneNestedNodes().reduce(0) { $0 + totalBytes(of: $1) }
    }

    static func totalBytes(of node: FileNode) -> Int {
        if node.isSymbolicLink == true { return 0 }
        // Nor a subtree this walk also reached directly: its bytes are counted there.
        if node.isCoveredElsewhere == true { return 0 }
        if node.isDirectory {
            return (node.children ?? []).reduce(0) { $0 + totalBytes(of: $1) }
        }
        return node.fileSize ?? 0
    }
}

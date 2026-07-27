import Foundation
import Sync

/// Finder-style summary for a multi-item selection in the Details sidebar: item count, a
/// files/folders breakdown, and the combined size of the selected FILES. Folder byte sizes
/// are deliberately excluded — everything here comes from the already-scanned `FileNode`
/// metadata, never from walking directories.
struct DetailsSelectionSummary: Equatable {
    let itemCount: Int
    let fileCount: Int
    let folderCount: Int
    /// Sum of the known `fileSize` of the selected files. A file node with no scanned size
    /// contributes 0 (sizes come from the tree, not a fresh stat).
    let totalFileBytes: Int64

    /// Builds the summary for a pane's selection, or nil when the selection isn't a
    /// multi-selection (0 or 1 items keep the existing single-item detail view).
    /// `itemCount` is the selection count even if some paths no longer resolve in the tree
    /// (they were selected, so hiding them would be misleading); unresolved paths just
    /// contribute nothing to the breakdown or the byte total.
    static func make(selectedPaths: Set<String>, in tree: [FileNode]) -> DetailsSelectionSummary? {
        make(selectedPaths: selectedPaths) { tree.findNodes(at: $0) }
    }

    /// The spelling the sidebar uses: it hands over a resolver rather than a tree, so the paths
    /// can go through `FileSyncManager`'s cached path→node index instead of a walk.
    ///
    /// `findNodes` looks cheap because it unwinds as soon as every requested path has matched —
    /// and it is, when the selection happens to sit near the front of the tree (measured 0.03ms).
    /// The cases that don't: a path at the far end of a ~40k-node tree costs 10.7ms, and a STALE
    /// path — one selected before a rescan removed it — never satisfies the exit at all and
    /// degrades to a full walk, 8.2ms. This is read straight from `body`, so during a bulk sync,
    /// which re-renders per published file, that is 8–11ms of main-thread work per copied file:
    /// the same shape as the freeze `PaneTree` was built to remove, in the one selection path that
    /// change did not reach. `ContentView+Toolbar.activeSelectionNodes` was moved onto the index
    /// for exactly this reason and this was left behind.
    ///
    /// The resolver is a closure rather than a `[FileNode]` parameter so the `count > 1` early-out
    /// still runs FIRST — a single selection resolves nothing, as before.
    ///
    /// Order is not read (only counts and a sum), which is what makes the index — documented as
    /// unordered — a safe substitute for `findNodes`' pre-order.
    static func make(selectedPaths: Set<String>,
                     resolving resolve: (Set<String>) -> [FileNode]) -> DetailsSelectionSummary? {
        guard selectedPaths.count > 1 else { return nil }

        var fileCount = 0
        var folderCount = 0
        var totalFileBytes: Int64 = 0
        for node in resolve(selectedPaths) {
            if node.isDirectory {
                folderCount += 1
            } else {
                fileCount += 1
                totalFileBytes += Int64(node.fileSize ?? 0)
            }
        }

        return DetailsSelectionSummary(
            itemCount: selectedPaths.count,
            fileCount: fileCount,
            folderCount: folderCount,
            totalFileBytes: totalFileBytes
        )
    }

    /// Header line, e.g. "5 items selected". `make` guarantees itemCount ≥ 2, so always plural.
    var title: String {
        "\(itemCount) items selected"
    }

    /// Files/folders breakdown, e.g. "3 files, 2 folders". Falls back to the raw item count
    /// when nothing in the selection resolved in the tree.
    var kindDescription: String {
        var parts: [String] = []
        if fileCount > 0 { parts.append(fileCount == 1 ? "1 file" : "\(fileCount) files") }
        if folderCount > 0 { parts.append(folderCount == 1 ? "1 folder" : "\(folderCount) folders") }
        return parts.isEmpty ? "\(itemCount) items" : parts.joined(separator: ", ")
    }

    /// Combined size of the selected files, marked "(files only)" whenever folders are in the
    /// selection so the number is never mistaken for the total. "—" when no files are selected.
    var sizeDescription: String {
        guard fileCount > 0 else { return "—" }
        let formatted = ByteCountFormatter.string(fromByteCount: totalFileBytes, countStyle: .file)
        return folderCount > 0 ? "\(formatted) (files only)" : formatted
    }
}

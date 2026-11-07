@testable import FileExplorer
import Sync

/// A `FileActionDelegate` that does nothing, for tests that mount a pane or build its menu but
/// never act through it. Every other member keeps the protocol's default, `isEquivalent` (`false`)
/// included.
struct NoOpFileActionDelegate: FileActionDelegate {
    func handleRefresh() {}
    func handleOpenInEditor(_ path: String) {}
    func handleFocus(_ node: FileNode) {}
    func handleCopy(_ nodes: [FileNode]) {}
    func handleMove(_ nodes: [FileNode]) {}
    func handleDelete(_ nodes: [FileNode]) {}
    func handleCopyToClipboard(_ nodes: [FileNode], isCut: Bool) {}
    func handlePaste(_ targetDir: FileNode) {}
    func handlePasteExplicit(_ targetDir: FileNode, nodes: [FileNode]) {}
    func handlePasteToPath(_ path: String) {}
    func handleRename(_ node: FileNode) {}
    func handleCreateFolder(at path: String) {}
    func handleGetInfo(for path: String) {}
    func handleSort(_ option: SortOption) {}
    func handleIgnore(_ nodes: [FileNode]) {}
    func isNodeIgnored(_ node: FileNode, currentPath: String) -> Bool { false }
}

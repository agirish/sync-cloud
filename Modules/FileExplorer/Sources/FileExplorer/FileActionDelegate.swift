import Sync

@MainActor
public protocol FileActionDelegate: Sendable {
    func handleRefresh()
    func handleFocus(_ node: FileNode)
    func handleCopy(_ nodes: [FileNode])
    func handleMove(_ nodes: [FileNode])
    func handleDelete(_ nodes: [FileNode])
    func handleCopyToClipboard(_ nodes: [FileNode], isCut: Bool)
    func handlePaste(_ targetDir: FileNode)
    func handlePasteExplicit(_ targetDir: FileNode, nodes: [FileNode])
    func handlePasteToPath(_ path: String)
    /// Nodes dragged from the other pane and dropped into the directory at `path`.
    /// Copies by default; moves (with the standard move confirmation) when `isMove`.
    func handleDrop(_ nodes: [FileNode], toPath path: String, isMove: Bool)
    func handleRename(_ node: FileNode)
    func handleCreateFolder(at path: String)
    func handleGetInfo(for path: String)
    func handleSort(_ option: SortOption)
    func handleIgnore(_ nodes: [FileNode])
    func isNodeIgnored(_ node: FileNode, currentPath: String) -> Bool
    /// Double-click on a file row: preview it (Quick Look). Optional; defaults to a no-op.
    func handleQuickLook(_ node: FileNode)
}

public extension FileActionDelegate {
    func handleQuickLook(_ node: FileNode) {}
}

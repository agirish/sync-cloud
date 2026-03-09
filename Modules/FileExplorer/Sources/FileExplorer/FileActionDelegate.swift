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
    func handleRename(_ node: FileNode)
    func handleCreateFolder(at path: String)
    func handleGetInfo(for path: String)
    func handleSort(_ option: SortOption)
}

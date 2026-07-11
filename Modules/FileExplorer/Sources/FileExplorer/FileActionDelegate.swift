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
    /// Whether the app's internal clipboard holds items to paste — drives the enablement
    /// of the "Paste here" menu items (pasting from an empty clipboard is a silent no-op).
    var clipboardHasItems: Bool { get }
}

extension FileActionDelegate {
    /// Conservative default: hosts that don't expose their clipboard keep "Paste here"
    /// enabled rather than permanently disabled.
    public var clipboardHasItems: Bool { true }
}

import Foundation
import Sync
import Events
import Settings
import FileExplorer
import Dashboard

/// Connects a single pane’s `FileTreeView` to `FileActionHandler` (focus, copy, move, delete, rename, etc.).
@MainActor
struct PaneActionDelegate: FileActionDelegate {
    let handler: FileActionHandler?
    let syncManager: FileSyncManager
    let settings: SettingsManager
    let isLeft: Bool
    let leftProviderId: String
    let rightProviderId: String
    let forceRefreshAction: () -> Void

    func handleRefresh() {
        forceRefreshAction()
    }
    func handleFocus(_ node: FileNode) { handler?.focusFolder(node, isLeft: isLeft, leftProviderId: leftProviderId, rightProviderId: rightProviderId) }
    func handleCopy(_ nodes: [FileNode]) { handler?.copyItems(nodes, fromLeft: isLeft, leftProviderId: leftProviderId, rightProviderId: rightProviderId) }
    func handleMove(_ nodes: [FileNode]) { 
        Task {
            _ = await handler?.moveItems(nodes, fromLeft: isLeft, leftProviderId: leftProviderId, rightProviderId: rightProviderId) 
        }
    }
    func handleDelete(_ nodes: [FileNode]) { handler?.confirmDelete(nodes) }
    func handleCopyToClipboard(_ nodes: [FileNode], isCut: Bool) { 
        handler?.handleCopyToClipboard(nodes, isCut: isCut)
    }
    func handlePaste(_ targetDir: FileNode) { handler?.pasteClipboard(to: targetDir) }
    func handlePasteExplicit(_ targetDir: FileNode, nodes: [FileNode]) { handler?.pasteItems(nodes, to: targetDir, isCut: false) }
    func handlePasteToPath(_ path: String) { handler?.pasteClipboard(toPath: path) }
    func handleDrop(_ nodes: [FileNode], toPath path: String, isMove: Bool) {
        if isMove {
            handler?.moveItems(nodes, toPath: path)
        } else {
            handler?.pasteItems(nodes, toPath: path, isCut: false)
        }
    }
    func handleRename(_ node: FileNode) { handler?.beginRename(node) }
    func handleCreateFolder(at path: String) { handler?.beginCreateFolder(in: path) }
    func handleGetInfo(for path: String) { handler?.openGetInfo(for: path) }
    func handleSort(_ option: SortOption) { 
        Logger.shared.info("User changed sort option to \(option)")
        syncManager.sortOption = option 
    }
    func handleIgnore(_ nodes: [FileNode]) {
        let rootPath = isLeft ? settings.path(for: leftProviderId) : settings.path(for: rightProviderId)
        let expandedRoot = (rootPath as NSString).expandingTildeInPath
        let relPrefix = isLeft ? syncManager.leftRelativePath : syncManager.rightRelativePath
        
        let basePath = relPrefix.isEmpty ? expandedRoot : (expandedRoot as NSString).appendingPathComponent(relPrefix)

        // Convert to relative paths from current focal point so they sync across panes seamlessly
        let relativeTargets = PaneLogic.relativeIgnoreTargets(nodeIds: nodes.map(\.id), basePath: basePath)
        syncManager.ignoredPaths = PaneLogic.toggledIgnoredPaths(
            targets: relativeTargets,
            ignoredPaths: syncManager.ignoredPaths
        )
    }
    func isNodeIgnored(_ node: FileNode, currentPath: String) -> Bool {
        syncManager.isNodeIgnored(node, currentPath: currentPath)
    }
    /// "Paste here" enablement: the app's internal clipboard is `syncManager.clipboardNodes`
    /// (the pasteboard is not involved), so an empty list means paste would be a no-op.
    var clipboardHasItems: Bool {
        !syncManager.clipboardNodes.isEmpty
    }
}

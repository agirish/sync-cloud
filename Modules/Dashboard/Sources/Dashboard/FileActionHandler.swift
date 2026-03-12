import Foundation
import SwiftUI
import Sync
import Settings
import Events

/// Centralized handler for file management actions triggered from the UI.
/// Relieves the View layers of business logic handling.
@MainActor
public class FileActionHandler {
    private let syncManager: FileSyncManager
    private let settings: SettingsManager
    
    public init(syncManager: FileSyncManager, settings: SettingsManager) {
        self.syncManager = syncManager
        self.settings = settings
    }
    
    // MARK: - Navigation
    
    /// Dives into a sub-folder within the targeted pane, adjusting the relative path navigation state.
    public func focusFolder(_ node: FileNode, isLeft: Bool, leftProviderId: String, rightProviderId: String) {
        let rootPath = isLeft ? settings.path(for: leftProviderId) : settings.path(for: rightProviderId)
        
        let expandedRoot = (rootPath as NSString).expandingTildeInPath
        let nodePath = node.id
        
        var relPath = nodePath
        if relPath.hasPrefix(expandedRoot) {
            relPath = String(relPath.dropFirst(expandedRoot.count))
        }
        if relPath.hasPrefix("/") { relPath.removeFirst() }
        
        Logger.shared.info("User focusing folder: \(relPath)")
        syncManager.focusOn(relativePath: relPath, isLeft: isLeft)
    }
    
    // MARK: - Native Actions
    
    /// Triggers native macOS 'Get Info' window using AppleScript.
    public func openGetInfo(for path: String) {
        let escapedPath = Self.escapeForAppleScript(path)
        let script = """
        tell application "Finder"
            activate
            open information window of (POSIX file "\(escapedPath)" as alias)
        end tell
        """
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
            if let err = error {
                Logger.shared.error("Failed to open Get Info: \(err)", showAlert: false)
            }
        }
    }
    
    // MARK: - File Transfers
    
    /// Initiates an asynchronous cross-pane copy operation.
    public func copyItems(_ nodes: [FileNode], fromLeft: Bool, leftProviderId: String, rightProviderId: String) {
        let leftRoot = settings.path(for: leftProviderId)
        let rightRoot = settings.path(for: rightProviderId)
        let targetDisplayName = providerDisplayName(forProviderId: fromLeft ? rightProviderId : leftProviderId)
        
        Logger.shared.info("User initiating copy of \(nodes.count) items")
        Task {
            let copiedNodes = await syncManager.copyItems(nodes: nodes, fromLeft: fromLeft, leftRoot: leftRoot, rightRoot: rightRoot)
            setBannerForCopy(copiedNodes, to: targetDisplayName)
        }
    }
    
    @discardableResult
    public func moveItems(_ nodes: [FileNode], fromLeft: Bool, leftProviderId: String, rightProviderId: String) async -> [FileNode] {
        let targetLabel = fromLeft ? "Right" : "Left"
        guard NativeAlerts.confirmMove(for: nodes.map { $0.name }, destinationLabel: targetLabel) else {
            Logger.shared.debug("User cancelled move of \(nodes.count) items to \(targetLabel)")
            return []
        }

        let leftRoot = settings.path(for: leftProviderId)
        let rightRoot = settings.path(for: rightProviderId)
        let targetDisplayName = providerDisplayName(forProviderId: fromLeft ? rightProviderId : leftProviderId)
        
        Logger.shared.info("User initiating move of \(nodes.count) items")
        let movedNodes = await syncManager.moveItems(nodes: nodes, fromLeft: fromLeft, leftRoot: leftRoot, rightRoot: rightRoot)
        setBannerForMove(movedNodes, to: targetDisplayName)
        return movedNodes
    }
    
    public func pasteItems(_ nodes: [FileNode], to targetDir: FileNode, isCut: Bool) {
        let validDestinationPath = targetDir.isDirectory ? targetDir.id : URL(fileURLWithPath: targetDir.id).deletingLastPathComponent().path
        let destDisplayName = providerDisplayName(forPath: validDestinationPath)

        Logger.shared.info("User pasting \(nodes.count) items (isCut: \(isCut))")
        Task {
            if isCut {
                let movedNodes = await syncManager.moveItems(nodes: nodes, toPath: validDestinationPath)
                let successfullyMovedIds = Set(movedNodes.map { $0.id })
                syncManager.clipboardNodes.removeAll { successfullyMovedIds.contains($0.id) }
                if syncManager.clipboardNodes.isEmpty {
                    syncManager.clipboardIsCut = false
                }
                setBannerForMove(movedNodes, to: destDisplayName)
            } else {
                let copiedNodes = await syncManager.copyItems(nodes: nodes, toPath: validDestinationPath)
                setBannerForCopy(copiedNodes, to: destDisplayName)
            }
        }
    }
    
    public func pasteClipboard(to targetDir: FileNode) {
        let nodesToPaste = syncManager.clipboardNodes
        guard !nodesToPaste.isEmpty else { return }
        pasteItems(nodesToPaste, to: targetDir, isCut: syncManager.clipboardIsCut)
    }
    
    public func handleCopyToClipboard(_ nodes: [FileNode], isCut: Bool) {
        Logger.shared.info("User \(isCut ? "cut" : "copied") \(nodes.count) items to internal clipboard.")
        syncManager.clipboardNodes = nodes
        syncManager.clipboardIsCut = isCut
    }
    
    public func pasteItems(_ nodes: [FileNode], toPath destinationPath: String, isCut: Bool) {
        let destDisplayName = providerDisplayName(forPath: destinationPath)
        Logger.shared.info("User pasting \(nodes.count) items to specific path (isCut: \(isCut))")
        Task {
            if isCut {
                let movedNodes = await syncManager.moveItems(nodes: nodes, toPath: destinationPath)
                let successfullyMovedIds = Set(movedNodes.map { $0.id })
                syncManager.clipboardNodes.removeAll { successfullyMovedIds.contains($0.id) }
                if syncManager.clipboardNodes.isEmpty {
                    syncManager.clipboardIsCut = false
                }
                setBannerForMove(movedNodes, to: destDisplayName)
            } else {
                let copiedNodes = await syncManager.copyItems(nodes: nodes, toPath: destinationPath)
                setBannerForCopy(copiedNodes, to: destDisplayName)
            }
        }
    }
    
    public func pasteClipboard(toPath destinationPath: String) {
        let nodesToPaste = syncManager.clipboardNodes
        guard !nodesToPaste.isEmpty else { return }
        pasteItems(nodesToPaste, toPath: destinationPath, isCut: syncManager.clipboardIsCut)
    }

    private static func escapeForAppleScript(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
    
    private func providerDisplayName(forProviderId id: String) -> String {
        settings.availableProviders.first(where: { $0.id == id })?.displayName ?? "other pane"
    }
    
    private func providerDisplayName(forPath path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        for p in settings.availableProviders {
            let root = (p.path as NSString).expandingTildeInPath
            if expanded == root || expanded.hasPrefix(root + "/") {
                return p.displayName
            }
        }
        return "other pane"
    }
    
    private func setBannerForCopy(_ nodes: [FileNode], to destinationName: String) {
        guard !nodes.isEmpty else { return }
        syncManager.bannerMessage = nodes.count == 1
            ? "Copied \"\(nodes[0].name)\" to \(destinationName)"
            : "Copied \(nodes.count) items to \(destinationName)"
    }
    
    private func setBannerForMove(_ nodes: [FileNode], to destinationName: String) {
        guard !nodes.isEmpty else { return }
        syncManager.bannerMessage = nodes.count == 1
            ? "Moved \"\(nodes[0].name)\" to \(destinationName)"
            : "Moved \(nodes.count) items to \(destinationName)"
    }
    
    // MARK: - Mutations
    
    public func beginRename(_ node: FileNode) {
        if let newName = NativeAlerts.promptForRename(currentName: node.name), newName != node.name {
            Logger.shared.info("User initiated rename of '\(node.name)' to '\(newName)'")
            Task {
                await syncManager.renameItem(at: node.id, to: newName)
            }
        }
    }
    
    public func beginCreateFolder(in path: String) {
        if let folderName = NativeAlerts.promptForNewFolder() {
            Logger.shared.info("User initiated create folder: '\(folderName)'")
            Task {
                await syncManager.createFolder(named: folderName, in: path)
            }
        }
    }
    
    public func confirmDelete(_ nodes: [FileNode]) {
        if NativeAlerts.confirmDelete(for: nodes.map { $0.name }) {
            Logger.shared.info("User confirmed deletion of \(nodes.count) items")
            Task {
                await syncManager.deleteItems(at: nodes.map { $0.id })
            }
        }
    }
}

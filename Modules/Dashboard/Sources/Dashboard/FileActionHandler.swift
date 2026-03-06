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
    public func focusFolder(_ node: FileNode, isSource: Bool, sourceProviderId: String, destProviderId: String) {
        let rootPath = isSource ? settings.path(for: sourceProviderId) : settings.path(for: destProviderId)
        let otherRootPath = isSource ? settings.path(for: destProviderId) : settings.path(for: sourceProviderId)
        
        let expandedRoot = (rootPath as NSString).expandingTildeInPath
        let nodePath = node.id
        
        var relPath = nodePath
        if relPath.hasPrefix(expandedRoot) {
            relPath = String(relPath.dropFirst(expandedRoot.count))
        }
        if relPath.hasPrefix("/") { relPath.removeFirst() }
        
        Logger.shared.info("User focusing folder: \(relPath)")
        syncManager.focusOn(relativePath: relPath, isSource: isSource, otherProviderPath: otherRootPath)
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
    public func copyItems(_ nodes: [FileNode], fromSource: Bool, sourceProviderId: String, destProviderId: String) {
        let sourceRoot = settings.path(for: sourceProviderId)
        let destRoot = settings.path(for: destProviderId)
        
        Logger.shared.info("User initiating copy of \(nodes.count) items")
        Task {
            await syncManager.copyItems(nodes: nodes, fromSource: fromSource, sourceRoot: sourceRoot, destinationRoot: destRoot)
        }
    }
    
    @discardableResult
    public func moveItems(_ nodes: [FileNode], fromSource: Bool, sourceProviderId: String, destProviderId: String) async -> [FileNode] {
        let sourceRoot = settings.path(for: sourceProviderId)
        let destRoot = settings.path(for: destProviderId)
        
        Logger.shared.info("User initiating move of \(nodes.count) items")
        return await syncManager.moveItems(nodes: nodes, fromSource: fromSource, sourceRoot: sourceRoot, destinationRoot: destRoot)
    }
    
    public func pasteItems(_ nodes: [FileNode], to targetDir: FileNode, isCut: Bool) {
        let validDestinationPath = targetDir.isDirectory ? targetDir.id : URL(fileURLWithPath: targetDir.id).deletingLastPathComponent().path

        Logger.shared.info("User pasting \(nodes.count) items (isCut: \(isCut))")
        Task {
            if isCut {
                let movedNodes = await syncManager.moveItems(nodes: nodes, toPath: validDestinationPath)
                let successfullyMovedIds = Set(movedNodes.map { $0.id })
                syncManager.clipboardNodes.removeAll { successfullyMovedIds.contains($0.id) }
                if syncManager.clipboardNodes.isEmpty {
                    syncManager.clipboardIsCut = false
                }
            } else {
                await syncManager.copyItems(nodes: nodes, toPath: validDestinationPath)
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
        Logger.shared.info("User pasting \(nodes.count) items to specific path (isCut: \(isCut))")
        Task {
            if isCut {
                let movedNodes = await syncManager.moveItems(nodes: nodes, toPath: destinationPath)
                let successfullyMovedIds = Set(movedNodes.map { $0.id })
                syncManager.clipboardNodes.removeAll { successfullyMovedIds.contains($0.id) }
                if syncManager.clipboardNodes.isEmpty {
                    syncManager.clipboardIsCut = false
                }
            } else {
                await syncManager.copyItems(nodes: nodes, toPath: destinationPath)
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

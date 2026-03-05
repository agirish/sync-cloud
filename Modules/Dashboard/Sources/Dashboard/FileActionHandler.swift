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
        
        syncManager.focusOn(relativePath: relPath, isSource: isSource, otherProviderPath: otherRootPath)
    }
    
    // MARK: - Native Actions
    
    /// Triggers native macOS 'Get Info' window using AppleScript.
    public func openGetInfo(for path: String) {
        let script = """
        tell application "Finder"
            activate
            open information window of (POSIX file "\(path)" as alias)
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
        
        Task {
            await syncManager.copyItems(nodes: nodes, fromSource: fromSource, sourceRoot: sourceRoot, destinationRoot: destRoot)
        }
    }
    
    /// Initiates an asynchronous cross-pane move operation.
    public func moveItems(_ nodes: [FileNode], fromSource: Bool, sourceProviderId: String, destProviderId: String) {
        let sourceRoot = settings.path(for: sourceProviderId)
        let destRoot = settings.path(for: destProviderId)
        
        Task {
            await syncManager.moveItems(nodes: nodes, fromSource: fromSource, sourceRoot: sourceRoot, destinationRoot: destRoot)
        }
    }
    
    public func pasteItems(_ nodes: [FileNode], to targetDir: FileNode, isCut: Bool) {
        let validDestinationPath = targetDir.isDirectory ? targetDir.id : URL(fileURLWithPath: targetDir.id).deletingLastPathComponent().path
        
        if isCut {
            syncManager.clipboardNodes = []
            syncManager.clipboardIsCut = false
        }
        
        Task {
            if isCut {
                await syncManager.moveItems(nodes: nodes, toPath: validDestinationPath)
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
    
    public func pasteItems(_ nodes: [FileNode], toPath destinationPath: String, isCut: Bool) {
        if isCut {
            syncManager.clipboardNodes = []
            syncManager.clipboardIsCut = false
        }
        
        Task {
            if isCut {
                await syncManager.moveItems(nodes: nodes, toPath: destinationPath)
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
    
    // MARK: - Mutations
    
    public func beginRename(_ node: FileNode) {
        if let newName = NativeAlerts.promptForRename(currentName: node.name), newName != node.name {
            Task {
                await syncManager.renameItem(at: node.id, to: newName)
            }
        }
    }
    
    public func beginCreateFolder(in path: String) {
        if let folderName = NativeAlerts.promptForNewFolder() {
            Task {
                await syncManager.createFolder(named: folderName, in: path)
            }
        }
    }
    
    public func confirmDelete(_ nodes: [FileNode]) {
        if NativeAlerts.confirmDelete(for: nodes.map { $0.name }) {
            Task {
                await syncManager.deleteItems(at: nodes.map { $0.id })
            }
        }
    }
}

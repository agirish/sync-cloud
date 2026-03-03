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
    public func focusFolder(_ node: FileNode, isSource: Bool, sourceProviderId: String, destProviderId: String, refreshAction: @escaping () -> Void) {
        let rootPath = isSource ? settings.path(for: sourceProviderId) : settings.path(for: destProviderId)
        let otherRootPath = isSource ? settings.path(for: destProviderId) : settings.path(for: sourceProviderId)
        
        let expandedRoot = (rootPath as NSString).expandingTildeInPath
        let nodePath = node.id
        
        var relPath = nodePath.replacingOccurrences(of: expandedRoot, with: "")
        if relPath.hasPrefix("/") { relPath.removeFirst() }
        
        syncManager.focusOn(relativePath: relPath, isSource: isSource, otherProviderPath: otherRootPath)
        refreshAction()
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
    public func copyItems(_ nodes: [FileNode], fromSource: Bool, sourceProviderId: String, destProviderId: String, refreshAction: @escaping () -> Void) {
        let sourceRoot = settings.path(for: sourceProviderId)
        let destRoot = settings.path(for: destProviderId)
        
        Task {
            await syncManager.copyItems(nodes: nodes, fromSource: fromSource, sourceRoot: sourceRoot, destinationRoot: destRoot)
            refreshAction()
        }
    }
    
    /// Handles the internal execution of dropping nodes into a directory, observing if it was a Cut or Copy.
    public func pasteItems(_ nodes: [FileNode], to targetFolderPath: String, isCut: Bool, refreshAction: @escaping () -> Void) {
        Task {
            if isCut {
                await syncManager.moveItems(nodes: nodes, toPath: targetFolderPath)
            } else {
                await syncManager.copyItems(nodes: nodes, toPath: targetFolderPath)
            }
            syncManager.clipboardNodes = []
            syncManager.clipboardIsCut = false
            refreshAction()
        }
    }
    
    public func pasteClipboard(to targetFolderPath: String, refreshAction: @escaping () -> Void) {
        let nodesToPaste = syncManager.clipboardNodes
        guard !nodesToPaste.isEmpty else { return }
        pasteItems(nodesToPaste, to: targetFolderPath, isCut: syncManager.clipboardIsCut, refreshAction: refreshAction)
    }
    
    // MARK: - Mutations
    
    public func beginRename(_ node: FileNode, refreshAction: @escaping () -> Void) {
        if let newName = NativeAlerts.promptForRename(currentName: node.name), newName != node.name {
            Task {
                await syncManager.renameItem(at: node.id, to: newName)
                refreshAction()
            }
        }
    }
    
    public func beginCreateFolder(in path: String, refreshAction: @escaping () -> Void) {
        if let folderName = NativeAlerts.promptForNewFolder() {
            Task {
                await syncManager.createFolder(named: folderName, in: path)
                refreshAction()
            }
        }
    }
    
    public func confirmDelete(_ nodes: [FileNode], refreshAction: @escaping () -> Void) {
        if NativeAlerts.confirmDelete(for: nodes.map { $0.name }) {
            Task {
                await syncManager.deleteItems(at: nodes.map { $0.id })
                refreshAction()
            }
        }
    }
}

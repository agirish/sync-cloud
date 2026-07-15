import Foundation
import SwiftUI
import Sync
import Settings
import Events
import Design

/// Handles file and folder actions from the UI (copy, move, delete, rename, focus, paste).
/// Coordinates between `FileSyncManager`, `SettingsManager`, and system APIs (Finder, alerts).
@MainActor
public class FileActionHandler {
    private let syncManager: FileSyncManager
    private let settings: SettingsManager
    
    public init(syncManager: FileSyncManager, settings: SettingsManager) {
        self.syncManager = syncManager
        self.settings = settings
    }
    
    // MARK: - Navigation
    
    /// Focuses the comparison on the selected folder (updates left/right relative path for the given pane).
    /// - Parameters:
    ///   - node: The folder node the user chose to “compare only this folder”.
    ///   - isLeft: `true` if the folder is in the left pane, `false` if in the right.
    ///   - leftProviderId: Current left-pane provider ID (for path lookup).
    ///   - rightProviderId: Current right-pane provider ID.
    public func focusFolder(_ node: FileNode, isLeft: Bool, leftProviderId: String, rightProviderId: String) {
        let side = isLeft ? "left" : "right"
        let rootPath = isLeft ? settings.path(for: leftProviderId) : settings.path(for: rightProviderId)
        // path(for:) returns "" for a provider that vanished from settings; "" prefix-matches
        // every node, which would turn the node's absolute path into the "relative" focus path.
        guard !rootPath.isEmpty else {
            syncManager.present(paneUnavailableError(side: side))
            return
        }

        let expandedRoot = (rootPath as NSString).expandingTildeInPath
        // Same boundary rule as providerDisplayName(forPath:): the root itself or "root/…",
        // never a bare string prefix ("/data/foo" must not claim "/data/foobar").
        let relPath: String
        if node.id == expandedRoot {
            relPath = ""
        } else if node.id.hasPrefix(expandedRoot + "/") {
            relPath = String(node.id.dropFirst(expandedRoot.count + 1))
        } else {
            syncManager.present(SyncError(
                title: "Can't Focus Folder",
                message: "\"\(node.name)\" is not inside the \(side) pane's folder. Rescan and try again.",
                path: node.id))
            return
        }

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
                // A failed Finder "Get Info" is a cosmetic dead-end (nothing is left in a bad
                // state), so it's a warning, not an app-level error.
                Logger.shared.warning("Failed to open Get Info: \(err)")
            }
        }
    }
    
    // MARK: - File Transfers
    
    /// Copies the given items from one pane to the other (left → right or right → left).
    /// - Parameters:
    ///   - fromLeft: `true` if items are in the left pane (copy to right); `false` for right → left.
    ///   - leftProviderId: Provider ID for the left pane (root path).
    ///   - rightProviderId: Provider ID for the right pane.
    public func copyItems(_ nodes: [FileNode], fromLeft: Bool, leftProviderId: String, rightProviderId: String) {
        let targetDisplayName = providerDisplayName(forProviderId: fromLeft ? rightProviderId : leftProviderId)

        Logger.shared.info("User initiating copy of \(nodes.count) items")
        Task {
            guard let roots = await transferRoots(fromLeft: fromLeft, leftProviderId: leftProviderId, rightProviderId: rightProviderId) else { return }
            let copiedNodes = await syncManager.copyItems(nodes: nodes, fromLeft: fromLeft, leftRoot: roots.left, rightRoot: roots.right)
            setTransferBanner(verb: "Copied", copiedNodes, to: targetDisplayName)
        }
    }

    /// Moves the given items to the opposite pane. Returns the nodes that were moved.
    /// Confirmation lives in the sync layer's Settings-gated `transferConfirmer` — do not
    /// add a prompt here; a second one makes every move double-confirm.
    /// - Parameters: Same as `copyItems`; direction is determined by `fromLeft`.
    @discardableResult
    public func moveItems(_ nodes: [FileNode], fromLeft: Bool, leftProviderId: String, rightProviderId: String) async -> [FileNode] {
        guard let roots = await transferRoots(fromLeft: fromLeft, leftProviderId: leftProviderId, rightProviderId: rightProviderId) else { return [] }

        let targetDisplayName = providerDisplayName(forProviderId: fromLeft ? rightProviderId : leftProviderId)

        Logger.shared.info("User initiating move of \(nodes.count) items")
        let movedNodes = await syncManager.moveItems(nodes: nodes, fromLeft: fromLeft, leftRoot: roots.left, rightRoot: roots.right)
        setTransferBanner(verb: "Moved", movedNodes, to: targetDisplayName)
        return movedNodes
    }

    /// The roots for a pane-to-pane transfer, or nil (after presenting an error) when either
    /// pane's provider is no longer known or the source root has vanished from disk — the
    /// window where a rediscovery pass dropped a provider while its stale tree is still showing.
    /// `settings.path(for:)` returns "" for an unknown id, and an empty root must never reach
    /// the sync layer: it would resolve destinations against the process working directory.
    private func transferRoots(fromLeft: Bool, leftProviderId: String, rightProviderId: String) async -> (left: String, right: String)? {
        let leftRoot = settings.path(for: leftProviderId)
        let rightRoot = settings.path(for: rightProviderId)
        let sourceRoot = fromLeft ? leftRoot : rightRoot
        let destinationRoot = fromLeft ? rightRoot : leftRoot

        guard !sourceRoot.isEmpty else {
            syncManager.present(paneUnavailableError(side: fromLeft ? "left" : "right"))
            return nil
        }
        guard !destinationRoot.isEmpty else {
            syncManager.present(paneUnavailableError(side: fromLeft ? "right" : "left"))
            return nil
        }

        // One stat, off the main actor. The destination root's existence is the sync layer's
        // check: transferItems stats it on the file-operation queue right before any I/O.
        let expandedSource = (sourceRoot as NSString).expandingTildeInPath
        let sourceExists = await Task.detached { FileManager.default.fileExists(atPath: expandedSource) }.value
        guard sourceExists else {
            syncManager.present(SyncError(
                title: "Folder Unavailable",
                message: "The \(fromLeft ? "left" : "right") pane's folder no longer exists on disk. Rescan before copying or moving items.",
                path: expandedSource))
            return nil
        }
        return (leftRoot, rightRoot)
    }

    private func paneUnavailableError(side: String) -> SyncError {
        SyncError(
            title: "Folder Unavailable",
            message: "The \(side) pane's folder is no longer available. Rescan before continuing.")
    }
    
    /// Moves the given items into the directory at `destinationPath`.
    /// This is drag & drop's move route; unlike the cut+paste route it never touches the
    /// internal clipboard, and unlike the pane-to-pane move it targets an explicit directory.
    /// Confirmation lives in the sync layer's `transferConfirmer` (same as the pane-to-pane
    /// `moveItems` above — no prompt here).
    public func moveItems(_ nodes: [FileNode], toPath destinationPath: String) {
        let destDisplayName = providerDisplayName(forPath: destinationPath)
        Logger.shared.info("User initiating move of \(nodes.count) items to a dropped-on directory")
        Task {
            let movedNodes = await syncManager.moveItems(nodes: nodes, toPath: destinationPath)
            setTransferBanner(verb: "Moved", movedNodes, to: destDisplayName)
        }
    }

    public func pasteItems(_ nodes: [FileNode], to targetDir: FileNode, isCut: Bool) {
        let validDestinationPath = targetDir.isDirectory ? targetDir.id : URL(fileURLWithPath: targetDir.id).deletingLastPathComponent().path
        pasteItems(nodes, toPath: validDestinationPath, isCut: isCut)
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
        Logger.shared.info("User pasting \(nodes.count) items (isCut: \(isCut))")
        Task {
            if isCut {
                let movedNodes = await syncManager.moveItems(nodes: nodes, toPath: destinationPath)
                let successfullyMovedIds = Set(movedNodes.map { $0.id })
                syncManager.clipboardNodes.removeAll { successfullyMovedIds.contains($0.id) }
                if syncManager.clipboardNodes.isEmpty {
                    syncManager.clipboardIsCut = false
                }
                setTransferBanner(verb: "Moved", movedNodes, to: destDisplayName)
            } else {
                let copiedNodes = await syncManager.copyItems(nodes: nodes, toPath: destinationPath)
                setTransferBanner(verb: "Copied", copiedNodes, to: destDisplayName)
            }
        }
    }
    
    public func pasteClipboard(toPath destinationPath: String) {
        let nodesToPaste = syncManager.clipboardNodes
        guard !nodesToPaste.isEmpty else { return }
        pasteItems(nodesToPaste, toPath: destinationPath, isCut: syncManager.clipboardIsCut)
    }

    // Internal (not private) so its escaping order can be unit-tested; only used by openGetInfo.
    static func escapeForAppleScript(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
    
    private func providerDisplayName(forProviderId id: String) -> String {
        settings.availableProviders.first(where: { $0.id == id })?.displayName ?? "other pane"
    }
    
    // Internal (not private) so the provider root-matching (incl. the "/" prefix boundary) is testable.
    func providerDisplayName(forPath path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        for p in settings.availableProviders {
            let root = (p.path as NSString).expandingTildeInPath
            if expanded == root || expanded.hasPrefix(root + "/") {
                return p.displayName
            }
        }
        return "other pane"
    }
    
    /// Success banner after a transfer; no banner when nothing was actually transferred.
    /// `verb` is the past-tense operation name ("Copied" or "Moved").
    private func setTransferBanner(verb: String, _ nodes: [FileNode], to destinationName: String) {
        guard !nodes.isEmpty else { return }
        // copyItems/moveItems register one grouped undo for the whole batch, so a single Undo (⌘Z)
        // reverses it — the banner may offer the button.
        syncManager.banner = .success(nodes.count == 1
            ? "\(verb) \"\(nodes[0].name)\" to \(destinationName)"
            : "\(verb) \(nodes.count) items to \(destinationName)", undoable: true)
    }
    
    // MARK: - Mutations
    
    public func beginRename(_ node: FileNode) {
        if let newName = NativeAlerts.promptForRename(currentName: node.name, validate: FileSyncManager.validateItemName), newName != node.name {
            Logger.shared.info("User initiated rename of '\(node.name)' to '\(newName)'")
            Task {
                await syncManager.renameItem(at: node.id, to: newName)
            }
        }
    }
    
    public func beginCreateFolder(in path: String) {
        // "" is the root of a pane whose provider vanished from settings (`settings.path(for:)`
        // for an unknown id) while its stale tree was still showing. The sync layer refuses it
        // too; short-circuit here — like focusFolder/transferRoots — so the user is never
        // prompted for a name the folder cannot get.
        guard !path.isEmpty else {
            syncManager.present(SyncError(
                title: "Folder Unavailable",
                message: "The pane's folder is no longer available. Rescan before continuing."))
            return
        }
        if let folderName = NativeAlerts.promptForNewFolder(validate: FileSyncManager.validateItemName) {
            Logger.shared.info("User initiated create folder: '\(folderName)'")
            Task {
                await syncManager.createFolder(named: folderName, in: path)
            }
        }
    }
    
    /// Deletes after the confirmation alert — or immediately when the user switched the
    /// "Confirm before deleting" setting off (items still go to the Trash and stay undoable;
    /// deletions that require a PERMANENT delete keep their own confirmation regardless).
    public func confirmDelete(_ nodes: [FileNode]) {
        if GeneralSettings.shouldConfirmBeforeDelete() {
            guard NativeAlerts.confirmDelete(for: nodes.map { $0.name }) else { return }
            Logger.shared.info("User confirmed deletion of \(nodes.count) items")
        } else {
            Logger.shared.info("User deleted \(nodes.count) items (confirmation disabled in Settings)")
        }
        Task {
            await syncManager.deleteItems(at: nodes.map { $0.id })
        }
    }
}

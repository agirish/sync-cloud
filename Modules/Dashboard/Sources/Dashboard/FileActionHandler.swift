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
    /// Read for the "Confirm before deleting" flag; injectable so tests don't mutate `.standard`.
    private let defaults: UserDefaults
    /// Runs an AppleScript source, returning the error dictionary on failure (nil on success).
    /// Injectable so tests can capture the script instead of driving the real Finder.
    private let appleScriptRunner: (String) -> NSDictionary?
    /// The modal prompts and confirmation behind rename / new-folder / delete. They default to
    /// the real `NativeAlerts`; tests substitute closures because the real ones block on NSAlert.
    private let renamePrompter: (_ currentName: String, _ validate: (String) -> String?) -> String?
    private let newFolderPrompter: (_ validate: (String) -> String?) -> String?
    private let deleteConfirmer: (_ itemNames: [String]) -> Bool

    public init(
        syncManager: FileSyncManager,
        settings: SettingsManager,
        defaults: UserDefaults = .standard,
        appleScriptRunner: ((String) -> NSDictionary?)? = nil,
        renamePrompter: @escaping (_ currentName: String, _ validate: (String) -> String?) -> String? =
            { NativeAlerts.promptForRename(currentName: $0, validate: $1) },
        newFolderPrompter: @escaping (_ validate: (String) -> String?) -> String? =
            { NativeAlerts.promptForNewFolder(validate: $0) },
        deleteConfirmer: @escaping (_ itemNames: [String]) -> Bool =
            { NativeAlerts.confirmDelete(for: $0) }
    ) {
        self.syncManager = syncManager
        self.settings = settings
        self.defaults = defaults
        // nil → the real NSAppleScript runner (an internal symbol can't appear as a public
        // init's default argument directly).
        self.appleScriptRunner = appleScriptRunner ?? Self.executeAppleScript
        self.renamePrompter = renamePrompter
        self.newFolderPrompter = newFolderPrompter
        self.deleteConfirmer = deleteConfirmer
    }

    /// The production AppleScript runner behind `appleScriptRunner`: executes via `NSAppleScript`
    /// and surfaces the error dictionary (nil when the script compiled and ran cleanly).
    /// `nonisolated` only so it can be a default argument; `openGetInfo` still calls it on the
    /// main actor, exactly like the pre-seam inline implementation.
    nonisolated static func executeAppleScript(_ source: String) -> NSDictionary? {
        guard let appleScript = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        appleScript.executeAndReturnError(&error)
        return error
    }
    
    // MARK: - Navigation
    
    /// Focuses the comparison on the selected folder (updates left/right relative path for the given pane).
    /// - Parameters:
    ///   - node: The folder node the user chose to “compare only this folder”.
    ///   - isLeft: `true` if the folder is in the left pane, `false` if in the right.
    ///   - leftProviderId: Current left-pane provider ID (for path lookup).
    ///   - rightProviderId: Current right-pane provider ID.
    public func focusFolder(_ node: FileNode, isLeft: Bool, leftProviderId: String, rightProviderId: String, suppressLinkedNavigation: Bool = false) {
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

        Logger.shared.info("User focused folder: \(relPath.isEmpty ? "root" : relPath)")
        // Honor the breadcrumb "Link both panes" toggle here too. The feature promises the panes
        // stay in lock-step "while drilling down," but drilling into a folder from the file list
        // lands here — not on a breadcrumb crumb — so without this check only clicking an ancestor
        // crumb ever moved the sibling pane. When linked, drive both panes to the same subfolder.
        //
        // `suppressLinkedNavigation` is the single-source rail's opt-out: the rail reuses the left pane's
        // plumbing but has NO visible sibling — honoring the link there silently dragged the
        // hidden right pane along (growing its history, overwriting its saved focus for the next
        // launch, and recording "Recent" folders the user never visited).
        if PaneLinkPreference.isLinked && !suppressLinkedNavigation {
            syncManager.focusBoth(relativePath: relPath)
        } else {
            syncManager.focusOn(relativePath: relPath, isLeft: isLeft)
        }
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
        if let err = appleScriptRunner(script) {
            // A failed Finder "Get Info" is a cosmetic dead-end (nothing is left in a bad
            // state), so it's a warning, not an app-level error.
            Logger.shared.warning("Failed to open Get Info: \(err)")
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

        Logger.shared.info("User initiated copy of \(nodes.count) item(s)")
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

        Logger.shared.info("User initiated move of \(nodes.count) item(s)")
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
        Logger.shared.info("User initiated move of \(nodes.count) item(s) to a dropped-on directory")
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
        Logger.shared.info("User \(isCut ? "cut" : "copied") \(nodes.count) item(s) to the internal clipboard")
        syncManager.clipboardNodes = nodes
        syncManager.clipboardIsCut = isCut
    }
    
    public func pasteItems(_ nodes: [FileNode], toPath destinationPath: String, isCut: Bool) {
        let destDisplayName = providerDisplayName(forPath: destinationPath)
        Logger.shared.info("User pasted \(nodes.count) item(s) (\(isCut ? "move" : "copy"))")
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
        if let newName = renamePrompter(node.name, FileSyncManager.validateItemName), newName != node.name {
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
        if let folderName = newFolderPrompter(FileSyncManager.validateItemName) {
            Logger.shared.info("User initiated create folder: '\(folderName)'")
            Task {
                await syncManager.createFolder(named: folderName, in: path)
            }
        }
    }
    
    /// Deletes after the confirmation alert — or immediately when the user switched the
    /// "Confirm before deleting" setting off (items still go to the Trash and stay undoable;
    /// deletions that require a PERMANENT delete keep their own confirmation regardless).
    ///
    /// - Parameter alwaysConfirm: asks regardless of the setting. One caller passes it: the pane
    ///   bar's Delete button, which is permanently visible beside Sort and Hidden Files rather
    ///   than something you navigated a menu to reach. A stray click on a rung in a row of
    ///   otherwise reversible controls is a different risk from a menu item chosen by name, and
    ///   the setting is about the latter. The flag is per-CALL and defaults to off, so the row
    ///   menu and ⌘⌫ keep honouring the preference exactly as before — this is not a second
    ///   reading of the defaults key.
    public func confirmDelete(_ nodes: [FileNode], alwaysConfirm: Bool = false) {
        if alwaysConfirm || GeneralSettings.shouldConfirmBeforeDelete(defaults) {
            guard deleteConfirmer(nodes.map { $0.name }) else { return }
            Logger.shared.info("User confirmed deletion of \(nodes.count) item(s)")
        } else {
            Logger.shared.info("User deleted \(nodes.count) item(s) (confirmation disabled in Settings)")
        }
        Task {
            await syncManager.deleteItems(at: nodes.map { $0.id }, reportsNothingToDo: true)
        }
    }
}

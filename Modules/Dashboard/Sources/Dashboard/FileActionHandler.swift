import Foundation
import SwiftUI
import Sync
import Settings
import Events
import Design

/// Handles file and folder actions from the UI (copy, move, delete, rename, focus, paste).
/// Coordinates between `FileSyncManager`, `SettingsManager`, and system APIs (pasteboard, alerts).
@MainActor
public class FileActionHandler {
    private let syncManager: FileSyncManager
    private let settings: SettingsManager
    /// Read for the "Confirm before deleting" and "Link both panes" flags. No default, so a test
    /// can't fall back to `.standard`, the user's live settings when the app hosts it.
    private let defaults: UserDefaults
    /// The system pasteboard this handler copies to and pastes from. No default, for the same
    /// reason as `defaults`: a test on the real one would clobber the user's clipboard, and could
    /// paste whatever happens to be on it.
    public let pasteboard: NSPasteboard
    /// The modal prompts and confirmation behind rename / new-folder / delete. They default to
    /// the real `NativeAlerts`; tests substitute closures because the real ones block on NSAlert.
    private let renamePrompter: (_ currentName: String, _ validate: (String) -> String?) -> String?
    private let newFolderPrompter: (_ validate: (String) -> String?) -> String?
    private let deleteConfirmer: (_ itemNames: [String], _ hiddenByFilter: Int) -> Bool

    public init(
        syncManager: FileSyncManager,
        settings: SettingsManager,
        defaults: UserDefaults,
        pasteboard: NSPasteboard,
        renamePrompter: @escaping (_ currentName: String, _ validate: (String) -> String?) -> String? =
            { NativeAlerts.promptForRename(currentName: $0, validate: $1) },
        newFolderPrompter: @escaping (_ validate: (String) -> String?) -> String? =
            { NativeAlerts.promptForNewFolder(validate: $0) },
        deleteConfirmer: @escaping (_ itemNames: [String], _ hiddenByFilter: Int) -> Bool =
            { NativeAlerts.confirmDelete(for: $0, hiddenByFilter: $1) }
    ) {
        self.syncManager = syncManager
        self.settings = settings
        self.defaults = defaults
        self.pasteboard = pasteboard
        self.renamePrompter = renamePrompter
        self.newFolderPrompter = newFolderPrompter
        self.deleteConfirmer = deleteConfirmer
    }
    
    // MARK: - The run lock

    /// Refuses a write while a long run is going, and says why. The window greys every write
    /// control during a run, but some routes here are keys (⌫ in a list, ⌘V, ↩ to rename, the
    /// palette's New Folder), and a key can't be greyed, so the banner says what a greyed control's
    /// tooltip would. Undo waits too, but not here: ⌘Z is the window's, refused by `RunUndoGate`.
    private func refusedWhileRunning() -> Bool {
        guard let run = syncManager.activeProgress else { return false }
        let reason = run.runLockReason ?? Progress.genericRunLockReason
        Logger.shared.info("File action refused while a run is going: \(run.localizedDescription ?? "a run") — \(reason)")
        syncManager.banner = .refusal(reason, log: .warn)
        return true
    }

    // MARK: - Navigation
    
    /// Focuses the comparison on the selected folder (updates left/right relative path for the given pane).
    /// - Parameters:
    ///   - node: The folder node the user chose to “compare only this folder”.
    ///   - isLeft: `true` if the folder is in the left pane, `false` if in the right.
    ///   - leftProviderId: Current left-pane provider ID (for path lookup).
    ///   - rightProviderId: Current right-pane provider ID.
    /// - Parameter suppressLinkedNavigation: whether to ignore the "Link both panes" toggle for this
    ///   focus. **Required, with no default**, on purpose: the caller that needs it true is the
    ///   single-source rail, which has no visible sibling pane, and a silent default would drag the
    ///   hidden pane along, growing its history, overwriting its saved focus and recording "Recent"
    ///   folders the user never visited. No delegate test would notice: their fixtures use
    ///   `handler: nil`.
    public func focusFolder(_ node: FileNode, isLeft: Bool, leftProviderId: String, rightProviderId: String, suppressLinkedNavigation: Bool) {
        let side = isLeft ? "left" : "right"
        let rootPath = isLeft ? settings.rootPath(for: leftProviderId) : settings.rootPath(for: rightProviderId)
        // rootPath(for:) returns "" for a provider that vanished from settings; "" prefix-matches
        // every node, which would turn the node's absolute path into the "relative" focus path.
        guard !rootPath.isEmpty else {
            syncManager.present(paneUnavailableError(side: side))
            return
        }

        let expandedRoot = (rootPath as NSString).expandingTildeInPath
        // Same boundary rule as providerDisplayName(forPath:): the root itself or "root/…", never
        // a bare string prefix ("/data/foo" must not claim "/data/foobar"). `PathBoundary` also
        // admits a folder the root links in from outside (iCloud Drive's `Documents`, walked as
        // `~/Documents`). Where the id isn't spelled under the root at all (below a folder
        // symlink, or a root reached through one), the names down the pane's own tree place it.
        guard let relPath = syncManager.paneRelativePath(of: node, isLeft: isLeft, root: expandedRoot) else {
            syncManager.present(SyncError(
                title: "Can’t Focus Folder",
                message: "“\(node.name)” is not inside the \(side) pane’s folder. Rescan and try again.",
                path: node.id))
            return
        }

        Logger.shared.info("User focused folder: \(relPath.isEmpty ? "root" : relPath)")
        // Honor the "Link both panes" toggle here too: drilling into a folder from the file list
        // lands here, not on a breadcrumb crumb, and the link promises lock-step while drilling
        // down. When linked, drive both panes to the same subfolder.
        //
        // `suppressLinkedNavigation` is the single-source rail's opt-out: the rail reuses the left
        // pane's plumbing but has no visible sibling to drag along.
        if PaneLinkPreference.isLinked(in: defaults) && !suppressLinkedNavigation {
            // `relPath` is relative to this pane's root, and the sibling's need not share its
            // origin: a source lands at `openAt`, which is `""` for iCloud and two components deep
            // for Google Drive. The same string for both would send the sibling into a doubled
            // `Documents`, or into an unrelated folder, and the comparison would diff the wrong
            // pair.
            let sibling = PathBoundary.reanchor(relPath,
                                                from: syncManager.paneOpenAt(isLeft),
                                                to: syncManager.paneOpenAt(!isLeft))
            syncManager.focusBoth(left: isLeft ? relPath : sibling,
                                  right: isLeft ? sibling : relPath)
        } else {
            syncManager.focusOn(relativePath: relPath, isLeft: isLeft)
        }
    }
    
    // MARK: - File Transfers
    
    /// Copies the given items from one pane to the other (left → right or right → left).
    /// - Parameters:
    ///   - fromLeft: `true` if items are in the left pane (copy to right); `false` for right → left.
    ///   - leftProviderId: Provider ID for the left pane (root path).
    ///   - rightProviderId: Provider ID for the right pane.
    public func copyItems(_ nodes: [FileNode], fromLeft: Bool, leftProviderId: String, rightProviderId: String) {
        guard !refusedWhileRunning() else { return }
        let targetDisplayName = providerDisplayName(forProviderId: fromLeft ? rightProviderId : leftProviderId)

        Logger.shared.info("User initiated copy of \(nodes.count) item(s)")
        let hidden = syncManager.typeFilterHiddenCounts(inside: nodes)
        Task {
            guard let roots = await transferRoots(fromLeft: fromLeft, leftProviderId: leftProviderId, rightProviderId: rightProviderId) else { return }
            let receipt = SyncRunReceipt()
            let copiedNodes = await syncManager.copyItems(nodes: nodes, fromLeft: fromLeft, leftRoot: roots.left, rightRoot: roots.right,
                                                          fileManager: syncManager.fileManager, receipt: receipt)
            setTransferBanner(verb: "Copied", copiedNodes, to: targetDisplayName, hiddenByFilter: hidden, run: receipt.runId)
        }
    }

    /// Moves the given items to the opposite pane. Returns the nodes that were moved.
    /// Confirmation lives in the sync layer's Settings-gated `transferConfirmer`. Don't add a
    /// prompt here, or every move double-confirms.
    /// - Parameters: Same as `copyItems`; direction is determined by `fromLeft`.
    @discardableResult
    public func moveItems(_ nodes: [FileNode], fromLeft: Bool, leftProviderId: String, rightProviderId: String) async -> [FileNode] {
        guard !refusedWhileRunning() else { return [] }
        let hidden = syncManager.typeFilterHiddenCounts(inside: nodes)
        guard let roots = await transferRoots(fromLeft: fromLeft, leftProviderId: leftProviderId, rightProviderId: rightProviderId) else { return [] }

        let targetDisplayName = providerDisplayName(forProviderId: fromLeft ? rightProviderId : leftProviderId)

        Logger.shared.info("User initiated move of \(nodes.count) item(s)")
        let receipt = SyncRunReceipt()
        let movedNodes = await syncManager.moveItems(nodes: nodes, fromLeft: fromLeft, leftRoot: roots.left, rightRoot: roots.right,
                                                     fileManager: syncManager.fileManager, receipt: receipt)
        setTransferBanner(verb: "Moved", movedNodes, to: targetDisplayName, hiddenByFilter: hidden, run: receipt.runId)
        return movedNodes
    }

    /// The roots for a pane-to-pane transfer, or nil (after presenting an error) when either
    /// pane's provider is no longer known or the source root has vanished from disk, as when a
    /// rediscovery pass drops a provider while its stale tree is still showing.
    /// `settings.rootPath(for:)` returns "" for an unknown id, and an empty root must never reach
    /// the sync layer: it would resolve destinations against the process working directory.
    private func transferRoots(fromLeft: Bool, leftProviderId: String, rightProviderId: String) async -> (left: String, right: String)? {
        let leftRoot = settings.rootPath(for: leftProviderId)
        let rightRoot = settings.rootPath(for: rightProviderId)
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
                message: "The \(fromLeft ? "left" : "right") pane’s folder no longer exists on disk. Rescan before copying or moving items.",
                path: expandedSource))
            return nil
        }
        return (leftRoot, rightRoot)
    }

    private func paneUnavailableError(side: String) -> SyncError {
        SyncError(
            title: "Folder Unavailable",
            message: "The \(side) pane’s folder is no longer available. Rescan before continuing.")
    }
    
    /// Moves the given items into the directory at `destinationPath`.
    /// This is drag & drop's move route; unlike the cut+paste route it never touches the
    /// internal clipboard, and unlike the pane-to-pane move it targets an explicit directory.
    /// Confirmation lives in the sync layer's `transferConfirmer`, as for the pane-to-pane
    /// `moveItems` above: no prompt here.
    public func moveItems(_ nodes: [FileNode], toPath destinationPath: String) {
        guard !refusedWhileRunning() else { return }
        let destDisplayName = providerDisplayName(forPath: destinationPath)
        Logger.shared.info("User initiated move of \(nodes.count) item(s) to a dropped-on directory")
        let hidden = syncManager.typeFilterHiddenCounts(inside: nodes)
        Task {
            let receipt = SyncRunReceipt()
            let movedNodes = await syncManager.moveItems(nodes: nodes, toPath: destinationPath,
                                                         fileManager: syncManager.fileManager, receipt: receipt)
            setTransferBanner(verb: "Moved", movedNodes, to: destDisplayName, hiddenByFilter: hidden, run: receipt.runId)
        }
    }

    public func pasteItems(_ nodes: [FileNode], to targetDir: FileNode, isCut: Bool) {
        let validDestinationPath = targetDir.isDirectory ? targetDir.id : URL(fileURLWithPath: targetDir.id).deletingLastPathComponent().path
        pasteItems(nodes, toPath: validDestinationPath, isCut: isCut)
    }
    
    /// Resolves the directory, as `pasteItems(_:to:isCut:)` does, and hands over to
    /// `pasteClipboard(toPath:)`, which decides which clipboard to paste. One place answers where
    /// a paste goes, one what is pasted.
    public func pasteClipboard(to targetDir: FileNode) {
        let destination = targetDir.isDirectory
            ? targetDir.id
            : URL(fileURLWithPath: targetDir.id).deletingLastPathComponent().path
        pasteClipboard(toPath: destination)
    }

    /// ⌘C / ⌘X: into the app's own clipboard and onto the system pasteboard, so ⌘C here and ⌘V in
    /// Finder work. The change count returned later tells a paste whether SyncCloud still owns the
    /// pasteboard; see `FileSyncManager.clipboardPasteboardChangeCount`.
    public func handleCopyToClipboard(_ nodes: [FileNode], isCut: Bool) {
        // Nothing selected changes nothing: writing an empty set clears `NSPasteboard.general`,
        // so a ⌘C that copied nothing would throw away whatever the user copied in another app.
        guard !nodes.isEmpty else { return }
        Logger.shared.info("User \(isCut ? "cut" : "copied") \(nodes.count) item(s) to the clipboard")
        syncManager.clipboardNodes = nodes
        syncManager.clipboardIsCut = isCut
        // A cut writes what a copy writes: the pasteboard has no move flag that Finder reads, so a
        // cut here pasted in Finder copies. See `SystemClipboard.write`.
        syncManager.clipboardPasteboardChangeCount = SystemClipboard.write(paths: nodes.map(\.id),
                                                                             to: pasteboard)
    }
    
    public func pasteItems(_ nodes: [FileNode], toPath destinationPath: String, isCut: Bool) {
        guard !refusedWhileRunning() else { return }
        let destDisplayName = providerDisplayName(forPath: destinationPath)
        Logger.shared.info("User pasted \(nodes.count) item(s) (\(isCut ? "move" : "copy"))")
        let hidden = syncManager.typeFilterHiddenCounts(inside: nodes)
        Task {
            let receipt = SyncRunReceipt()
            if isCut {
                let movedNodes = await syncManager.moveItems(nodes: nodes, toPath: destinationPath,
                                                             fileManager: syncManager.fileManager, receipt: receipt)
                let successfullyMovedIds = Set(movedNodes.map { $0.id })
                syncManager.clipboardNodes.removeAll { successfullyMovedIds.contains($0.id) }
                if syncManager.clipboardNodes.isEmpty {
                    syncManager.clipboardIsCut = false
                    // Clear the pasteboard too, while we still own it: after the move its paths
                    // name files that are gone, and `hasFiles` reads what the pasteboard says,
                    // not the disk, so ⌘V and "Paste here" would stay enabled over nothing.
                    // Only while we own it: if anything has copied since, clearing would throw
                    // their copy away.
                    if syncManager.clipboardPasteboardChangeCount == pasteboard.changeCount {
                        pasteboard.clearContents()
                        syncManager.clipboardPasteboardChangeCount = pasteboard.changeCount
                    }
                }
                setTransferBanner(verb: "Moved", movedNodes, to: destDisplayName, hiddenByFilter: hidden, run: receipt.runId)
            } else {
                let copiedNodes = await syncManager.copyItems(nodes: nodes, toPath: destinationPath,
                                                              fileManager: syncManager.fileManager, receipt: receipt)
                setTransferBanner(verb: "Copied", copiedNodes, to: destDisplayName, hiddenByFilter: hidden, run: receipt.runId)
            }
        }
    }
    
    /// ⌘V — from whichever clipboard last had something put on it.
    ///
    /// One clipboard, decided by `changeCount` (`ClipboardSource.resolve`). While the app still
    /// owns the pasteboard its own list wins, because only that list carries `isCut` and can move.
    /// Once anything else has written, the pasteboard is what a paste means, as a user who just
    /// pressed ⌘C in Finder expects.
    ///
    /// A pasteboard holding something other than files pastes nothing rather than falling back to
    /// a stale in-app list: copying text elsewhere and pressing ⌘V here must not write files.
    public func pasteClipboard(toPath destinationPath: String) {
        guard !refusedWhileRunning() else { return }
        switch ClipboardSource.current(pasteboard: pasteboard,
                                       hasInAppItems: !syncManager.clipboardNodes.isEmpty,
                                       ownChangeCount: syncManager.clipboardPasteboardChangeCount) {
        case .inApp:
            pasteItems(syncManager.clipboardNodes, toPath: destinationPath,
                       isCut: syncManager.clipboardIsCut)
        case .system:
            // Read again rather than reusing the probe above: `nodes` drops URLs whose file is
            // gone, so this is the list that will actually be written.
            let nodes = SystemClipboard.nodes(from: pasteboard)
            guard !nodes.isEmpty else {
                Logger.shared.warning("Paste: the pasteboard's files are no longer on disk")
                return
            }
            Logger.shared.info("User pasted \(nodes.count) item(s) from another app")
            // Never a move: the pasteboard carries no cut flag, so the only safe reading of
            // somebody else's copy is a copy.
            pasteItems(nodes, toPath: destinationPath, isCut: false)
        case .none:
            Logger.shared.info("Paste: nothing on either clipboard to paste")
        }
    }

    private func providerDisplayName(forProviderId id: String) -> String {
        settings.availableProviders.first(where: { $0.id == id })?.displayName ?? "the other pane"
    }
    
    // Internal (not private) so the provider root-matching (incl. the "/" prefix boundary) is testable.
    func providerDisplayName(forPath path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        for p in settings.availableProviders {
            let root = (p.rootPath as NSString).expandingTildeInPath
            if PathBoundary.contains(expanded, under: root) {
                return p.displayName
            }
        }
        return "the other pane"
    }
    
    /// Success banner after a transfer; no banner when nothing was actually transferred.
    /// `verb` is the past-tense operation name ("Copied" or "Moved").
    ///
    /// `hiddenByFilter` is `typeFilterHiddenCounts` taken before the transfer: a folder carries
    /// everything in it, and the banner says how much of that the type filter was hiding, in the
    /// Trash prompt's words. Only what landed counts. `run` is the Sync History run the transfer
    /// recorded, which the message reports in Activity's Events.
    private func setTransferBanner(verb: String, _ nodes: [FileNode], to destinationName: String,
                                   hiddenByFilter: [String: Int] = [:], run: UUID? = nil) {
        guard !nodes.isEmpty else { return }
        let includes = Self.filterHidingClause(nodes.reduce(0) { $0 + (hiddenByFilter[$1.id] ?? 0) })
        // copyItems/moveItems register one grouped undo for the whole batch, so a single ⌘Z
        // reverses it and the banner may offer the button.
        syncManager.banner = .success((nodes.count == 1
            ? "\(verb) “\(nodes[0].name)” to \(destinationName)"
            : "\(verb) \(nodes.count) items to \(destinationName)") + includes, undoable: true)
            .reporting(run: run)
    }

    /// ". Includes 3 items the filter is hiding", or "" for none: the Trash prompt's words.
    static func filterHidingClause(_ hidden: Int) -> String {
        hidden == 0 ? "" : ". Includes \(hidden == 1 ? "1 item" : "\(hidden.formatted()) items") the filter is hiding"
    }
    
    // MARK: - Mutations
    
    public func beginRename(_ node: FileNode) {
        guard !refusedWhileRunning() else { return }
        if let newName = renamePrompter(node.name, FileSyncManager.validateItemName), newName != node.name {
            Logger.shared.info("User initiated rename of '\(node.name)' to '\(newName)'")
            Task {
                await syncManager.renameItem(at: node.id, to: newName, fileManager: syncManager.fileManager)
            }
        }
    }
    
    public func beginCreateFolder(in path: String) {
        guard !refusedWhileRunning() else { return }
        // "" is the root of a pane whose provider vanished from settings (`settings.rootPath(for:)`
        // for an unknown id) while its stale tree is still showing. The sync layer refuses it too;
        // stopping here, like focusFolder/transferRoots, means no prompt for a name the folder
        // can't get.
        guard !path.isEmpty else {
            syncManager.present(SyncError(
                title: "Folder Unavailable",
                message: "The pane’s folder is no longer available. Rescan before continuing."))
            return
        }
        if let folderName = newFolderPrompter(FileSyncManager.validateItemName) {
            Logger.shared.info("User initiated create folder: '\(folderName)'")
            Task {
                await syncManager.createFolder(named: folderName, in: path, fileManager: syncManager.fileManager)
            }
        }
    }
    
    /// Deletes after the confirmation alert, or at once when "Confirm before deleting" is off
    /// (items still go to the Trash and stay undoable; a permanent delete keeps its own
    /// confirmation regardless).
    ///
    /// - Parameter alwaysConfirm: asks regardless of the setting. The pane bar's Delete button
    ///   passes it: it sits beside reversible controls, where a stray click is a different risk
    ///   from a menu item chosen by name, which is what the setting is about. Per call and off by
    ///   default, so the row menu and ⌘⌫ keep honouring the preference.
    public func confirmDelete(_ nodes: [FileNode], alwaysConfirm: Bool = false) {
        guard !refusedWhileRunning() else { return }
        // A folder goes with everything in it, including what the type filter hides. The prompt
        // says so; with no prompt, the result banner has to.
        var unsaidHidden: [String: Int] = [:]
        if alwaysConfirm || GeneralSettings.shouldConfirmBeforeDelete(defaults) {
            guard deleteConfirmer(nodes.map { $0.name }, syncManager.itemsHiddenByTypeFilter(inside: nodes)) else { return }
            Logger.shared.info("User confirmed deletion of \(nodes.count) item(s)")
        } else {
            unsaidHidden = syncManager.typeFilterHiddenCounts(inside: nodes)
            Logger.shared.info("User deleted \(nodes.count) item(s) (confirmation disabled in Settings)")
        }
        Task {
            let outcome = await syncManager.deleteItems(at: nodes.map { $0.id }, fileManager: syncManager.fileManager,
                                                        reportsNothingToDo: true)
            guard !unsaidHidden.isEmpty,
                  outcome.trashed + outcome.trashedWithoutLocation + outcome.permanentlyDeleted > 0,
                  var banner = syncManager.banner, banner.severity == .success else { return }
            // Only what left the disk counts, as a transfer counts only what landed.
            let hidden = nodes.reduce(0) { total, node in
                guard let count = unsaidHidden[node.id],
                      !syncManager.fileManager.fileExists(atPath: node.id) else { return total }
                return total + count
            }
            guard hidden > 0 else { return }
            banner.message += Self.filterHidingClause(hidden)
            syncManager.banner = banner
        }
    }
}

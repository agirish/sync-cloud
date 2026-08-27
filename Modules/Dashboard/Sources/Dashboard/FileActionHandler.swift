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
    /// The system pasteboard this handler copies to and pastes from — injected for the same reason
    /// `defaults` is: a test that used the real one would clobber the developer's clipboard mid-session,
    /// and one such test wrote a file into a temp dir from whatever happened to be on it.
    public let pasteboard: NSPasteboard
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
        pasteboard: NSPasteboard = .general,
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
        self.pasteboard = pasteboard
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
    /// - Parameter suppressLinkedNavigation: whether to ignore the "Link both panes" toggle for this
    ///   focus. **Required, with no default**, and that is the guard rather than a style choice: the
    ///   one caller that needs it true is the single-source rail, which has no visible sibling pane,
    ///   and dropping the argument there compiled silently and fell back to honoring the link —
    ///   dragging the hidden pane along, growing its history, overwriting its saved focus for the
    ///   next launch and recording "Recent" folders the user never visited. Nothing caught that:
    ///   every delegate fixture is built with `handler: nil`, so the navigation half is a no-op in
    ///   all of them, and the rule test calls this method directly, making itself its only reader.
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
            // `relPath` is relative to THIS pane's root, and the sibling's root need not share its
            // origin any more — a source lands at `openAt`, which is `""` for iCloud and two
            // components deep for Google Drive. Handing the same string to both sent the sibling
            // into a doubled `Documents` one way and into a real but unrelated top-level folder the
            // other, where the comparison then diffed the wrong pair.
            let sibling = PathBoundary.reanchor(relPath,
                                                from: syncManager.paneOpenAt(isLeft),
                                                to: syncManager.paneOpenAt(!isLeft))
            syncManager.focusBoth(left: isLeft ? relPath : sibling,
                                  right: isLeft ? sibling : relPath)
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
    
    /// Resolves the directory and hands over to `pasteClipboard(toPath:)`, which owns the
    /// which-clipboard decision — the same resolution `pasteItems(_:to:isCut:)` does, kept here so
    /// there is exactly one place that answers "where is a paste going" and one that answers
    /// "what is being pasted".
    public func pasteClipboard(to targetDir: FileNode) {
        let destination = targetDir.isDirectory
            ? targetDir.id
            : URL(fileURLWithPath: targetDir.id).deletingLastPathComponent().path
        pasteClipboard(toPath: destination)
    }

    /// ⌘C / ⌘X — into the app's own clipboard **and** onto the system pasteboard.
    ///
    /// The second half is what makes ⌘C here and ⌘V in Finder work. The change count it returns is
    /// what later tells a paste whether SyncCloud still owns the pasteboard; see
    /// `FileSyncManager.clipboardPasteboardChangeCount`.
    public func handleCopyToClipboard(_ nodes: [FileNode], isCut: Bool) {
        // **Nothing selected changes nothing.** Before the pasteboard was involved this was
        // harmless — it emptied a list that only this app read. It is not harmless now: writing an
        // empty set clears `NSPasteboard.general`, so a ⌘C that copied nothing would throw away
        // whatever the user had copied in another app. No caller does this today; the guard is
        // here because the consequence of one that did changed when the bridge landed.
        guard !nodes.isEmpty else { return }
        Logger.shared.info("User \(isCut ? "cut" : "copied") \(nodes.count) item(s) to the clipboard")
        syncManager.clipboardNodes = nodes
        syncManager.clipboardIsCut = isCut
        // A cut writes what a copy writes: the pasteboard has no move flag that Finder reads, so a
        // cut here pasted THERE copies. See `SystemClipboard.write`.
        syncManager.clipboardPasteboardChangeCount = SystemClipboard.write(paths: nodes.map(\.id),
                                                                             to: pasteboard)
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
                    // **And the pasteboard with it, while we still own it.** A cut's paths are on
                    // the system pasteboard too, and after the move they name files that are no
                    // longer there. `hasFiles` reads what the pasteboard *says*, not what is on
                    // disk — checking would be a `stat` per URL per render — so leaving them would
                    // keep ⌘V and "Paste here" enabled over a paste that finds nothing and logs.
                    // A control that cannot act does not offer to.
                    //
                    // Guarded on ownership for the obvious reason: if anything has copied since,
                    // the board is theirs and clearing it would throw their copy away.
                    if syncManager.clipboardPasteboardChangeCount == pasteboard.changeCount {
                        pasteboard.clearContents()
                        syncManager.clipboardPasteboardChangeCount = pasteboard.changeCount
                    }
                }
                setTransferBanner(verb: "Moved", movedNodes, to: destDisplayName)
            } else {
                let copiedNodes = await syncManager.copyItems(nodes: nodes, toPath: destinationPath)
                setTransferBanner(verb: "Copied", copiedNodes, to: destDisplayName)
            }
        }
    }
    
    /// ⌘V — from whichever clipboard last had something put on it.
    ///
    /// **One rule, one clipboard, decided by `changeCount`** (`ClipboardSource.resolve`). While the
    /// app still owns the pasteboard its own list wins, because that list carries `isCut` and is
    /// therefore the only path that can move rather than copy. Once anything else has written, the
    /// pasteboard is what a paste means — which is what a user who just pressed ⌘C in Finder
    /// expects, and what a single-clipboard platform promises.
    ///
    /// A pasteboard holding something that is not files ends in `.none` and pastes nothing, rather
    /// than falling back to a stale in-app list: copying text elsewhere and then pressing ⌘V here
    /// must not write files nobody asked for.
    public func pasteClipboard(toPath destinationPath: String) {
        switch ClipboardSource.current(pasteboard: pasteboard,
                                       hasInAppItems: !syncManager.clipboardNodes.isEmpty,
                                       ownChangeCount: syncManager.clipboardPasteboardChangeCount) {
        case .inApp:
            pasteItems(syncManager.clipboardNodes, toPath: destinationPath,
                       isCut: syncManager.clipboardIsCut)
        case .system:
            // Read again rather than reusing the probe above: `nodes` drops URLs whose file is no
            // longer there, so this is the list that will actually be written, not the one that
            // decided which clipboard to use.
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
            let root = (p.rootPath as NSString).expandingTildeInPath
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
        // "" is the root of a pane whose provider vanished from settings (`settings.rootPath(for:)`
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

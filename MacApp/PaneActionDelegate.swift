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
    /// True when this delegate serves the Tidy single-source rail: there is no visible sibling
    /// pane, so linked navigation (the 🔗 toggle) must not drag the hidden right pane along.
    let isSingleSource: Bool
    let forceRefreshAction: () -> Void
    /// Shows the in-app Info inspector for a path (replaces Finder's Get Info from the pane menu).
    let onGetInfo: (String) -> Void
    /// Raises the window's destination picker. Only the single-source rail offers the menu item
    /// that reaches this, so the comparison panes pass a no-op.
    let onChooseDestination: ([FileNode], Bool) -> Void

    /// A snapshot of the ignore set, carried purely so `isEquivalent` can notice it changing.
    ///
    /// It is never read by `isNodeIgnored`, which still asks the manager for the live answer. It
    /// exists because the pane's ignored-row treatment — the struck-through name — is rendered
    /// eagerly, unlike everything else the delegate answers (the context menu is built when it
    /// opens, so it always sees live state). Ignoring a row publishes `ignoredPaths`, which
    /// re-renders the host but need not change ANY of the values `FileTreeView.==` compares: the
    /// row is still in the tree, at the same path, in the same selection. Without a token here the
    /// pane would skip the re-render and the strikethrough would not appear until something
    /// unrelated moved.
    ///
    /// A snapshot rather than a counter because the inputs are plural — the session set, the
    /// durable store, and the remember-ignores switch all feed `effectiveIgnoredPaths` — and a
    /// hand-maintained generation bumped at three call sites is one forgotten `didSet` away from
    /// exactly the silent staleness this is here to prevent. Comparing the set costs one pass over
    /// a handful of entries.
    let ignoreStateToken: Set<String>

    /// Opts this delegate into `FileTreeView`'s equality (see `FileActionDelegate.isEquivalent`),
    /// which is what lets a pane skip re-rendering — and with it every visible row — when the only
    /// thing that moved was some unrelated corner of the manager.
    ///
    /// Every stored property is accounted for. The six values are compared outright; the three
    /// references are compared by identity; and the three closures are ignored, which is the one
    /// claim here that needs justifying.
    ///
    /// They are safe to ignore because none of them captures a decision. `forceRefreshAction`,
    /// `onGetInfo` and `onChooseDestination` are all built by `ContentView` and read their state
    /// back through property wrappers (`@State`, `@AppStorage`, `@ObservedObject`,
    /// `@EnvironmentObject`) whose storage outlives any single render — so a closure captured three
    /// renders ago sees exactly what one built this instant would. What they must never do is read
    /// a plain `let` snapshot off the captured view; if one ever does, it belongs in the comparison
    /// below rather than outside it.
    func isEquivalent(to other: FileActionDelegate) -> Bool {
        guard let other = other as? PaneActionDelegate else { return false }
        return handler === other.handler
            && syncManager === other.syncManager
            && settings === other.settings
            && isLeft == other.isLeft
            && leftProviderId == other.leftProviderId
            && rightProviderId == other.rightProviderId
            && isSingleSource == other.isSingleSource
            && ignoreStateToken == other.ignoreStateToken
    }

    func handleRefresh() {
        forceRefreshAction()
    }
    func handleFocus(_ node: FileNode) { handler?.focusFolder(node, isLeft: isLeft, leftProviderId: leftProviderId, rightProviderId: rightProviderId, suppressLinkedNavigation: isSingleSource) }
    func handleCopy(_ nodes: [FileNode]) { handler?.copyItems(nodes, fromLeft: isLeft, leftProviderId: leftProviderId, rightProviderId: rightProviderId) }
    func handleMove(_ nodes: [FileNode]) { 
        Task {
            _ = await handler?.moveItems(nodes, fromLeft: isLeft, leftProviderId: leftProviderId, rightProviderId: rightProviderId) 
        }
    }
    func handleDelete(_ nodes: [FileNode]) { handler?.confirmDelete(nodes) }
    func handleChooseDestination(_ nodes: [FileNode], isMove: Bool) { onChooseDestination(nodes, isMove) }
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
    func handleGetInfo(for path: String) { onGetInfo(path) }
    func handleSort(_ option: SortOption) { 
        Logger.shared.info("User changed sort option to \(option)")
        syncManager.sortOption = option 
    }
    func handleIgnore(_ nodes: [FileNode]) {
        // Root + in-pane focus for THIS pane, composed in PaneLogic so the pairing (and the
        // tilde expansion) is pinned by tests — a wrong base persists wrong relative paths
        // into the durable ignore store.
        let basePath = PaneLogic.ignoreBasePath(
            isLeft: isLeft,
            leftRoot: settings.path(for: leftProviderId),
            rightRoot: settings.path(for: rightProviderId),
            leftRelativePath: syncManager.leftRelativePath,
            rightRelativePath: syncManager.rightRelativePath)

        // Convert to relative paths from current focal point so they sync across panes seamlessly
        let relativeTargets = PaneLogic.relativeIgnoreTargets(nodeIds: nodes.map(\.id), basePath: basePath)
        // The manager toggles against the EFFECTIVE ignore set (session + remembered items),
        // so a node ignored in an earlier session un-ignores instead of re-ignoring.
        syncManager.toggleIgnored(focusRelativePaths: Set(relativeTargets))
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

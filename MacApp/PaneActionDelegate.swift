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
    /// True when this delegate serves the single-source rail: with no visible sibling pane, linked
    /// navigation (the 🔗 toggle) must not drag the hidden right pane along.
    let isSingleSource: Bool
    /// Whether this surface's Open also re-aims Organize's lenses: Organize's own rail, and nothing
    /// else. Kept apart from `isSingleSource`, a layout question (how many trees are on screen)
    /// that Browse and Storage answer the same way the rail does.
    let ownsOrganizeScope: Bool
    /// Whether this is Edit's own source pane, whose rows are dimmed when the editor would refuse
    /// them and open on a single click. Every other surface answers `nil` to `editorRefusal`. Kept
    /// apart from `isSingleSource` for `ownsOrganizeScope`'s reason.
    let servesEditor: Bool
    let forceRefreshAction: () -> Void
    /// Shows the in-app Info inspector for a path (in place of Finder's Get Info in the pane menu).
    let onGetInfo: (String) -> Void
    /// Raises the window's destination picker. Only the single-source rail offers the menu item
    /// that reaches this, so the comparison panes pass a no-op.
    let onChooseDestination: ([FileNode], Bool) -> Void
    /// Hands a file to the Editor workspace. Built by `ContentView`, which owns the workspace
    /// selection and the document (see `ContentView+Editor`).
    ///
    /// It takes no side on purpose: the editor reads the left pane only, so re-rooting the right
    /// one would move a pane the editor never draws. See ``ContentView/handOffToEditor(_:)``.
    let onOpenInEditor: (String) -> Void

    /// A snapshot of the ignore set, carried only so `isEquivalent` notices it changing.
    ///
    /// `isNodeIgnored` never reads it; it asks the manager for the live answer. It exists because
    /// the row's struck-through name is rendered eagerly, and so is its context menu, which SwiftUI
    /// builds with the row (its labels can be a render old, which is why its Favorites item acts on
    /// what its label said: `FileContextMenu.favoriteLabelStillHolds`). Ignoring a row re-renders
    /// the host but need not change any value `FileTreeView.==` compares, so without this token the
    /// pane would skip the re-render and the strikethrough would wait for something unrelated to
    /// move.
    ///
    /// A snapshot rather than a counter because three inputs feed `effectiveIgnoredPaths` (the
    /// session set, the durable store and the remember-ignores switch), and a generation bumped at
    /// three call sites is one forgotten `didSet` from going stale. Comparing the set is one pass
    /// over a handful of entries.
    let ignoreStateToken: Set<String>

    /// A snapshot of the kept-names set, carried for `ignoreStateToken`'s reason.
    ///
    /// The row badge is the second eagerly rendered delegate answer. Keeping a name changes what
    /// every row with that name draws and nothing else the pane compares, so without this the pane
    /// would skip the re-render and the dismissed badge would stay on screen. The set rather than a
    /// count: withdrawing one keep while adding another leaves the count unchanged.
    let keptNamesToken: Set<String>

    /// Opens Duplicates on this pane's source and reveals the group holding the file. Ignored by
    /// `isEquivalent` like the other closures: it reads its state through the view's property
    /// wrappers, so an old capture sees what a fresh one would.
    let onFindDuplicatesOf: (FileNode) -> Void
    /// Points Organize at a folder; see ``handleOrganizeFolder(_:)``.
    let onOrganizeFolder: (FileNode) -> Void
    /// The route to the shape question: aims the Restructure lens at the row's folder.
    let onCheckFolderShape: (FileNode) -> Void
    /// Moves Organize's scope to a folder without starting a scan; see ``handleFocus(_:)``.
    ///
    /// Unlike `onOrganizeFolder`, which also scans: Open is navigation, and a filing pass behind
    /// every folder you step into would be a scan per click. Scope filters rather than rescans, so
    /// the other four lenses re-answer for free; To File keeps the last scan's findings until the
    /// user asks again.
    let onOrganizeScope: (FileNode) -> Void
    /// Opens a folder in a new tab of this pane; see ``handleOpenInNewTab(_:)``. Ignored by
    /// `isEquivalent` like the closures beside it.
    let onOpenInNewTab: (FileNode) -> Void
    /// A new tab on a folder named by path: the background menu's ⌘T, with no node under the
    /// pointer to hand over.
    let onNewTabHere: (String) -> Void
    /// Closes this pane's active tab.
    let onCloseTab: () -> Void
    /// Adds a folder to Favorites or takes it out; see ``handleToggleFolderFavorite(_:)``.
    /// Defaulted so the delegate's own tests need not name a route they don't test.
    var onToggleFolderFavorite: (FileNode) -> Void = { _ in }

    /// Opens the file-pair viewer on two files; see
    /// ``handleCompareFilePair(_:with:secondIsInOtherPane:)``. Defaulted for the same reason as the
    /// line above.
    var onCompareFilePair: (FileNode, FileNode, Bool) -> Void = { _, _, _ in }
    var onArmComparePick: (FileNode) -> Void = { _ in }
    /// Runs a PDF tool from a row's menu; see ``handlePDFTool(_:paths:)``. Defaulted, and ignored
    /// by `isEquivalent`: it reaches the window's `PanePDFTools` and workspace through `@State`.
    var onPDFTool: (PDFToolRequest, [String]) -> Void = { _, _ in }
    /// Saves files as PDF from a row's menu; see ``handleSaveAsPDF(paths:)``. Defaulted and ignored
    /// by `isEquivalent` on the same terms: it reaches the window's `PaneSaveAsPDF` through
    /// `@State`.
    var onSaveAsPDF: ([String]) -> Void = { _ in }
    /// Forwarded from the host's `ComparePick`; nil when no pick is live.
    var armedComparePath: String?

    /// Ask Claude About This and Hide from Claude. Off unless the window turns it on, so the
    /// delegate's own tests draw the menus without them.
    var canAskClaude = false
    var onAskClaude: ([String]) -> Void = { _ in }
    /// File with Claude: the same rows, with the question asked.
    var onFileWithClaude: ([String]) -> Void = { _ in }
    var askClaudeRefusalFor: ([String]) -> String? = { _ in nil }
    var hiddenFromClaude: (String) -> Bool = { _ in false }
    var hiddenFromClaudeCover: (String) -> String? = { _ in nil }
    var onSetHiddenFromClaude: (FileNode, Bool) -> Void = { _, _ in }
    /// The Never show Claude list, carried for `ignoreStateToken`'s reason: the row menu's Hide or
    /// Show label is built with the row, and a change to the list moves nothing else the pane
    /// compares.
    var hiddenFromClaudeToken: [String] = []

    /// Opts this delegate into `FileTreeView`'s equality (see `FileActionDelegate.isEquivalent`),
    /// so a pane can skip re-rendering every visible row when only an unrelated corner of the
    /// manager moved.
    ///
    /// Every stored property is accounted for: values compared outright, the three references by
    /// identity, and the closures ignored. Ignoring them is safe because none captures a decision:
    /// each is built by `ContentView` and reads its state through property wrappers (`@State`,
    /// `@AppStorage`, `@ObservedObject`, `@EnvironmentObject`) whose storage outlives any render,
    /// so an old capture sees what a fresh one would. A closure here must never read a plain `let`
    /// snapshot off the captured view; one that does belongs in the comparison below.
    func isEquivalent(to other: FileActionDelegate) -> Bool {
        guard let other = other as? PaneActionDelegate else { return false }
        return handler === other.handler
            && syncManager === other.syncManager
            && settings === other.settings
            && isLeft == other.isLeft
            && leftProviderId == other.leftProviderId
            && rightProviderId == other.rightProviderId
            && isSingleSource == other.isSingleSource
            && ownsOrganizeScope == other.ownsOrganizeScope
            // Rendered eagerly per row, so it must take part: left out, switching into Edit doesn't
            // re-render the pane and its rows stay bright until something unrelated moves.
            && servesEditor == other.servesEditor
            && ignoreStateToken == other.ignoreStateToken
            && keptNamesToken == other.keptNamesToken
            && canAskClaude == other.canAskClaude
            && hiddenFromClaudeToken == other.hiddenFromClaudeToken
    }

    func handleRefresh() {
        forceRefreshAction()
    }
    /// Re-roots this pane at a folder: the row menu's Open on the single-source rail, and "Compare
    /// only this folder" on the comparison panes.
    ///
    /// Open also moves Organize's scope; browsing does not. The scope must not follow whatever
    /// folder the pane drifts to, because the left pane is where destinations get inspected while
    /// filing and a following scope would destroy the queue. Open is the user naming a folder, the
    /// same act as "Organize This Folder…", so the pane and the lenses must agree on it.
    ///
    /// Gated on `ownsOrganizeScope`, not `isSingleSource`: Browse and Storage are single-source
    /// too, and Open there must not re-aim Organize at a folder the user never gave it (the scope
    /// survives relaunch, and nothing would look wrong). On the comparison panes the call is a
    /// claim about the comparison, so it leaves the lenses alone too. That is also why this isn't
    /// hooked in `FileActionHandler.focusFolder`, which every surface shares and can't tell the
    /// verbs apart.
    ///
    /// Routed through `onOrganizeScope` → `ContentView.setOrganizeScope`, so opening the provider
    /// root clears the scope rather than encoding the global view a second way.
    func handleFocus(_ node: FileNode) {
        handler?.focusFolder(node, isLeft: isLeft, leftProviderId: leftProviderId, rightProviderId: rightProviderId, suppressLinkedNavigation: isSingleSource)
        if ownsOrganizeScope, node.isDirectory { onOrganizeScope(node) }
    }
    func handleCopy(_ nodes: [FileNode]) { handler?.copyItems(nodes, fromLeft: isLeft, leftProviderId: leftProviderId, rightProviderId: rightProviderId) }
    func handleMove(_ nodes: [FileNode]) { 
        Task {
            _ = await handler?.moveItems(nodes, fromLeft: isLeft, leftProviderId: leftProviderId, rightProviderId: rightProviderId) 
        }
    }
    func handleDelete(_ nodes: [FileNode]) { handler?.confirmDelete(nodes) }
    func handleChooseDestination(_ nodes: [FileNode], isMove: Bool) { onChooseDestination(nodes, isMove) }
    func handleOpenInEditor(_ path: String) { onOpenInEditor(path) }
    func handleCopyToClipboard(_ nodes: [FileNode], isCut: Bool) { 
        handler?.handleCopyToClipboard(nodes, isCut: isCut)
    }
    func handlePaste(_ targetDir: FileNode) { handler?.pasteClipboard(to: targetDir) }
    func handlePasteExplicit(_ targetDir: FileNode, nodes: [FileNode]) { handler?.pasteItems(nodes, to: targetDir, isCut: false) }
    func handlePasteToPath(_ path: String) { handler?.pasteClipboard(toPath: path) }
    func handleRename(_ node: FileNode) { handler?.beginRename(node) }

    /// This pane's name ruleset: the source's own, except where
    /// `SettingsManager.nameRuleType(for:)` substitutes OneDrive (the strictest) for an id it can't
    /// resolve, so an unresolved source over-reports rather than letting a sync-breaking name pass,
    /// and the user's `folderNameRule` for a folder source, which has no rules of its own.
    private var paneProviderType: CloudProvider.ProviderType {
        settings.nameRuleType(for: isLeft ? leftProviderId : rightProviderId)
    }

    func riskyName(for node: FileNode) -> RiskyName? {
        // Asked by every visible row's menu on every render, since SwiftUI builds a row's context
        // menu with the row. The memo answers the common case, a clean name; only a flagged name
        // pays for the full verdict. The memo's verdict, not `riskyNameReason`'s: that one drops
        // kept names, and "Stop Allowing This Name" is offered on a kept one.
        guard RiskyNameBadgeCache.reason(name: node.name, isDirectory: node.isDirectory,
                                         provider: paneProviderType) != nil else { return nil }
        // The relative path only labels the row in the batch list; a single-file fix renames in
        // place from the absolute path, so the node's own name is the honest value here.
        return NameNormalizer.risky(name: node.name, relativePath: node.name, absolutePath: node.id,
                                    isDirectory: node.isDirectory, provider: paneProviderType)
    }

    /// The badge's answer, memoized by provider and name; see `RiskyNameBadgeCache` for why this
    /// one can't be computed fresh each time. The kept check comes first and is a set lookup, so a
    /// name the user chose to keep costs less than one they haven't.
    func riskyNameReason(forName name: String, isDirectory: Bool) -> String? {
        guard !syncManager.isKeptName(name) else { return nil }
        return RiskyNameBadgeCache.reason(name: name, isDirectory: isDirectory, provider: paneProviderType)
    }

    /// See `FileActionDelegate.editorRefusal`. The too-large sentence is the rail's, word for word,
    /// from the one static both surfaces call.
    func editorRefusal(forPath path: String, isDirectory: Bool, size: Int) -> String? {
        guard servesEditor, !isDirectory else { return nil }
        if !EditableText.opensInEdit(path: path) { return "Not a kind Edit opens." }
        // A PDF is drawn by PDFKit, not read into a text buffer, so the text size limit doesn't
        // apply.
        if EditableText.isPDF(path: path) { return nil }
        return EditorRailEntry.tooLargeReason(size: size)
    }

    func isKeptName(_ name: String) -> Bool { syncManager.isKeptName(name) }

    func handleKeepName(_ node: FileNode) {
        syncManager.keptNamesStore?.keep(node.name)
    }

    func handleStopKeepingName(_ node: FileNode) {
        syncManager.keptNamesStore?.stopKeeping(node.name)
    }

    /// A real window is behind this delegate, so the row menu may offer the item.
    var canFindDuplicates: Bool { true }

    func handleFindDuplicates(_ node: FileNode) {
        // Files only. The menu gates on this too; checking here keeps the guarantee with the
        // handler, not only with its one caller.
        guard !node.isDirectory else { return }
        onFindDuplicatesOf(node)
    }

    /// A real window is behind this delegate, so the row menu may offer the item.
    var canCompareFilePair: Bool { true }

    func handleCompareFilePair(_ first: FileNode, with second: FileNode,
                               secondIsInOtherPane: Bool) {
        // Files only, both sides, checked here as well as in the menu.
        guard !first.isDirectory, !second.isDirectory else { return }
        // And never a file against itself: a cross-pane pick names the same path twice when both
        // panes show one folder, and the viewer would report "identical" about nothing.
        guard first.id != second.id else { return }
        onCompareFilePair(first, second, secondIsInOtherPane)
    }

    func handleArmComparePick(_ node: FileNode) {
        // Files only, checked here as well as in the menu. Arming a folder would enter a mode whose
        // only completion is a pair the viewer can't render.
        guard !node.isDirectory else { return }
        onArmComparePick(node)
    }

    /// A real window is behind this delegate, so the row menu may offer the item.
    var canOrganizeFolder: Bool { true }

    /// A real pane is behind this delegate, so it has a strip to open a tab in.
    var canOpenInNewTab: Bool { true }

    /// A real sidebar is behind this delegate, so Favorites is a list that exists.
    var canFavoriteFolder: Bool { true }

    /// Answered against this pane's root, which is why the delegate is built per pane. A SwiftUI
    /// context menu doesn't move focus, so a right-click in the unfocused pane would otherwise be
    /// answered against the other pane's root (the trap `providerRootExpanded(forProviderId:)`
    /// documents). The wrong root usually still relativizes, so the menu would silently read
    /// "Remove from Favorites" about a same-named folder in the other account.
    func isFolderFavorite(_ node: FileNode) -> Bool {
        guard let place = favoritePlace(for: node) else { return false }
        return FolderJumpStore.shared.pinnedPaths(forRoot: place.root).contains(place.relativePath)
    }

    func handleToggleFolderFavorite(_ node: FileNode) {
        // Folders only: Favorites lists places you go, and a pane can't be pointed at a file.
        // Checked here as well as in the menu.
        guard node.isDirectory else { return }
        onToggleFolderFavorite(node)
    }

    /// This pane's root plus the node's path within it, or nil when the node is outside the pane.
    ///
    /// A root is refused, as the pane header's jump menu does: a source's root is always in the
    /// sidebar's Locations section, so favoriting it would add a second row for the same place.
    func favoritePlace(for node: FileNode) -> (root: String, relativePath: String)? {
        Self.favoritePlace(nodePath: node.id, isDirectory: node.isDirectory, paneRoot: paneRootPath)
    }

    /// The rule on its own, so it can be asserted without building a pane. `nonisolated` because it
    /// touches only its arguments, so a test needn't hop to the main actor.
    nonisolated static func favoritePlace(nodePath: String, isDirectory: Bool,
                              paneRoot: String) -> (root: String, relativePath: String)? {
        guard isDirectory else { return nil }
        let root = (paneRoot as NSString).expandingTildeInPath
        guard !root.isEmpty, let relative = PathBoundary.relativize(nodePath, under: root),
              !relative.isEmpty else { return nil }
        return (FolderJumpStore.key(forRoot: root), relative)
    }

    /// The root of the pane this delegate belongs to, never "the focused pane's root".
    var paneRootPath: String { settings.rootPath(for: isLeft ? leftProviderId : rightProviderId) }

    /// Only past a second tab: at one, closing the tab would close the window, and "Close Tab" that
    /// closes the window is a trap. Read from the manager, so the menu is right on the render it
    /// opens in.
    var canCloseTab: Bool { syncManager.paneTabs(isLeft: isLeft).count > 1 }

    func handleNewTab(at path: String) {
        onNewTabHere(path)
    }

    func handleCloseTab() {
        onCloseTab()
    }

    /// A real window is behind this delegate, with somewhere to present a tool's sheet.
    var canRunPDFTools: Bool { true }

    func handlePDFTool(_ request: PDFToolRequest, paths: [String]) {
        // PDFs only, and passwords one file at a time; checked here as well as in the menu.
        guard !paths.isEmpty, paths.allSatisfy({ EditableText.isPDF(path: $0) }),
              paths.count == 1 || request.runsOnSeveral else { return }
        onPDFTool(request, paths)
    }

    /// A real window is behind this delegate, with a foot to show the run's banner in.
    var canSaveAsPDF: Bool { true }

    func askClaudeRefusal(_ nodes: [FileNode]) -> String? { askClaudeRefusalFor(nodes.map(\.id)) }

    func handleAskClaude(_ nodes: [FileNode]) {
        guard canAskClaude, !nodes.isEmpty else { return }
        onAskClaude(nodes.map(\.id))
    }

    func handleFileWithClaude(_ nodes: [FileNode]) {
        guard canAskClaude, !nodes.isEmpty else { return }
        onFileWithClaude(nodes.map(\.id))
    }

    func isHiddenFromClaude(_ node: FileNode) -> Bool { hiddenFromClaude(node.id) }

    func hiddenFromClaudeCover(_ node: FileNode) -> String? { hiddenFromClaudeCover(node.id) }

    func handleSetHiddenFromClaude(_ node: FileNode, hidden: Bool) {
        guard canAskClaude else { return }
        onSetHiddenFromClaude(node, hidden)
    }

    func handleSaveAsPDF(paths: [String]) {
        // Only what an engine converts; checked here as well as in the menu.
        guard !paths.isEmpty, paths.allSatisfy({ SaveAsPDFKind.of(path: $0) != nil }) else { return }
        onSaveAsPDF(paths)
    }

    func handleOpenInNewTab(_ node: FileNode) {
        // Folders only: a tab is a location. Checked here as well as in the menu.
        guard node.isDirectory else { return }
        onOpenInNewTab(node)
    }

    func handleOrganizeFolder(_ node: FileNode) {
        // Folders only. The menu gates on this too; checking here keeps the guarantee with the
        // handler, not only with its one caller.
        guard node.isDirectory else { return }
        onOrganizeFolder(node)
    }

    func handleCheckFolderShape(_ node: FileNode) {
        // Folders only, for its sibling's reason: a file has no shape to check.
        guard node.isDirectory else { return }
        onCheckFolderShape(node)
    }

    func handleFixName(_ node: FileNode) {
        guard let risky = riskyName(for: node) else { return }
        Logger.shared.info("User requested a name fix for \(node.id) — \(risky.reason)")
        Task { await syncManager.normalizeNames([risky]) }
    }
    func handleCreateFolder(at path: String) { handler?.beginCreateFolder(in: path) }
    func handleGetInfo(for path: String) { onGetInfo(path) }
    func handleSort(_ option: SortOption) { 
        Logger.shared.info("User changed sort option to \(option)")
        syncManager.sortOption = option 
    }
    func handleIgnore(_ nodes: [FileNode]) {
        // Root plus in-pane focus for this pane, composed in PaneLogic so the pairing and the tilde
        // expansion are pinned by tests: a wrong base persists wrong relative paths into the
        // durable ignore store.
        let basePath = PaneLogic.ignoreBasePath(
            isLeft: isLeft,
            leftRoot: settings.rootPath(for: leftProviderId),
            rightRoot: settings.rootPath(for: rightProviderId),
            leftRelativePath: syncManager.leftRelativePath,
            rightRelativePath: syncManager.rightRelativePath)

        // Relative to the current focus, so they apply across panes.
        let relativeTargets = PaneLogic.relativeIgnoreTargets(nodeIds: nodes.map(\.id), basePath: basePath)
        // The manager toggles against the effective ignore set (session plus remembered), so a node
        // ignored in an earlier session un-ignores instead of re-ignoring.
        syncManager.toggleIgnored(focusRelativePaths: Set(relativeTargets))
    }
    func isNodeIgnored(_ node: FileNode, currentPath: String) -> Bool {
        syncManager.isNodeIgnored(node, currentPath: currentPath)
    }
    /// "Paste here" enablement across both clipboards (the app's and Finder's), resolved by the
    /// rule the paste itself uses so the offer and the act can't disagree.
    var clipboardHasItems: Bool {
        ClipboardSource.current(pasteboard: handler?.pasteboard ?? .general,
                                hasInAppItems: !syncManager.clipboardNodes.isEmpty,
                                ownChangeCount: syncManager.clipboardPasteboardChangeCount) != .none
    }
}

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

    /// A snapshot of the kept-names set, carried for exactly the reason `ignoreStateToken` is.
    ///
    /// The row badge is the app's second eagerly-rendered delegate answer (the strikethrough was
    /// the first). Keeping a name changes what every row showing that name draws, and changes
    /// nothing else the pane compares: same tree, same paths, same selection. Without this the
    /// pane would answer "equivalent", skip the re-render, and the badge the user just dismissed
    /// would stay on screen until something unrelated moved — the precise staleness
    /// `ignoreStateToken` exists to prevent, arriving through the second door.
    ///
    /// The set itself rather than a count: withdrawing one keep while adding another leaves the
    /// count where it was.
    let keptNamesToken: Set<String>

    /// The cloud ground the `⌂ on this Mac only` badge is resolved against — or **nil when this
    /// pane's source is not a folder source**, which is the badge's whole gating rule folded into
    /// the value it would otherwise need alongside.
    ///
    /// Inside a cloud source's own pane every row is covered by definition, so a badge there would
    /// be a mark on everything and say nothing. It shows exactly when the source is a plain folder
    /// — the only time the question is live — and that includes a Compare pane aimed at a folder
    /// source and the single-source rail, because both reach this same delegate.
    ///
    /// **A compared value, not something read live off `settings`.** It is the app's third
    /// eagerly-rendered delegate answer, and the pane's row badges are rendered from it. Adding a
    /// folder source, removing a provider, or re-pointing one's Location changes what every visible
    /// row should draw and changes nothing else this delegate compares — same tree, same paths,
    /// same selection — so without it here the pane would answer "equivalent", skip the re-render,
    /// and go on marking rows against a source list that no longer exists. That is `4cae0471`'s
    /// finding-outliving-the-provider, arriving through a third door; `ignoreStateToken` and
    /// `keptNamesToken` are here for exactly the first two.
    let homeBadgeCoverage: FileLocation.Coverage?

    /// Opens Duplicates on this pane's source and reveals the group holding the file. Ignored by
    /// `isEquivalent` for the reason the other closures are: it reads its state back through the
    /// view's property wrappers, so one captured three renders ago sees what one built this
    /// instant would.
    let onFindDuplicatesOf: (FileNode) -> Void
    /// Points Organize at a folder — see ``handleOrganizeFolder(_:)``.
    let onOrganizeFolder: (FileNode) -> Void
    /// Moves Organize's scope to a folder **without** starting a scan — see ``handleFocus(_:)``.
    ///
    /// Distinct from `onOrganizeFolder`, which also scans: Open is a navigation, and making it pay
    /// for a filing pass would put a scan behind every folder you step into. Scope filters rather
    /// than rescans, so the other four lenses re-answer for free either way; To File keeps whatever
    /// the last scan found until the user asks for a new one.
    let onOrganizeScope: (FileNode) -> Void

    /// Opts this delegate into `FileTreeView`'s equality (see `FileActionDelegate.isEquivalent`),
    /// which is what lets a pane skip re-rendering — and with it every visible row — when the only
    /// thing that moved was some unrelated corner of the manager.
    ///
    /// Every stored property is accounted for. The seven values are compared outright; the three
    /// references are compared by identity; and the closures are ignored, which is the one claim
    /// here that needs justifying.
    ///
    /// They are safe to ignore because none of them captures a decision. `forceRefreshAction`,
    /// `onGetInfo` and `onChooseDestination` are all built by `ContentView` and read their state
    /// back through property wrappers (`@State`, `@AppStorage`, `@ObservedObject`,
    /// `@EnvironmentObject`) whose storage outlives any single render — so a closure captured three
    /// renders ago sees exactly what one built this instant would. `onFindDuplicatesOf`,
    /// `onOrganizeFolder` and `onOrganizeScope` are the same shape — the last one writes
    /// `organizeScopePath`, an `@AppStorage` whose storage outlives any render. What a closure here
    /// must never do is read a plain `let` snapshot off the captured view; if one ever does, it
    /// belongs in the comparison below rather than outside it.
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
            && keptNamesToken == other.keptNamesToken
            && homeBadgeCoverage == other.homeBadgeCoverage
    }

    func handleRefresh() {
        forceRefreshAction()
    }
    /// Re-roots this pane at a folder — the row menu's **Open** on the single-source rail, and
    /// "Compare only this folder" on the comparison panes.
    ///
    /// **Open also moves Organize's scope; browsing does not.** Those are not in tension. The rule
    /// Organize's scope rejects is *live-binding to whatever folder the pane drifted to*, because
    /// the left pane is how destinations get inspected while filing and a scope that followed that
    /// would destroy the queue. Open is not drift: it is the user naming a folder and re-rooting
    /// the pane on it, which is the same act as "Organize This Folder…" arriving through a
    /// different door. Having the two disagree would leave the pane rooted at one subject while
    /// every lens answered about another.
    ///
    /// Gated on `isSingleSource`, which is exactly when the menu item reads **Open**. On the
    /// comparison panes the same call is "Compare only this folder" — a claim about the comparison,
    /// not about what Organize is answering about — so it must not re-aim the lenses. That is also
    /// why this is not hooked in `FileActionHandler.focusFolder`: that lives in Dashboard, is
    /// shared by both surfaces, and could not tell the two verbs apart.
    ///
    /// Routed through `onOrganizeScope` → `ContentView.setOrganizeScope`, so opening the provider
    /// root clears the scope rather than encoding the global view a second way.
    func handleFocus(_ node: FileNode) {
        handler?.focusFolder(node, isLeft: isLeft, leftProviderId: leftProviderId, rightProviderId: rightProviderId, suppressLinkedNavigation: isSingleSource)
        if isSingleSource, node.isDirectory { onOrganizeScope(node) }
    }
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
    func handleRename(_ node: FileNode) { handler?.beginRename(node) }

    /// This pane's name ruleset — the source's own, except where `SettingsManager.nameRuleType(for:)`
    /// substitutes: OneDrive (the strictest) when the id can't be resolved, so an unresolved source
    /// over-reports rather than letting a name that will break a sync pass unflagged, and the
    /// user's `folderNameRule` for a folder source, which has no rules of its own.
    private var paneProviderType: CloudProvider.ProviderType {
        settings.nameRuleType(for: isLeft ? leftProviderId : rightProviderId)
    }

    func riskyName(for node: FileNode) -> RiskyName? {
        // The relative path is only used to LABEL the row in the batch list; a single-file fix
        // renames in place from the absolute path, so the node's own name is the honest value
        // here rather than a path this delegate would have to reconstruct against a scan root.
        NameNormalizer.risky(name: node.name, relativePath: node.name, absolutePath: node.id,
                             isDirectory: node.isDirectory, provider: paneProviderType)
    }

    /// The badge's door. Memoized by (provider, name) — see `RiskyNameBadgeCache` for why this one
    /// answer, alone among the delegate's, cannot afford to be computed fresh each time it is asked.
    ///
    /// The kept check comes FIRST and is a set lookup, so a name the user has decided to live with
    /// costs less than one they haven't, rather than running the rules only to discard the verdict.
    func riskyNameReason(forName name: String, isDirectory: Bool) -> String? {
        guard !syncManager.isKeptName(name) else { return nil }
        return RiskyNameBadgeCache.reason(name: name, isDirectory: isDirectory, provider: paneProviderType)
    }

    func isKeptName(_ name: String) -> Bool { syncManager.isKeptName(name) }

    func handleKeepName(_ node: FileNode) {
        syncManager.keptNamesStore?.keep(node.name)
    }

    func handleStopKeepingName(_ node: FileNode) {
        syncManager.keptNamesStore?.stopKeeping(node.name)
    }

    /// The ⌂ badge's answer. Nil coverage means the badge never applies in this pane — see
    /// `homeBadgeCoverage`.
    ///
    /// Memoized per path by `HomeOnlyBadgeCache`, for the reason `riskyNameReason` is memoized by
    /// `RiskyNameBadgeCache`: this is asked eagerly, per visible row, per render pass. The memo
    /// invalidates on the coverage it is handed, so there is no counter here to forget to bump.
    func isOnThisMacOnly(forPath path: String) -> Bool {
        guard let coverage = homeBadgeCoverage else { return false }
        return HomeOnlyBadgeCache.isOutsideEveryCloudFolder(path: path, coverage: coverage)
    }

    /// A real window is behind this delegate, so the row menu may offer the door.
    var canFindDuplicates: Bool { true }

    func handleFindDuplicates(_ node: FileNode) {
        // Files only. The menu gates on this too; asserting it here as well keeps the guarantee
        // with the handler rather than only with the one caller that happens to respect it.
        guard !node.isDirectory else { return }
        onFindDuplicatesOf(node)
    }

    /// A real window is behind this delegate, so the row menu may offer the door.
    var canOrganizeFolder: Bool { true }

    func handleOrganizeFolder(_ node: FileNode) {
        // Folders only. The menu gates on this too; asserting it here as well keeps the guarantee
        // with the handler rather than only with the one caller that happens to respect it.
        guard node.isDirectory else { return }
        onOrganizeFolder(node)
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

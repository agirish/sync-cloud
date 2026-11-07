import Events
import Foundation

/// Back/forward stack for one pane's focused relative path. Each pane owns an independent
/// history, so the back button in a pane's header only undoes that pane's navigation.
/// `Sendable` because a parked tab carries one (`PaneTab`), and a public struct's conformance is
/// not inferred across a module boundary.
public struct PaneNavigationHistory: Equatable, Sendable {
    /// Visited relative paths, oldest first. Always contains at least the root entry `""`.
    public private(set) var entries: [String] = [""]
    /// Index of the current entry.
    public private(set) var index: Int = 0

    public init() {}

    /// A fresh history for a pane opening at `landing`, the source's `openAt` folder. The landing
    /// is the first entry, not one above the root, so Back is unavailable right after a provider
    /// switch rather than offering a folder the user hasn't been to.
    public init(startingAt landing: String) {
        entries = [landing]
        index = 0
    }

    public var current: String { entries[index] }
    public var canGoBack: Bool { index > 0 }
    public var canGoForward: Bool { index < entries.count - 1 }

    /// Appends `path` as the new current entry, trimming any forward entries first.
    public mutating func push(_ path: String) {
        if index < entries.count - 1 {
            entries.removeSubrange((index + 1)...)
        }
        entries.append(path)
        index = entries.count - 1
    }

    /// Steps back one entry; no-op at the oldest entry.
    public mutating func goBack() {
        if canGoBack { index -= 1 }
    }

    /// Steps forward one entry; no-op at the newest entry.
    public mutating func goForward() {
        if canGoForward { index += 1 }
    }

    /// Back to a single-entry history at the pane's opening folder, the root unless the source
    /// says otherwise.
    public mutating func reset(to landing: String = "") {
        entries = [landing]
        index = 0
    }
}

extension FileSyncManager {

    // MARK: - Navigation Methods

    /// Sets the focused subfolder for one pane and appends to that pane's history.
    /// - Parameters:
    ///   - relativePath: Subfolder path relative to the pane root (e.g. `"Documents/Projects"`).
    ///   - isLeft: `true` if the user drilled into this folder from the left pane; `false` for the right pane.
    public func focusOn(relativePath: String, isLeft: Bool) {
        // Already there: no-op (as in focusBoth), so a duplicate history entry doesn't make Back
        // seem to stall.
        guard (isLeft ? leftRelativePath : rightRelativePath) != relativePath else { return }
        clearSessionIgnoredPaths()
        // Re-rooting replaces the tree the columns were walking. Reset rather than prune: the new
        // tree is a different scope, not a changed one.
        resetBrowsePath(isLeft: isLeft)
        if isLeft {
            leftHistory.push(relativePath)
        } else {
            rightHistory.push(relativePath)
        }
        syncPathsFromHistory()
    }

    /// Sets the focused subfolder for both panes at once (⌥-click on a pane breadcrumb).
    /// Panes already focused on `relativePath` keep their history untouched, so Back in each
    /// pane still undoes exactly that pane's last move. No-op when both panes are already there.
    ///
    /// Both panes to the same root-relative path, which is right only while the two sources land in
    /// the same place. `focusBoth(left:right:)` is the general form.
    public func focusBoth(relativePath: String) {
        focusBoth(left: relativePath, right: relativePath)
    }

    /// Each pane to its own root-relative path, since a linked move must be translated across
    /// sources that may open at different depths. The caller translates (`PathBoundary.reanchor`):
    /// it knows both landing folders.
    public func focusBoth(left: String, right: String) {
        guard leftRelativePath != left || rightRelativePath != right else { return }
        clearSessionIgnoredPaths()
        // Only a pane that moves loses its column stack and gains a history entry.
        if leftRelativePath != left { resetBrowsePath(isLeft: true); leftHistory.push(left) }
        if rightRelativePath != right { resetBrowsePath(isLeft: false); rightHistory.push(right) }
        syncPathsFromHistory()
    }

    // MARK: - Column stack

    /// Drops a pane back to its resting single column.
    @MainActor func resetBrowsePath(isLeft: Bool) {
        if isLeft {
            if !leftBrowsePath.isEmpty || leftBrowsePath.canAdvance { leftBrowsePath.reset() }
        } else {
            if !rightBrowsePath.isEmpty || rightBrowsePath.canAdvance { rightBrowsePath.reset() }
        }
    }

    /// A pane's location as one path: its comparison scope joined with where it is browsing. The
    /// two are separate state (`PaneBrowsePath`), but the header shows one location, so walking
    /// into a column moves the breadcrumb just as re-rooting does.
    public func combinedRelativePath(isLeft: Bool) -> String {
        PathBoundary.joinRelative(isLeft ? leftRelativePath : rightRelativePath,
                                 (isLeft ? leftBrowsePath : rightBrowsePath).relativePath)
    }

    /// Where a pane in a given presentation is: the folder its header names and its "current
    /// folder" actions target. Columns draws the stack, so it is the join above. Tree draws no
    /// columns and lists the scope whole, so it is the scope, or the header would name a column
    /// folder the tree isn't showing. The stack is kept, so switching back restores the columns.
    ///
    /// `drawsColumns` rather than a `PaneViewMode`: this module has no view vocabulary, and the
    /// answer turns only on whether the stack is on screen.
    public func paneLocation(isLeft: Bool, drawsColumns: Bool) -> String {
        drawsColumns
            ? combinedRelativePath(isLeft: isLeft)
            : (isLeft ? leftRelativePath : rightRelativePath)
    }

    /// Routes a click on that joined path to whichever half owns it. A crumb inside the scope is a
    /// browse move, cheap and with no rescan; a crumb above the scope is the only way out, so it
    /// re-roots.
    @MainActor public func navigatePane(isLeft: Bool, toCombinedPath combined: String, drawsColumns: Bool) {
        let focus = isLeft ? leftRelativePath : rightRelativePath
        let side = isLeft ? "left" : "right"
        // Every branch logs, so a crumb click that goes nowhere still leaves a line.
        let target = combined.isEmpty ? "root" : combined
        // Tree has no stack, so a browse move would write state it never draws and the click would
        // do nothing. Every target is a re-root there, which also makes it reachable by Back.
        if !drawsColumns {
            // Split so the log says which happened: `focusOn` no-ops on the folder the tree is
            // already rooted at.
            if combined == focus {
                Logger.shared.debug("[crumb] \(side) pane is already rooted at \(target) (tree)")
            } else {
                Logger.shared.debug("[crumb] \(side) pane re-roots to \(target) (tree draws no columns)")
                focusOn(relativePath: combined, isLeft: isLeft)
            }
        } else if focus.isEmpty {
            Logger.shared.debug("[crumb] \(side) pane browses to \(target) (scope at root)")
            setBrowsePath(isLeft: isLeft, PaneBrowsePath(relativePath: combined))
        } else if combined == focus {
            Logger.shared.debug("[crumb] \(side) pane returns to its scope \(target)")
            setBrowsePath(isLeft: isLeft, PaneBrowsePath())
        } else if combined.hasPrefix(focus + "/") {
            Logger.shared.debug("[crumb] \(side) pane browses to \(target) inside scope \(focus)")
            setBrowsePath(isLeft: isLeft, PaneBrowsePath(relativePath: String(combined.dropFirst(focus.count + 1))))
        } else {
            // Above the comparison scope: a real re-root, history and all.
            Logger.shared.debug("[crumb] \(side) pane re-roots to \(target) from scope \(focus)")
            focusOn(relativePath: combined, isLeft: isLeft)
        }
    }

    /// The both-panes form of `navigatePane`: the ⌥-click, and every plain crumb click while the
    /// seam link is on. Each pane is routed through its own halves, independently, since their
    /// scopes need not agree. `focusBoth` compares only focus paths, so with both panes scoped at
    /// the root it would ignore a root-crumb click, and re-root (and rescan) for any other crumb.
    ///
    /// `otherIndex` prunes the sibling's new stack against the tree it has, as a mirrored column
    /// drill does (`applyColumnNavigation`). An autoclosure, so landing both at the root never
    /// builds the index.
    ///
    /// Two `drawsColumns` flags: the presentation is per pane, so one side may browse while the
    /// other re-roots. `otherCombinedPath` is the sibling's own spelling of the same folder
    /// (default: the clicked pane's); it can differ when the sources land in different places
    /// (`PathBoundary.reanchor`). The caller translates.
    @MainActor public func navigateBothPanes(
        toCombinedPath combined: String,
        otherCombinedPath: String? = nil,
        from isLeft: Bool,
        drawsColumns: Bool,
        otherDrawsColumns: Bool,
        otherIndex: @autoclosure () -> PaneChildrenIndex,
        otherTreeRoot: String
    ) {
        let otherFocusBefore = isLeft ? rightRelativePath : leftRelativePath
        navigatePane(isLeft: isLeft, toCombinedPath: combined, drawsColumns: drawsColumns)
        navigatePane(isLeft: !isLeft, toCombinedPath: otherCombinedPath ?? combined,
                     drawsColumns: otherDrawsColumns)

        // Only a browse move can be pruned here. If the sibling re-rooted, `otherTreeRoot` and
        // `otherIndex` describe the tree it left; the prune on the next republish applies instead.
        guard (isLeft ? rightRelativePath : leftRelativePath) == otherFocusBefore,
              !(isLeft ? rightBrowsePath : leftBrowsePath).isEmpty else { return }
        pruneBrowsePath(isLeft: !isLeft, against: otherIndex(), treeRoot: otherTreeRoot)
    }

    /// Sets a pane's column stack outright. Public because the mirroring decision needs both
    /// panes' children indices, which only the app layer holds.
    @MainActor public func setBrowsePath(isLeft: Bool, _ path: PaneBrowsePath) {
        if isLeft {
            if leftBrowsePath != path { leftBrowsePath = path }
        } else {
            if rightBrowsePath != path { rightBrowsePath = path }
        }
    }

    /// Applies a column drill, optionally mirroring it onto the sibling pane. The mirror is pruned
    /// against the other pane's tree, not copied: a folder opened on one side may not exist on the
    /// other, so it lands on the deepest folder both share (or the root column), never on an empty
    /// column for a missing folder.
    ///
    /// The caller decides `mirror`: it depends on the seam link, the ⌥ key and the layout.
    /// `otherIndex` is an autoclosure so an unmirrored click doesn't build it: a cold index is a
    /// full walk of the other pane's tree, on the main thread inside the click handler.
    @MainActor public func applyColumnNavigation(
        _ path: PaneBrowsePath,
        isLeft: Bool,
        mirror: Bool,
        otherIndex: @autoclosure () -> PaneChildrenIndex,
        otherTreeRoot: String
    ) {
        let side = isLeft ? "left" : "right"
        let from = (isLeft ? leftBrowsePath : rightBrowsePath).depth
        setBrowsePath(isLeft: isLeft, path)
        guard mirror else {
            // Walking columns writes no history and runs no scan, so this line is the only record
            // of what the user was doing.
            Logger.shared.debug("[columns] \(side) pane depth \(from) → \(path.depth) at \(path.relativePath.isEmpty ? "root" : path.relativePath)")
            return
        }
        // The mirror is the expensive half: `pruned` walks the other pane's children index, and
        // building that index is a full pass over its tree when the cache is cold.
        let started = CFAbsoluteTimeGetCurrent()
        let mirrored = path.pruned(against: otherIndex(), treeRoot: otherTreeRoot, links: linkedFolders)
        let elapsed = (CFAbsoluteTimeGetCurrent() - started) * 1000
        setBrowsePath(isLeft: !isLeft, mirrored)
        Logger.shared.debug(
            "[columns] \(side) pane depth \(from) → \(path.depth) at \(path.relativePath.isEmpty ? "root" : path.relativePath); "
            + "mirrored to depth \(mirrored.depth) in \(String(format: "%.1fms", elapsed))")
    }

    /// The folder a pane's published tree was read at (absolute, as the walk was handed it), or
    /// `nil` when the pane holds no walk (never loaded, or dropped by `invalidatePaneTree`).
    ///
    /// Tells a caller whether the tree on screen is for where the pane now is: `focusOn` moves
    /// `leftRelativePath` at once, but the old folder's tree stays published until the walk lands.
    /// Edit's owed selection checks this so it never selects in a tree about to be replaced.
    /// Read-only; `loadTree` and `invalidatePaneTree` own the value.
    public func paneTreeFolder(isLeft: Bool) -> String? {
        isLeft ? lastLoadedLeftFocusPath : lastLoadedRightFocusPath
    }

    /// ``paneRelativePath(of:isLeft:root:)`` for a whole selection, walking the pane's tree once
    /// for all nodes whose id is not spelled under `root`, rather than once per node.
    public func paneRelativePaths(of nodes: [FileNode], isLeft: Bool, root: String) -> [String: String] {
        var placed: [String: String] = [:]
        var unplaced: Set<String> = []
        for node in nodes {
            if let relative = PathBoundary.relativize(node.id, under: root, links: linkedFolders) {
                placed[node.id] = relative
            } else {
                unplaced.insert(node.id)
            }
        }
        guard !unplaced.isEmpty, let folder = paneTreeFolder(isLeft: isLeft),
              let base = PathBoundary.relativize(folder, under: root, links: linkedFolders) else { return placed }
        for (id, names) in TreeShape.names(downTo: unplaced, in: isLeft ? rawLeftTree : rawRightTree) {
            placed[id] = PathBoundary.joinRelative(base, names.joined(separator: "/"))
        }
        return placed
    }

    /// Where a folder this pane lists sits below its source's root (the relative path a focus on
    /// it takes), or nil when the pane doesn't hold it.
    ///
    /// The node's id when it is spelled under the root, the tree's shape when it isn't. Ids leave
    /// the root below a folder symlink (`contentsOfDirectory(at:)` answers where the link leads),
    /// under a root spelled through a link (`/var/…` lists `/private/var/…`), and in iCloud Drive's
    /// linked folders. Then the names down the tree go onto the walked folder's relative path, and
    /// `focusURL` joins them back through the link.
    ///
    /// The id comes first because a folder can appear twice (Home holds `~/Dropbox` and the folder
    /// it links to) and the names would take whichever route sorts first. It reads the raw tree
    /// with `paneTreeFolder`, which `adoptRawTree` writes together; the published tree trails them
    /// by a filter pass, so its names could land on the new walk's folder.
    public func paneRelativePath(of node: FileNode, isLeft: Bool, root: String) -> String? {
        if let relative = PathBoundary.relativize(node.id, under: root, links: linkedFolders) {
            return relative
        }
        guard let folder = paneTreeFolder(isLeft: isLeft),
              let base = PathBoundary.relativize(folder, under: root, links: linkedFolders),
              let names = TreeShape.names(downTo: node.id, in: isLeft ? rawLeftTree : rawRightTree)
        else { return nil }
        return PathBoundary.joinRelative(base, names.joined(separator: "/"))
    }

    /// Drops one pane's tree, so it reloads while the other keeps what it shows. A comparison
    /// belongs to the pair, but a tree is a walk of one root at one focus, so a pane that didn't
    /// move keeps its tree rather than being rebuilt for nothing.
    ///
    /// Not the prefetch cache: it is keyed by absolute path, so its entries stay true, and every
    /// real staleness source (a file operation, a forced rescan, a sort or hidden-files change)
    /// clears it. The caller still drops the comparison (`invalidateDifferencesForPaneRetarget`).
    @MainActor public func invalidatePaneTree(isLeft: Bool) {
        if isLeft {
            rawLeftTree = []
            if !leftTree.isEmpty { leftTree = [] }
            leftTreeBeforeTypeFilter = []
            if leftItemCount != 0 { leftItemCount = 0 }
            lastLoadedLeftFocusPath = nil
            // The stamp dated the tree that just went. Nil, as for a pane that never loaded.
            leftTreeReadAt = nil
            // Its links went with it: a pane holding no walk reaches nothing.
            leftTreeLinkTargets = []
            leftWatch.readMark = nil
        } else {
            rawRightTree = []
            if !rightTree.isEmpty { rightTree = [] }
            rightTreeBeforeTypeFilter = []
            if rightItemCount != 0 { rightItemCount = 0 }
            lastLoadedRightFocusPath = nil
            rightTreeReadAt = nil
            rightTreeLinkTargets = []
            rightWatch.readMark = nil
        }
        publishDiskChanges()
    }

    /// Re-resolves a pane's column stack against a freshly published tree, dropping trailing
    /// folders that no longer exist. Must run on every republish: otherwise a deleted folder leaves
    /// empty columns while `currentDirectory` still names it, where New Folder and paste would act.
    /// Assigns only on a real change, so an unaffected stack costs no publish.
    ///
    /// **Never against a tree that isn't loaded.** An empty tree means "nothing to ask yet", and
    /// pruning against it returns the root. Re-pointing a pane publishes an empty tree before the
    /// reload, so pruning then would send every browse-tab switch back to the root. A loaded tree
    /// with no children still prunes; `lastLoadedFocusPath` tells the two apart.
    @MainActor public func pruneBrowsePath(isLeft: Bool, against index: PaneChildrenIndex, treeRoot: String) {
        // Both halves of `pruneSelection`'s guard. Progressive loading publishes a shallow tree
        // (the root's children only) that sets `lastLoadedFocusPath` too, so the marker alone
        // would prune against it and collapse the stack to its first component.
        guard (isLeft ? lastLoadedLeftFocusPath : lastLoadedRightFocusPath) != nil,
              !(isLeft ? isLoadingLeftTree : isLoadingRightTree) else { return }
        if isLeft {
            let pruned = leftBrowsePath.pruned(against: index, treeRoot: treeRoot, links: linkedFolders)
            if pruned != leftBrowsePath { leftBrowsePath = pruned }
        } else {
            let pruned = rightBrowsePath.pruned(against: index, treeRoot: treeRoot, links: linkedFolders)
            if pruned != rightBrowsePath { rightBrowsePath = pruned }
        }
    }

    /// Whether this pane's `‹` has anywhere to go: the column stack first, then the focus history.
    /// One meaning, "undo my last navigation": a pane can be columns deep without ever re-rooting,
    /// and in a narrow pane `‹` is the only way out. The stack counts only when `drawsColumns`,
    /// since a Tree pane's stack is parked off screen and stepping out of it would change nothing.
    public func canGoBack(isLeft: Bool, drawsColumns: Bool) -> Bool {
        let browse = isLeft ? leftBrowsePath : rightBrowsePath
        return (drawsColumns && !browse.isEmpty) || (isLeft ? leftHistory : rightHistory).canGoBack
    }

    /// Counterpart of `canGoBack(isLeft:)`. Forward walks back into a column `‹` stepped out of
    /// before it considers the focus history, so the two arrows stay each other's inverse.
    public func canGoForward(isLeft: Bool, drawsColumns: Bool) -> Bool {
        let browse = isLeft ? leftBrowsePath : rightBrowsePath
        return (drawsColumns && browse.canAdvance) || (isLeft ? leftHistory : rightHistory).canGoForward
    }

    /// Navigates one pane back: out of a column if it is inside one, otherwise to the previous
    /// entry in its own focus history.
    @MainActor public func goBack(isLeft: Bool, drawsColumns: Bool) {
        // Columns first: browsing adds no history entry, so a column is the latest navigation.
        // Returns without `clearSessionIgnoredPaths()`, which belongs to a change of comparison
        // scope; stepping out of a column only changes where you look. Skipped in Tree, where it
        // would change nothing on screen and use up the columns kept for switching back.
        if drawsColumns, isLeft ? leftBrowsePath.popLast() : rightBrowsePath.popLast() {
            let browse = isLeft ? leftBrowsePath : rightBrowsePath
            Logger.shared.debug("Stepped \(isLeft ? "left" : "right") pane out to column depth \(browse.depth)")
            return
        }
        if isLeft {
            guard leftHistory.canGoBack else { return }
            leftHistory.goBack()
        } else {
            guard rightHistory.canGoBack else { return }
            rightHistory.goBack()
        }
        clearSessionIgnoredPaths()
        let pane = isLeft ? "left" : "right"
        let target = (isLeft ? leftHistory : rightHistory).current
        Logger.shared.info("User navigated \(pane) pane back to \(target.isEmpty ? "root" : target)")
        syncPathsFromHistory()
    }

    /// Navigates one pane forward: back into a column `‹` stepped out of, otherwise to the next
    /// entry in its own focus history. The inverse of `goBack(isLeft:)`, in the same order.
    @MainActor public func goForward(isLeft: Bool, drawsColumns: Bool) {
        // As in `goBack`: `›` must not spend a click re-entering a column a Tree pane can't show.
        if drawsColumns, isLeft ? leftBrowsePath.advance() : rightBrowsePath.advance() {
            let browse = isLeft ? leftBrowsePath : rightBrowsePath
            Logger.shared.debug("Stepped \(isLeft ? "left" : "right") pane into column depth \(browse.depth)")
            return
        }
        if isLeft {
            guard leftHistory.canGoForward else { return }
            leftHistory.goForward()
        } else {
            guard rightHistory.canGoForward else { return }
            rightHistory.goForward()
        }
        clearSessionIgnoredPaths()
        let pane = isLeft ? "left" : "right"
        let target = (isLeft ? leftHistory : rightHistory).current
        Logger.shared.info("User navigated \(pane) pane forward to \(target.isEmpty ? "root" : target)")
        syncPathsFromHistory()
    }

    /// Re-points one pane at a new source: re-homes it on that source's opening folder, drops the
    /// state that only meant something where it was, and drops the pair's comparison. Called when
    /// a pane's provider changes.
    ///
    /// The comparison must go: its absolute paths and copy directions no longer match the panes,
    /// and left clickable until the rescan lands they would misdirect sync arrows and copy/move
    /// targets. Everything else is per pane, as in `applyTab`: the other pane keeps its tree,
    /// columns, selection and history, and the reload is scoped to the moved pane
    /// (`PaneReloadScope`). The scan still compares both.
    ///
    /// - Parameters:
    ///   - isLeft: the pane whose source changed. The only pane this touches.
    ///   - landing: where it should open, relative to its new root. `""` is the root.
    ///
    /// `landing` has no default: `""` can name the account folder above a source's documents tree,
    /// so omitting it would mean somewhere else. Passed in because this type has no
    /// `SettingsManager`, which keeps navigation testable without a provider list.
    @MainActor public func retargetPane(isLeft: Bool, landing: String) {
        let side = isLeft ? "left" : "right"
        let other = isLeft ? "right" : "left"
        let history = isLeft ? leftHistory : rightHistory
        // Two questions. The log asks about the folder: did the pane end up somewhere new? A
        // history with entries behind it differs from a fresh one even at the same folder. The
        // write asks about the history, which it replaces: skipping it when only the folder
        // matches would leave Back pointing into the tree the pane is leaving.
        let moves = history.current != landing
        let rewrites = history != PaneNavigationHistory(startingAt: landing)
        let place = landing.isEmpty ? "the source root" : landing
        // Names what the sibling keeps, phrased as what this call did, not the window's end state:
        // one gesture can retarget both panes (`undoProviderPin` retargets the sibling first), and
        // two lines each calling the other pane untouched would contradict each other.
        let onlyThisPane = "This touched only the \(side) pane — the \(other) pane's tree, "
                         + "columns, selection and history are as they were."
        if moves {
            Logger.shared.info("Re-homed the \(side) pane at \(place). \(onlyThisPane)")
        } else {
            Logger.shared.info("The \(side) pane did not move: it is already at \(place). "
                               + onlyThisPane)
        }
        // The pane's half: only the moved pane's tree. The sibling's root and focus didn't change.
        invalidatePaneTree(isLeft: isLeft)
        // The prefetch cache goes, except the sibling's walk. Its entries stay true, but they are
        // whole walked trees (tens of thousands of nodes) for a source not asked for again, so
        // they go for memory, as in `applyTab`. The sibling's entry is the array it shows anyway.
        dropPrefetchedTrees(keeping: isLeft ? lastLoadedRightFocusPath : lastLoadedLeftFocusPath)
        // The pair's half: differences and verification results carry absolute paths under a
        // root one pane no longer shows, and would misdirect actions until the rescan lands.
        invalidateDifferencesForPaneRetarget()
        clearSessionIgnoredPaths()
        // Only the moved pane's selection: the sibling's still points at files the user selected
        // under a root that didn't move.
        if isLeft {
            if !selectedLeftPaths.isEmpty { selectedLeftPaths = [] }
        } else {
            if !selectedRightPaths.isEmpty { selectedRightPaths = [] }
        }
        // Skips only a no-op write: a single entry already naming the landing. A pane at its
        // landing with history behind it still rewrites, since Back would lead into the old tree.
        if rewrites {
            if isLeft { leftHistory.reset(to: landing) } else { rightHistory.reset(to: landing) }
        }
        // A column stack naming folders under the old root is meaningless now. The sibling's
        // still names folders on screen, so it stays.
        resetBrowsePath(isLeft: isLeft)
        // Forced, not inferred: walk the moved pane even when its landing is the folder it was
        // on, because its root changed. See `syncPathsFromHistory`.
        syncPathsFromHistory(forcing: .movedPane(isLeft: isLeft))
    }

    /// Drops every piece of state that is only meaningful for the pane roots it was built
    /// against: differences (raw and published), the named panes' trees, checksum-verification
    /// results, and the scanned flag — synchronously, so no observer ever sees rows for roots
    /// the panes no longer show. Also supersedes in-flight loads, scans, and filter passes,
    /// which hold pre-change snapshots and must not publish over the cleared state. Call
    /// whenever a pane's provider or its root path changes; the caller's rescan repopulates
    /// (with `hasScanned` false and `differences` empty the UI shows "No Scan Performed",
    /// never a false "Everything is in sync").
    ///
    /// - Parameter reloading: whose trees to drop. The differences always go, but a tree belongs
    ///   to one pane: dropping a sibling's puts a spinner over a pane whose root didn't move and
    ///   flattens its column stack. `.both` only when both roots moved. **Pass the same scope to
    ///   the rescan that follows**, or a pane whose tree was dropped here stays blank.
    @MainActor public func invalidateComparisonState(reloading scope: PaneReloadScope = .both) {
        // Drop the prefetch cache: the old root's walked tree is dead weight (tens of thousands
        // of nodes). Keep the walk of a pane this doesn't reload, as in `retargetPane`: the rescan
        // reads cached trees only when both sides hit, and would otherwise walk both from disk.
        switch scope {
        case .both: dropPrefetchedTrees()
        case .leftOnly: dropPrefetchedTrees(keeping: lastLoadedRightFocusPath)
        case .rightOnly: dropPrefetchedTrees(keeping: lastLoadedLeftFocusPath)
        }
        if scope != .rightOnly { invalidatePaneTree(isLeft: true) }
        if scope != .leftOnly { invalidatePaneTree(isLeft: false) }

        // The differences half, shared with the retarget-only invalidation. All in one synchronous
        // main-actor block, so no observer sees a half-cleared state.
        invalidateDifferencesForPaneRetarget()
    }

    /// The differences-only subset of `invalidateComparisonState`: drops the diff results
    /// (differences, verification results, the copy-identical offer, scan-freshness fields) and
    /// supersedes in-flight loads, scans and filter passes, without touching pane trees,
    /// navigation, selections or lens state such as `duplicateGroups`.
    ///
    /// For the provider changes that suppress the full reset (the Duplicates lens's "Compare
    /// copies" hand-off and its restore, `pendingSwapProviderChanges`), which must keep the
    /// duplicate results. Without it the old differences stay actionable while trees load, and a
    /// row click would sync absolute paths from roots the panes no longer show. Call it
    /// synchronously before the re-focus and refresh; until the rescan the UI shows "No Scan
    /// Performed", never a false "Everything is in sync".
    @MainActor public func invalidateDifferencesForPaneRetarget() {
        supersedeInFlightPaneWork()
        rawDifferences = []
        if !differences.isEmpty { differences = [] }
        verifiedSameDifferenceIds.removeAll()
        verifiedIdenticalForCopy = nil
        lastRightProviderType = nil
        lastScanProviders = nil
        lastScanRootNames = nil
        lastScanReadAt = nil
        lastScanDate = nil
        // The coverage claim belongs to the dropped rows (`lastScanCoverage`).
        if !lastScanCoverage.isComplete { lastScanCoverage = .complete }
        if hasScanned { hasScanned = false }

        // A filter pass that snapshotted state before this clear may still publish after it. A
        // fresh pass over the cleared raws supersedes it by generation within one in-memory pass.
        Task { await self.applyFilters() }
    }

    /// Cancels/supersedes work in flight for the current pane orientation and roots: per-pane
    /// tree loads (cancelled, and their spinner-cleanup tokens invalidated), a pending or
    /// running scan (its publish is generation-gated), and any off-main resort snapshot.
    @MainActor private func supersedeInFlightPaneWork() {
        activeLoadLeftTask?.cancel()
        activeLoadRightTask?.cancel()
        leftLoadGeneration += 1
        rightLoadGeneration += 1
        rawTreeGeneration += 1
        scanRequestGeneration += 1
        pendingScanRequest = nil
        // The next refresh must supersede the in-flight one, never dedupe against it: that one's
        // loads were just cancelled, so a dedupe would leave the cleared panes blank.
        noteScanConfigChanged()
    }

    /// Swaps the left and right panes wholesale: paths, selections, histories, both trees with
    /// their bookkeeping, and every difference, remapped via `FileDifference.mirrored()` so paths,
    /// sizes, arrows and actions flip with the labels. One synchronous update, so no observer sees
    /// a half-swapped state.
    ///
    /// Refused (returns `false`, with a banner) while a file operation or sync is in flight: it
    /// captured pre-swap paths and directions, and the remapped arrows would no longer match it.
    /// Also during Verify All, whose `verifiedIdenticalForCopy` offer would copy the pre-swap way.
    ///
    /// The provider ids live in @AppStorage (ContentView) and are swapped there in lockstep; this
    /// owns only the manager's paired state. The caller drives the one refresh after both swaps.
    @MainActor @discardableResult public func swapPanes() -> Bool {
        guard activeFileOperationsCount == 0,
              !isBulkSyncRunning,
              bulkSyncProgress == nil,
              !isVerifyAllRunning,
              syncingDifferenceIds.isEmpty else {
            // `isBulkSyncRunning` is the only flag up during syncAll's confirm prompt, when a swap
            // would mirror rows under a snapshot the sync still holds.
            Logger.shared.warning("Ignored pane swap while file operations are in flight")
            banner = .warning("Can’t swap panes while an operation is running", log: .warn)
            return false
        }
        Logger.shared.info("User swapped the left and right panes")

        // In-flight loads/scans/filter passes were built for the pre-swap orientation and
        // must not publish over the swapped state; the caller's refresh rebuilds them.
        supersedeInFlightPaneWork()

        // Read before the path swap below, whose didSet empties them.
        let typeFilterKeeps = (left: leftTypeFilterKeep, right: rightTypeFilterKeep)
        swap(&leftRelativePath, &rightRelativePath)
        swap(&selectedLeftPaths, &selectedRightPaths)
        // Focus travels with the selection, or ⌘F, ⌘[ and ⇧⌘N would aim at the pane their content
        // left. `nil` stays nil: implicit focus reads the selection, which has already moved.
        noteFocusedPane(focusedPaneSide?.opposite, because: "the panes were swapped")

        swap(&leftHistory, &rightHistory)
        // The column stack travels with the tree it indexes, like the history.
        swap(&leftBrowsePath, &rightBrowsePath)
        // The two tab lists swap, not the active tabs: a list is one pane's locations, and the
        // pane's location just moved sides. Each active entry is a snapshot of its pane.
        swap(&leftPaneTabs, &rightPaneTabs)

        // In-flight column listings are dropped, not mirrored: each names the side it was asked
        // for, which now holds the other tree. The generation bump makes them discard their result
        // rather than graft it into the wrong pane, and the column re-asks on its own.
        paneOrientationGeneration += 1
        columnGraftsInFlight.removeAll()
        columnGraftsUnreadable.removeAll()

        swap(&rawLeftTree, &rawRightTree)
        swap(&leftTree, &rightTree)
        swap(&leftItemCount, &rightItemCount)
        // Each pane's type filter travels with its tree, or each tree would pass through the other
        // pane's filter, and a selected row could land hidden yet still in reach of ⌘⌫. The
        // filters' didSets empty the keep-sets, so those are written back after.
        swap(&leftTypeFilter, &rightTypeFilter)
        leftTypeFilterKeep = typeFilterKeeps.right
        rightTypeFilterKeep = typeFilterKeeps.left
        swap(&leftTypeFilterOpen, &rightTypeFilterOpen)
        swap(&leftTypeFilterFacts, &rightTypeFilterFacts)
        swap(&leftTreeBeforeTypeFilter, &rightTreeBeforeTypeFilter)
        swap(&lastLoadedLeftFocusPath, &lastLoadedRightFocusPath)
        // The walk's provenance travels with the walk, so "which pane holds this file" names the
        // pane the tree is on now.
        swap(&leftTreeLinkTargets, &rightTreeLinkTargets)
        swap(&isLoadingLeftTree, &isLoadingRightTree)
        // And what the folder watcher has said about it.
        swap(&leftWatch, &rightWatch)
        owedPaneChanges = (owedPaneChanges.right, owedPaneChanges.left)
        publishDiskChanges()

        // Remap rather than clear: the results stay valid (same folders and files), only their
        // side labels flip, and the list stays actionable instead of empty until the rescan.
        rawDifferences = rawDifferences.map { $0.mirrored() }
        differences = differences.map { $0.mirrored() }
        // verifiedSameDifferenceIds survives: mirrored() keeps ids and checksum equality is
        // symmetric. The copy-identical offer doesn't: its differences and wording are pre-swap.
        verifiedIdenticalForCopy = nil
        // The Drive date-noise filter is right-pane-specific; the provider just changed sides,
        // and the post-swap rescan re-learns the new right pane's type.
        lastRightProviderType = nil
        // The name-check provider pair and the Path column's root names stay valid (same two
        // roots), but their sides flip.
        lastScanProviders = lastScanProviders.map { ($0.right, $0.left) }
        lastScanRootNames = lastScanRootNames.map { ($0.right, $0.left) }
        // The coverage claim is side-labelled too, read beside `lastScanProviders` to name the
        // source that came back partial. Unmirrored, the banner would name the wrong side.
        lastScanCoverage = PartialComparison(left: lastScanCoverage.right,
                                             right: lastScanCoverage.left)

        // As in invalidateComparisonState, a fresh pass supersedes any holding a pre-swap
        // snapshot. A row it hides leaves the selection, as after any filter change.
        Task { await self.applyFilters(); self.scheduleSelectionPrune() }
        return true
    }

    // MARK: - Which pane the user is working in

    /// The one writer of `focusedPaneSide`, and the one place its moves are logged. Every
    /// pane-scoped chord reads it (⌘F, ⌘[, ⌘], ⇧⌘N, ⇧⌘P, ⌘T, ⌘W). ⌘W matters most: on the last tab
    /// `closeTab` closes the window, so a wrong side turns "close this tab" into "close
    /// everything", and the log must say where the chords were aimed. Never write it bare.
    ///
    /// - Parameter reason: what moved it, in the log's voice ("⌃⇥", "a row was picked in the left
    ///   pane"). The cause, not just the side, answers "why did ⌘W close my window".
    @MainActor public func noteFocusedPane(_ side: PaneTree.Side?, because reason: String) {
        // No line for a no-op: most calls are clicks in the pane already focused, and a line per
        // click would bury the moves that matter. `selectTab` follows the same rule.
        guard focusedPaneSide != side else { return }
        let was = focusedPaneSide
        focusedPaneSide = side
        // Info: the only record of where ⌘W was aimed when a window closed, and the guard above
        // keeps it to real moves, not every click in the pane already focused.
        Logger.shared.info(
            "The pane-scoped chords (⌘W, ⌘T, ⌘F) now aim at \(Self.paneName(side)) rather than "
            + "\(Self.paneName(was)): \(reason)")
    }

    /// The `isLeft` spelling every host call site uses. The polarity lives here, where a test can
    /// reach it; in `ContentView`, a flipped ternary would aim every tab verb at the wrong pane
    /// with no test failing.
    @MainActor public func noteFocusedPane(isLeft: Bool, because reason: String) {
        noteFocusedPane(isLeft ? .left : .right, because: reason)
    }

    private static func paneName(_ side: PaneTree.Side?) -> String {
        switch side {
        case .left: return "the left pane"
        case .right: return "the right pane"
        case nil: return "whichever pane holds the selection"
        }
    }

    /// Publishes each pane's current history entry into its relative path and refreshes only the
    /// pane that moved. Walking the other pane re-reads a root nothing changed: a visible reload
    /// when warm, and a full walk of tens of thousands of nodes when the cache is cold.
    ///
    /// Neither moving sends `.both`: the caller wants a refresh for a reason this can't see, and
    /// `.both` is what that has always meant. A narrow scope can't strand a pane by timing:
    /// `refreshTreesAndScan` widens it when a wider refresh is in flight, and the scan still
    /// compares both, the unmoved pane using the tree it holds.
    ///
    /// - Parameter forcing: the scope to send regardless of what moved. Only `retargetPane` uses
    ///   it, because the pane it re-pointed must be walked even at the same folder: its root
    ///   changed, which the history can't show.
    func syncPathsFromHistory(forcing: PaneReloadScope? = nil) {
        let leftMoved = leftRelativePath != leftHistory.current
        let rightMoved = rightRelativePath != rightHistory.current
        if leftMoved { leftRelativePath = leftHistory.current }
        if rightMoved { rightRelativePath = rightHistory.current }
        let scope: PaneReloadScope
        if let forcing {
            scope = forcing
        } else {
            switch (leftMoved, rightMoved) {
            case (true, false): scope = .leftOnly
            case (false, true): scope = .rightOnly
            default: scope = .both
            }
        }
        refreshSubject.send(scope)
    }

}

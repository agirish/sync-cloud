import SwiftUI
import AppKit
import Dashboard
import Design
import Events
import FileExplorer
import Settings
import Sync

/// Browse tabs: the host's half.
///
/// `FileSyncManager+PaneTabs` owns the model and the capture/apply rule. Three things it cannot own
/// live here:
///
/// - The provider id is `@AppStorage` on this view. A tab switch that changes source has to write
///   it and suppress the `onChange` that would otherwise call `retargetPane()` over the navigation
///   the switch just restored: the suppression `swapPanesAction` uses, on its own counter so the
///   two never consume each other's.
/// - The search field is this view's `@State`. The manager reads it back through
///   `paneSearchSnapshot` when it parks a tab; applying it is done here, off the tab each verb
///   returns.
/// - Persistence and the launch seed need the provider list, the roots on disk and `UserDefaults`,
///   none of which `Sync` reaches into.
///
/// Everything routes through `tabAction`, so one place knows the order these happen in.
extension ContentView {

    // MARK: - What the strip renders

    /// This pane's own provider id: where the source pair is narrowed to a side. `paneScope(isLeft:)`
    /// and `paneStack(isLeft:)` do the same for the location pair, one wrapper per pair.
    ///
    /// **Never write `isLeft ? leftProviderId : rightProviderId` by hand.** A ternary is a spelling
    /// nothing can check: transposed inside `tabAction`'s `PaneTabProviderSwitch.decide(current:)`
    /// call, a cross-source chip click would ask about the sibling's source, answer `.keep`, render
    /// the tab's path under the wrong root, and `saveBrowseTabs` would write the tab's `providerId`
    /// to a source it never named.
    ///
    /// One wrapper over `PaneSideChoice.own`, so the polarity is a real assertion
    /// (`theSideChoiceReadsItsArgument` calls it) and the pair-to-side arguments are written once.
    /// Every call site is `paneProviderId(isLeft: …)`, which the argument-token invariants can read.
    func paneProviderId(isLeft: Bool) -> String {
        PaneSideChoice.own(isLeft, left: leftProviderId, right: rightProviderId)
    }

    /// This pane's own comparison scope: the same narrowing, for the location pair.
    ///
    /// **Never cut the location pair by hand.** A transposed ternary is invisible to every test and
    /// breaks three things:
    ///
    /// - the `openedFromScope:` cuts. With the sibling's scope, `PaneTabOpening.location` either
    ///   gets a scope that is not a prefix of this pane's location and returns
    ///   `(combined, PaneBrowsePath())`, flattening the columns, or a deeper prefix and creates the
    ///   tab at a `relativePath` the user never set.
    /// - `saveBrowseTabs`' overlay, which would store the sibling's folder and column stack as this
    ///   pane's active tab, restored onto it at the next launch.
    /// - `ColumnStackPruning`, which would prune the left stack against the right pane's children
    ///   index, collapsing it in Compare to the deepest prefix the right side happens to have.
    ///
    /// One wrapper each, so the pair-to-side arguments are written once and every call site spells
    /// its side as an `isLeft:` argument the invariants can read.
    func paneScope(isLeft: Bool) -> String {
        PaneSideChoice.own(isLeft, left: syncManager.leftRelativePath,
                           right: syncManager.rightRelativePath)
    }

    /// This pane's own column stack, the other half of where a pane is (see `PaneBrowsePath`),
    /// narrowed separately for `paneScope`'s reasons. A tab with one of these and the sibling's other
    /// would have a stack naming folders not under its scope.
    func paneStack(isLeft: Bool) -> PaneBrowsePath {
        PaneSideChoice.own(isLeft, left: syncManager.leftBrowsePath,
                           right: syncManager.rightBrowsePath)
    }

    /// This pane's chips, through `PaneTabChips`, where the rule can be tested; this half only looks
    /// up who each tab's provider is.
    func paneTabItems(isLeft: Bool) -> [PaneTabStrip.Item] {
        PaneTabChips.items(
            syncManager.paneTabs(isLeft: isLeft),
            liveProviderId: paneProviderId(isLeft: isLeft),
            // The chip names the folder the pane is showing, the same answer as the header's crumb
            // right under it; a chip reading a parked column stack the tree can't draw would
            // contradict that line. The tab's stored location keeps both halves (see `openTabHere`);
            // only this readout is resolved.
            livePath: syncManager.paneLocation(isLeft: isLeft, drawsColumns: paneDrawsColumns(isLeft: isLeft)),
            drawsColumns: paneDrawsColumns(isLeft: isLeft),
            // The discovered list here, not `paneCanShowSource`'s, and this is the one place that is
            // right: this resolves a name and a mark, not whether the pane may go there. A source
            // switched off in Settings still has a display name, and a chip reading "Dropbox" for
            // the moment before the tab is discarded beats one reading its raw id.
            source: { id in
                guard let provider = settings.availableProviders.first(where: { $0.id == id }) else { return nil }
                return PaneTabChips.Source(displayName: provider.displayName,
                                           markImageName: provider.imageName,
                                           root: provider.rootPath)
            })
    }

    /// Whether the source pane beside Edit's document or an Organize lens is drawing its tab strip,
    /// which pushes the pane's toolbar card down (see `EditorWorkspaceView.paneShowsTabStrip` and
    /// `LensWorkspaceView.paneShowsTabStrip`; both leave its slot empty above their header). The
    /// pane's own rule, and only while the pane is open. Here rather than in
    /// `ContentView+Editor.swift` because it reads the strip, and this file's readers are called
    /// from the files `everyTabVerbTheHostWiresReachesTheFocusDoorUnconditionally` walks.
    var sourcePaneShowsTabStrip: Bool {
        !panesHiddenForCurrentTab && paneShowsTabStrip(isLeft: true)
    }

    /// The source pane's strip rule alone, open or folded: what the workspace beside it keys its
    /// strip animation on. `sourcePaneShowsTabStrip` also flips when the pane folds, and an animation
    /// keyed on it would ease the workspace's width through a fold that snaps.
    var sourcePaneStripIgnoringFold: Bool {
        paneShowsTabStrip(isLeft: true)
    }

    /// Whether this pane draws a strip at all; see `PaneTabStripVisibility` for the rule, which is
    /// more than "does this pane have two tabs".
    func paneShowsTabStrip(isLeft: Bool) -> Bool {
        // Through the one flip, like every other reach for the sibling in this file; see
        // `PaneSideChoice.sibling`.
        let sibling = PaneSideChoice.sibling(isLeft)
        return PaneTabStripVisibility.shows(
            own: syncManager.paneTabs(isLeft: isLeft).showsStrip || tabStripHold.holds(isLeft: isLeft),
            sibling: syncManager.paneTabs(isLeft: sibling).showsStrip || tabStripHold.holds(isLeft: sibling),
            isCompare: layoutMode == .compare,
            switchIsOn: tabBarVisible)
    }

    /// Track the tab strip gives up to the seam controls, which are drawn over this row.
    func seamInset(isLeft: Bool, leading: Bool) -> CGFloat {
        PaneTabSeam.inset(isCompare: layoutMode == .compare, isLeft: isLeft, leading: leading)
    }

    /// Whether a pane may be pointed at this source at all: the one list every tab question asks,
    /// `enabledProviders`.
    ///
    /// **Not `availableProviders`**, the discovered list. That keeps a source switched off in
    /// Settings (its folder is still on disk, and the inspector's *Where it lives* coverage wants it;
    /// see `SettingsManager.cloudCoverage`), but nothing that points a pane wants it.
    /// `refreshAction` and `refreshForTabSwitch` resolve their providers from `enabledProviders` and
    /// load nothing when one is missing, so a pane on a disabled source is never walked. At launch,
    /// `restoreBrowseTabs` writes the restored tab's provider over the pane's id after
    /// `applyProviderSelection` resolved it, so restoring a tab on a disabled source would leave both
    /// panes up, empty, with no scan and nothing said. Mid-session, `decide` would answer `.adopt`
    /// where it means `.unavailable`.
    ///
    /// One predicate, so the question can't be asked two ways. Chip rendering deliberately still
    /// reads `availableProviders` (`paneTabItems`): naming a disabled source beats showing its raw
    /// id for the moment before the tab is discarded.
    var paneCanShowSource: (String) -> Bool {
        { id in settings.enabledProviders.contains { $0.id == id } }
    }

    // MARK: - The one door

    /// Runs a tab verb and settles everything that follows from it: the provider id, the search
    /// field, the reload, and the saved strip.
    ///
    /// `verb` returns the tab the pane arrived at, or `nil` when the pane did not move (closing a
    /// parked tab, selecting the tab already live). `nil` still saves, since the strip changed, and
    /// still costs no reload, which is the point of the distinction.
    ///
    /// - Parameter movesFocus: whether this counts as the user working in `isLeft`. True for every
    ///   verb aimed at a pane; false for the mirrored half of a linked open, which lands on the
    ///   sibling because the user did not aim at it. See `noteWorkingIn`.
    private func tabAction(isLeft: Bool, movesFocus: Bool = true, _ verb: () -> PaneTab?) {
        // The bootstrap window is interactive, and a tab verb there would move a pane whose source
        // the bootstrap hasn't finished choosing, and `saveBrowseTabs` would write that over the
        // strip the restore is about to read. Refused outright, as `swapPanesAction` refuses.
        guard !isBootstrappingProviders else { return }

        if movesFocus { noteWorkingIn(isLeft: isLeft, "a browse tab verb was aimed at this pane") }

        // Read before the verb runs, because the verb moves the pane: the arriving tab is compared
        // against these two to decide whether anything needs reloading.
        let fromProvider = paneProviderId(isLeft: isLeft)
        let fromFocus = paneScope(isLeft: isLeft)

        guard let arrived = verb() else {
            saveBrowseTabs(isLeft: isLeft)
            return
        }

        // The search field travels with the tab: set to the incoming tab's own state, which for a
        // new tab is an empty, closed field.
        paneSearchState(isLeft: isLeft).wrappedValue = PaneSearchFieldState(
            query: arrived.searchQuery, isExpanded: arrived.searchIsExpanded)

        switch PaneTabProviderSwitch.decide(
            arrived: arrived.providerId,
            current: paneProviderId(isLeft: isLeft),
            isAvailable: paneCanShowSource) {
        case .keep:
            break
        case .adopt(let id):
            adoptProviderForTab(id, isLeft: isLeft,
                                log: "A browse tab moved the \(PaneSideChoice.name(isLeft)) pane to \(id)")
        case .unavailable:
            // The tab names a source this pane can no longer be pointed at, and by now the verb has
            // already pointed the pane at that tab's folder path under the live source's root,
            // which usually exists nowhere. The tab goes, and the pane lands on one that works;
            // `discardTab` says what that means for the last tab.
            //
            // Every dead tab behind it goes too: the fallback is a neighbour, and two tabs on one
            // dead source would otherwise land the pane on the second one, showing the same empty
            // folder. See `discardDeadTabs`.
            let outcome = syncManager.discardDeadTabs(
                startingAt: arrived.id, isLeft: isLeft,
                currentProviderId: paneProviderId(isLeft: isLeft),
                isAvailable: paneCanShowSource)
            for gone in outcome.discarded {
                Logger.shared.warning("Discarded a browse tab: its source “\(gone)” is gone or switched off")
            }
            // The id is always in the list (the verb that returned it put it there), so reaching
            // here means an assumption this branch rests on has stopped holding, and the log is the
            // only place that would say so.
            if outcome.discarded.isEmpty {
                Logger.shared.warning("A browse tab named an unusable source but could not be discarded")
            }
            if let landed = outcome.landed {
                paneSearchState(isLeft: isLeft).wrappedValue = PaneSearchFieldState(
                    query: landed.searchQuery, isExpanded: landed.searchIsExpanded)
                // **The tab it landed on may be on a third source, and must be adopted like any other
                // arrival.** `discardDeadTabs` stops at the first neighbour this pane can show, not
                // necessarily the pane's current source: with Dropbox gone and tabs [iCloud, Dropbox,
                // GoogleDrive], clicking the Dropbox chip lands on GoogleDrive. Taking only its search
                // field would show GoogleDrive's folder path under iCloud's root (an empty pane), with
                // iCloud's mark on the chip, and `saveBrowseTabs` would retarget that tab to iCloud.
                if landed.providerId != paneProviderId(isLeft: isLeft),
                   paneCanShowSource(landed.providerId) {
                    adoptProviderForTab(landed.providerId, isLeft: isLeft,
                                        log: "Landed the \(PaneSideChoice.name(isLeft)) pane on \(landed.providerId) after discarding a dead tab")
                }
            }
        }
        saveBrowseTabs(isLeft: isLeft)
        // Only when the arriving tab is somewhere else, asked with the values captured above: the
        // two have to agree with `applyTab`'s rule, or a pane is invalidated and never reloaded. A
        // switch inside one source at one scope moves the column stack, selection and history,
        // which the trees and differences aren't computed from. Refreshing is the Refresh button's
        // job.
        //
        // Asked of `arrived`, not of whatever `.unavailable` landed on, and that is right by
        // construction: `decide` reports `.unavailable` only for a source that differs from the
        // pane's, so a discarded tab always answers yes here, which it needs, since the verb that
        // applied it already dropped the trees.
        if PaneTabArrival.needsReload(arrivingAt: arrived, fromProvider: fromProvider, fromFocus: fromFocus) {
            refreshForTabSwitch(movedPane: isLeft)
        }
    }

    /// Points a pane at the source a tab names: the one spelling of that operation.
    ///
    /// A tab switch that changes source is a provider switch that differs from the source menu's in
    /// one way: the tab carries the navigation, so the `onChange` handler's `retargetPane()` must not
    /// run. The suppression counter skips that handler, so this does the rest of its work:
    ///
    /// - the ignored-items re-key. That store is keyed on the pair of sources; left on the old pair,
    ///   the scan hides items ignored for a comparison no longer on screen, and a new "Ignore" is
    ///   saved under the wrong key.
    /// - the lens clear: no stale Tidy result outlives its provider, and the left strip is the
    ///   Organize/Storage rail's strip.
    /// - the review dispatch, which ends a guided review framed on the old pair (a no-op with no
    ///   review, so the launch restore can share this path). It dispatches `.tabChangedSource`, not
    ///   `.providerSwitched`, on purpose: `.providerSwitched` can answer `.undoProviderPin`, which
    ///   repoints and re-homes the sibling pane, yanking it off the folder its own tab names. The pin
    ///   is left alone instead.
    ///
    /// `log` is the only thing that varies between callers, so they can't drift apart.
    ///
    /// `ForTab` names the contract, not the caller. ⌘K's Go to Folder for a path in another source
    /// (`ContentView.switchSourceAndReveal`) needs exactly this: it has already decided where the
    /// pane goes, and still owes the re-key, the lens clear and the tab-shaped review dispatch. It is
    /// `internal` for that caller alone; every write of a pane provider id in this file still goes
    /// through it, which `theOnlyWriterOfAPaneProviderIdInTheTabsFileIsTheAdoptHelper` counts.
    ///
    /// The counter is shared with the palette's use, safe for the reason a mis-attribution between
    /// `PaneProviderChange`'s two consuming cases is: what is guaranteed is a total, and
    /// `.consumeTab` does the same nothing for either writer. See that rule's doc.
    func adoptProviderForTab(_ id: String, isLeft: Bool, log: String) {
        // One suppressed change, then the caller drives the single reload: the shape
        // `swapPanesAction` uses, on its own counter. Sharing one would let a swap eat a tab
        // switch's suppression and reset the navigation it just restored.
        pendingTabProviderChanges += 1
        if isLeft { leftProviderId = id } else { rightProviderId = id }
        Logger.shared.info(log)
        // Through the coordinator's tab-shaped door, not the bare event: the epilogue needs to know
        // which pane the tab moved, and `CompareReviewEvent.tabChangedSource` carries no side.
        // Gated on the pair having moved instead, the stranded-pin warning would fire when nothing
        // was stranded. See `DuplicateReviewCoordinator.noteTabChangedSource`.
        reviewCoordinator.noteTabChangedSource(isLeft: isLeft)
        syncManager.clearLensResultsForProviderSwitch()
        // Both ids read back after the write above, because the pair key is both of them. `pairKey`
        // sorts, so the order here doesn't matter; the values do.
        syncManager.ignoredItemsStore?.activate(
            pairKey: IgnoredItemsStore.pairKey(leftProviderId, rightProviderId))
    }

    /// Records that the user is working in this pane, so the pane-scoped chords follow them.
    ///
    /// `focusedPaneSide` answers "which pane am I working in". A strip click, the ＋, the header
    /// card's New Tab and the pane background menu all have to say so too, or in Compare ⌘W, ⌘T, ⇧⌘]
    /// (and ⌘F, ⌘[, ⌘], ⇧⌘N) aim at the pane the user isn't looking at. One of those is
    /// destructive: with a second tab open on the right and focus on a one-tab left pane, ⌘W hits
    /// `closeTab`'s last-tab branch and closes the window.
    ///
    /// The side is resolved by `FileSyncManager.noteFocusedPane(isLeft:because:)`, not here:
    /// `ContentView` can't be built in a test, so a flipped ternary here would be invisible. That
    /// type owns the polarity, and writes the log line.
    private func noteWorkingIn(isLeft: Bool, _ reason: String) {
        syncManager.noteFocusedPane(isLeft: isLeft, because: reason)
    }

    /// The reload a tab switch asks for, when it asks for one.
    ///
    /// A provider change writes `@AppStorage` a beat after `applyTab` returns, so this runs after
    /// that write and drives the single reload. Asking twice is free when nothing moved:
    /// `refreshTreesAndScan` dedupes an identical in-flight target rather than restarting it.
    /// - Parameter movedPane: the side the switch happened on. Only that pane is walked: the other's
    ///   tree is a walk the switch did not touch, and re-walking it costs 15–36ms of every switch
    ///   for nothing. The scan still compares both, using the tree the untouched pane already holds.
    ///
    /// `internal` for the same one caller as `adoptProviderForTab`: ⌘K's cross-source Go to Folder
    /// drives the same single reload after the same suppressed provider write.
    ///
    /// Through `refreshAction`, the one spelling of a comparing refresh, never a copy of it. That
    /// settles what Compare owes: the other pane isn't walked, so the scan reads its cached walk
    /// (kept by `dropPrefetchedTrees(keeping:)`), and a file the editor wrote under its folder would
    /// be compared as it was before the write unless that walk goes first.
    func refreshForTabSwitch(movedPane isLeft: Bool) {
        refreshAction(reloading: .movedPane(isLeft: isLeft))
    }

    // MARK: - The verbs, as the UI names them

    /// ⌘T, the ＋, and a double-click on the strip's empty stretch.
    ///
    /// Opens the current folder, and the control says so ("New tab here"). That gives two tabs
    /// with the same name, but opening at the provider root would throw away the folder you pressed
    /// ⌘T from.
    func openNewTabHere(isLeft: Bool) {
        openTabHere(isLeft: isLeft)
        // Mirrored as the verb reads, not as a path. ⌘T's contract is that the pane doesn't move,
        // so the sibling gets a new tab at its own current folder rather than being teleported to
        // this one's. Linked and in step those are the same folder; drifted, both keep their place.
        guard tabsOpenOnBothPanes else { return }
        let sibling = PaneSideChoice.sibling(isLeft)
        openTabHere(isLeft: sibling, mirrored: true)
    }

    /// `mirrored` changes only the log line: a mirrored ⌘T opens the sibling at its own folder, so
    /// without it the two panes would log the same sentence in the same second and read as one
    /// keystroke firing twice.
    private func openTabHere(isLeft: Bool, mirrored: Bool = false) {
        let providerId = paneProviderId(isLeft: isLeft)
        let here = syncManager.combinedRelativePath(isLeft: isLeft)
        // Both halves of where the pane is, not the joined string. Handing `here` over as the new
        // tab's scope would collapse the column stack: scope draws one column and the stack the
        // rest, so ⌘T from four open columns would give one full-width column, and persistence
        // would keep it that way across restarts.
        //
        // Through `PaneTabOpening`, so this and `openInNewTab` cut a location the same way; from
        // the pane's own location it returns exactly the pane's own two halves. The scope comes
        // through `paneScope(isLeft:)`, never a ternary, which transposed would flatten the columns
        // the same way.
        let cut = PaneTabOpening.location(of: here, openedFromScope: paneScope(isLeft: isLeft))
        // A mirrored open lands on the pane the user did not aim at, so it must not take the focus,
        // or ⌘T in a linked Compare would leave every pane-scoped chord on the sibling.
        tabAction(isLeft: isLeft, movesFocus: !mirrored) {
            // Logged from inside, so a refused action (the bootstrap guard) leaves no line claiming
            // it happened.
            let where_ = here.isEmpty ? "the source root" : here
            Logger.shared.info(mirrored
                ? "Linked panes: also opened a new tab at “\(where_)” on the other pane"
                : "User opened a new tab at “\(where_)”")
            return syncManager.openTab(
                PaneTab(providerId: providerId, relativePath: cut.scope, browsePath: cut.stack),
                isLeft: isLeft, currentProviderId: providerId)
        }
    }

    /// A tab at `route`, rooted at the folder: the whole path its scope, no column stack. A value
    /// only; it moves no pane.
    ///
    /// Deliberately not cut like Open in New Tab's (`PaneTabOpening.location`), which keeps the
    /// pane's scope and stacks the rest as columns; that suits a row on screen, which the scope's
    /// walk has reached. A followed folder can be anywhere, and a walk of a large source stops at
    /// 200,000 entries, so the stack would be pruned to what was walked and the pane would land a
    /// folder short with nothing selected. Rooted at the folder, the tab walks the folder itself;
    /// the breadcrumb still climbs.
    static func tabAtRoute(_ route: ExternalOpen.SourceRoute, selecting selection: Set<String> = []) -> PaneTab {
        PaneTab(providerId: route.providerId, relativePath: route.relativePath, browsePath: PaneBrowsePath(),
                selection: selection)
    }

    /// Opens a tab at `route` on the `isLeft` pane and makes it live: the pane following a file Edit
    /// is opening (`ContentView.followFolderInTabs`). Through `tabAction`, so a tab on another source
    /// adopts it exactly as clicking that tab's chip would, and the strip is saved.
    func openTabAtRoute(_ route: ExternalOpen.SourceRoute, isLeft: Bool, log: String) {
        let current = paneProviderId(isLeft: isLeft)
        let tab = Self.tabAtRoute(route)
        tabAction(isLeft: isLeft) {
            Logger.shared.info(log)
            return syncManager.openTab(tab, isLeft: isLeft, currentProviderId: current)
        }
    }

    /// Right-click a folder ▸ Open in New Tab, and File ▸ Open in New Tab for the selected folder:
    /// the discovery route, and the only entry point that opens the new tab somewhere different.
    func openInNewTab(absolutePath: String, isLeft: Bool) {
        let providerId = paneProviderId(isLeft: isLeft)
        // Expanded. A source's stored path may use a tilde, while a row's id is always absolute;
        // `relativize` compares them as strings, so an unexpanded root matches nothing and this
        // entry point becomes a silent no-op. `PaneLogic.fullPath` and `PaneLogic.paneFocusRestores`
        // expand for the same reason.
        let root = (settings.rootPath(for: providerId) as NSString).expandingTildeInPath
        guard let relative = PathBoundary.relativize(absolutePath, under: root) else {
            // A folder outside this pane's root has no tab to be opened as: the strip lists
            // locations under one source, and inventing one would name a path the pane can't reach.
            Logger.shared.warning("Ignored Open in New Tab for a path outside the pane's source: \(absolutePath)")
            return
        }
        // Cut against the pane this row belongs to (see `openTabHere`). A folder under the pane's
        // scope keeps that scope and becomes stack, so the new tab opens with the ancestor columns;
        // a folder outside it is all scope.
        let cut = PaneTabOpening.location(of: relative, openedFromScope: paneScope(isLeft: isLeft))
        tabAction(isLeft: isLeft) {
            Logger.shared.info("User opened “\(relative)” in a new tab")
            return syncManager.openTab(
                PaneTab(providerId: providerId, relativePath: cut.scope, browsePath: cut.stack),
                isLeft: isLeft, currentProviderId: providerId)
        }
        mirrorOpenInNewTab(relative, from: isLeft)
    }

    /// The sibling's half of Open in New Tab, when the panes are linked.
    ///
    /// Pruned, not copied. The two sides are compared because they differ, so the folder just opened
    /// here may not exist there; `PaneTabMirror` walks the sibling as deep as it really can, as
    /// `applyColumnNavigation` does for a mirrored drill. A tab naming a folder that pane doesn't
    /// have would be a chip that can't be navigated to.
    private func mirrorOpenInNewTab(_ relative: String, from isLeft: Bool) {
        guard tabsOpenOnBothPanes else { return }
        // Through the one flip, never a hand-written `!`: dropped, it would open both tabs of a
        // linked Open in New Tab on the aimed pane and none on the sibling, unseen by any test. The
        // polarity lives on a type a test can call (`theSideChoiceReadsItsArgument`).
        let other = PaneSideChoice.sibling(isLeft)
        let providerId = paneProviderId(isLeft: other)
        // Expanded, for the reason `openInNewTab` gives: a tilde root exists on no disk, so every
        // mirror would prune away to the sibling's root.
        let root = (settings.rootPath(for: providerId) as NSString).expandingTildeInPath
        // Translated first, as a linked crumb click and a linked drill are: `relative` is measured
        // from the clicked pane's root, and the two sources need not open at the same depth.
        // Untranslated, the failure hides behind the pruning: handed `Family` from an iCloud pane, a
        // OneDrive sibling would look for `<account>/Family`, prune to nothing and open at the top
        // of the account while the folder sits at `Documents/Family`; or `<account>/Family` exists
        // and is an unrelated tree, and the tab opens on it. Aimed at `other`, like every
        // side-taking call in this verb; `relativePathForPane` holds the two-sidedness so this call
        // site names only the pane it opens a tab on.
        let mirrored = relativePathForPane(relative, isLeft: other)
        let landing = PaneTabMirror.landing(for: mirrored) { candidate in
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(
                atPath: PaneLogic.fullPath(root: root, relativePath: candidate), isDirectory: &isDirectory)
            return exists && isDirectory.boolValue
        }
        // Cut against the sibling's scope, not this pane's: the landing was pruned to what that pane
        // has, and the wrong pane's scope would put components in a stack not underneath it.
        let cut = PaneTabOpening.location(of: landing, openedFromScope: paneScope(isLeft: other))
        // The sibling's half of the open: the user aimed at the pane `other` is the sibling of, so
        // the focus stays there.
        tabAction(isLeft: other, movesFocus: false) {
            Logger.shared.info("Linked panes: also opened “\(landing.isEmpty ? "the source root" : landing)” in a new tab on the other pane")
            return syncManager.openTab(
                PaneTab(providerId: providerId, relativePath: cut.scope, browsePath: cut.stack),
                isLeft: other, currentProviderId: providerId)
        }
    }

    /// Whether opening a tab on one pane opens one on the other too.
    ///
    /// The same test `applyColumnNavigation` applies to a mirrored drill (Compare only, and the
    /// seam's 🔗 or a held ⌥), so every way of opening a folder obeys the one setting.
    private var tabsOpenOnBothPanes: Bool {
        layoutMode == .compare
            && (PaneLinkPreference.isLinked || NSEvent.modifierFlags.contains(.option))
    }

    /// How one tab is named in the log: the chip's own title, and the location under it.
    ///
    /// Both, because neither alone identifies a tab. ⌘T opens the folder you are already in, so
    /// same-titled chips are expected, and the title (the leaf component) alone would make two
    /// closes of different tabs read identically. The path alone isn't what the chip says.
    ///
    /// Read through `paneTabItems` for the title and split the same way for the path: the active tab
    /// is described by the live pane and every parked one by its own snapshot, because the list's
    /// active entry is stale by construction (see `PaneTab`). Read off the list, the active tab would
    /// be named by the folder it was parked at.
    private func tabLogDescription(id: UUID, isLeft: Bool) -> String {
        let list = syncManager.paneTabs(isLeft: isLeft)
        let title = paneTabItems(isLeft: isLeft).first { $0.id == id }?.title ?? "a tab"
        guard let index = list.index(of: id) else { return "“\(title)”" }
        // Resolved exactly as the chip is (see `PaneTabChips.items`), so the log never names a
        // folder the strip didn't show.
        let drawsColumns = paneDrawsColumns(isLeft: isLeft)
        let path = index == list.selectedIndex
            ? syncManager.paneLocation(isLeft: isLeft, drawsColumns: drawsColumns)
            : (drawsColumns ? list.tabs[index].combinedRelativePath : list.tabs[index].relativePath)
        return "“\(title)” (\(path.isEmpty ? "the source root" : path))"
    }

    /// Selecting and cycling log at debug, not info.
    ///
    /// Every other tab verb logs at info, in the app's `User <verbed>` style. These two don't
    /// because ⌃⇥ held down walks the whole strip, and at info one impatient cycle would bury the
    /// lines worth finding. The lines still name the side and the tab, so they mean something when
    /// they are the ones being read.
    func selectTab(id: UUID, isLeft: Bool) {
        let list = syncManager.paneTabs(isLeft: isLeft)
        // Named before the switch, as `closeTab` names its tab: this tab is parked now, so its own
        // snapshot is where it is; after the switch it would be the live pane's.
        let arriving = tabLogDescription(id: id, isLeft: isLeft)
        // Clicking the chip you are already on logs nothing, because nothing happened.
        // `PaneTabStrip` fires `onSelect` from every chip including the active one, and `switchTab`
        // answers `nil` for that (`target != list.selectedIndex`). `cycleTab` likewise declines to
        // claim a move it didn't make.
        //
        // A guard on the index rather than a log moved below the verb, because the description has
        // to be taken while this tab is still parked. Asked the way `switchTab` asks it, both
        // halves: an id not in this strip doesn't move the pane either, the shape
        // `guard let target = list.index(of: id)` refuses.
        let target = list.index(of: id)
        let moves = target != nil && target != list.selectedIndex
        tabAction(isLeft: isLeft) {
            if moves {
                Logger.shared.debug("User selected the \(PaneSideChoice.name(isLeft)) pane's browse tab \(arriving)")
            }
            return syncManager.switchTab(to: id, isLeft: isLeft,
                                         currentProviderId: paneProviderId(isLeft: isLeft))
        }
    }

    func cycleTab(forward: Bool, isLeft: Bool) {
        tabAction(isLeft: isLeft) {
            // Named after the verb: which tab ⌃⇥ lands on is the verb's answer, and working it out
            // here would be a second copy of `selectNext`'s wrap. The tab it returns is by then the
            // live pane, which is how `tabLogDescription` describes it.
            let arrived = syncManager.cycleTab(forward: forward, isLeft: isLeft,
                                               currentProviderId: paneProviderId(isLeft: isLeft))
            // Nothing moved, nothing said: a one-tab pane has nowhere to cycle to, and pressing the
            // chord there is a real thing a user does.
            if let arrived {
                Logger.shared.debug(
                    "User cycled to the \(forward ? "next" : "previous") browse tab in the "
                    + "\(PaneSideChoice.name(isLeft)) pane: \(tabLogDescription(id: arrived.id, isLeft: isLeft))")
            }
            return arrived
        }
    }

    /// Closing the last tab closes the window, as Finder does, which keeps ⌘W meaning "get rid of
    /// this" with no exception to remember.
    func closeTab(id: UUID, isLeft: Bool) {
        // Named before it goes, because afterwards there is nothing to name it by, and closing is
        // the one tab verb that throws away state (history, selection) with only a ten-deep undo
        // behind it. The side and the whole path, not the title alone: ⌘T opens the folder you are
        // already in, so titles repeat, and in Compare the line must say which pane lost a tab.
        //
        // Taken ahead of the last-tab guard, because that branch needs it most: closing the window
        // is this feature's one destructive outcome, and which pane the press landed in is the
        // question that line has to answer.
        let closing = tabLogDescription(id: id, isLeft: isLeft)
        // A keyboard close lets a held strip go at once, since nothing is aiming at it. A close
        // from the strip holds it again straight after (`holdingTabStrip`).
        if tabStripHold.holds(isLeft: isLeft) { tabStripHold.release(isLeft: isLeft) }
        guard syncManager.paneTabs(isLeft: isLeft).count > 1 else {
            // Asked because this closes the window, not because the buffer would be lost: the
            // document belongs to the app (``SyncCloudApp/editorDocument``) and outlives the window,
            // so reopening brings the typing back. The question stays because this is the last
            // moment the user is looking at an unsaved document, and the platform prompts when a
            // window with unsaved work closes. Cancelling leaves the tab and the window where they
            // are. "Don't Save" reloads the file, since the document stays open behind the window.
            guard EditorDocumentClose.settleForWindowClose(
                // The PDF outlives the window, so its pending order is not asked about here, nor is
                // a deleted file's text, which is still on screen when the window comes back.
                document: editorDocument, settle: { settleEditorDocument(asksAboutPDFWork: false, asksAboutTheOnlyCopy: false) },
                reload: { reloadOverTheBuffer(path: $0) }) else {
                Logger.shared.info(
                    "User cancelled Close Tab on the \(PaneSideChoice.name(isLeft)) pane's last "
                    + "browse tab \(closing) — the editor has unsaved changes")
                return
            }
            Logger.shared.info(
                "User pressed Close Tab on the \(PaneSideChoice.name(isLeft)) pane's last browse tab "
                + "\(closing) — closing the window")
            NSApp.keyWindow?.performClose(nil)
            return
        }
        tabAction(isLeft: isLeft) {
            Logger.shared.info("User closed the \(PaneSideChoice.name(isLeft)) pane's browse tab \(closing)")
            return syncManager.closeTab(id: id, isLeft: isLeft,
                                        currentProviderId: paneProviderId(isLeft: isLeft))
        }
    }

    func closeOtherTabs(keeping id: UUID, isLeft: Bool) {
        // The count is the point of this line: this is the one gesture that closes several tabs
        // at once, and "how many did that take" is unanswerable afterwards. Counted from the list
        // as it stands before the verb, the only place the answer exists.
        let list = syncManager.paneTabs(isLeft: isLeft)
        let closing = list.closableOthers(keeping: id)
        tabAction(isLeft: isLeft) {
            let arrived = syncManager.closeOtherTabs(keeping: id, isLeft: isLeft,
                                                     currentProviderId: paneProviderId(isLeft: isLeft))
            // Written after the verb, and only when it closed something, so an ⌥-click on the ✕
            // of a strip whose other tabs are all pinned doesn't log "User closed 0 other browse
            // tabs". The verb still runs: "leave me with this one" also makes the kept tab live.
            if closing > 0 {
                Logger.shared.info("User closed \(closing) other \(PaneSideChoice.name(isLeft)) pane browse tab\(closing == 1 ? "" : "s")\(list.pinnedCount > 0 ? ", keeping \(list.pinnedCount) pinned" : "")")
            }
            return arrived
        }
    }

    func duplicateTab(id: UUID, isLeft: Bool) {
        // Named before the verb, and named at all: a duplicate is a second chip with the same title
        // at the same folder, so a bare "duplicated a browse tab" couldn't be matched to a chip.
        let duplicating = tabLogDescription(id: id, isLeft: isLeft)
        tabAction(isLeft: isLeft) {
            Logger.shared.info("User duplicated the \(PaneSideChoice.name(isLeft)) pane's browse tab \(duplicating)")
            return syncManager.duplicateTab(id: id, isLeft: isLeft,
                                            currentProviderId: paneProviderId(isLeft: isLeft))
        }
    }

    /// Pin / unpin, from a tab's context menu, through `tabAction` returning `nil`.
    ///
    /// The pane doesn't move, so there is no provider to write, no search field to swap and no
    /// reload. That is what the one door's `nil` answer means, and it does the remaining steps in
    /// the order this verb needs: refuse during bootstrap, record which pane the user is working
    /// in, run the verb, save the strip.
    ///
    /// **Don't write those steps out by hand.** The invariant that bans
    /// `noteWorkingIn(isLeft: !isLeft, …)` is scoped to `tabAction`'s body, and so is the one that
    /// keeps the focus move unconditional (an `if pinned { … }` around it would leave ⌘W aimed at
    /// the pane the user isn't looking at after an unpin). `moveTab` goes through the door too.
    func setTabPinned(_ pinned: Bool, id: UUID, isLeft: Bool) {
        tabAction(isLeft: isLeft) {
            // Named before the verb: pinning re-sorts the strip, so afterwards this tab sits at a
            // different index and `tabLogDescription`'s live-versus-parked test would ask about the
            // wrong one.
            Logger.shared.info(
                "User \(pinned ? "pinned" : "unpinned") the \(PaneSideChoice.name(isLeft)) pane's browse "
                + "tab \(tabLogDescription(id: id, isLeft: isLeft))")
            syncManager.setTabPinned(pinned, id: id, isLeft: isLeft)
            // The pane did not move; see `tabAction`, where `nil` still saves the strip and still
            // costs no reload.
            return nil
        }
    }

    /// Drag-to-reorder. Debug, like selecting: a drag emits one line and changes nothing but where a
    /// chip sits. Through `tabAction` with a `nil` answer, for `setTabPinned`'s reasons.
    func moveTab(id: UUID, to index: Int, isLeft: Bool) {
        tabAction(isLeft: isLeft) {
            // Named before the verb, for `setTabPinned`'s reason: after the move this tab is at
            // another index, and the description is read off the list by index.
            Logger.shared.debug(
                "User reordered the \(PaneSideChoice.name(isLeft)) pane's browse tab "
                + "\(tabLogDescription(id: id, isLeft: isLeft))")
            syncManager.moveTab(id: id, to: index, isLeft: isLeft)
            return nil
        }
    }

    func reopenClosedTab(isLeft: Bool) {
        tabAction(isLeft: isLeft) {
            // Inside the verb, so a press that brings nothing back writes no line claiming a tab
            // came back. The item is normally disabled then (`shortcutReopenClosedTab` returns nil
            // when the target pane's `canReopen` is false, and `ReopenClosedTabCommand` is
            // `.disabled(reopen == nil)`), so this guard is the defensive reading, but still the
            // only thing between an empty stack and a line asserting a reopen.
            guard let tab = syncManager.reopenClosedTab(
                isLeft: isLeft, currentProviderId: paneProviderId(isLeft: isLeft))
            else { return nil }
            // Named after the verb, as `cycleTab` is: which tab comes back is the verb's answer, and
            // by now it is the live pane, which is how `tabLogDescription` describes it. The side
            // says which pane, in Compare.
            Logger.shared.info(
                "User reopened the \(PaneSideChoice.name(isLeft)) pane's closed browse tab "
                + "\(tabLogDescription(id: tab.id, isLeft: isLeft))")
            return tab
        }
    }

    /// Copy Path, from a tab's context menu: the absolute path, which is what is useful in Terminal
    /// or Finder's ⇧⌘G, rather than the relative one the chip is named for.
    func copyTabPath(id: UUID, isLeft: Bool) {
        // Refused while the providers are still bootstrapping, like every other strip verb:
        // otherwise it would move the pane-scoped chords, and write a line, against a pane whose
        // source the bootstrap hasn't finished choosing.
        guard !isBootstrappingProviders else { return }
        guard let item = paneTabItems(isLeft: isLeft).first(where: { $0.id == id }) else { return }
        // A strip-aimed verb where the pane doesn't move, so it skips `tabAction` and must say
        // itself which pane the user is working in: otherwise Copy Path in the right strip with a
        // one-tab left pane focused, then ⌘W, would close the window. Below the guard, so a menu
        // aimed at a chip this strip doesn't hold moves nothing.
        noteWorkingIn(isLeft: isLeft, "Copy Path from a browse tab's menu")
        NSPasteboard.general.clearContents()
        // `item.fullPath`, so this copies what the chip says, presentation and all. In Tree that is
        // the tab's scope, not its parked column stack: the chip's title, its tooltip and this
        // string are three renderings of one answer, where selecting the tab lands you. Copying a
        // folder the pane won't show would be the stranger result. Pinned in `PaneTabWiringTests`.
        NSPasteboard.general.setString(item.fullPath, forType: .string)
        // Named like every other strip-aimed verb, with the side, since same-titled chips in both
        // strips are expected and an absolute path doesn't say which chip was right-clicked. The
        // absolute path stays on the end: it is what went on the pasteboard, and
        // `tabLogDescription` carries the relative one the chip is named for.
        Logger.shared.info(
            "User copied the \(PaneSideChoice.name(isLeft)) pane's browse tab "
            + "\(tabLogDescription(id: id, isLeft: isLeft)) path: \(item.fullPath)")
    }

    // MARK: - Persistence and the launch seed

    /// Saves one pane's strip, each pane under its own key (see `PaneTabsStore`).
    ///
    /// **Refuses while the providers are still bootstrapping.** The launch sequence points the pane
    /// at its stored folder before `restoreBrowseTabs` reads the stored strip, and that move fires
    /// the `onChange` this hangs off. The pane then holds the freshly made one-tab list, so a save in
    /// that window would overwrite the user's whole strip with one tab before the restore reads it.
    /// Whether the window opens depends on when SwiftUI runs an update across the `await` between
    /// them, which is not a thing to leave to timing.
    func saveBrowseTabs(isLeft: Bool) {
        guard !isBootstrappingProviders else { return }
        // The active entry is a stale snapshot by construction, so it is written from the live pane
        // rather than the list; otherwise quitting would save the folder the tab was parked at.
        // The two halves of where the pane is (scope and column stack) go separately so the stored
        // depth isn't flattened to zero.
        //
        // The overlay is `PaneTabList.replacingActive`, in `Sync`, where tests can run it; this
        // file is a `View` extension nothing can instantiate.
        let saving = syncManager.paneTabs(isLeft: isLeft).replacingActive(
            providerId: paneProviderId(isLeft: isLeft),
            relativePath: paneScope(isLeft: isLeft),
            browsePath: paneStack(isLeft: isLeft))
        PaneTabsStore.save(tabs: saving.tabs, selected: saving.selectedIndex, isLeft: isLeft)
    }

    /// Restores the strip at launch, once the providers are known.
    ///
    /// Called from the same place the panes are first pointed at their sources. Does nothing when
    /// there is one stored tab at the root: that is where a fresh install and an upgrade both start,
    /// and seeding it would replace an identical list with one whose ids nothing else knows.
    func restoreBrowseTabs(isLeft: Bool) {
        // Behind the same setting as the folder restore beside it. Someone who turned "reopen the
        // last folder" off wants the app to start at the root, not five tabs of where they were.
        guard GeneralSettings.shouldRestoreLastFocus() else { return }
        // A pane with nothing stored keeps what `openPanesAtTheirLandingFolders` just gave it, which
        // for the right pane is the `lastRightFocusPath` restore, so a launch with no stored strip
        // behaves as it did before tabs.
        guard let stored = PaneTabsStore.load(isLeft: isLeft) else { return }
        let outcome = PaneTabsStore.restore(
            entries: stored.entries,
            selected: stored.selected,
            // The pane's list, not the discovered one (see `paneCanShowSource`): a tab on a source
            // the user switched off is dropped here rather than restored onto a pane nothing would
            // walk.
            isKnownProvider: paneCanShowSource,
            folderExists: { providerId, relativePath in
                guard !relativePath.isEmpty else { return true }
                // Expanded, for the reason `openInNewTab` gives: a tilde root never exists on disk,
                // so every restored tab would fall back to its provider's root.
                var isDirectory: ObjCBool = false
                let exists = FileManager.default.fileExists(
                    atPath: PaneLogic.fullPath(root: settings.rootPath(for: providerId),
                                               relativePath: relativePath),
                    isDirectory: &isDirectory)
                return exists && isDirectory.boolValue
            })
        // Everything from here to the applies is decided in `BrowseTabRestorePlan.plan`, where a
        // test can run it: which lines are said and in what order, whether anything is installed
        // (the seed-state abandon is there), and whether the pane must adopt the active tab's
        // provider.
        let plan = BrowseTabRestorePlan.plan(storedCount: stored.entries.count,
                                             outcome: outcome,
                                             isLeft: isLeft,
                                             currentProviderId: paneProviderId(isLeft: isLeft),
                                             canShowSource: paneCanShowSource)
        for line in plan.lines {
            switch line.level {
            case .warning: Logger.shared.warning(line.message)
            case .info: Logger.shared.info(line.message)
            }
        }
        guard let restored = plan.install else { return }
        syncManager.setPaneTabs(restored, isLeft: isLeft)
        if let adopt = plan.adoptProviderId {
            // **The counter, not the bootstrap guard.** SwiftUI evaluates `onChange` on the next
            // view update, and the bootstrap's tail lowers `isBootstrappingProviders` synchronously
            // right after these restores, so a bare id write would reach the handler with the guard
            // already down and take the full user-switch path: `retargetPane()` would put the pane
            // back at its root and `BrowseTabPersistence` would save that over the restored strip.
            // (A `@State` write followed synchronously by lowering a guard flag reaches `onChange`
            // with the flag false; with an `await` between them it is protected, which is why
            // `applyProviderSelection` is safe.)
            //
            // Arming the counter can't strand it, because the handler consumes the counters before
            // testing the bootstrap guard: wherever the write lands, it is accounted for once.
            adoptProviderForTab(adopt, isLeft: isLeft, log: plan.adoptLog ?? "")
        }
        // Re-read, because the line above may have just written it: `applyTab`'s reload rule has to
        // compare against the id the pane is on now, or it would report a source change already
        // adopted. At launch the pane is at its root and the tab usually isn't, so this normally
        // invalidates anyway; the bootstrap's own refresh two steps later is the reload.
        syncManager.applyTab(restored.active, isLeft: isLeft,
                             currentProviderId: paneProviderId(isLeft: isLeft))
    }
}


/// Keeps the saved strip in step with the live pane.
///
/// The active tab is the live pane (see `PaneTab`), so a strip written only when a tab opens or
/// closes would restore every tab at the folder it was created in. All three halves of where a tab
/// is are watched: the comparison scope, the column stack (the half that moves in Columns), and the
/// source.
///
/// **The source is easy to leave out and bites hardest.** Switching source at the root changes
/// nothing else: `retargetPane` finds the history default, the stack empty and the relative path
/// `""`, so neither path `onChange` fires. The stored active entry would keep naming the old
/// source, and since `restoreBrowseTabs` writes the restored tab's provider over
/// `selectedLeftProviderId`, the next launch would reopen on the source the user left.
///
/// A `ViewModifier` rather than `onChange`s in `ContentView.body`, because that chain is at the
/// type-checker's budget; this body is type-checked on its own.
struct BrowseTabPersistence: ViewModifier {
    @ObservedObject var syncManager: FileSyncManager
    /// Each pane's source. Plain `String`s rather than the `@AppStorage` bindings: this only needs
    /// to notice that one changed, and taking values keeps the modifier testable as a value.
    let leftProviderId: String
    let rightProviderId: String
    /// Saves the side that moved. Per side, not one save of both: the strips live under separate
    /// keys, and a single callback would either re-save the pane that didn't move on every click in
    /// the other, or need this modifier to know which key each value belongs to, the host's job.
    let save: (_ isLeft: Bool) -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: syncManager.leftRelativePath) { _, _ in save(true) }
            .onChange(of: syncManager.leftBrowsePath) { _, _ in save(true) }
            .onChange(of: leftProviderId) { _, _ in save(true) }
            .onChange(of: syncManager.rightRelativePath) { _, _ in save(false) }
            .onChange(of: syncManager.rightBrowsePath) { _, _ in save(false) }
            .onChange(of: rightProviderId) { _, _ in save(false) }
    }
}


/// The panes whose strip is held on screen under the pointer: begun by `holdingTabStrip` only
/// while `PaneTabStripPointer` has the pointer on that strip, ended when it leaves or a keyboard
/// close comes. Folded into each pane's `showsStrip` by `paneShowsTabStrip`, so in Compare a held
/// strip keeps its sibling's up too, as two tabs would.
struct PaneTabStripHold: Equatable {
    private var held: Set<Bool> = []

    func holds(isLeft: Bool) -> Bool { held.contains(isLeft) }
    mutating func hold(isLeft: Bool) { held.insert(isLeft) }
    mutating func release(isLeft: Bool) { held.remove(isLeft) }
}

/// Whether the pointer is on each pane's strip. A class, unobserved, because the strip's hover
/// fires on every crossing and a `ContentView` state write would re-render the window for it.
@MainActor
final class PaneTabStripPointer {
    private var over: Set<Bool> = []

    func isOver(isLeft: Bool) -> Bool { over.contains(isLeft) }

    func setOver(_ inside: Bool, isLeft: Bool) {
        if inside { over.insert(isLeft) } else { over.remove(isLeft) }
    }
}

/// Where the last right-click menu stood, for a Close Tab chosen from it.
///
/// The pane header's and a row's menus close a tab too, and without a hold the strip would go at
/// once, jumping the header and list up 34pt under a pointer still where the menu was. A menu
/// leaves no handle on where it was drawn, so this watches menus open: a context menu (one in no
/// menu bar) opens with its top-left at the click, pushed on-screen at the edges, at the size AppKit
/// laid it out. That frame, plus the point where the item was chosen, is the area the strip is held
/// for until the pointer leaves it (`ContentView.holdingTabStrip`).
@MainActor
final class PaneMenuOrigin {
    static let shared = PaneMenuOrigin()

    /// The open or last context menu's frame on screen.
    private(set) var area: NSRect?
    /// When it closed; `nil` while it is still up.
    private var closedAt: Date?
    private var observers: [NSObjectProtocol] = []
    /// Bumped per watch, so a watch a later hold replaced stops rather than releasing that hold.
    private var watchGeneration = 0

    /// How soon after a menu closes its item is still "from the menu": AppKit sends the action after
    /// the menu has gone.
    static let freshness: TimeInterval = 1

    /// The menu's frame from where it opened: top-left at `origin`, then moved onto `visible`, as
    /// AppKit moves a menu that would run off the screen.
    nonisolated static func estimatedFrame(origin: NSPoint, size: NSSize, visible: NSRect?) -> NSRect {
        var frame = NSRect(x: origin.x, y: origin.y - size.height, width: size.width, height: size.height)
        guard let visible else { return frame }
        if frame.maxX > visible.maxX { frame.origin.x = max(visible.minX, visible.maxX - frame.width) }
        if frame.minY < visible.minY { frame.origin.y = min(visible.maxY - frame.height, visible.minY) }
        return frame
    }

    /// The area a close just chosen from a context menu holds the strip for (the menu's frame and the
    /// point it was chosen at), or `nil` when no context menu is up or closed just now.
    func justChosenArea(at point: NSPoint, now: Date = Date()) -> NSRect? {
        guard let area else { return nil }
        if let closedAt, now.timeIntervalSince(closedAt) > Self.freshness { return nil }
        return area.union(NSRect(origin: point, size: .zero)).insetBy(dx: -4, dy: -4)
    }

    /// Notes a context menu opening at `origin` and closing. Split from the observers for the tests.
    func menuOpened(size: NSSize, at origin: NSPoint, visible: NSRect?) {
        area = Self.estimatedFrame(origin: origin, size: size, visible: visible)
        closedAt = nil
    }

    func menuClosed(now: Date = Date()) {
        if area != nil { closedAt = now }
    }

    /// Watches context menus open and close. Once, at launch.
    func install() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil,
                                            queue: nil) { note in
            guard Thread.isMainThread, let menu = note.object as? NSMenu else { return }
            MainActor.assumeIsolated {
                // A menu-bar menu, or a submenu of one, is not where a pane's Close Tab is chosen.
                guard menu.supermenu == nil, menu !== NSApp.mainMenu else { return }
                let origin = NSEvent.mouseLocation
                let screen = NSScreen.screens.first { NSMouseInRect(origin, $0.frame, false) }
                PaneMenuOrigin.shared.menuOpened(size: menu.size, at: origin, visible: screen?.visibleFrame)
            }
        })
        observers.append(center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil,
                                            queue: nil) { note in
            guard Thread.isMainThread, let menu = note.object as? NSMenu else { return }
            MainActor.assumeIsolated {
                guard menu.supermenu == nil, menu !== NSApp.mainMenu else { return }
                PaneMenuOrigin.shared.menuClosed()
            }
        })
    }

    /// Lets a strip held for a menu go once the pointer is out of `area` and off the strip, whose own
    /// hover lets it go when it leaves (`paneColumn`). Polled: the pointer's moves reach no view
    /// here, and a tenth of a second is soon enough for a strip to slide away.
    func watch(_ area: NSRect, stillHeld: @escaping () -> Bool, pointerOnStrip: @escaping () -> Bool,
               release: @escaping () -> Void) {
        watchGeneration += 1
        let generation = watchGeneration
        Task { @MainActor in
            while generation == watchGeneration, stillHeld() {
                try? await Task.sleep(for: .milliseconds(100))
                guard generation == watchGeneration, stillHeld() else { return }
                if !area.contains(NSEvent.mouseLocation) && !pointerOnStrip() {
                    release()
                    return
                }
            }
        }
    }
}

/// Whether a pane draws a tab strip.
///
/// A rule because of the middle term: **in Compare, one pane growing a second tab draws the strip
/// on both panes.** The two panes read as one row (headers, breadcrumbs and lists line up across the
/// seam), and a strip on one side only pushes that side's header 34pt down, so every row after it
/// names a different folder on the left than on the right. The sibling's strip holds one chip and a
/// ＋, which is also the discoverable way to give that side a second tab.
///
/// Browse has no sibling, and the single-source rail's other pane isn't on screen: both take the
/// own-pane term alone. Ticked-and-disabled past one tab is enforced by `shortcutTabBar`, so the
/// switch stays a plain disjunct.
enum PaneTabStripVisibility {
    static func shows(own: Bool, sibling: Bool, isCompare: Bool, switchIsOn: Bool) -> Bool {
        own || switchIsOn || (isCompare && sibling)
    }

    /// Whether View ▸ Tab Bar must read ticked-and-disabled: whether a strip is on screen for a
    /// reason the switch does not control.
    ///
    /// This is `shows` with the switch's own term removed, and that is the whole definition. The
    /// switch is frozen exactly when turning it off wouldn't put the strip away, because hiding it
    /// then would strand tabs the user can't otherwise reach: `shows(…, switchIsOn: false)`. Derived
    /// any other way (asking only the focused pane, say), a second tab in Compare's unfocused pane
    /// would put a strip on screen while the item read unticked and live.
    ///
    /// `theForcingIsExactlyTheStripShowingWithoutTheSwitch` holds the identity across every
    /// combination.
    static func forcesTabBarSwitch(own: Bool, sibling: Bool, isCompare: Bool) -> Bool {
        shows(own: own, sibling: sibling, isCompare: isCompare, switchIsOn: false)
    }
}


/// Where a mirrored tab lands on the sibling pane.
///
/// The deepest prefix of the folder that pane really has, which is "" (its root) when it has none.
/// Separate from the caller so the walk can be tested against a set of folders instead of a disk,
/// and because the empty result is the case worth pinning: a pane that shares nothing with the
/// other still gets a tab.
enum PaneTabMirror {
    static func landing(for relativePath: String, exists: (String) -> Bool) -> String {
        var walked: [String] = []
        for component in relativePath.split(separator: "/") {
            let candidate = (walked + [String(component)]).joined(separator: "/")
            guard exists(candidate) else { break }
            walked.append(String(component))
        }
        return walked.joined(separator: "/")
    }
}


/// Keeps each pane's column stack honest about the tree it is standing in.
///
/// Not a tabs concern; it lives beside `BrowseTabPersistence` for the reason that modifier gives:
/// `ContentView.body` is at the type-checker's budget, and these `onChange`s inline push it over
/// ("unable to type-check this expression in reasonable time"). One modifier, type-checked on its
/// own.
///
/// Two triggers, and the second is not belt-and-braces:
///
/// - Every republish. A republish can delete a folder a stack stands in, externally or by the
///   user's own Delete, and without this the columns render nothing while `currentDirectory`
///   still names the dead folder, where New Folder and paste would then act.
/// - Every pane settling. `pruneBrowsePath` refuses while a tree is loading, because progressive
///   loading publishes a shallow root-children-only tree first and pruning against that cuts a
///   valid stack to its first component. But the deep tree is published before
///   `await applyFilters()` and the loading flag is cleared after it, so the update carrying the
///   final tree can arrive while the flag is still up: the republish trigger skips, and nothing
///   re-fires it. The falling edge closes that without depending on which side of an `await` a
///   SwiftUI update lands.
///
/// Both skip a pane with nothing to prune, since building the children index is a whole-tree walk;
/// `canAdvance` counts because a pane resting at its root can still hold a `›` stack pointing into
/// a folder just deleted.
struct ColumnStackPruning: ViewModifier {
    @ObservedObject var syncManager: FileSyncManager
    let leftTreeRoot: String
    let rightTreeRoot: String

    /// All three values narrowed through the one door, never by ternaries. Transposed, they would
    /// prune the left pane's column stack against the right pane's children index and tree root:
    /// in Compare the left stack would collapse to the deepest prefix the right side has, with
    /// nothing on screen to explain it, and no test would notice.
    ///
    /// The index is built lazily by `PaneSideChoice.own`'s `@autoclosure`, which matters: each of
    /// these calls is a whole-tree walk, and an eager `own` would run both on every prune.
    private func prune(isLeft: Bool) {
        let stack = PaneSideChoice.own(isLeft, left: syncManager.leftBrowsePath,
                                       right: syncManager.rightBrowsePath)
        guard !stack.isEmpty || stack.canAdvance else { return }
        let root = PaneSideChoice.own(isLeft, left: leftTreeRoot, right: rightTreeRoot)
        let index = PaneSideChoice.own(isLeft,
                                       left: syncManager.leftChildrenIndex(treeRoot: root),
                                       right: syncManager.rightChildrenIndex(treeRoot: root))
        syncManager.pruneBrowsePath(isLeft: isLeft, against: index, treeRoot: root)
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: syncManager.leftPaneTree) { _, _ in prune(isLeft: true) }
            .onChange(of: syncManager.rightPaneTree) { _, _ in prune(isLeft: false) }
            .onChange(of: syncManager.isLoadingLeftTree) { _, isLoading in
                guard !isLoading else { return }
                prune(isLeft: true)
            }
            .onChange(of: syncManager.isLoadingRightTree) { _, isLoading in
                guard !isLoading else { return }
                prune(isLeft: false)
            }
    }
}


/// How much of the tab strip the seam controls take.
///
/// ⇄ and 🔗 are drawn on top of this row. `SeamPaneControls` is an overlay on the panes region
/// pinned 8pt from its top, straddling the pane boundary, exactly where a strip's trailing ＋ (left
/// pane) and leading chip (right pane) sit; unreserved, the left pane's ＋ lands about five points
/// from ⇄, near enough to read as one control.
///
/// A named rule because it can be wrong in two directions and only one is visible: too little and
/// the controls overlap, too much and Browse, which has no seam, loses track it should keep.
/// `PaneTabWiringTests` pins both.
enum PaneTabSeam {
    /// The seam capsule is two 26pt halves offset 13pt back from the boundary, so it reaches 13pt
    /// into each pane; 26 gives the strip's own gap on top of that.
    static let reserve: CGFloat = 26

    /// The inset for one edge of one pane's strip. Zero everywhere but the two edges that touch a
    /// seam, which exists only in Compare.
    static func inset(isCompare: Bool, isLeft: Bool, leading: Bool) -> CGFloat {
        guard isCompare else { return 0 }
        // The left pane gives up its trailing edge, the right pane its leading one.
        return leading == isLeft ? 0 : reserve
    }
}


/// What a pane's tab strip renders, as a rule.
///
/// Out of `ContentView` so it can be tested, and because it holds the one thing about the strip
/// that is easy to get subtly wrong: **the active chip reads the live pane, and every other chip
/// reads its own parked snapshot.** The list's active entry is a snapshot from when that tab was
/// last parked (see `PaneTab`), so a chip drawn from it would keep naming the folder you arrived in
/// while the pane walks on: right on arrival, wrong a click later.
enum PaneTabChips {
    /// What the host knows about one source. `nil` for a source that is no longer available.
    struct Source: Equatable {
        let displayName: String
        let markImageName: String
        /// As stored, possibly with a tilde. Expanded here, never at the call site.
        let root: String
    }

    /// `drawsColumns` is the pane's presentation, and it governs the parked chips as much as the
    /// live one. Presentation belongs to the pane, not a tab, so every tab in the strip is drawn the
    /// same way, and a parked chip titled from a column stack a Tree pane can't draw would promise a
    /// folder that selecting it doesn't deliver: it would rename itself on click, and its tooltip
    /// would point at a folder the pane never shows. A tab's stored location keeps both halves
    /// (see `openTabHere`); this resolves only what the strip says about it.
    static func items(_ list: PaneTabList,
                      liveProviderId: String,
                      livePath: String,
                      drawsColumns: Bool,
                      source: (String) -> Source?) -> [PaneTabStrip.Item] {
        let drafts = list.tabs.enumerated().map { index, tab -> Draft in
            let isActive = index == list.selectedIndex
            let providerId = isActive ? liveProviderId : tab.providerId
            let parkedPath = drawsColumns ? tab.combinedRelativePath : tab.relativePath
            let path = isActive ? livePath : parkedPath
            let resolved = source(providerId)
            // A tab at a source root has no folder to name, so it wears the source's name, or the
            // raw id if even that is gone, which at least says which source it meant.
            let name = path.isEmpty ? (resolved?.displayName ?? providerId)
                                    : (path as NSString).lastPathComponent
            return Draft(id: tab.id, title: name, providerId: providerId, path: path,
                         sourceName: resolved?.displayName,
                         // A source with no bundled mark wears a folder, which is what
                         // `ProviderLogo` draws for a folder source anyway.
                         markImageName: resolved?.markImageName ?? "folder.fill",
                         isActive: isActive,
                         fullPath: PaneLogic.fullPath(root: resolved?.root ?? "", relativePath: path),
                         isPinned: tab.isPinned)
        }
        let titles = disambiguatedTitles(drafts)
        return zip(drafts, titles).map { draft, title in
            PaneTabStrip.Item(id: draft.id, title: title, markImageName: draft.markImageName,
                              isActive: draft.isActive, fullPath: draft.fullPath,
                              isPinned: draft.isPinned, sourceName: draft.sourceName)
        }
    }

    /// One chip, before its title has been checked against the others.
    struct Draft {
        let id: UUID
        let title: String
        let providerId: String
        let path: String
        let sourceName: String?
        let markImageName: String
        let isActive: Bool
        let fullPath: String
        let isPinned: Bool
    }

    /// Titles, with colliding ones qualified until they separate.
    ///
    /// A tab's title is its folder's leaf name, and leaf names collide constantly: two Google Drive
    /// accounts both land on `My Drive`, iCloud and OneDrive both hold a `Documents`. The source mark
    /// (`Item.markImageName`) separates only chips whose sources wear different marks, and the
    /// commonest collision is two accounts of one brand, which wear the same one.
    ///
    /// Qualified only where it separates, never as a rule. The common strip has no collision and must
    /// be untouched: a chip that grew "— iCloud" for no reason spends the strip's scarcest resource
    /// (width; the ladder folds chips away when it runs out) on what the mark already said.
    ///
    /// Two qualifiers, tried in order, because a collision has two causes:
    /// - Different sources, the ordinary case: the source's display name, the string the sidebar
    ///   and the breadcrumb's source chip use, so the three surfaces name a source the same way.
    /// - One source, two folders sharing a leaf name (`2026/Statements` and `2025/Statements`): the
    ///   parent folder, the smallest thing that tells them apart.
    ///
    /// Neither is applied when it fails to separate: two chips on one source at one path are a
    /// duplicated tab, really the same folder, and an identical suffix on both would say nothing.
    ///
    /// An em dash rather than a parenthesis because the chip middle-truncates: the tail survives, so
    /// `My Drive — Google Drive (EMP)` degrades to something still carrying the account, while a
    /// leading qualifier would be the half that got eaten.
    static func disambiguatedTitles(_ drafts: [Draft]) -> [String] {
        var titles = drafts.map(\.title)
        var groups: [String: [Int]] = [:]
        for (index, draft) in drafts.enumerated() { groups[draft.title, default: []].append(index) }

        for (_, indices) in groups where indices.count > 1 {
            // Source name first, parent folder second. `separates` is what keeps an untouched strip
            // untouched and stops a duplicated tab from growing two identical suffixes.
            let candidates: [[String?]] = [
                indices.map { drafts[$0].sourceName },
                indices.map { Self.parentName(of: drafts[$0].path) },
            ]
            guard let qualifiers = candidates.first(where: { Set($0.map { $0 ?? "" }).count > 1 })
            else { continue }
            for (index, qualifier) in zip(indices, qualifiers) {
                guard let qualifier, !qualifier.isEmpty, qualifier != drafts[index].title else { continue }
                titles[index] = "\(drafts[index].title) — \(qualifier)"
            }
        }
        return titles
    }

    /// The folder above `path`'s leaf, or nil when there is none (a leaf at the source root).
    private static func parentName(of path: String) -> String? {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? nil : (parent as NSString).lastPathComponent
    }
}

/// Whether a tab switch also changes the pane's source.
///
/// A rule rather than an `if` at the call site because the middle case is invisible: a tab whose
/// source has gone since it was opened must not have its folder rendered under whatever source
/// the pane is showing, and nothing on screen would say that happened.
///
/// "Gone" is `paneCanShowSource`'s reading: **a source switched off in Settings is gone here**,
/// because no refresh will walk a pane pointed at one. The discovered list would report `.adopt`
/// for exactly those, landing the invisible case in the branch that says nothing.
enum PaneTabProviderSwitch: Equatable {
    /// The pane is already on this tab's source.
    case keep
    /// Write the id, and suppress the reset its `onChange` would otherwise run.
    case adopt(String)
    /// The tab names a source this pane cannot be pointed at. Stay put, and say so.
    case unavailable(String)

    static func decide(arrived: String, current: String, isAvailable: (String) -> Bool) -> PaneTabProviderSwitch {
        guard arrived != current else { return .keep }
        return isAvailable(arrived) ? .adopt(arrived) : .unavailable(arrived)
    }
}

/// What a pane-provider `onChange` should do with a change it has just been handed. Out of the two
/// handlers in `ContentView` because the order of their three tests is the whole rule, and inline
/// in a view body nothing could hold it.
///
/// **A suppression counter is consumed before the bootstrap guard is tested.** A counter is armed
/// only by a writer that has already done the handler's work (`swapPanesAction`,
/// `adoptProviderForTab`), so it must be balanced wherever its write lands, which the writer
/// doesn't control. SwiftUI evaluates `onChange` on the next view update, so a write made in the
/// bootstrap's final synchronous moments arrives after `isBootstrappingProviders` is lowered.
/// Testing the guard first would fail both ways: a bootstrap-time write would strand its counter
/// (swallowing the user's next real switch), and the launch tab restore's write would run the full
/// user-switch path, whose re-home wipes the strip the restore just put back.
///
/// **What this does not give you.** Both counters are single integers read by both handlers, and
/// this rule takes no side, so what is guaranteed is a total (every armed unit consumed by some
/// handler exactly once), not a pairing. If a left and a right write land in one update with only
/// one armed, whichever handler runs first takes the unit. That is harmless only while both
/// consuming cases simply `return`: `.consumeSwap` and `.consumeTab` must never do different work.
///
/// **One unarmed bootstrap writer remains:** `applyProviderSelection` writes both ids bare and
/// relies on the `await` after it to give SwiftUI an update while the guard is still up. That is an
/// empirical ordering, not a structural one; this rule protects only writes that arm a counter.
enum PaneProviderChange: Equatable {
    /// A pane swap flipped the id; it swapped the navigation atomically too.
    case consumeSwap
    /// A tab switch flipped the id; the tab carries the navigation.
    case consumeTab
    /// Providers are still being discovered and nobody armed anything: nothing to do.
    case ignore
    /// The user picked a source from the menu: the full reset.
    case userSwitch

    static func decide(swapPending: Int, tabPending: Int, isBootstrapping: Bool) -> PaneProviderChange {
        if swapPending > 0 { return .consumeSwap }
        if tabPending > 0 { return .consumeTab }
        return isBootstrapping ? .ignore : .userSwitch
    }
}

/// The two things `isLeft` decides, on a type a test can call.
///
/// Written as a ternary at each site, the polarity would be invisible: `ContentView` is a `View`
/// with `@State`, so no test can instantiate it, and a source scan for `!isLeft` can't see a
/// transposed ternary. Two such flips the app suite would not catch:
///
/// - `current: isLeft ? rightProviderId : leftProviderId` inside `tabAction`. A cross-source chip
///   click would ask `PaneTabProviderSwitch.decide` about the sibling's source, answer `.keep`,
///   render the tab's path under the wrong root, and `saveBrowseTabs` would persist the tab under a
///   source it never named. A chip on the pane's own source would answer a spurious `.adopt`,
///   tearing down a duplicate review, re-keying `IgnoredItemsStore` and clearing the lens.
/// - `isLeft ? "right" : "left"` in a log line: every tab line in `~/sync-cloud.log` naming the
///   wrong pane, in the file whose job is to say which pane a verb was aimed at.
///
/// Free functions on a type that needs nothing to exist, so `theSideChoiceReadsItsArgument` drives
/// the polarity for real. `PaneSideChoice.name` has one caller outside this file:
/// `DuplicateReviewCoordinator`'s stranded-pin warning, which names a pane for the same reason.
///
/// What this cannot see is the arguments: `own(isLeft, left: rightProviderId, right: leftProviderId)`
/// is a swap the callee can't know about, so the three `pane…(isLeft:)` wrappers keep it to one
/// call per pair. `everyPaneSideChoiceCallNarrowsAMatchedPair` scans the whole app target: every
/// `left:` must name a left-ish expression, every `right:` a right-ish one, and the two must be
/// halves of the same pair, which a per-argument check can't see because each argument contains
/// its own side's word. Being a scan is why the number of sites it covers has to stay small.
enum PaneSideChoice {
    /// This pane's own value out of the view's pair.
    ///
    /// `@autoclosure`, so only the chosen side is evaluated. One pair, `ColumnStackPruning`'s
    /// children index, is a whole-tree walk per side, and an eager parameter would double that cost
    /// on every prune.
    static func own<T>(_ isLeft: Bool, left: @autoclosure () -> T, right: @autoclosure () -> T) -> T {
        isLeft ? left() : right()
    }

    /// The other pane: the one flip, so a reach for the sibling is never spelled out by hand.
    ///
    /// A dropped `!` in `mirrorOpenInNewTab` would open both halves of an ⌥/linked Open in New Tab
    /// on the aimed pane and none on the sibling, unseen by any test, because a `!` in a
    /// `ContentView` extension is a spelling no test can drive. Here it is one character in one
    /// place `theSideChoiceReadsItsArgument` calls, and
    /// `everyReachForTheSiblingPaneGoesThroughTheOneFlip` bans the hand-written form from the tabs
    /// file.
    static func sibling(_ isLeft: Bool) -> Bool { !isLeft }

    /// How this pane is named in `~/sync-cloud.log`. Every tab line carries it: in Compare a line
    /// that does not say which pane it happened in is true of any tab in either strip.
    static func name(_ isLeft: Bool) -> String { isLeft ? "left" : "right" }
}

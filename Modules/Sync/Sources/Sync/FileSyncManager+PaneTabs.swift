import Foundation

/// The verbs that move a pane between tabs, and the rule under them: capture the live pane into
/// the outgoing tab, then apply the incoming tab over the pane.
///
/// All about one pane's state. The provider id is the host's `@AppStorage`, so each verb returns
/// the tab it arrived at, and the host writes the id (suppressing a provider switch's reset) and
/// drives the one reload.
extension FileSyncManager {

    /// This pane's list.
    public func paneTabs(isLeft: Bool) -> PaneTabList {
        isLeft ? leftPaneTabs : rightPaneTabs
    }

    /// The pane's live position, as the value a tab holds. `providerId` comes from the host for the
    /// reason above; so does the search field, through `paneSearchSnapshot`.
    @MainActor public func captureTab(isLeft: Bool, providerId: String) -> PaneTab {
        let search = paneSearchSnapshot?(isLeft) ?? (query: "", isExpanded: false)
        return PaneTab(id: paneTabs(isLeft: isLeft).active.id,
                       providerId: providerId,
                       relativePath: isLeft ? leftRelativePath : rightRelativePath,
                       browsePath: isLeft ? leftBrowsePath : rightBrowsePath,
                       history: isLeft ? leftHistory : rightHistory,
                       selection: isLeft ? selectedLeftPaths : selectedRightPaths,
                       searchQuery: search.query,
                       searchIsExpanded: search.isExpanded,
                       typeFilter: isLeft ? leftTypeFilter : rightTypeFilter)
    }

    /// Writes a parked tab over the pane. **Does not reload: the caller owns that.**
    ///
    /// When the tab is somewhere else, the comparison goes first: it answers the folder pair this
    /// pane is leaving. Like `retargetPane`'s opening, but restoring the navigation, not
    /// resetting it.
    ///
    /// The caller reloads, not `refreshSubject`: a tab can carry a different provider, whose id the
    /// host writes after this returns, and the subject fires synchronously, so ringing it here
    /// would load the new tab's path under the old root. The host writes the id, then reloads once
    /// (`ContentView.tabAction`).
    /// - Parameter currentProviderId: the source the pane is on now. Only the host knows it.
    @MainActor public func applyTab(_ tab: PaneTab, isLeft: Bool, currentProviderId: String) {
        // Drop nothing unless the arriving tab is somewhere else, and then only what is stale:
        // 1. Anything at all? A switch that changes neither root nor focus leaves tree and
        //    comparison correct. Dropping them would re-walk and rescan for nothing, and the
        //    reload's empty publish would flatten the column stack just restored.
        // 2. Which tree? Only this pane's; the other pane's didn't move.
        // 3. The prefetch cache? Kept within one source, so the tab paints from memory. Dropped
        //    when the source changes, for memory (whole walked trees, one per visited source),
        //    except the other pane's walk, which is what it shows and what the scan reads.
        // `PaneTabArrival` is the shared rule for (1). The host asks it too, to decide on the
        // scan; if the two disagree, a pane is invalidated and never reloaded.
        if PaneTabArrival.needsReload(arrivingAt: tab,
                                      fromProvider: currentProviderId,
                                      fromFocus: isLeft ? leftRelativePath : rightRelativePath) {
            if tab.providerId != currentProviderId {
                dropPrefetchedTrees(keeping: isLeft ? lastLoadedRightFocusPath : lastLoadedLeftFocusPath)
            }
            invalidatePaneTree(isLeft: isLeft)
            invalidateDifferencesForPaneRetarget()
            clearSessionIgnoredPaths()
        }

        // One pane holds a selection at a time; ⌘⌫ and the copy arrows rely on it. A non-empty
        // arriving selection clears the sibling's. An empty one leaves the sibling's alone: the
        // rule already holds, and clearing would discard a selection the switch never touched.
        if !tab.selection.isEmpty {
            if isLeft { selectedRightPaths = [] } else { selectedLeftPaths = [] }
        }

        if isLeft {
            leftHistory = tab.history
            leftBrowsePath = tab.browsePath
            selectedLeftPaths = tab.selection
            leftTypeFilter = tab.typeFilter
            // From the tab's history rather than its `relativePath` (the same value by
            // construction), which keeps Back working in the tab that arrives.
            if leftRelativePath != tab.history.current { leftRelativePath = tab.history.current }
        } else {
            rightHistory = tab.history
            rightBrowsePath = tab.browsePath
            selectedRightPaths = tab.selection
            rightTypeFilter = tab.typeFilter
            if rightRelativePath != tab.history.current { rightRelativePath = tab.history.current }
        }
    }

    // MARK: - The verbs

    /// Selects an existing tab. Returns the tab now live, or `nil` when the id is already active or
    /// unknown: nothing happened, so the host does no reload.
    @MainActor public func switchTab(to id: UUID, isLeft: Bool, currentProviderId: String) -> PaneTab? {
        var list = paneTabs(isLeft: isLeft)
        guard let target = list.index(of: id), target != list.selectedIndex else { return nil }
        list.captureActive(captureTab(isLeft: isLeft, providerId: currentProviderId))
        list.select(index: target)
        setPaneTabs(list, isLeft: isLeft)
        let tab = list.active
        applyTab(tab, isLeft: isLeft, currentProviderId: currentProviderId)
        return tab
    }

    /// ⇧⌘] / ⇧⌘[ / ⌃⇥ in Browse. Same contract as `switchTab(to:)`.
    @MainActor public func cycleTab(forward: Bool, isLeft: Bool, currentProviderId: String) -> PaneTab? {
        var list = paneTabs(isLeft: isLeft)
        guard list.count > 1 else { return nil }
        list.captureActive(captureTab(isLeft: isLeft, providerId: currentProviderId))
        if forward { list.selectNext() } else { list.selectPrevious() }
        setPaneTabs(list, isLeft: isLeft)
        let tab = list.active
        applyTab(tab, isLeft: isLeft, currentProviderId: currentProviderId)
        return tab
    }

    /// ⌘T and Open in New Tab. Opens `tab` at the trailing end and makes it live.
    @MainActor public func openTab(_ tab: PaneTab, isLeft: Bool, currentProviderId: String) -> PaneTab {
        var list = paneTabs(isLeft: isLeft)
        list.captureActive(captureTab(isLeft: isLeft, providerId: currentProviderId))
        list.open(tab)
        setPaneTabs(list, isLeft: isLeft)
        applyTab(tab, isLeft: isLeft, currentProviderId: currentProviderId)
        return tab
    }

    /// Opens `tabs` at the trailing end and leaves the live tab live
    /// (``PaneTabList/openInBackground(_:)``). Nothing is applied, since the pane didn't change;
    /// the live tab is captured first so the strip's snapshot isn't stale.
    @MainActor public func openTabsInBackground(_ tabs: [PaneTab], isLeft: Bool, currentProviderId: String) {
        guard !tabs.isEmpty else { return }
        var list = paneTabs(isLeft: isLeft)
        list.captureActive(captureTab(isLeft: isLeft, providerId: currentProviderId))
        for tab in tabs { list.openInBackground(tab) }
        setPaneTabs(list, isLeft: isLeft)
    }

    /// Closes a tab. Returns the tab now live when the pane moved, `nil` when it didn't: closing a
    /// parked tab, or refusing to close the last. The caller tells them apart by
    /// `paneTabs(isLeft:).count`.
    @MainActor public func closeTab(id: UUID, isLeft: Bool, currentProviderId: String) -> PaneTab? {
        var list = paneTabs(isLeft: isLeft)
        guard let index = list.index(of: id), list.count > 1 else { return nil }
        let wasActive = index == list.selectedIndex
        // Capture before removing: closing a tab left of the active one shifts the index, and a
        // later capture would write the pane into whichever tab slid into that slot.
        list.captureActive(captureTab(isLeft: isLeft, providerId: currentProviderId))
        list.close(at: index)
        setPaneTabs(list, isLeft: isLeft)
        guard wasActive else { return nil }
        let tab = list.active
        applyTab(tab, isLeft: isLeft, currentProviderId: currentProviderId)
        return tab
    }

    /// ⌥-click on a ✕, and Close Other Tabs. Always leaves `id` live.
    @MainActor public func closeOtherTabs(keeping id: UUID, isLeft: Bool, currentProviderId: String) -> PaneTab? {
        var list = paneTabs(isLeft: isLeft)
        guard list.count > 1, list.index(of: id) != nil else { return nil }
        let wasActive = list.active.id == id
        list.captureActive(captureTab(isLeft: isLeft, providerId: currentProviderId))
        list.closeOthers(keeping: id)
        setPaneTabs(list, isLeft: isLeft)
        guard !wasActive else { return nil }
        let tab = list.active
        applyTab(tab, isLeft: isLeft, currentProviderId: currentProviderId)
        return tab
    }

    /// Duplicate, from the tab's own context menu.
    @MainActor public func duplicateTab(id: UUID, isLeft: Bool, currentProviderId: String) -> PaneTab? {
        var list = paneTabs(isLeft: isLeft)
        guard list.index(of: id) != nil else { return nil }
        list.captureActive(captureTab(isLeft: isLeft, providerId: currentProviderId))
        list.duplicate(id: id)
        setPaneTabs(list, isLeft: isLeft)
        let tab = list.active
        applyTab(tab, isLeft: isLeft, currentProviderId: currentProviderId)
        return tab
    }

    /// File ▸ Reopen Closed Tab. `nil` when nothing has been closed this session.
    @MainActor public func reopenClosedTab(isLeft: Bool, currentProviderId: String) -> PaneTab? {
        var list = paneTabs(isLeft: isLeft)
        guard list.canReopen else { return nil }
        list.captureActive(captureTab(isLeft: isLeft, providerId: currentProviderId))
        guard let tab = list.reopenLastClosed() else { return nil }
        setPaneTabs(list, isLeft: isLeft)
        applyTab(tab, isLeft: isLeft, currentProviderId: currentProviderId)
        return tab
    }

    /// Drag-to-reorder from the strip. No capture and no apply: the pane doesn't move, so this verb
    /// returns nothing.
    @MainActor public func moveTab(id: UUID, to index: Int, isLeft: Bool) {
        var list = paneTabs(isLeft: isLeft)
        guard let from = list.index(of: id) else { return }
        list.move(from: from, to: index)
        setPaneTabs(list, isLeft: isLeft)
    }

    /// Pin / unpin, from a tab's context menu. No capture and no apply, like `moveTab`: only the
    /// order and the chip's own state change.
    @MainActor public func setTabPinned(_ pinned: Bool, id: UUID, isLeft: Bool) {
        var list = paneTabs(isLeft: isLeft)
        guard list.index(of: id) != nil else { return }
        if pinned { list.pin(id: id) } else { list.unpin(id: id) }
        setPaneTabs(list, isLeft: isLeft)
    }

    /// Discards a tab whose source was removed since it was opened, and leaves the pane on one that
    /// can be shown. Returns the tab now live.
    ///
    /// Not just a warning: the verbs apply a tab before the host can rule on its source (only the
    /// host knows what is installed), so by then the pane shows that tab's path under the live
    /// source's root, usually an empty folder, and the next click would repeat it. Launch applies
    /// the same rule (`PaneTabsStore.restore` drops unknown providers).
    ///
    /// The last tab isn't closed, since a pane always holds one; it is rebuilt at the root of
    /// `currentProviderId`, the one location certain to exist. `nil` for an id this pane doesn't
    /// hold, leaving the strip as it was: an unknown id must never replace the user's tabs.
    ///
    /// A discard is not a close, in either branch: the tab doesn't go on the reopen stack, or
    /// Reopen Closed Tab would cycle on a tab that can't come back (`PaneTabList.discard(at:)`),
    /// and the tabs the user closed by hand survive the rebuild.
    @MainActor public func discardTab(id: UUID, isLeft: Bool, currentProviderId: String) -> PaneTab? {
        var list = paneTabs(isLeft: isLeft)
        guard let index = list.index(of: id) else { return nil }
        if list.count > 1 {
            list.discard(at: index)
        } else {
            list = PaneTabList(tabs: [PaneTab(providerId: currentProviderId)],
                               recentlyClosed: list.recentlyClosed)
        }
        setPaneTabs(list, isLeft: isLeft)
        let tab = list.active
        applyTab(tab, isLeft: isLeft, currentProviderId: currentProviderId)
        return tab
    }

    /// What discarding a dead tab cost, and where it left the pane.
    public struct TabDiscardOutcome: Sendable {
        /// The source ids of the tabs dropped, in order, for the host's log.
        public let discarded: [String]
        /// The tab the pane is on now. `nil` only when there was nothing to discard.
        public let landed: PaneTab?
    }

    /// Discards `id` and every tab the pane falls back onto whose source is also gone, landing it
    /// on one that can be shown. A loop, because the fallback neighbour is often on the same
    /// removed source, and landing there shows an empty folder.
    ///
    /// Terminates by construction (the bound is a backstop): each pass removes a tab, and removing
    /// the last rebuilds one on `currentProviderId`, which the caller keeps available.
    /// `isAvailable` is injected because only the host knows which sources exist.
    @MainActor public func discardDeadTabs(startingAt id: UUID, isLeft: Bool,
                                           currentProviderId: String,
                                           isAvailable: (String) -> Bool) -> TabDiscardOutcome {
        var discarded: [String] = []
        var landed: PaneTab?
        var dead = id
        for _ in 0..<max(1, paneTabs(isLeft: isLeft).count) {
            // Read before the discard: afterwards only the landed tab's source is left to name.
            let going = paneTabs(isLeft: isLeft).tabs.first { $0.id == dead }?.providerId
            guard let next = discardTab(id: dead, isLeft: isLeft,
                                        currentProviderId: currentProviderId) else { break }
            if let going { discarded.append(going) }
            landed = next
            if isAvailable(next.providerId) { break }
            dead = next.id
        }
        return TabDiscardOutcome(discarded: discarded, landed: landed)
    }

    /// Replaces a pane's list outright: the launch seed, and the only write outside the verbs
    /// above.
    @MainActor public func setPaneTabs(_ list: PaneTabList, isLeft: Bool) {
        if isLeft {
            if leftPaneTabs != list { leftPaneTabs = list }
        } else {
            if rightPaneTabs != list { rightPaneTabs = list }
        }
    }
}

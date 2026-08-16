import Foundation

/// The four verbs that move a pane between tabs, and the one rule underneath them: **capture the
/// live pane into the outgoing tab, then apply the incoming tab over the pane.**
///
/// Everything here is deliberately about *one* pane's state. What a switch cannot do from in here
/// is change the provider — `leftProviderId` is the host's `@AppStorage`, not the manager's — so
/// each verb reports the tab it arrived at and the host writes the id (suppressing the reset that
/// a hand-made provider switch would otherwise run) and drives the one reload. That split is why
/// `switchTab` returns the applied tab rather than swallowing it.
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
                       searchIsExpanded: search.isExpanded)
    }

    /// Writes a parked tab over the pane. **Does not reload — the caller owns that.**
    ///
    /// The comparison goes first: the differences and the verification results were built for the
    /// folder pair this pane is leaving, and a tab switch that left them on screen would show one
    /// pane's new contents against the other pane's answer to the old question. This is
    /// `resetNavigation`'s opening, minus the part that resets the navigation — here the navigation
    /// is precisely what is being restored. **The trees are the conditional half**; see below.
    ///
    /// **Why the refresh is the caller's and not `refreshSubject`'s.** A tab can carry a different
    /// provider, and the id lives in the host's `@AppStorage` — written *after* this returns. The
    /// subject is delivered synchronously, so ringing it here starts a load of the new tab's PATH
    /// under the old tab's ROOT: a walk of a folder that usually does not exist there, superseded a
    /// beat later by the real one. Harmless in the end and wrong in the middle, which is the kind of
    /// thing that shows up once as a flash of the wrong tree. The host writes the id, then reloads
    /// once — `ContentView.tabAction`.
    /// - Parameter currentProviderId: the source the pane is on *now*. The caller knows; the manager
    ///   cannot, because the id is the host's `@AppStorage`.
    @MainActor public func applyTab(_ tab: PaneTab, isLeft: Bool, currentProviderId: String) {
        // **Nothing is dropped unless the arriving tab is somewhere else, and then only what is
        // actually stale.** Three separate questions, and answering them all with one blanket clear
        // is what produced three user-visible bugs in a row.
        //
        // 1. *Does anything need dropping at all?* A tree walks one root at one focus and the
        //    comparison is about one pair of focused folders, so a switch that changes neither
        //    leaves both correct. Dropping them cost a full re-walk to rebuild something identical
        //    plus a scan nobody asked for — and the reload republished the tree empty-then-shallow,
        //    straight into the republish prune that flattens the column stack this method has just
        //    restored. Refreshing is the button's job; a tab switch is navigation, and navigation
        //    here has never rescanned.
        // 2. *Which pane's tree?* Only the one that moved. A comparison is symmetric; a tree is
        //    not. Dropping both re-adopted the still pane's tree for nothing — 15–36ms of every
        //    switch, measured on a real strip.
        // 3. *And the fast-path cache?* Kept inside one source, so the arriving tab paints from
        //    memory rather than from a disk walk. Dropped when the SOURCE changes, and for memory
        //    rather than staleness: its entries are keyed by absolute path and stay true, but they
        //    are whole walked trees — this app's iCloud root measures 39,399 nodes — so never
        //    dropping them accumulates one per visited source for the session.
        //
        // `PaneTabArrival` is the shared rule for (1); the host asks it the same question to decide
        // whether to run the scan, and the two must agree or a pane ends up invalidated and never
        // reloaded.
        if PaneTabArrival.needsReload(arrivingAt: tab,
                                      fromProvider: currentProviderId,
                                      fromFocus: isLeft ? leftRelativePath : rightRelativePath) {
            if tab.providerId != currentProviderId { prefetchedTrees.removeAll() }
            invalidatePaneTree(isLeft: isLeft)
            invalidateDifferencesForPaneRetarget()
            clearSessionIgnoredPaths()
        }

        if isLeft {
            leftHistory = tab.history
            leftBrowsePath = tab.browsePath
            selectedLeftPaths = tab.selection
            // From the tab's own history rather than its `relativePath`, which is the same value by
            // construction — every initializer seeds the history from the path, and a capture takes
            // both off a pane `syncPathsFromHistory` has already put in step. Taking it from the
            // history is what keeps Back working in the tab that arrives.
            if leftRelativePath != tab.history.current { leftRelativePath = tab.history.current }
        } else {
            rightHistory = tab.history
            rightBrowsePath = tab.browsePath
            selectedRightPaths = tab.selection
            if rightRelativePath != tab.history.current { rightRelativePath = tab.history.current }
        }
    }

    // MARK: - The verbs

    /// Selects an existing tab. Returns the tab now live, or `nil` when the id is already active or
    /// unknown — `nil` means "nothing happened", so the host does no reload.
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

    /// ⌘T, ⌘-double-click and Open in New Tab. Opens `tab` at the trailing end and makes it live.
    @MainActor public func openTab(_ tab: PaneTab, isLeft: Bool, currentProviderId: String) -> PaneTab {
        var list = paneTabs(isLeft: isLeft)
        list.captureActive(captureTab(isLeft: isLeft, providerId: currentProviderId))
        list.open(tab)
        setPaneTabs(list, isLeft: isLeft)
        applyTab(tab, isLeft: isLeft, currentProviderId: currentProviderId)
        return tab
    }

    /// Closes a tab. Returns the tab now live when the pane moved, `nil` when it did not — which
    /// includes closing a *parked* tab (the strip changes, the pane does not) and the refusal on
    /// the last tab. The caller distinguishes the two through `paneTabs(isLeft:).count`.
    @MainActor public func closeTab(id: UUID, isLeft: Bool, currentProviderId: String) -> PaneTab? {
        var list = paneTabs(isLeft: isLeft)
        guard let index = list.index(of: id), list.count > 1 else { return nil }
        let wasActive = index == list.selectedIndex
        // Park the live pane before removing anything: closing a tab to the LEFT of the active one
        // shifts the active index, and a capture afterwards would write the pane's state into
        // whichever tab happened to slide into that slot.
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

    /// Drag-to-reorder from the strip. **No capture and no apply**: the pane does not move, so its
    /// live state is not involved at all — which is why this is the one verb that returns nothing.
    @MainActor public func moveTab(id: UUID, to index: Int, isLeft: Bool) {
        var list = paneTabs(isLeft: isLeft)
        guard let from = list.index(of: id) else { return }
        list.move(from: from, to: index)
        setPaneTabs(list, isLeft: isLeft)
    }

    /// Pin / unpin, from a tab's context menu. **No capture and no apply**, like `moveTab`: the
    /// pane does not move, only the order and the chip's own state.
    @MainActor public func setTabPinned(_ pinned: Bool, id: UUID, isLeft: Bool) {
        var list = paneTabs(isLeft: isLeft)
        guard list.index(of: id) != nil else { return }
        if pinned { list.pin(id: id) } else { list.unpin(id: id) }
        setPaneTabs(list, isLeft: isLeft)
    }

    /// Discards a tab that can no longer be shown — its source has been removed since it was opened
    /// — and leaves the pane on one that can. Returns the tab now live.
    ///
    /// **Why this exists rather than a warning.** The verbs apply a tab to the pane before the host
    /// can rule on its source, because the provider id is the host's `@AppStorage` and only the host
    /// knows what is still installed. By the time the host finds the source gone, the pane is
    /// already pointed at that tab's folder path *under the live source's root* — a path that
    /// usually exists nowhere, so the pane shows an empty folder while the log said it had stayed
    /// put. Leaving the chip in place also means the next click repeats it.
    ///
    /// Dropping the tab is the rule the feature already applies at launch: `PaneTabsStore.restore`
    /// discards entries whose provider is unknown. Doing it here too means a source removed
    /// mid-session cannot leave a tab behind that does not work.
    ///
    /// The last tab is not closed — a pane always holds one — so it is rebuilt on `currentProviderId`
    /// at its root, which is the one location certain to exist.
    ///
    /// **`nil` for an id this pane does not hold**, and the strip is left exactly as it was. That
    /// was one guard with the rebuild before: `if list.count > 1, list.index(of: id) != nil`, whose
    /// `else` therefore answered *two* questions with one destructive branch. The last-tab reading
    /// is the one it was written for; the other — a strip of five handed an unknown id — replaced
    /// all five tabs AND the reopen stack with a single fresh tab at the root. Nothing reaches it
    /// today (every verb returns a tab that is in the list), which is precisely why it is worth
    /// separating: an inert guard whose failure mode is "throw the user's tabs away" is not a guard.
    /// **A discard is not a close**, in either branch: the tab does not go on the reopen stack
    /// (`PaneTabList.discard(at:)` says what that cost), and the stack the user built by closing
    /// tabs by hand survives the rebuild. Recording it made Reopen Closed Tab cycle forever on a
    /// tab that could not come back; rebuilding with a fresh `PaneTabList` threw away every tab the
    /// user had genuinely closed, which the rebuild has no business touching — it is replacing the
    /// pane's *position*, not its session.
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
        /// The source ids of the tabs dropped, in the order they went — what the host logs.
        public let discarded: [String]
        /// The tab the pane is on now. `nil` only when there was nothing to discard.
        public let landed: PaneTab?
    }

    /// Discards `id` **and every tab the pane falls back onto whose source is also gone**, landing
    /// it on one that can actually be shown.
    ///
    /// A loop rather than a single discard, because the fallback is a neighbour and neighbours come
    /// from the same session: remove a source with two tabs open on it and discarding the first
    /// lands the pane on the second, which is just as dead. `applyTab` has by then pointed the pane
    /// at that tab's folder path under the LIVE source's root — a path that usually exists nowhere
    /// — so the pane shows an empty folder, which is the exact symptom a single discard was written
    /// to remove. It self-healed on the next click, one dead tab at a time.
    ///
    /// **Terminates by construction, and the bound is belt-and-braces on top of that.** Every pass
    /// removes a tab, and the pass that removes the last one rebuilds a single tab on
    /// `currentProviderId` — the pane's live source, which the caller only ever sets to one that is
    /// available — so the predicate is satisfied and the loop stops there.
    ///
    /// `isAvailable` is injected for `PaneTabsStore.restore`'s reason: which sources exist is the
    /// host's question, and the manager has never known the answer.
    @MainActor public func discardDeadTabs(startingAt id: UUID, isLeft: Bool,
                                           currentProviderId: String,
                                           isAvailable: (String) -> Bool) -> TabDiscardOutcome {
        var discarded: [String] = []
        var landed: PaneTab?
        var dead = id
        for _ in 0..<max(1, paneTabs(isLeft: isLeft).count) {
            // Read BEFORE the discard: afterwards the tab is off the list and the only source id
            // left to name is the one the pane landed ON, which is the wrong tab to log.
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

    /// Replaces a pane's list outright — the launch seed, and the only write that is not one of the
    /// verbs above.
    @MainActor public func setPaneTabs(_ list: PaneTabList, isLeft: Bool) {
        if isLeft {
            if leftPaneTabs != list { leftPaneTabs = list }
        } else {
            if rightPaneTabs != list { rightPaneTabs = list }
        }
    }
}

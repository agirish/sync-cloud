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
        // **Nothing is dropped for a move inside what the pane already has.**
        //
        // The trees walk one root at one focus and the comparison is about one pair of focused
        // folders, so a switch that changes neither leaves both correct — and dropping them costs
        // a full re-walk to rebuild something identical, plus a scan the user did not ask for.
        // That was the reported "switching tabs still refreshes and reloads"; the reload also
        // republishes the tree empty-then-shallow, straight into the republish prune that flattens
        // the column stack this method has just restored. Two visible bugs from one clear.
        //
        // Refreshing is the button's job. A tab switch is a navigation, and navigation here has
        // never rescanned: drilling through columns moves the same column stack this restores and
        // leaves the differences alone.
        //
        // When the source or the scope DOES change, everything goes — the trees walk the wrong
        // root, and the differences answer a question about a folder pair that is no longer on
        // screen. `PaneTabArrival` is the shared rule; the host asks it the same question to decide
        // whether to run the scan, and the two must agree or a pane ends up invalidated and never
        // reloaded.
        if PaneTabArrival.needsReload(arrivingAt: tab,
                                      fromProvider: currentProviderId,
                                      fromFocus: isLeft ? leftRelativePath : rightRelativePath) {
            invalidateComparisonState()
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

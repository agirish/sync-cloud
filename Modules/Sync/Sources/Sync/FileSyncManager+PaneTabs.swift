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
    /// reason above; nothing else does.
    @MainActor public func captureTab(isLeft: Bool, providerId: String) -> PaneTab {
        PaneTab(id: paneTabs(isLeft: isLeft).active.id,
                providerId: providerId,
                relativePath: isLeft ? leftRelativePath : rightRelativePath,
                browsePath: isLeft ? leftBrowsePath : rightBrowsePath,
                history: isLeft ? leftHistory : rightHistory,
                selection: isLeft ? selectedLeftPaths : selectedRightPaths,
                searchQuery: "",
                searchIsExpanded: false)
    }

    /// Writes a parked tab over the pane and asks for the reload it implies.
    ///
    /// The comparison state goes first and unconditionally: the trees, the differences and the
    /// verification results were built for the folder pair this pane is leaving, and a tab switch
    /// that left them on screen would show one pane's new contents against the other pane's answer
    /// to the old question. This is `resetNavigation`'s opening, minus the part that resets the
    /// navigation — here the navigation is precisely what is being restored.
    @MainActor public func applyTab(_ tab: PaneTab, isLeft: Bool) {
        invalidateComparisonState()
        clearSessionIgnoredPaths()

        if isLeft {
            leftHistory = tab.history
            leftBrowsePath = tab.browsePath
            selectedLeftPaths = tab.selection
        } else {
            rightHistory = tab.history
            rightBrowsePath = tab.browsePath
            selectedRightPaths = tab.selection
        }
        // Publishes the tab's path out of its own history and rings the refresh — the same door
        // `focusOn` and `goBack` leave through, so a tab switch reloads by exactly the route every
        // other navigation does.
        syncPathsFromHistory()
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
        applyTab(tab, isLeft: isLeft)
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
        applyTab(tab, isLeft: isLeft)
        return tab
    }

    /// ⌘T, ⌘-double-click and Open in New Tab. Opens `tab` at the trailing end and makes it live.
    @MainActor public func openTab(_ tab: PaneTab, isLeft: Bool, currentProviderId: String) -> PaneTab {
        var list = paneTabs(isLeft: isLeft)
        list.captureActive(captureTab(isLeft: isLeft, providerId: currentProviderId))
        list.open(tab)
        setPaneTabs(list, isLeft: isLeft)
        applyTab(tab, isLeft: isLeft)
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
        applyTab(tab, isLeft: isLeft)
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
        applyTab(tab, isLeft: isLeft)
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
        applyTab(tab, isLeft: isLeft)
        return tab
    }

    /// File ▸ Reopen Closed Tab. `nil` when nothing has been closed this session.
    @MainActor public func reopenClosedTab(isLeft: Bool, currentProviderId: String) -> PaneTab? {
        var list = paneTabs(isLeft: isLeft)
        guard list.canReopen else { return nil }
        list.captureActive(captureTab(isLeft: isLeft, providerId: currentProviderId))
        guard let tab = list.reopenLastClosed() else { return nil }
        setPaneTabs(list, isLeft: isLeft)
        applyTab(tab, isLeft: isLeft)
        return tab
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

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
/// `FileSyncManager+PaneTabs` owns the model and the capture/apply rule. Three things it cannot
/// own live here, and each is the reason this file exists rather than that one growing:
///
/// - **The provider id is `@AppStorage` on this view.** A tab switch that changes source has to
///   write it *and* suppress the `onChange` that would otherwise call `resetNavigation()` over the
///   navigation the switch has just restored — the same suppression `swapPanesAction` uses, on its
///   own counter so the two can never consume each other's.
/// - **The search field is this view's `@State`.** The manager reads it back through
///   `paneSearchSnapshot` when it parks a tab; applying it is done here, off the tab each verb
///   returns.
/// - **Persistence and the launch seed** need the provider list, the roots on disk, and
///   `UserDefaults` — none of which `Sync` reaches into.
///
/// Everything in here routes through `tabAction`, so there is exactly one place that knows the
/// order these have to happen in.
extension ContentView {

    // MARK: - What the strip renders

    /// This pane's chips, through `PaneTabChips` — the rule is over there so it can be tested;
    /// this half is only the lookup of who each tab's provider is.
    func paneTabItems(isLeft: Bool) -> [PaneTabStrip.Item] {
        PaneTabChips.items(
            syncManager.paneTabs(isLeft: isLeft),
            liveProviderId: isLeft ? leftProviderId : rightProviderId,
            livePath: syncManager.combinedRelativePath(isLeft: isLeft),
            // **The discovered list here, not `paneCanShowSource`'s**, and it is the one place that
            // divergence is right: this resolves a NAME and a mark, not whether the pane may go
            // there. A source switched off in Settings still has a folder and a display name, and
            // a chip reading "Dropbox" for the moment before the tab is discarded beats one reading
            // its raw id.
            source: { id in
                guard let provider = settings.availableProviders.first(where: { $0.id == id }) else { return nil }
                return PaneTabChips.Source(displayName: provider.displayName,
                                           markImageName: provider.imageName,
                                           root: provider.path)
            })
    }

    /// Whether this pane draws a strip at all — see `PaneTabStripVisibility` for the rule, which is
    /// not the plain "does this pane have two tabs" it started as.
    func paneShowsTabStrip(isLeft: Bool) -> Bool {
        PaneTabStripVisibility.shows(
            own: syncManager.paneTabs(isLeft: isLeft).showsStrip,
            sibling: syncManager.paneTabs(isLeft: !isLeft).showsStrip,
            isCompare: layoutMode == .compare,
            switchIsOn: tabBarVisible)
    }

    /// Track the tab strip gives up to the seam controls, which are drawn OVER this row.
    func seamInset(isLeft: Bool, leading: Bool) -> CGFloat {
        PaneTabSeam.inset(isCompare: layoutMode == .compare, isLeft: isLeft, leading: leading)
    }

    /// **Whether a pane may be pointed at this source at all — the one list every tab question
    /// asks, and it is `enabledProviders`.**
    ///
    /// This started as `availableProviders` in three places, which is the *discovered* list: it
    /// keeps a source the user has switched off in Settings, because a disabled provider's folder
    /// is still on disk and things like the ⌂ badge's coverage genuinely want it (see
    /// `homeBadgeCoverage`). Nothing that points a PANE wants it. `refreshAction` and
    /// `refreshForTabSwitch` both resolve their two providers out of `enabledProviders` and return
    /// without loading anything when either is missing, so a pane on a disabled source is a pane
    /// nothing will ever walk.
    ///
    /// The launch path was the sharp end. `restoreBrowseTabs` writes the restored tab's provider
    /// over the pane's id, and it ran *after* `applyProviderSelection` had resolved that id against
    /// the enabled list — so opening a tab on a source, switching that source off, and relaunching
    /// put the disabled id back and the bootstrap's `refreshAction()` then bailed: both panes up,
    /// empty, no scan, nothing said. Nothing re-resolved afterwards either, because
    /// `enabledProviders` had not changed and its `onChange` never fired. Mid-session the same
    /// mismatch made `decide` answer `.adopt` where it meant `.unavailable`, so clicking such a tab
    /// moved the pane onto a source no refresh would serve.
    ///
    /// One predicate, so the question cannot be asked two ways again. Chip RENDERING deliberately
    /// still reads `availableProviders` (`paneTabItems`): naming a disabled source is better than
    /// showing its raw id for the moment before the tab is discarded.
    var paneCanShowSource: (String) -> Bool {
        { id in settings.enabledProviders.contains { $0.id == id } }
    }

    // MARK: - The one door

    /// Runs a tab verb and settles everything that follows from it: the provider id, the search
    /// field, the reload, and the saved strip.
    ///
    /// `verb` returns the tab the pane arrived at, or `nil` when the pane did not move (closing a
    /// parked tab, selecting the tab already live). `nil` still saves — the strip changed even when
    /// the pane did not — and still costs no reload, which is the point of the distinction.
    private func tabAction(isLeft: Bool, _ verb: () -> PaneTab?) {
        // The bootstrap window is interactive, and a provider `onChange` bails on its own guard
        // there without decrementing the suppression counter — which would strand it and silently
        // swallow the user's next real source switch. `swapPanesAction` refuses for the same reason.
        guard !isBootstrappingProviders else { return }

        // Read BEFORE the verb runs, because the verb moves the pane: these two are what the
        // arriving tab is compared against to decide whether anything needs reloading at all.
        let fromProvider = isLeft ? leftProviderId : rightProviderId
        let fromFocus = isLeft ? syncManager.leftRelativePath : syncManager.rightRelativePath

        guard let arrived = verb() else {
            saveBrowseTabs(isLeft: isLeft)
            return
        }

        // The search field travels with the tab. Cleared to the incoming tab's own state, which for
        // a new tab is an empty, closed field.
        paneSearchState(isLeft: isLeft).wrappedValue = PaneSearchFieldState(
            query: arrived.searchQuery, isExpanded: arrived.searchIsExpanded)

        switch PaneTabProviderSwitch.decide(
            arrived: arrived.providerId,
            current: isLeft ? leftProviderId : rightProviderId,
            isAvailable: paneCanShowSource) {
        case .keep:
            break
        case .adopt(let id):
            // One suppressed change, then this method drives the single reload — exactly the shape
            // `swapPanesAction` uses, and on its OWN counter: two features sharing one would have a
            // swap eat a tab switch's suppression and reset the navigation it just restored.
            pendingTabProviderChanges += 1
            if isLeft { leftProviderId = id } else { rightProviderId = id }
        case .unavailable:
            // The tab names a source this pane can no longer be pointed at, so it cannot be shown
            // at all — and by now the verb has already pointed the pane at that tab's folder path
            // under the LIVE source's root, which is a path that usually exists nowhere. The tab
            // goes, and the pane lands on one that works. `discardTab` says what that means for the
            // last tab.
            //
            // This branch used to only warn, with a comment claiming the pane "stayed on its
            // current source" — true of the source and false of the folder, which is the half that
            // showed on screen as an empty pane.
            //
            // **Every dead tab behind it goes too**, which a single discard did not do: the
            // fallback is a neighbour, and two tabs opened on one source die together — so the pane
            // landed straight onto the second one and showed the same empty folder. See
            // `discardDeadTabs`.
            let outcome = syncManager.discardDeadTabs(
                startingAt: arrived.id, isLeft: isLeft,
                currentProviderId: isLeft ? leftProviderId : rightProviderId,
                isAvailable: paneCanShowSource)
            for gone in outcome.discarded {
                Logger.shared.warning("Discarded a browse tab: its source “\(gone)” is gone or switched off")
            }
            // Silent-on-impossible is exactly what the guard `discardTab` grew was about: the id
            // always is in the list (the verb that returned it put it there), so reaching here
            // means an assumption this branch rests on has stopped holding, and the log is the
            // only place that would ever say so.
            if outcome.discarded.isEmpty {
                Logger.shared.warning("A browse tab named an unusable source but could not be discarded")
            }
            if let landed = outcome.landed {
                paneSearchState(isLeft: isLeft).wrappedValue = PaneSearchFieldState(
                    query: landed.searchQuery, isExpanded: landed.searchIsExpanded)
            }
        }
        saveBrowseTabs(isLeft: isLeft)
        // **Only when the arriving tab is somewhere else.** The same rule `applyTab` used to decide
        // whether to drop anything, asked with the values captured above — the two have to agree, or
        // a pane ends up invalidated and never reloaded. A switch inside one source at one scope
        // reloads nothing and rescans nothing: it moves the column stack, the selection and the
        // history, none of which the trees or the differences are computed from. Refreshing is the
        // Refresh button's job.
        //
        // Asked of `arrived` rather than of whatever `.unavailable` landed on, and that is right by
        // construction rather than by luck: `decide` only reports `.unavailable` for a source that
        // DIFFERS from the pane's, so a discarded tab always answers yes here — which is what it
        // needs, since the verb that applied it had already dropped the trees.
        if PaneTabArrival.needsReload(arrivingAt: arrived, fromProvider: fromProvider, fromFocus: fromFocus) {
            refreshForTabSwitch(movedPane: isLeft)
        }
    }

    /// The reload a tab switch asks for, when it asks for one.
    ///
    /// A provider change writes `@AppStorage` a beat after `applyTab` returns, so this runs after
    /// that write and drives the single reload. Asking twice is free when nothing moved:
    /// `refreshTreesAndScan` dedupes an identical in-flight target rather than restarting it.
    /// - Parameter movedPane: the side the switch happened on. **Only that pane is walked**: the
    ///   other's tree is a walk of a root and focus the switch did not touch, so re-walking it
    ///   rebuilds something identical — 15–36ms of every switch, measured on a real strip, spent on
    ///   a pane nobody moved. The scan still runs and still compares both; the untouched pane
    ///   contributes the tree it already holds.
    private func refreshForTabSwitch(movedPane isLeft: Bool) {
        guard let left = settings.enabledProviders.first(where: { $0.id == leftProviderId }),
              let right = settings.enabledProviders.first(where: { $0.id == rightProviderId }) else { return }
        Task {
            await syncManager.refreshTreesAndScan(left: left, right: right,
                                                  reloading: .movedPane(isLeft: isLeft))
        }
    }

    // MARK: - The verbs, as the UI names them

    /// ⌘T, the ＋, and a double-click on the strip's empty stretch.
    ///
    /// **Opens the CURRENT folder**, and the control says so ("New tab here"). The result is two
    /// tabs with the same name and the strip's arrival is the only feedback — but opening at the
    /// provider root instead would throw away the folder you pressed ⌘T from, which is worse for
    /// being tidier.
    func openNewTabHere(isLeft: Bool) {
        openTabHere(isLeft: isLeft)
        // **Mirrored as the verb reads, not as a path.** ⌘T's whole contract is that the pane does
        // not move, so the sibling gets a new tab at *its* current folder rather than being
        // teleported to this one's. Linked and in step — which is what linked means — those are the
        // same folder, and drifted they at least both keep their place.
        guard tabsOpenOnBothPanes else { return }
        openTabHere(isLeft: !isLeft, mirrored: true)
    }

    /// `mirrored` changes **only the log line**, and that is the whole reason it exists: a mirrored
    /// ⌘T opens the sibling at its own folder, so without it the two panes emit the *same* sentence
    /// in the same second and the log reads as one keystroke firing twice. He audits this log, and a
    /// phantom double-fire is exactly the kind of thing it should not have to be reasoned away.
    private func openTabHere(isLeft: Bool, mirrored: Bool = false) {
        let providerId = isLeft ? leftProviderId : rightProviderId
        let here = syncManager.combinedRelativePath(isLeft: isLeft)
        // **Both halves of where the pane is, not the joined string.** Handing `here` over as the
        // new tab's SCOPE — which is what this did — collapses the column stack at the moment the
        // tab is created: scope draws exactly one column and the stack draws the rest, so ⌘T from
        // four open columns produced one full-width column. Persistence then round-tripped that
        // flattening perfectly, which is why it read as "the columns are collapsed again after a
        // restart" long after the restore itself had been fixed to carry the depth.
        //
        // Through `PaneTabOpening` rather than by reading the two properties directly, so this and
        // `openInNewTab` below cut a location the same way; from the pane's own location it returns
        // exactly the pane's own two halves.
        let cut = PaneTabOpening.location(of: here,
                                          openedFromScope: isLeft ? syncManager.leftRelativePath
                                                                  : syncManager.rightRelativePath)
        tabAction(isLeft: isLeft) {
            // Logged from inside, so a refused action (the bootstrap guard) leaves no line claiming
            // it happened — he audits this log.
            let where_ = here.isEmpty ? "the source root" : here
            Logger.shared.info(mirrored
                ? "Linked panes: also opened a new tab at “\(where_)” on the other pane"
                : "User opened a new tab at “\(where_)”")
            return syncManager.openTab(
                PaneTab(providerId: providerId, relativePath: cut.scope, browsePath: cut.stack),
                isLeft: isLeft, currentProviderId: providerId)
        }
    }

    /// Right-click a folder ▸ Open in New Tab, and ⌘-double-click on a folder row — the discovery
    /// route, and the only entry point that opens the new tab somewhere *different*.
    func openInNewTab(absolutePath: String, isLeft: Bool) {
        let providerId = isLeft ? leftProviderId : rightProviderId
        // **Expanded.** A source's stored path may be written with a tilde, while a row's id is
        // always absolute — `relativize` compares them as strings, so an unexpanded root matches
        // nothing and this whole entry point becomes a silent no-op. `PaneLogic.fullPath` and
        // `PaneLogic.paneFocusRestores` each expand for the same reason.
        let root = (settings.path(for: providerId) as NSString).expandingTildeInPath
        guard let relative = PathBoundary.relativize(absolutePath, under: root) else {
            // A folder outside this pane's root has no tab to be opened as: the strip is a list of
            // locations under one source, and inventing one here would name a path the pane could
            // not navigate to.
            Logger.shared.warning("Ignored Open in New Tab for a path outside the pane's source: \(absolutePath)")
            return
        }
        // Cut against the pane this row belongs to — see `openTabHere`. A folder UNDER the pane's
        // scope keeps that scope and becomes stack, so the new tab opens with the ancestor columns
        // rather than as one full-width column; a folder outside it is all scope, as before.
        let cut = PaneTabOpening.location(of: relative,
                                          openedFromScope: isLeft ? syncManager.leftRelativePath
                                                                  : syncManager.rightRelativePath)
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
    /// **Pruned, not copied.** The two sides are being compared precisely because they differ, so
    /// the folder just opened over here may not exist over there; `PaneTabMirror` walks the sibling
    /// as deep as it genuinely can — the same treatment `applyColumnNavigation` gives a mirrored
    /// drill, for the same reason. A tab naming a folder that pane does not have would be a chip
    /// that cannot be navigated to.
    private func mirrorOpenInNewTab(_ relative: String, from isLeft: Bool) {
        guard tabsOpenOnBothPanes else { return }
        let other = !isLeft
        let providerId = other ? leftProviderId : rightProviderId
        // Expanded, for the reason `openInNewTab` gives above: a tilde root exists on no disk, so
        // every mirror would prune away to the sibling's root.
        let root = (settings.path(for: providerId) as NSString).expandingTildeInPath
        let landing = PaneTabMirror.landing(for: relative) { candidate in
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(
                atPath: PaneLogic.fullPath(root: root, relativePath: candidate), isDirectory: &isDirectory)
            return exists && isDirectory.boolValue
        }
        // Cut against the SIBLING's scope, not this pane's: the landing was pruned to what that
        // pane actually has, and cutting it against the wrong pane's scope would put components in
        // a stack that is not underneath it.
        let cut = PaneTabOpening.location(of: landing,
                                          openedFromScope: other ? syncManager.leftRelativePath
                                                                 : syncManager.rightRelativePath)
        tabAction(isLeft: other) {
            Logger.shared.info("Linked panes: also opened “\(landing.isEmpty ? "the source root" : landing)” in a new tab on the other pane")
            return syncManager.openTab(
                PaneTab(providerId: providerId, relativePath: cut.scope, browsePath: cut.stack),
                isLeft: other, currentProviderId: providerId)
        }
    }

    /// Whether opening a tab on one pane opens one on the other too.
    ///
    /// The same test `applyColumnNavigation` applies to a mirrored drill — Compare only, and the
    /// seam's 🔗 or a held ⌥ — so every way of opening a folder, in this window or in a new tab,
    /// obeys the one setting rather than each growing its own answer.
    private var tabsOpenOnBothPanes: Bool {
        layoutMode == .compare
            && (PaneLinkPreference.isLinked || NSEvent.modifierFlags.contains(.option))
    }

    /// Selecting and cycling log at **debug**, not info.
    ///
    /// Every other tab verb here is INFO, matching "User switched to <workspace>" and the rest of
    /// the app's `User <verbed>` house style. These two are the exception because ⌃⇥ held down walks
    /// the whole strip: at INFO a single impatient cycle buries the line above it, and the log's
    /// value to him is that the interesting lines are still findable.
    func selectTab(id: UUID, isLeft: Bool) {
        tabAction(isLeft: isLeft) {
            Logger.shared.debug("User selected a browse tab")
            return syncManager.switchTab(to: id, isLeft: isLeft,
                                         currentProviderId: isLeft ? leftProviderId : rightProviderId)
        }
    }

    func cycleTab(forward: Bool, isLeft: Bool) {
        tabAction(isLeft: isLeft) {
            Logger.shared.debug("User cycled to the \(forward ? "next" : "previous") browse tab")
            return syncManager.cycleTab(forward: forward, isLeft: isLeft,
                                        currentProviderId: isLeft ? leftProviderId : rightProviderId)
        }
    }

    /// Closing the last tab closes the WINDOW, as Finder does — which is also what keeps ⌘W
    /// meaning "get rid of this" instead of acquiring an exception nobody would remember.
    func closeTab(id: UUID, isLeft: Bool) {
        guard syncManager.paneTabs(isLeft: isLeft).count > 1 else {
            Logger.shared.info("User pressed Close Tab on the pane's last tab — closing the window")
            NSApp.keyWindow?.performClose(nil)
            return
        }
        // Named before it goes, because after the close there is nothing left to name it by — and a
        // closed tab is the one tab verb that throws away state (its history, its selection) with
        // only a ten-deep undo behind it.
        let closing = paneTabItems(isLeft: isLeft).first { $0.id == id }?.title ?? "a tab"
        tabAction(isLeft: isLeft) {
            Logger.shared.info("User closed the browse tab “\(closing)”")
            return syncManager.closeTab(id: id, isLeft: isLeft,
                                        currentProviderId: isLeft ? leftProviderId : rightProviderId)
        }
    }

    func closeOtherTabs(keeping id: UUID, isLeft: Bool) {
        // The count is the point of this line: this is the one gesture in the feature that closes
        // several tabs at once, and "how many did that just take" is unanswerable afterwards.
        let list = syncManager.paneTabs(isLeft: isLeft)
        let closing = list.closableOthers(keeping: id)
        tabAction(isLeft: isLeft) {
            Logger.shared.info("User closed \(closing) other browse tab\(closing == 1 ? "" : "s")\(list.pinnedCount > 0 ? ", keeping \(list.pinnedCount) pinned" : "")")
            return syncManager.closeOtherTabs(keeping: id, isLeft: isLeft,
                                              currentProviderId: isLeft ? leftProviderId : rightProviderId)
        }
    }

    func duplicateTab(id: UUID, isLeft: Bool) {
        tabAction(isLeft: isLeft) {
            Logger.shared.info("User duplicated a browse tab")
            return syncManager.duplicateTab(id: id, isLeft: isLeft,
                                            currentProviderId: isLeft ? leftProviderId : rightProviderId)
        }
    }

    /// Drag-to-reorder. **Not through `tabAction`**: the pane does not move, so there is no
    /// provider to write, no search field to swap and no reload to drive — only the strip and what
    /// is saved of it change.
    /// Pin / unpin, from a tab's context menu. Like `moveTab`, the pane does not move — only the
    /// strip's order and that chip's own state — so this does not go through `tabAction`.
    func setTabPinned(_ pinned: Bool, id: UUID, isLeft: Bool) {
        guard !isBootstrappingProviders else { return }
        Logger.shared.info("User \(pinned ? "pinned" : "unpinned") a browse tab")
        syncManager.setTabPinned(pinned, id: id, isLeft: isLeft)
        saveBrowseTabs(isLeft: isLeft)
    }

    /// Debug, like selecting: a drag emits one line and changes nothing but where a chip sits.
    func moveTab(id: UUID, to index: Int, isLeft: Bool) {
        guard !isBootstrappingProviders else { return }
        Logger.shared.debug("User reordered a browse tab")
        syncManager.moveTab(id: id, to: index, isLeft: isLeft)
        saveBrowseTabs(isLeft: isLeft)
    }

    func reopenClosedTab(isLeft: Bool) {
        tabAction(isLeft: isLeft) {
            // Inside the verb, so a press with nothing on the stack writes no line claiming a tab
            // came back — the item is always enabled, so that press is a real thing a user does.
            guard let tab = syncManager.reopenClosedTab(
                isLeft: isLeft, currentProviderId: isLeft ? leftProviderId : rightProviderId)
            else { return nil }
            Logger.shared.info("User reopened the closed tab “\(tab.combinedRelativePath.isEmpty ? "the source root" : tab.combinedRelativePath)”")
            return tab
        }
    }

    /// Copy Path, from a tab's context menu — the absolute path, which is what is useful in a
    /// Terminal or a Finder ⇧⌘G, rather than the relative one the chip is named for.
    func copyTabPath(id: UUID, isLeft: Bool) {
        guard let item = paneTabItems(isLeft: isLeft).first(where: { $0.id == id }) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.fullPath, forType: .string)
        Logger.shared.info("User copied a tab's path: \(item.fullPath)")
    }

    // MARK: - Persistence and the launch seed

    /// Saves one pane's strip. **Both panes now**, under their own keys — see `PaneTabsStore`.
    ///
    /// **Refuses while the providers are still bootstrapping**, which is not belt-and-braces: the
    /// launch sequence points the pane at its stored folder *before* `restoreBrowseTabs` reads the
    /// stored strip, and that first move fires the `onChange` this hangs off. The pane at that
    /// moment holds the freshly-initialised one-tab list, so a save landing in the window between
    /// those two steps overwrites the user's whole strip with a single tab — and the restore then
    /// reads back what it just lost. Whether the window opens at all depends on when SwiftUI runs a
    /// view update across the `await` in between, which is not a thing to leave to timing. Every
    /// other tab entry point already refuses here; this was the one that did not.
    func saveBrowseTabs(isLeft: Bool) {
        guard !isBootstrappingProviders else { return }
        let list = syncManager.paneTabs(isLeft: isLeft)
        // The ACTIVE entry is a stale snapshot by construction, so it is written from the live pane
        // rather than from the list — otherwise quitting saves the folder the tab was parked at
        // rather than the one on screen.
        var tabs = list.tabs
        tabs[list.selectedIndex] = PaneTab(
            id: list.active.id,
            providerId: isLeft ? leftProviderId : rightProviderId,
            // **The two halves, not the joined string.** `PaneTabsStore` needs to know where the
            // cut between them is (it stores the depth), and a tab rebuilt with the combined path
            // as its scope reports a stack depth of zero — which is exactly how the ACTIVE tab, the
            // one on screen, used to lose its columns across a quit while parked tabs kept theirs.
            relativePath: isLeft ? syncManager.leftRelativePath : syncManager.rightRelativePath,
            browsePath: isLeft ? syncManager.leftBrowsePath : syncManager.rightBrowsePath,
            // Carried over: this entry is rebuilt from the LIVE pane, which knows nothing about
            // pinning, so reading it from anywhere but the list would unpin the active tab on the
            // next thing that saves.
            isPinned: list.active.isPinned)
        PaneTabsStore.save(tabs: tabs, selected: list.selectedIndex, isLeft: isLeft)
    }

    /// Restores the strip at launch, once the providers are known.
    ///
    /// Called from the same place the panes are first pointed at their sources, and it deliberately
    /// does nothing at all when there is one stored tab at the root — that is the state a fresh
    /// install and an upgrading one both start in, and seeding it would replace an identical list
    /// with a new one whose ids nothing else knows about.
    func restoreBrowseTabs(isLeft: Bool) {
        // **Behind the same setting as the folder restore beside it.** Someone who has turned
        // "reopen the last folder" off has said they want the app to start at the root; handing
        // them five tabs' worth of where they were is that answer at five times the volume.
        guard GeneralSettings.shouldRestoreLastFocus() else { return }
        // A pane with nothing stored keeps whatever `restoreLastPaneFocusIfEnabled` just gave it,
        // which for the right pane is the older `lastRightFocusPath` restore. That is what makes
        // the first launch after this shipped identical to the last one before it.
        guard let stored = PaneTabsStore.load(isLeft: isLeft) else { return }
        let restored = PaneTabsStore.restore(
            entries: stored.entries,
            selected: stored.selected,
            // The pane's list, not the discovered one — see `paneCanShowSource`. A tab on a source
            // the user has switched off is dropped here rather than restored onto a pane that
            // nothing would then walk.
            isKnownProvider: paneCanShowSource,
            folderExists: { providerId, relativePath in
                guard !relativePath.isEmpty else { return true }
                // Expanded, for the reason `openInNewTab` gives: a tilde root never exists on disk,
                // so every restored tab would fall back to its provider's root and the strip would
                // come back pointing at nothing in particular.
                var isDirectory: ObjCBool = false
                let exists = FileManager.default.fileExists(
                    atPath: PaneLogic.fullPath(root: settings.path(for: providerId),
                                               relativePath: relativePath),
                    isDirectory: &isDirectory)
                return exists && isDirectory.boolValue
            })
        // Nothing to restore only when the strip is genuinely the state a fresh install opens in:
        // one tab, at the root, unpinned. The rule lives on `PaneTabList` because it has to read
        // the tab's COMBINED location rather than its scope, and getting that wrong here skipped
        // the restore outright for a single tab drilled down from the root — see `isSeedState`.
        // **What the restore threw away, before what it kept.** `PaneTabsStore.restore` drops an
        // entry whose source this pane cannot be pointed at, and since that list is now
        // `enabledProviders` the commonest way to reach it is not a source vanishing but the user
        // switching one OFF in Settings — a reversible decision whose cost here is not. Dropping is
        // still the right answer (there is no root to fall back to, and a tab that cannot be opened
        // is not a place), but doing it in silence is not: the strip is rewritten by the first
        // thing that saves, so those tabs are gone for good with nothing to say where. He audits
        // this log.
        let dropped = (stored.entries.count) - (restored?.count ?? 0)
        if dropped > 0 {
            Logger.shared.warning(
                "Dropped \(dropped) stored \(isLeft ? "left" : "right") browse tab\(dropped == 1 ? "" : "s"): "
                + "their source is gone or switched off")
        }
        guard let restored, !restored.isSeedState else { return }
        Logger.shared.info(
            "Restored \(restored.count) \(isLeft ? "left" : "right") browse tab\(restored.count == 1 ? "" : "s")")
        syncManager.setPaneTabs(restored, isLeft: isLeft)
        // The restored ACTIVE tab is the pane's position, so it has to be applied like any other
        // switch — including its provider, which may not be the one the pane was pointed at.
        let active = restored.active
        let currentProviderId = isLeft ? leftProviderId : rightProviderId
        if active.providerId != currentProviderId, paneCanShowSource(active.providerId) {
            // **No suppression counter here, deliberately.** This runs inside the provider
            // bootstrap, where the id's `onChange` bails on `isBootstrappingProviders` *without*
            // decrementing — so arming the counter would strand it at one and silently swallow the
            // user's next real source switch, leaving that switch's navigation un-reset. The
            // bootstrap guard IS the suppression here; `applyProviderSelection` two lines earlier
            // writes both ids the same way. `tabAction` arms the counter because it runs later,
            // when the handler is live.
            if isLeft { leftProviderId = active.providerId } else { rightProviderId = active.providerId }
        }
        // Re-read, because the line above may have just written it: the id the pane is NOW on is
        // what `applyTab`'s reload rule has to compare against, so passing the pre-write value
        // would report a source change that has already been adopted. At launch the pane is at its
        // root and the tab usually is not, so this normally invalidates anyway; the bootstrap's own
        // refresh two steps later is the reload.
        syncManager.applyTab(active, isLeft: isLeft,
                             currentProviderId: isLeft ? leftProviderId : rightProviderId)
    }
}


/// Keeps the saved strip in step with the live pane.
///
/// **The active tab IS the live pane** (see `PaneTab`), so a strip written only when a tab opens or
/// closes would restore every tab at the folder it was created in. All three halves of "where a tab
/// is" are watched: the comparison scope, the column stack (the half that moves in Columns), and
/// the **source**.
///
/// The source is the one that is easy to leave out and the one that bites hardest. Switching source
/// while sitting at the root changes *nothing else* — `resetNavigation` finds the history already
/// default, the column stack already empty and the relative path already `""`, so neither path
/// `onChange` fires and nothing saves. The stored active entry keeps naming the old source, and
/// because `restoreBrowseTabs` writes the restored tab's provider over `selectedLeftProviderId`,
/// the next launch does not merely fail to follow the switch — it actively undoes it, reopening on
/// the source the user navigated away from. That is a regression of behaviour that predates tabs,
/// caused by the strip becoming a second, staler answer to "which source was this pane on".
///
/// A `ViewModifier` rather than `onChange`s in `ContentView.body` because that chain is already
/// long enough that adding two more tipped it past the type-checker's budget. One modifier, and its
/// body is type-checked on its own.
struct BrowseTabPersistence: ViewModifier {
    @ObservedObject var syncManager: FileSyncManager
    /// Each pane's source. Plain `String`s rather than the `@AppStorage` bindings: this only needs
    /// to notice that one changed, and taking the values keeps the modifier testable as a value.
    let leftProviderId: String
    let rightProviderId: String
    /// Saves the side that moved. **Per-side, not one save of both**: the two strips live under
    /// separate keys, and a single callback would either write the pane that did not move —
    /// re-saving a right pane the user has not touched on every left-pane click — or need this
    /// modifier to know which key each value belongs to, which is the host's job.
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


/// Whether a pane draws a tab strip.
///
/// A rule rather than the one-line disjunction it was, because of the middle term: **in Compare,
/// one pane growing a second tab draws the strip on BOTH panes.** The two panes are read as one
/// row — headers, breadcrumbs and lists all line up across the seam — and a strip on one side only
/// pushes that side's header 34pt down, so every row after it names a different folder on the left
/// than on the right. The sibling's strip holds one chip and a ＋, which is also the discoverable
/// way to give that side a second tab.
///
/// Browse has no sibling, and the single-source rail's other pane is not on screen: both take the
/// own-pane term alone. Ticked-and-disabled past one tab is enforced by `shortcutTabBar`, so the
/// switch stays a plain disjunct.
enum PaneTabStripVisibility {
    static func shows(own: Bool, sibling: Bool, isCompare: Bool, switchIsOn: Bool) -> Bool {
        own || switchIsOn || (isCompare && sibling)
    }
}


/// Where a mirrored tab lands on the sibling pane.
///
/// The deepest prefix of the folder that pane genuinely has, which is "" — its root — when it has
/// none of it. Separate from the caller so the walk can be tested against a set of folders instead
/// of against a disk, and because the empty-string result is the case worth pinning: it is what a
/// pane that shares nothing with the other gets, and it must still be a tab rather than nothing.
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
/// **Not a tabs concern**, and it lives beside `BrowseTabPersistence` for the reason that modifier
/// records: `ContentView.body` is at the type-checker's budget, and these four `onChange`s pushed it
/// over ("unable to type-check this expression in reasonable time") the moment the last two were
/// added inline. One modifier, type-checked on its own.
///
/// Two triggers, and the second is not belt-and-braces:
///
/// - **Every republish.** A republish can delete a folder a stack is standing in — externally, or
///   by the user's own Delete — and without this the columns render nothing while `currentDirectory`
///   still names the dead folder, which is where New Folder and paste would then act.
/// - **Every pane settling.** `pruneBrowsePath` refuses while a tree is loading, because progressive
///   loading publishes a shallow root-children-only tree first and pruning against that cuts a valid
///   stack to its first component. But the deep tree is published *before* `await applyFilters()`
///   and the loading flag is cleared *after* it, so the update carrying the final tree can arrive
///   while the flag is still up — the republish trigger skips, and the tree does not change again to
///   re-fire it. The falling edge closes that without depending on which side of an `await` a
///   SwiftUI update happens to land on.
///
/// Both skip a pane with nothing to prune: building the children index is a whole-tree walk, and
/// `canAdvance` counts because a pane resting at its root can still hold a `›` stack pointing into a
/// folder that has just been deleted.
struct ColumnStackPruning: ViewModifier {
    @ObservedObject var syncManager: FileSyncManager
    let leftTreeRoot: String
    let rightTreeRoot: String

    private func prune(isLeft: Bool) {
        let stack = isLeft ? syncManager.leftBrowsePath : syncManager.rightBrowsePath
        guard !stack.isEmpty || stack.canAdvance else { return }
        let root = isLeft ? leftTreeRoot : rightTreeRoot
        syncManager.pruneBrowsePath(
            isLeft: isLeft,
            against: isLeft ? syncManager.leftChildrenIndex(treeRoot: root)
                            : syncManager.rightChildrenIndex(treeRoot: root),
            treeRoot: root)
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
/// **⇄ and 🔗 are drawn on top of this row.** `SeamPaneControls` is an overlay on the panes region
/// pinned 8pt from its top and straddling the pane boundary — which is exactly where a strip's
/// trailing ＋ (left pane) and leading chip (right pane) sit. Measured on the shipping app: the
/// left pane's ＋ landed about five points from ⇄, near enough to read as one control.
///
/// A named rule rather than a ternary at the call site because it is wrong in two directions and
/// only one of them is visible: too little and the controls overlap, too much and Browse — which
/// has no seam at all — loses track it should keep. `PaneTabWiringTests` pins both.
enum PaneTabSeam {
    /// The seam capsule is two 26pt halves offset 13pt back from the boundary, so it reaches 13pt
    /// into each pane; 26 gives the strip's own gap on top of that.
    static let reserve: CGFloat = 26

    /// The inset for one edge of one pane's strip. Zero everywhere but the two edges that touch a
    /// seam, which exists only in Compare.
    static func inset(isCompare: Bool, isLeft: Bool, leading: Bool) -> CGFloat {
        guard isCompare else { return 0 }
        // The left pane gives up its TRAILING edge, the right pane its LEADING one.
        return leading == isLeft ? 0 : reserve
    }
}


/// What a pane's tab strip renders, as a rule.
///
/// Lifted out of `ContentView` so it can be tested at all, and because it holds the one thing about
/// the strip that is easy to get subtly wrong: **the active chip reads the LIVE pane, and every
/// other chip reads its own parked snapshot.** The active entry in the list is a snapshot from when
/// that tab was last parked (see `PaneTab`), so a chip drawn from it keeps naming the folder you
/// arrived in while the pane walks on — a strip that is correct on arrival and wrong a click later,
/// which is exactly the kind of thing a screenshot taken at the wrong moment makes look fine.
enum PaneTabChips {
    /// What the host knows about one source. `nil` for a source that is no longer available.
    struct Source: Equatable {
        let displayName: String
        let markImageName: String
        /// As stored — possibly with a tilde. Expanded here, never at the call site.
        let root: String
    }

    static func items(_ list: PaneTabList,
                      liveProviderId: String,
                      livePath: String,
                      source: (String) -> Source?) -> [PaneTabStrip.Item] {
        list.tabs.enumerated().map { index, tab in
            let isActive = index == list.selectedIndex
            let providerId = isActive ? liveProviderId : tab.providerId
            let path = isActive ? livePath : tab.combinedRelativePath
            let resolved = source(providerId)
            // A tab at a source root has no folder to name, so it wears the source's name — and
            // the raw id if even that is gone, which at least says which source it meant.
            let name = path.isEmpty ? (resolved?.displayName ?? providerId)
                                    : (path as NSString).lastPathComponent
            return PaneTabStrip.Item(
                id: tab.id,
                title: name,
                // A source with no bundled mark wears a folder, which is what `ProviderLogo` draws
                // for a folder source anyway.
                markImageName: resolved?.markImageName ?? "folder.fill",
                isActive: isActive,
                fullPath: PaneLogic.fullPath(root: resolved?.root ?? "", relativePath: path),
                isPinned: tab.isPinned)
        }
    }
}

/// Whether a tab switch also changes the pane's source.
///
/// A rule rather than an `if` at the call site because the middle case is invisible: a tab whose
/// source has been removed since it was opened must NOT have its folder rendered under whatever
/// source the pane happens to be showing, and there is nothing on screen to tell you that happened.
///
/// "Gone" is `paneCanShowSource`'s reading — **a source switched off in Settings is gone for this
/// purpose**, because no refresh will walk a pane pointed at one. Asking the discovered list here
/// instead reported `.adopt` for exactly those, which is the invisible middle case landing in the
/// branch that says nothing.
enum PaneTabProviderSwitch: Equatable {
    /// The pane is already on this tab's source.
    case keep
    /// Write the id — and suppress the reset its `onChange` would otherwise run.
    case adopt(String)
    /// The tab names a source this pane cannot be pointed at. Stay put, and say so.
    case unavailable(String)

    static func decide(arrived: String, current: String, isAvailable: (String) -> Bool) -> PaneTabProviderSwitch {
        guard arrived != current else { return .keep }
        return isAvailable(arrived) ? .adopt(arrived) : .unavailable(arrived)
    }
}

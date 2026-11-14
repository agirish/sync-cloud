import Testing
import Foundation
import Events
@testable import Sync

/// The tab list's own rules: what closing a tab selects next, what a duplicate carries, and, less
/// obviously, that the active entry is a stale snapshot until something parks it. That is why
/// every verb in `FileSyncManager+PaneTabs` calls `captureActive` first; checking only which tab
/// is selected would pass with every capture removed.
@Suite struct PaneTabListTests {

    private func tab(_ path: String, provider: String = "iCloud") -> PaneTab {
        PaneTab(providerId: provider, relativePath: path)
    }

    private func list(_ paths: [String], selected: Int = 0) -> PaneTabList {
        PaneTabList(tabs: paths.map { tab($0) }, selectedIndex: selected)
    }

    // MARK: The strip's own visibility

    @Test func theStripIsHiddenAtOneTabAndShownAtTwo() {
        #expect(!PaneTabList(single: tab("")).showsStrip)
        #expect(list(["", "Documents"]).showsStrip)
    }

    // MARK: Opening

    @Test func aNewTabLandsAtTheTrailingEndAndBecomesActive() {
        var tabs = list(["A", "B"], selected: 0)
        tabs.open(tab("C"))
        #expect(tabs.tabs.map(\.relativePath) == ["A", "B", "C"])
        #expect(tabs.active.relativePath == "C")
    }

    /// A background tab waits and the live one stays live: files opened together from Finder put
    /// the first on screen and each other in a tab of its own. Fails if the appended tab is
    /// selected, as `open` does.
    @Test func aBackgroundTabLandsAtTheTrailingEndAndLeavesTheActiveOne() {
        var tabs = list(["A", "B"], selected: 0)
        let id = tabs.openInBackground(PaneTab(providerId: "dropbox", relativePath: "C", selection: ["/c/C/x.md"]))
        #expect(tabs.tabs.map(\.relativePath) == ["A", "B", "C"])
        #expect(tabs.active.relativePath == "A")
        let waiting = try? #require(tabs.tabs.first { $0.id == id })
        #expect(waiting?.providerId == "dropbox" && waiting?.selection == ["/c/C/x.md"],
                "the waiting tab lost its source or the file it was opened for")
    }

    // MARK: Closing

    /// Closing the active tab selects the one to its right (Finder's rule, and the one that lets
    /// you close several in a row without moving the pointer), or its left when it was last.
    /// Closing a parked tab to the LEFT of the active one keeps the *same tab* live, at a lower
    /// index: the case that silently mis-selects if the index is not adjusted.
    @Test(arguments: [(selected: 1, closeAt: 1, active: "C", order: ["A", "C"]),
                      (2, 2, "B", ["A", "B"]),
                      (2, 0, "C", ["B", "C"])])
    func closingATabSelectsTheRightNeighbour(selected: Int, closeAt: Int, active: String, order: [String]) {
        var tabs = list(["A", "B", "C"], selected: selected)
        let closed = tabs.close(at: closeAt)
        #expect(closed)
        #expect(tabs.active.relativePath == active)
        #expect(tabs.tabs.map(\.relativePath) == order)
    }

    /// A pane always holds a location — the last tab is refused here and the window closes instead
    /// (`CloseTabCommand`). Refused rather than emptied, so `active` needs no optional anywhere.
    @Test func theLastTabIsNeverClosed() {
        var tabs = PaneTabList(single: tab("A"))
        let closed = tabs.close(at: 0)
        #expect(!closed)
        #expect(tabs.count == 1)
    }

    @Test func closeOthersLeavesTheKeptTabLive() {
        var tabs = list(["A", "B", "C"], selected: 0)
        let keep = tabs.tabs[1].id
        tabs.closeOthers(keeping: keep)
        #expect(tabs.count == 1)
        #expect(tabs.active.id == keep)
        #expect(tabs.active.relativePath == "B")
    }

    // MARK: Cycling

    @Test func cyclingWrapsInBothDirections() {
        var tabs = list(["A", "B", "C"], selected: 2)
        tabs.selectNext()
        #expect(tabs.active.relativePath == "A")
        tabs.selectPrevious()
        #expect(tabs.active.relativePath == "C")
    }

    @Test func cyclingOneTabIsANoOp() {
        var tabs = PaneTabList(single: tab("A"))
        tabs.selectNext()
        #expect(tabs.selectedIndex == 0)
    }

    // MARK: Capture — the rule the rest of the feature rests on

    /// A capture is the same tab with newer contents, so it keeps its id: the strip's `ForEach`
    /// would otherwise tear the chip down and rebuild it on every switch.
    @Test func captureKeepsTheTabsIdentityAndTakesItsNewContents() {
        var tabs = list(["A", "B"], selected: 0)
        let id = tabs.active.id
        tabs.captureActive(PaneTab(providerId: "Dropbox", relativePath: "A/Deep",
                                   selection: ["/r/A/Deep/x.pdf"], searchQuery: "tax"))
        #expect(tabs.active.id == id)
        #expect(tabs.active.providerId == "Dropbox")
        #expect(tabs.active.relativePath == "A/Deep")
        #expect(tabs.active.selection == ["/r/A/Deep/x.pdf"])
        #expect(tabs.active.searchQuery == "tax")
        // And it wrote into the ACTIVE slot only.
        #expect(tabs.tabs[1].relativePath == "B")
    }

    // MARK: The overlay a save writes over the active entry

    /// The save overlay writes the live pane over the active entry, a snapshot from when the tab was
    /// last parked, and leaves everything else alone. Every line answers differently without it, and
    /// `recentlyClosed` is seeded so a reset of the reopen stack would fail.
    @Test func theSaveOverlayWritesTheLivePaneOverTheActiveEntryAndNothingElse() {
        let live = PaneTab(providerId: "iCloud", relativePath: "Finance", isPinned: true)
        let parked = PaneTab(providerId: "iCloud", relativePath: "Photos")
        let closed = PaneTab(providerId: "Dropbox", relativePath: "Taxes/2019")
        let strip = PaneTabList(tabs: [live, parked], selectedIndex: 0, recentlyClosed: [closed])

        let saving = strip.replacingActive(providerId: "Dropbox",
                                           relativePath: "School",
                                           browsePath: PaneBrowsePath(relativePath: "US/Daughter"))

        #expect(saving.active.providerId == "Dropbox",
                "the save stored the tab's parked source rather than the pane's live one")
        #expect(saving.active.relativePath == "School")
        #expect(saving.active.browsePath.relativePath == "US/Daughter")
        #expect(saving.active.combinedRelativePath == "School/US/Daughter")
        // The id: a save is the same tab with a newer location, and the strip's `ForEach` is keyed
        // on it.
        #expect(saving.active.id == live.id, "the saved entry is a different tab from the one it replaced")
        // The pin: read from anywhere but the list, it would unpin the active tab on the next save.
        #expect(saving.active.isPinned, "the tab on screen was unpinned by the act of saving it")
        // …and nothing else moved.
        #expect(saving.tabs[1] == parked, "a parked tab was rewritten by the active tab's save")
        #expect(saving.selectedIndex == strip.selectedIndex, "the save moved which tab is live")
        #expect(saving.count == 2)
        #expect(saving.recentlyClosed == [closed],
                "the save emptied the reopen stack — Reopen Closed Tab dies on the next pane move")
        // The strip it was asked of is untouched: this is a projection for the store.
        #expect(strip.active.providerId == "iCloud", "the overlay mutated the live strip")
        #expect(strip.active.relativePath == "Finance")
    }

    /// Whichever tab is live is the one written, not index 0: a rule tested only at the head would
    /// pass with the index hardcoded.
    @Test func theSaveOverlayFollowsTheSelectionRatherThanTheHeadOfTheStrip() {
        let strip = PaneTabList(tabs: [PaneTab(providerId: "iCloud", relativePath: "A"),
                                       PaneTab(providerId: "iCloud", relativePath: "B"),
                                       PaneTab(providerId: "iCloud", relativePath: "C")],
                                selectedIndex: 2)
        let saving = strip.replacingActive(providerId: "iCloud", relativePath: "Live",
                                           browsePath: PaneBrowsePath())
        #expect(saving.tabs.map(\.relativePath) == ["A", "B", "Live"],
                "the overlay wrote over the wrong tab")
        // Which tab is live must survive the overlay, or the pane reopens on the wrong tab after a
        // quit. Asserted off a non-head selection: index 0 is `PaneTabList.init`'s default, so the
        // test above can't see an overlay that resets it.
        #expect(saving.selectedIndex == 2,
                "the save moved the selection to another tab, so the pane reopens on the wrong one")
    }

    /// The overlay throws the active tab's history away, on purpose: `PaneTab.init` re-seeds it from
    /// the path written. Right for `saveBrowseTabs`, whose store holds no history, but a second
    /// caller reaching for it would quietly kill Back.
    @Test func theSaveOverlayReSeedsTheActiveTabsHistoryRatherThanCarryingIt() {
        var walked = PaneNavigationHistory()
        walked.push("Finance")
        walked.push("Finance/2024")
        let strip = PaneTabList(single: PaneTab(providerId: "iCloud", relativePath: "Finance/2024",
                                                history: walked))

        let saving = strip.replacingActive(providerId: "iCloud", relativePath: "School",
                                           browsePath: PaneBrowsePath(relativePath: "US"))

        // Seeded from the scope, which is what a pane's history tracks (`PaneTabArrival` compares
        // `history.current` against `leftRelativePath`), not from the combined location.
        #expect(saving.active.history.entries == ["", "School"],
                "the overlay carried a history across — it now disagrees with the path beside it")
        #expect(saving.active.history.current == "School",
                "the saved entry's history does not agree with its own scope")
        #expect(saving.active.history.canGoBack,
                "the seeded history cannot walk out of the folder it names")
        // The strip it was asked of keeps the real walk, so the pane on screen can still go Back
        // twice.
        #expect(strip.active.history == walked, "the overlay mutated the live tab's history")
    }

    // MARK: Duplicate and reopen

    /// A duplicate is a second view of a folder, not a second copy of what you were doing to it.
    @Test func duplicateCarriesTheLocationButNotTheSelectionOrQuery() {
        var tabs = PaneTabList(single: PaneTab(providerId: "iCloud", relativePath: "Finance",
                                               selection: ["/r/Finance/a.pdf"], searchQuery: "irs"))
        let id = tabs.active.id
        tabs.duplicate(id: id)
        #expect(tabs.count == 2)
        #expect(tabs.active.relativePath == "Finance")
        #expect(tabs.active.id != id)
        #expect(tabs.active.selection.isEmpty)
        #expect(tabs.active.searchQuery.isEmpty)
    }

    @Test func reopenBringsBackTheNewestClosedTabUnderAFreshIdentity() {
        var tabs = list(["A", "B", "C"], selected: 0)
        let closedId = tabs.tabs[1].id
        let closed = tabs.close(at: 1)
        #expect(closed)
        let reopened = tabs.reopenLastClosed()
        #expect(reopened?.relativePath == "B")
        // A fresh id: Close Other Tabs pushes several at once, so a reopened tab could collide with
        // one still on the stack, and two chips sharing an id is a `ForEach` collision.
        #expect(reopened?.id != closedId)
        #expect(tabs.active.relativePath == "B")
    }

    @Test func thereIsNothingToReopenBeforeAnythingIsClosed() {
        var tabs = list(["A", "B"])
        #expect(!tabs.canReopen)
        let reopened = tabs.reopenLastClosed()
        #expect(reopened == nil)
    }

    /// The stack is capped, and the cap is about not keeping a session's worth of the user's paths
    /// alive for a menu item nobody reaches past the second entry.
    @Test func theReopenStackIsCapped() {
        var tabs = PaneTabList(tabs: (0...20).map { tab("F\($0)") }, selectedIndex: 0)
        while tabs.count > 1 { _ = tabs.close(at: 0) }
        #expect(tabs.recentlyClosed.count == PaneTabList.reopenLimit)
        // The newest survive: reopen is a stack, so the oldest are dropped.
        #expect(tabs.recentlyClosed.last?.relativePath == "F19")
    }

    // MARK: Pinning

    /// The pinned run is a PREFIX, always — every other pinning rule is stated in terms of it.
    private func isPartitioned(_ list: PaneTabList) -> Bool {
        list.tabs.map(\.isPinned) == list.tabs.map(\.isPinned).sorted { $0 && !$1 }
    }

    @Test func pinningMovesATabToTheLeadingEnd() {
        var tabs = list(["A", "B", "C"], selected: 0)
        tabs.pin(id: tabs.tabs[2].id)
        #expect(tabs.tabs.map(\.relativePath) == ["C", "A", "B"])
        #expect(tabs.pinnedCount == 1)
        #expect(isPartitioned(tabs))
        // …and the tab you were looking at is still the one you are looking at.
        #expect(tabs.active.relativePath == "A")
    }

    @Test func pinningASecondTabKeepsThePinnedRunInPinOrder() {
        var tabs = list(["A", "B", "C"], selected: 0)
        tabs.pin(id: tabs.tabs[2].id)          // C
        tabs.pin(id: tabs.tabs.first(where: { $0.relativePath == "B" })!.id)
        #expect(tabs.tabs.map(\.relativePath) == ["C", "B", "A"])
        #expect(tabs.pinnedCount == 2)
        #expect(isPartitioned(tabs))
    }

    /// Unpinning drops the tab to the head of the unpinned run — closest to where it just was.
    @Test func unpinningDropsToTheHeadOfTheRest() {
        var tabs = list(["A", "B", "C"], selected: 0)
        tabs.pin(id: tabs.tabs[0].id)
        tabs.pin(id: tabs.tabs.first(where: { $0.relativePath == "B" })!.id)
        tabs.unpin(id: tabs.tabs.first(where: { $0.relativePath == "A" })!.id)
        #expect(tabs.tabs.map(\.relativePath) == ["B", "A", "C"])
        #expect(tabs.pinnedCount == 1)
        #expect(isPartitioned(tabs))
    }

    /// Pinned tabs survive Close Other Tabs: that is most of what pinning is for.
    @Test func closeOthersKeepsThePinnedOnes() {
        var tabs = list(["A", "B", "C", "D"], selected: 0)
        tabs.pin(id: tabs.tabs.first(where: { $0.relativePath == "D" })!.id)
        let keep = tabs.tabs.first { $0.relativePath == "B" }!.id
        tabs.closeOthers(keeping: keep)
        #expect(tabs.tabs.map(\.relativePath) == ["D", "B"])
        #expect(tabs.active.relativePath == "B")
        #expect(isPartitioned(tabs))
    }

    /// Keeping a PINNED tab leaves it in the prefix rather than appended after it.
    @Test func closeOthersKeepingAPinnedTabHoldsThePartition() {
        var tabs = list(["A", "B", "C"], selected: 0)
        tabs.pin(id: tabs.tabs.first(where: { $0.relativePath == "A" })!.id)
        tabs.pin(id: tabs.tabs.first(where: { $0.relativePath == "B" })!.id)
        let keep = tabs.tabs.first { $0.relativePath == "B" }!.id
        tabs.closeOthers(keeping: keep)
        #expect(tabs.tabs.map(\.relativePath) == ["A", "B"])
        #expect(tabs.active.relativePath == "B")
        #expect(isPartitioned(tabs))
    }

    /// A drag cannot cross the pin line in either direction.
    @Test func aDragCannotCrossThePinLine() {
        var tabs = list(["A", "B", "C", "D"], selected: 0)
        tabs.pin(id: tabs.tabs.first(where: { $0.relativePath == "A" })!.id)   // ["A", "B", "C", "D"]
        tabs.move(from: 3, to: 0)     // D, unpinned, dropped onto the pinned slot
        #expect(tabs.tabs.map(\.relativePath) == ["A", "D", "B", "C"])
        #expect(isPartitioned(tabs))

        tabs.move(from: 0, to: 3)     // A, pinned, dragged into the unpinned run
        #expect(tabs.tabs.first?.relativePath == "A", "a pinned tab was dragged out of the prefix")
        #expect(isPartitioned(tabs))
    }

    /// A capture carries the live PANE's contents, and the pane has no idea about pinning.
    @Test func capturingThePaneDoesNotUnpinItsTab() {
        var tabs = list(["A", "B"], selected: 0)
        tabs.pin(id: tabs.tabs[0].id)
        tabs.captureActive(PaneTab(providerId: "iCloud", relativePath: "A/Deep"))
        #expect(tabs.active.isPinned, "walking around inside a pinned tab unpinned it")
        #expect(tabs.active.relativePath == "A/Deep")
    }

    /// A reopened tab comes back unpinned — `open` appends at the trailing end, and a pinned tab
    /// there would break the prefix.
    @Test func aReopenedTabComesBackUnpinned() {
        var tabs = list(["A", "B"], selected: 0)
        tabs.pin(id: tabs.tabs[1].id)
        let pinned = tabs.tabs.first { $0.isPinned }!.id
        _ = tabs.close(id: pinned)
        let reopened = tabs.reopenLastClosed()
        #expect(reopened?.isPinned == false)
        #expect(isPartitioned(tabs))
    }

    // MARK: Reorder

    /// Dragging a tab moves the chip, not which tab you are looking at.
    @Test func reorderingKeepsTheSameTabLive() {
        var tabs = list(["A", "B", "C"], selected: 2)
        tabs.move(from: 0, to: 2)
        #expect(tabs.tabs.map(\.relativePath) == ["B", "C", "A"])
        #expect(tabs.active.relativePath == "C", "reordering changed which tab is live")
    }

    @Test func reorderingTheLiveTabKeepsItLive() {
        var tabs = list(["A", "B", "C"], selected: 0)
        tabs.move(from: 0, to: 2)
        #expect(tabs.active.relativePath == "A")
        #expect(tabs.selectedIndex == 2)
    }

    /// A drop index comes from a pointer position, so a wild one is refused rather than clamped —
    /// clamping would silently land the tab somewhere the user did not drop it.
    @Test func anImpossibleDropIsRefused() {
        var tabs = list(["A", "B"], selected: 0)
        tabs.move(from: 0, to: 7)
        tabs.move(from: -1, to: 1)
        tabs.move(from: 1, to: 1)
        #expect(tabs.tabs.map(\.relativePath) == ["A", "B"])
    }

    // MARK: Names

    @Test func aTabIsNamedForItsLeafFolder() {
        let deep = PaneTab(providerId: "iCloud", relativePath: "Finance",
                           browsePath: PaneBrowsePath(relativePath: "US/2024"))
        #expect(deep.combinedRelativePath == "Finance/US/2024")
        #expect(deep.displayName(providerName: "iCloud Drive") == "2024")
    }

    /// At the root there is no folder to name, and an unnamed chip can't be told from another; ⌘T
    /// creates exactly that state.
    @Test func aTabAtTheRootWearsItsSourcesName() {
        #expect(PaneTab(providerId: "iCloud").displayName(providerName: "iCloud Drive") == "iCloud Drive")
    }

    /// The two positions a tab carries must agree. `applyTab` publishes the pane's path from the
    /// tab's history, so a history disagreeing with `relativePath` would land the pane somewhere
    /// the chip doesn't name. Every way of making a tab is checked.
    @Test func everyConstructedTabHasAHistoryThatAgreesWithItsPath() {
        let plain = PaneTab(providerId: "iCloud", relativePath: "Finance/US")
        #expect(plain.history.current == plain.relativePath)

        let root = PaneTab(providerId: "iCloud")
        #expect(root.history.current == root.relativePath)

        var list = PaneTabList(single: plain)
        list.duplicate(id: plain.id)
        #expect(list.active.history.current == list.active.relativePath, "a duplicate disagrees with itself")

        list.captureActive(PaneTab(providerId: "iCloud", relativePath: "Photos"))
        #expect(list.active.history.current == list.active.relativePath, "a capture disagrees with itself")

        _ = list.close(at: 1)
        let reopened = list.reopenLastClosed()
        #expect(reopened?.history.current == reopened?.relativePath, "a reopened tab disagrees with itself")
    }

    /// A tab seeded at a folder must be able to walk back out of it, or Back is dead in a restored
    /// tab.
    @Test func aSeededTabCanGoBackToItsRoot() {
        let seeded = PaneTab(providerId: "iCloud", relativePath: "Finance/US")
        #expect(seeded.history.current == "Finance/US")
        #expect(seeded.history.canGoBack)
        var history = seeded.history
        history.goBack()
        #expect(history.current == "")
    }
}

/// What survives a quit, and what deliberately does not.
@Suite struct PaneTabsStoreTests {

    /// Everything logged between two of this test's own markers, with `act` run between them.
    ///
    /// Read from the log file through `logLines(tag:during:)`, never `Logger.shared.entries`, a
    /// rolled 1000-line window a parallel run can log past (`docs/flaky-tests.md`, "A log assertion
    /// reading a window that has already rolled"). The file is per-process and never trimmed under
    /// a test. Levels are read by name off the canonical line, `[WARN]`.
    @MainActor
    private func loggedWindow(_ act: () -> Void) async throws -> [String] {
        try await logLines(tag: "pane-tabs \(UUID().uuidString)") { act() }
    }

    @Test func aRoundTripKeepsTheStripAndItsSelection() {
        let defaults = ScratchDefaults("PaneTabsStore")
        let tabs = [PaneTab(providerId: "iCloud", relativePath: "Finance"),
                    PaneTab(providerId: "Dropbox", relativePath: "Photos")]
        PaneTabsStore.save(tabs: tabs, selected: 1, isLeft: true, to: defaults)

        let loaded = PaneTabsStore.load(isLeft: true, from: defaults)
        #expect(loaded?.entries == [.init(providerId: "iCloud", relativePath: "Finance"),
                                    .init(providerId: "Dropbox", relativePath: "Photos")])
        #expect(loaded?.selected == 1)
    }

    /// Pins survive a save, a load and a restore.
    @Test func pinsSurviveAQuit() {
        let defaults = ScratchDefaults("PaneTabsStore-pins")
        var list = PaneTabList(tabs: [PaneTab(providerId: "iCloud", relativePath: "Finance"),
                                      PaneTab(providerId: "iCloud", relativePath: "Photos")])
        list.pin(id: list.tabs[1].id)
        PaneTabsStore.save(tabs: list.tabs, selected: list.selectedIndex, isLeft: true, to: defaults)

        let loaded = PaneTabsStore.load(isLeft: true, from: defaults)
        #expect(loaded?.entries.map(\.pinned) == [true, false])
        let restored = PaneTabsStore.restore(entries: loaded?.entries ?? [], selected: 0,
                                             isKnownProvider: { _ in true },
                                             folderExists: { _, _ in true })
        #expect(restored?.list.tabs.map(\.isPinned) == [true, false])
        #expect(restored?.list.pinnedCount == 1)
    }

    /// A stored strip that interleaves pinned and unpinned tabs comes back partitioned. Every rule
    /// in `PaneTabList` reads the pinned run as a prefix, and the file is not a promise.
    @Test func aStoredStripThatBreaksThePartitionIsRepairedOnTheWayIn() {
        let entries = [PaneTabsStore.Entry(providerId: "iCloud", relativePath: "A"),
                       PaneTabsStore.Entry(providerId: "iCloud", relativePath: "B", pinned: true),
                       PaneTabsStore.Entry(providerId: "iCloud", relativePath: "C"),
                       PaneTabsStore.Entry(providerId: "iCloud", relativePath: "D", pinned: true)]
        let restored = PaneTabsStore.restore(entries: entries, selected: 2,
                                             isKnownProvider: { _ in true },
                                             folderExists: { _, _ in true })
        #expect(restored?.list.tabs.map(\.relativePath) == ["B", "D", "A", "C"],
                "the restored strip interleaves pinned and unpinned tabs")
        #expect(restored?.list.pinnedCount == 2)
        // …and the tab that was selected is still the one selected, wherever the sort put it.
        #expect(restored?.list.active.relativePath == "C")
    }

    /// A strip with no `pinned` key still decodes. `Codable` rejects the whole value on a missing
    /// key, and that value is the user's tabs.
    @Test func aStripWrittenBeforePinningStillDecodes() {
        let defaults = ScratchDefaults("PaneTabsStore-legacy")
        defaults.set(#"[{"providerId":"iCloud","relativePath":"Finance"}]"#, forKey: PaneTabsStore.tabsKey)
        let loaded = PaneTabsStore.load(isLeft: true, from: defaults)
        #expect(loaded?.entries.count == 1)
        #expect(loaded?.entries.first?.pinned == false)
    }

    /// No key at all tells the caller to seed from the pane's own stored provider, so it must be
    /// distinguishable from an empty strip, which can't exist.
    @Test func nothingStoredReadsAsNothingRatherThanAsAnEmptyStrip() {
        let defaults = ScratchDefaults("PaneTabsStore-empty")
        #expect(PaneTabsStore.load(isLeft: true, from: defaults) == nil)
    }

    /// A corrupt value reads as nothing stored, and says so. An unreadable key returns the same
    /// `nil` as a missing one, so the caller seeds a fresh strip and the next save overwrites it
    /// for good. That is right (there is nothing to restore), but it must not lose the user's strip
    /// in silence. Reachable by a hand-edited plist or a later format change.
    @MainActor
    @Test func anUnreadableStoredStripIsReportedRatherThanSilentlyReplaced() async throws {
        // Not JSON at all: nil. Loaded outside the log window, so only the load below can meet
        // the warning's assertion.
        let notJSON = ScratchDefaults("PaneTabsStore-corrupt")
        notJSON.set("{not json", forKey: PaneTabsStore.tabsKey)
        #expect(PaneTabsStore.load(isLeft: true, from: notJSON) == nil)

        let defaults = ScratchDefaults("PaneTabsStore-corruptLog")
        defaults.set(#"[{"providerId":"iCloud","relativePath":]"#, forKey: PaneTabsStore.tabsKey)

        // Read between this test's own markers, not over the whole buffer, where the line could
        // scroll off before the assertion reads it.
        var loaded: (entries: [PaneTabsStore.Entry], selected: Int)?
        let logged = try await loggedWindow { loaded = PaneTabsStore.load(isLeft: true, from: defaults) }

        #expect(loaded == nil,
                "the caller must still be told to seed — this is a log line, not a new behaviour")
        #expect(logged.contains {
            $0.contains("[WARN]") && $0.contains("left browse tab strip could not be read")
        }, "an unreadable strip is thrown away by the next save with nothing said")
    }

    /// No key at all, or an empty array, is the ordinary case and stays quiet. Reading between the
    /// test's own markers, with the opening one required, reports a rolled window instead of passing
    /// on a window that never held the moment.
    @MainActor
    @Test func aStripThatWasNeverWrittenOrIsEmptyIsNotReported() async throws {
        let defaults = ScratchDefaults("PaneTabsStore-quietLoad")
        var neverWritten: (entries: [PaneTabsStore.Entry], selected: Int)?
        var empty: (entries: [PaneTabsStore.Entry], selected: Int)?

        let logged = try await loggedWindow {
            neverWritten = PaneTabsStore.load(isLeft: false, from: defaults)
            defaults.set("[]", forKey: PaneTabsStore.rightTabsKey)
            empty = PaneTabsStore.load(isLeft: false, from: defaults)
        }

        #expect(neverWritten == nil)
        #expect(empty == nil)
        #expect(!logged.contains {
            $0.contains("right browse tab strip could not be read")
        }, "a pane that has never stored a strip is reported as corrupt on every launch")
    }

    /// A stored index past the end of a shortened list would crash `PaneTabList`'s precondition if
    /// it were trusted; both the load and the restore clamp it.
    @Test func aSelectionPastTheEndIsClamped() {
        let defaults = ScratchDefaults("PaneTabsStore-clamp")
        PaneTabsStore.save(tabs: [PaneTab(providerId: "iCloud")], selected: 0, isLeft: true, to: defaults)
        defaults.set(7, forKey: PaneTabsStore.selectedKey)
        #expect(PaneTabsStore.load(isLeft: true, from: defaults)?.selected == 0)
    }

    // MARK: Restoring

    /// A re-rooted tab looks like any tab at the root in the restored list, so the restore reports
    /// it separately. The stored path is the last place that folder is named (the first save writes
    /// the root over it), so it comes back beside the strip or not at all. A second tab whose folder
    /// is fine stops this passing by reporting every entry.
    @Test func aRestoreNamesTheFolderEachReRootedTabLost() {
        let entries = [PaneTabsStore.Entry(providerId: "iCloud", relativePath: "Taxes/2019"),
                       PaneTabsStore.Entry(providerId: "iCloud", relativePath: "Photos")]
        let restored = PaneTabsStore.restore(entries: entries, selected: 0,
                                             isKnownProvider: { _ in true },
                                             folderExists: { _, path in path != "Taxes/2019" })
        #expect(restored?.list.count == 2, "a tab whose folder is gone should be re-rooted, not dropped")
        #expect(restored?.lostFolders == ["Taxes/2019"],
                "the restore cannot say which folder the re-rooted tab lost")
        #expect(restored?.list.tabs.map(\.combinedRelativePath) == ["", "Photos"])
    }

    /// The report is in stored order, not the strip's. The strip is re-sorted so the pinned run is
    /// a prefix, so a pinned entry stored second comes back first in `list.tabs` and second in
    /// `lostFolders`. Stored order is right: the report names stored paths the strip no longer
    /// holds (its re-rooted tabs are all at `""`).
    @Test func theLostFolderReportIsInStoredOrderRatherThanStripOrder() {
        let entries = [PaneTabsStore.Entry(providerId: "iCloud", relativePath: "Taxes/2019"),
                       PaneTabsStore.Entry(providerId: "iCloud", relativePath: "Photos/2020",
                                           pinned: true)]
        let restored = PaneTabsStore.restore(entries: entries, selected: 0,
                                             isKnownProvider: { _ in true },
                                             folderExists: { _, _ in false })
        // The strip floats the pin to the front…
        #expect(restored?.list.tabs.map(\.isPinned) == [true, false],
                "the pinned run is no longer a prefix, so this fixture proves nothing about order")
        // …and the report does not follow it.
        #expect(restored?.lostFolders == ["Taxes/2019", "Photos/2020"],
                "the lost-folder report is not in the stored order its doc promises")
    }

    /// A tab stored at its source root has no folder to lose; reporting it would name `""` in a
    /// warning about a deleted folder.
    @Test func aTabStoredAtItsRootIsNotReportedAsLost() {
        let restored = PaneTabsStore.restore(
            entries: [PaneTabsStore.Entry(providerId: "iCloud", relativePath: "")],
            selected: 0,
            isKnownProvider: { _ in true },
            folderExists: { _, _ in false })
        #expect(restored?.lostFolders.isEmpty == true,
                "a pane sitting at its source root was warned about as a lost folder")
    }

    /// A tab dropped for its source is not also reported as a lost folder: it never reaches the
    /// folder check, and counting it twice would double-report a single loss.
    @Test func aTabDroppedForItsSourceIsNotAlsoReportedAsALostFolder() {
        let entries = [PaneTabsStore.Entry(providerId: "Gone", relativePath: "Taxes/2019"),
                       PaneTabsStore.Entry(providerId: "iCloud", relativePath: "Photos")]
        let restored = PaneTabsStore.restore(entries: entries, selected: 1,
                                             isKnownProvider: { $0 == "iCloud" },
                                             folderExists: { _, path in path == "Photos" })
        #expect(restored?.list.count == 1)
        #expect(restored?.lostFolders.isEmpty == true,
                "a tab dropped for its source was reported a second time as a lost folder")
    }

    @Test func aTabOnASourceThatIsGoneIsDropped() {
        let entries = [PaneTabsStore.Entry(providerId: "Dropbox", relativePath: "Photos"),
                       PaneTabsStore.Entry(providerId: "iCloud", relativePath: "Finance")]
        let restored = PaneTabsStore.restore(
            entries: entries, selected: 1,
            isKnownProvider: { $0 == "iCloud" },
            folderExists: { _, _ in true })
        #expect(restored?.list.count == 1)
        #expect(restored?.list.active.providerId == "iCloud")
        // The stored index pointed at entry 1, which is entry 0 of what survived.
        #expect(restored?.list.selectedIndex == 0)
    }

    /// The selection follows its own entry, not its index. Dropping an entry ahead of the selected
    /// one shifts it down; a clamp would silently land on a different folder.
    @Test func theSelectionFollowsItsOwnTabPastDroppedOnes() {
        let entries = [PaneTabsStore.Entry(providerId: "Gone", relativePath: "A"),
                       PaneTabsStore.Entry(providerId: "iCloud", relativePath: "B"),
                       PaneTabsStore.Entry(providerId: "iCloud", relativePath: "C"),
                       PaneTabsStore.Entry(providerId: "iCloud", relativePath: "D")]
        let restored = PaneTabsStore.restore(
            entries: entries, selected: 2,
            isKnownProvider: { $0 == "iCloud" },
            folderExists: { _, _ in true })
        #expect(restored?.list.tabs.map(\.relativePath) == ["B", "C", "D"])
        #expect(restored?.list.active.relativePath == "C", "the restored strip opened on the wrong tab")
    }

    /// And when the selected entry is itself dropped, the nearest survivor takes over rather than
    /// the strip refusing to restore.
    @Test func aDroppedSelectionFallsBackRatherThanLosingTheStrip() {
        let entries = [PaneTabsStore.Entry(providerId: "iCloud", relativePath: "A"),
                       PaneTabsStore.Entry(providerId: "Gone", relativePath: "B")]
        let restored = PaneTabsStore.restore(
            entries: entries, selected: 1,
            isKnownProvider: { $0 == "iCloud" },
            folderExists: { _, _ in true })
        #expect(restored?.list.count == 1)
        #expect(restored?.list.active.relativePath == "A")
    }

    @Test func everySourceGoneRestoresNothingAtAll() {
        let entries = [PaneTabsStore.Entry(providerId: "Dropbox", relativePath: "Photos")]
        let restored = PaneTabsStore.restore(entries: entries, selected: 0,
                                             isKnownProvider: { _ in false },
                                             folderExists: { _, _ in true })
        #expect(restored == nil)
    }

    // MARK: The column stack across a quit

    /// A drilled tab keeps its columns across a quit. The save joins scope and stack into one
    /// string, and restoring it all as scope would draw one column (`columnDirectories`). A
    /// non-empty scope and stack make all-as-scope fail every check, not just one.
    @Test func aDrilledColumnStackSurvivesTheRoundTrip() {
        let defaults = ScratchDefaults("PaneTabsStore-stack")
        let tab = PaneTab(providerId: "iCloud",
                          relativePath: "School",
                          browsePath: PaneBrowsePath(relativePath: "US/Daughter/Homework"))
        PaneTabsStore.save(tabs: [tab], selected: 0, isLeft: true, to: defaults)

        let loaded = PaneTabsStore.load(isLeft: true, from: defaults)
        let restored = PaneTabsStore.restore(entries: loaded?.entries ?? [], selected: 0,
                                             isKnownProvider: { _ in true },
                                             folderExists: { _, _ in true })
        #expect(restored?.list.active.relativePath == "School", "the scope came back wrong")
        #expect(restored?.list.active.browsePath.relativePath == "US/Daughter/Homework",
                "the column stack did not survive the quit")
        // What the user sees: the stack draws one column per component on top of the scope's own.
        #expect(restored?.list.active.browsePath.depth == 3)
        // …and the joined location is unchanged, so the header's path line reads as before the quit.
        #expect(restored?.list.active.combinedRelativePath == "School/US/Daughter/Homework")
    }

    /// The active tab's columns, end to end through the overlay: the entry is a stale snapshot at the
    /// root and the pane has walked three columns deep. The stored path is the combined one (scope
    /// plus stack), or the tab would reopen somewhere shallower.
    @Test func theActiveTabIsSavedWhereThePaneIsAndNotWhereItWasParked() {
        let defaults = ScratchDefaults("PaneTabsStore-activeOverlay")
        let strip = PaneTabList(tabs: [PaneTab(providerId: "iCloud"),
                                       PaneTab(providerId: "iCloud", relativePath: "Photos")],
                                selectedIndex: 0)
        let saving = strip.replacingActive(providerId: "iCloud",
                                           relativePath: "School",
                                           browsePath: PaneBrowsePath(relativePath: "US/Daughter/Homework"))
        PaneTabsStore.save(tabs: saving.tabs, selected: saving.selectedIndex, isLeft: true, to: defaults)

        let loaded = PaneTabsStore.load(isLeft: true, from: defaults)
        #expect(loaded?.entries.first?.relativePath == "School/US/Daughter/Homework",
                "the tab on screen was saved where it was parked, not where it is")
        #expect(loaded?.entries.first?.stackDepth == 3,
                "the active tab's columns were flattened on the way to disk")
        // The parked tab went to disk untouched, so this can't pass by writing the live pane over
        // the whole strip.
        #expect(loaded?.entries.last?.relativePath == "Photos")
        #expect(loaded?.selected == 0)
    }

    /// A tab never drilled into is all scope and no stack, and stays that way (the ⌘T / Open in New
    /// Tab case); a stack would claim columns the user never opened.
    @Test func aTabOpenedAtAFolderRatherThanDrilledComesBackWithNoStack() {
        let defaults = ScratchDefaults("PaneTabsStore-noStack")
        PaneTabsStore.save(tabs: [PaneTab(providerId: "iCloud", relativePath: "Finance/US")],
                           selected: 0, isLeft: true, to: defaults)
        let loaded = PaneTabsStore.load(isLeft: true, from: defaults)
        #expect(loaded?.entries.first?.stackDepth == 0)
        let restored = PaneTabsStore.restore(entries: loaded?.entries ?? [], selected: 0,
                                             isKnownProvider: { _ in true },
                                             folderExists: { _, _ in true })
        #expect(restored?.list.active.relativePath == "Finance/US")
        #expect(restored?.list.active.browsePath.isEmpty == true)
    }

    /// Old strip, new build: a strip with no `stackDepth` must decode, not take the user's tabs
    /// with it (as `aStripWrittenBeforePinningStillDecodes` covers for the pin). It restores as all
    /// scope, one column.
    @Test func aStripWrittenBeforeTheStackWasPersistedStillDecodes() {
        let defaults = ScratchDefaults("PaneTabsStore-legacyStack")
        defaults.set(#"[{"providerId":"iCloud","relativePath":"School/US/Daughter"}]"#,
                     forKey: PaneTabsStore.tabsKey)
        let loaded = PaneTabsStore.load(isLeft: true, from: defaults)
        #expect(loaded?.entries.count == 1, "a strip without the new key was rejected wholesale")
        #expect(loaded?.entries.first?.stackDepth == 0)
        let restored = PaneTabsStore.restore(entries: loaded?.entries ?? [], selected: 0,
                                             isKnownProvider: { _ in true },
                                             folderExists: { _, _ in true })
        #expect(restored?.list.active.relativePath == "School/US/Daughter")
        #expect(restored?.list.active.browsePath.isEmpty == true)
    }

    /// New strip, old build: the format adds a depth beside `relativePath` rather than redefining
    /// it as the scope, so a build that ignores `stackDepth` still lands on the folder the user
    /// left. Asserted on the encoded JSON, all that build would see.
    @Test func theStoredPathStaysTheWholeLocationSoAnOlderBuildLandsOnIt() {
        let defaults = ScratchDefaults("PaneTabsStore-forward")
        let tab = PaneTab(providerId: "iCloud",
                          relativePath: "School",
                          browsePath: PaneBrowsePath(relativePath: "US/Daughter/Homework"))
        PaneTabsStore.save(tabs: [tab], selected: 0, isLeft: true, to: defaults)
        let raw = defaults.string(forKey: PaneTabsStore.tabsKey) ?? ""
        #expect(raw.contains(#""relativePath":"School\/US\/Daughter\/Homework""#)
                    || raw.contains(#""relativePath":"School/US/Daughter/Homework""#),
                "the stored path is no longer the whole location: \(raw)")
    }

    /// `stackDepth` arrives from a file, so it is not trusted. The negative case matters: without
    /// the `max(0,` clamp a `-1` in a hand-edited strip traps in `dropLast` during launch's restore.
    /// The over-the-end half pins behaviour that `dropLast` and `suffix` already saturate.
    @Test func aStackDepthOutOfRangeIsClampedRatherThanTrusted() {
        let negative = PaneTabsStore.split(relativePath: "A/B", stackDepth: -3)
        #expect(negative.scope == "A/B", "a negative depth should leave the whole path as scope")
        #expect(negative.stack.isEmpty == true)

        let deep = PaneTabsStore.split(relativePath: "A/B", stackDepth: 9)
        #expect(deep.scope == "", "a depth past the end should make the whole path the stack")
        #expect(deep.stack.relativePath == "A/B")
    }

    /// Drilling straight down from the root leaves the scope empty and puts every component in the
    /// stack: `relativePath` is `""` while the tab is four columns deep. The launch restore's
    /// "fresh install?" check must not read that as the seed state; `isSeedState` owns the rule.
    @Test func aTabDrilledFromTheRootKeepsEveryColumnAndReportsAnEmptyScope() {
        let defaults = ScratchDefaults("PaneTabsStore-rootDrilled")
        let tab = PaneTab(providerId: "iCloud",
                          browsePath: PaneBrowsePath(relativePath: "School/US/Daughter/Homework"))
        PaneTabsStore.save(tabs: [tab], selected: 0, isLeft: true, to: defaults)
        #expect(PaneTabsStore.load(isLeft: true, from: defaults)?.entries.first?.stackDepth == 4)

        let restored = PaneTabsStore.restore(entries: PaneTabsStore.load(isLeft: true, from: defaults)?.entries ?? [],
                                             selected: 0,
                                             isKnownProvider: { _ in true },
                                             folderExists: { _, _ in true })
        #expect(restored?.list.active.relativePath == "", "a root drill should re-root nothing")
        #expect(restored?.list.active.browsePath.depth == 4, "the columns did not survive")
        #expect(restored?.list.active.combinedRelativePath == "School/US/Daughter/Homework")
        // The guard that reads this: an empty SCOPE must not read as "this tab is at the root".
        #expect(restored?.list.isSeedState == false,
                "a strip holding a four-column tab was mistaken for a fresh install and skipped")
    }

    /// The other side of that guard: the state it exists to detect.
    @Test func aLoneUnpinnedTabAtTheRootIsTheSeedState() {
        #expect(PaneTabList(single: PaneTab(providerId: "iCloud")).isSeedState == true)
        // …and each way out of it, separately.
        #expect(PaneTabList(single: PaneTab(providerId: "iCloud", relativePath: "Finance"))
                    .isSeedState == false, "a re-rooted tab is not the seed state")
        #expect(PaneTabList(single: PaneTab(providerId: "iCloud", isPinned: true))
                    .isSeedState == false, "a pinned tab is a decision the user made")
        #expect(PaneTabList(tabs: [PaneTab(providerId: "iCloud"), PaneTab(providerId: "iCloud")])
                    .isSeedState == false, "two tabs is not the seed state")
    }

    // MARK: Two panes, two strips

    /// One pane saving must leave the other's stored strip untouched, in both directions. A shared
    /// key, or a `keys(isLeft:)` that ignored its argument, would show only here.
    @Test func eachPanesStripIsStoredUnderItsOwnKey() {
        let defaults = ScratchDefaults("PaneTabsStore-sides")
        PaneTabsStore.save(tabs: [PaneTab(providerId: "iCloud", relativePath: "Left")],
                           selected: 0, isLeft: true, to: defaults)
        PaneTabsStore.save(tabs: [PaneTab(providerId: "Dropbox", relativePath: "Right")],
                           selected: 0, isLeft: false, to: defaults)

        #expect(PaneTabsStore.load(isLeft: true, from: defaults)?.entries.first?.relativePath == "Left")
        #expect(PaneTabsStore.load(isLeft: false, from: defaults)?.entries.first?.relativePath == "Right")
        // …and the providers too, since a crossed key would also cross the source.
        #expect(PaneTabsStore.load(isLeft: true, from: defaults)?.entries.first?.providerId == "iCloud")
        #expect(PaneTabsStore.load(isLeft: false, from: defaults)?.entries.first?.providerId == "Dropbox")

        // Re-saving one side must not disturb the other, which a read-modify-write of one shared
        // blob would break.
        PaneTabsStore.save(tabs: [PaneTab(providerId: "iCloud", relativePath: "LeftAgain")],
                           selected: 0, isLeft: true, to: defaults)
        #expect(PaneTabsStore.load(isLeft: false, from: defaults)?.entries.first?.relativePath == "Right",
                "saving the left strip overwrote the right one")
    }

    /// The left keeps the side-less key names, so no strip already on disk is orphaned. Pinned as
    /// literals: a tidy-up rename would silently lose every existing user's tabs.
    @Test func theLeftPaneKeepsTheOriginalKeyNames() {
        #expect(PaneTabsStore.tabsKey == "browseTabs")
        #expect(PaneTabsStore.selectedKey == "browseSelectedTab")
        #expect(PaneTabsStore.rightTabsKey != PaneTabsStore.tabsKey)
        #expect(PaneTabsStore.rightSelectedKey != PaneTabsStore.selectedKey)
    }

    /// A right pane never written reads as nothing stored, so the caller falls through to the
    /// `lastRightFocusPath` restore rather than seeding an empty strip over it (only the left key
    /// exists).
    @Test func aRightStripThatWasNeverWrittenReadsAsNothingStored() {
        let defaults = ScratchDefaults("PaneTabsStore-rightMissing")
        PaneTabsStore.save(tabs: [PaneTab(providerId: "iCloud", relativePath: "Left")],
                           selected: 0, isLeft: true, to: defaults)
        #expect(PaneTabsStore.load(isLeft: false, from: defaults) == nil,
                "an unwritten right strip must not read as an empty one")
        #expect(PaneTabsStore.load(isLeft: true, from: defaults) != nil)
    }

    /// Each side's selected index is its own. Stored under one key they would fight, and a two-tab
    /// right pane would follow the left pane's selection around.
    @Test func eachPaneKeepsItsOwnSelectedIndex() {
        let defaults = ScratchDefaults("PaneTabsStore-sideSelection")
        let three = [PaneTab(providerId: "iCloud", relativePath: "A"),
                     PaneTab(providerId: "iCloud", relativePath: "B"),
                     PaneTab(providerId: "iCloud", relativePath: "C")]
        PaneTabsStore.save(tabs: three, selected: 0, isLeft: true, to: defaults)
        PaneTabsStore.save(tabs: three, selected: 2, isLeft: false, to: defaults)
        #expect(PaneTabsStore.load(isLeft: true, from: defaults)?.selected == 0)
        #expect(PaneTabsStore.load(isLeft: false, from: defaults)?.selected == 2)
    }

    /// A tab whose folder is gone comes back at the root rather than at nothing, and loses its
    /// stack with the scope: the components name folders under a path that no longer resolves,
    /// and would point New Folder and paste at a path that doesn't exist.
    @Test func aTabWhoseFolderIsGoneLosesItsStackToo() {
        let entries = [PaneTabsStore.Entry(providerId: "iCloud",
                                           relativePath: "School/US/Daughter/Homework", stackDepth: 3)]
        let restored = PaneTabsStore.restore(entries: entries, selected: 0,
                                             isKnownProvider: { _ in true },
                                             folderExists: { _, _ in false })
        #expect(restored?.list.count == 1)
        #expect(restored?.list.active.relativePath == "")
        #expect(restored?.list.active.browsePath.isEmpty == true)
    }
    /// The count "Close Other Tabs" acts on, which is not `count - 1`: pins survive it. One rule,
    /// because the host logs this number and the strip gates its menu item on it.
    @Test func closableOthersCountsWhatTheGestureWouldActuallyClose() {
        let a = PaneTab(providerId: "iCloud", relativePath: "A")
        let b = PaneTab(providerId: "iCloud", relativePath: "B", isPinned: true)
        let c = PaneTab(providerId: "iCloud", relativePath: "C", isPinned: true)
        let d = PaneTab(providerId: "iCloud", relativePath: "D")

        #expect(PaneTabList(tabs: [b, c, a]).closableOthers(keeping: a.id) == 0,
                "a strip whose every other tab is pinned reported something to close")
        #expect(PaneTabList(tabs: [b, a, d]).closableOthers(keeping: a.id) == 1)
        #expect(PaneTabList(single: a).closableOthers(keeping: a.id) == 0, "a lone tab counted itself")
        // A pinned tab's own menu still closes the unpinned others.
        #expect(PaneTabList(tabs: [b, c, d]).closableOthers(keeping: b.id) == 1)
    }
}

/// Where a newly opened tab sits: its scope and column stack, cut the way the pane's are, so its
/// columns survive a restart.
@MainActor
@Suite struct PaneTabOpeningTests {

    /// ⌘T from a pane four columns deep gives a tab four columns deep. Passing
    /// `combinedRelativePath` as the scope with no stack would flatten the tab at creation, and
    /// save and restore would keep it flat.
    @Test func openingHereKeepsThePanesOwnColumnCut() {
        let stack = PaneBrowsePath(components: ["Health", "Medical", "Included Health", "Expert Opinions"])
        let cut = PaneTabOpening.location(of: "Health/Medical/Included Health/Expert Opinions",
                                          openedFromScope: "")
        #expect(cut.scope == "", "the whole location became scope, which draws exactly one column")
        #expect(cut.stack == stack)
        #expect(cut.stack.depth == 4, "a tab opened from four open columns came back with none")
    }

    /// With the pane's scope not the root: opening here, scope deep and a shallow stack on top,
    /// shows the cut is the pane's, not a fixed one; Open in New Tab on a folder under the pane
    /// keeps the scope and puts the rest in the stack, so the new tab has the ancestor columns.
    @Test(arguments: [("Health/Medical/Included Health", ["Medical", "Included Health"]),
                      ("Health/Medical/Included Health/Expert Opinions", ["Medical", "Included Health", "Expert Opinions"])])
    func openingUnderAScopeThatIsNotTheRootKeepsTheScope(target: String, stack: [String]) {
        let cut = PaneTabOpening.location(of: target, openedFromScope: "Health")
        #expect(cut.scope == "Health")
        #expect(cut.stack.components == stack)
    }

    /// A target outside the pane's scope is all scope, no stack; the components would otherwise
    /// name folders under a path that doesn't contain them.
    @Test func aTargetOutsideTheScopeIsAllScope() {
        let cut = PaneTabOpening.location(of: "Legal/US", openedFromScope: "Family")
        #expect(cut.scope == "Legal/US")
        #expect(cut.stack.isEmpty)
    }

    /// A pane at its root opening its root is the seed state, and must stay it, or the launch
    /// restore's `isSeedState` skip stops recognising a fresh install.
    @Test func openingTheRootFromTheRootIsStillTheRoot() {
        let cut = PaneTabOpening.location(of: "", openedFromScope: "")
        #expect(cut.scope == "")
        #expect(cut.stack.isEmpty)
    }
}

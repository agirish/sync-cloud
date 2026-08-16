import Testing
import Foundation
@testable import Sync

/// The tab list's own rules, which are the ones a user would notice within a second of using the
/// strip: what closing a tab selects next, what a duplicate carries, and — the one that is not
/// obvious — that the ACTIVE entry is a stale snapshot until something parks it.
///
/// The last of those is why `captureActive` exists and why every verb in
/// `FileSyncManager+PaneTabs` calls it before it does anything else. A test suite that only ever
/// asked "is the right tab selected" would pass with every capture removed and the feature would
/// silently forget where each tab was.
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

    // MARK: Closing

    /// Finder's rule, and the one that lets you close several in a row without moving the pointer.
    @Test func closingTheActiveTabSelectsTheOneToItsRight() {
        var tabs = list(["A", "B", "C"], selected: 1)
        let closed = tabs.close(at: 1)
        #expect(closed)
        #expect(tabs.active.relativePath == "C")
    }

    @Test func closingTheTrailingTabFallsBackToItsLeft() {
        var tabs = list(["A", "B", "C"], selected: 2)
        let closed = tabs.close(at: 2)
        #expect(closed)
        #expect(tabs.active.relativePath == "B")
    }

    /// The case that silently mis-selects if the index is not adjusted: closing something to the
    /// LEFT of the active tab keeps the *same tab* live, at a lower index.
    @Test func closingAParkedTabToTheLeftKeepsTheSameTabActive() {
        var tabs = list(["A", "B", "C"], selected: 2)
        let closed = tabs.close(at: 0)
        #expect(closed)
        #expect(tabs.active.relativePath == "C")
        #expect(tabs.tabs.map(\.relativePath) == ["B", "C"])
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
        // A fresh id: Close Other Tabs pushes several at once, so a reopened tab can collide with
        // one still on the stack — and two chips sharing an id is a `ForEach` collision.
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
        // The NEWEST survive — reopen is a stack, so dropping from the front is what keeps it one.
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

    /// **Pinned tabs survive Close Other Tabs** — that is most of what pinning is for.
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

    /// Dragging a tab moves the chip, **not** which tab you are looking at.
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

    /// At the root there is no folder to name, and an unnamed chip is the one tab you cannot tell
    /// from another — which is exactly the state ⌘T creates.
    @Test func aTabAtTheRootWearsItsSourcesName() {
        #expect(PaneTab(providerId: "iCloud").displayName(providerName: "iCloud Drive") == "iCloud Drive")
    }

    /// **The two positions a tab carries have to agree.** `applyTab` publishes the pane's path out
    /// of the tab's HISTORY, so a constructor that seeded a history disagreeing with `relativePath`
    /// would land the pane somewhere the chip does not name. Every way of making a tab is checked
    /// here, because the invariant is what lets `applyTab` pick either one.
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

    /// A tab seeded at a folder must be able to walk back OUT of it, or Back is dead in a restored
    /// tab and the pane has a location with no way home.
    @Test func aSeededTabCanGoBackToItsRoot() {
        let seeded = PaneTab(providerId: "iCloud", relativePath: "Finance/US")
        #expect(seeded.history.current == "Finance/US")
        #expect(seeded.history.canGoBack)
        var history = seeded.history
        history.goBack()
        #expect(history.current == "")
    }
}

/// What survives a quit — and, as much, what deliberately does not.
@Suite struct PaneTabsStoreTests {

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

    /// The stored path is the COMBINED one — scope plus column stack — because that is the folder
    /// that was on screen, and restoring only the scope would reopen the tab somewhere shallower.
    @Test func theStoredPathIsWhereTheTabActuallyWas() {
        let defaults = ScratchDefaults("PaneTabsStore-combined")
        let deep = PaneTab(providerId: "iCloud", relativePath: "Finance",
                           browsePath: PaneBrowsePath(relativePath: "US/2024"))
        PaneTabsStore.save(tabs: [deep], selected: 0, isLeft: true, to: defaults)
        #expect(PaneTabsStore.load(isLeft: true, from: defaults)?.entries.first?.relativePath == "Finance/US/2024")
    }

    /// No key at all is what tells the caller to seed from the pane's own stored provider, so it
    /// must be distinguishable from an empty strip — which cannot exist.
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
        #expect(restored?.tabs.map(\.isPinned) == [true, false])
        #expect(restored?.pinnedCount == 1)
    }

    /// **A strip written before pinning existed still decodes.** `Codable` rejects the whole file
    /// on a missing key, and that file is the user's tabs — they would vanish on the first launch
    /// after the upgrade, with nothing to say why.
    /// A stored strip that interleaves pinned and unpinned tabs comes back partitioned. The file
    /// is not a promise — every rule in `PaneTabList` reads the pinned run as a PREFIX, and a list
    /// that broke it would have `pinnedCount` and `pinned` disagreeing about itself.
    @Test func aStoredStripThatBreaksThePartitionIsRepairedOnTheWayIn() {
        let entries = [PaneTabsStore.Entry(providerId: "iCloud", relativePath: "A"),
                       PaneTabsStore.Entry(providerId: "iCloud", relativePath: "B", pinned: true),
                       PaneTabsStore.Entry(providerId: "iCloud", relativePath: "C"),
                       PaneTabsStore.Entry(providerId: "iCloud", relativePath: "D", pinned: true)]
        let restored = PaneTabsStore.restore(entries: entries, selected: 2,
                                             isKnownProvider: { _ in true },
                                             folderExists: { _, _ in true })
        #expect(restored?.tabs.map(\.relativePath) == ["B", "D", "A", "C"],
                "the restored strip interleaves pinned and unpinned tabs")
        #expect(restored?.pinnedCount == 2)
        // …and the tab that was selected is still the one selected, wherever the sort put it.
        #expect(restored?.active.relativePath == "C")
    }

    @Test func aStripWrittenBeforePinningStillDecodes() {
        let defaults = ScratchDefaults("PaneTabsStore-legacy")
        defaults.set(#"[{"providerId":"iCloud","relativePath":"Finance"}]"#, forKey: PaneTabsStore.tabsKey)
        let loaded = PaneTabsStore.load(isLeft: true, from: defaults)
        #expect(loaded?.entries.count == 1)
        #expect(loaded?.entries.first?.pinned == false)
    }

    @Test func nothingStoredReadsAsNothingRatherThanAsAnEmptyStrip() {
        let defaults = ScratchDefaults("PaneTabsStore-empty")
        #expect(PaneTabsStore.load(isLeft: true, from: defaults) == nil)
    }

    @Test func aCorruptValueReadsAsNothingStored() {
        let defaults = ScratchDefaults("PaneTabsStore-corrupt")
        defaults.set("{not json", forKey: PaneTabsStore.tabsKey)
        #expect(PaneTabsStore.load(isLeft: true, from: defaults) == nil)
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

    @Test func aTabWhoseFolderIsGoneComesBackAtTheRootRatherThanAtNothing() {
        let entries = [PaneTabsStore.Entry(providerId: "iCloud", relativePath: "Finance/US/2024")]
        let restored = PaneTabsStore.restore(
            entries: entries, selected: 0,
            isKnownProvider: { _ in true },
            folderExists: { _, _ in false })
        #expect(restored?.count == 1)
        #expect(restored?.active.relativePath == "")
    }

    @Test func aTabOnASourceThatIsGoneIsDropped() {
        let entries = [PaneTabsStore.Entry(providerId: "Dropbox", relativePath: "Photos"),
                       PaneTabsStore.Entry(providerId: "iCloud", relativePath: "Finance")]
        let restored = PaneTabsStore.restore(
            entries: entries, selected: 1,
            isKnownProvider: { $0 == "iCloud" },
            folderExists: { _, _ in true })
        #expect(restored?.count == 1)
        #expect(restored?.active.providerId == "iCloud")
        // The stored index pointed at entry 1, which is entry 0 of what survived.
        #expect(restored?.selectedIndex == 0)
    }

    /// **The selection follows its own entry, not its index.** Dropping an entry ahead of the
    /// selected one shifts it down; a clamp would land on a different folder and say nothing.
    @Test func theSelectionFollowsItsOwnTabPastDroppedOnes() {
        let entries = [PaneTabsStore.Entry(providerId: "Gone", relativePath: "A"),
                       PaneTabsStore.Entry(providerId: "iCloud", relativePath: "B"),
                       PaneTabsStore.Entry(providerId: "iCloud", relativePath: "C"),
                       PaneTabsStore.Entry(providerId: "iCloud", relativePath: "D")]
        let restored = PaneTabsStore.restore(
            entries: entries, selected: 2,
            isKnownProvider: { $0 == "iCloud" },
            folderExists: { _, _ in true })
        #expect(restored?.tabs.map(\.relativePath) == ["B", "C", "D"])
        #expect(restored?.active.relativePath == "C", "the restored strip opened on the wrong tab")
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
        #expect(restored?.count == 1)
        #expect(restored?.active.relativePath == "A")
    }

    @Test func everySourceGoneRestoresNothingAtAll() {
        let entries = [PaneTabsStore.Entry(providerId: "Dropbox", relativePath: "Photos")]
        let restored = PaneTabsStore.restore(entries: entries, selected: 0,
                                             isKnownProvider: { _ in false },
                                             folderExists: { _, _ in true })
        #expect(restored == nil)
    }

    // MARK: The column stack across a quit

    /// **The regression this section exists for.** A tab drilled four columns deep came back as one
    /// full-width column: the save joined scope and stack into one string and the restore handed the
    /// whole thing back as scope, and scope draws exactly one column (`columnDirectories`).
    ///
    /// The fixture is deliberately built so the bug and the fix give *different* answers on every
    /// line: a non-empty scope with a non-empty stack, so restoring everything-as-scope (the old
    /// behaviour) fails the scope check, the stack check and the depth check rather than passing one
    /// of them by coincidence.
    @Test func aDrilledColumnStackSurvivesTheRoundTrip() {
        let defaults = ScratchDefaults("PaneTabsStore-stack")
        let tab = PaneTab(providerId: "iCloud",
                          relativePath: "School",
                          browsePath: PaneBrowsePath(relativePath: "US/Aditi/Homework"))
        PaneTabsStore.save(tabs: [tab], selected: 0, isLeft: true, to: defaults)

        let loaded = PaneTabsStore.load(isLeft: true, from: defaults)
        let restored = PaneTabsStore.restore(entries: loaded?.entries ?? [], selected: 0,
                                             isKnownProvider: { _ in true },
                                             folderExists: { _, _ in true })
        #expect(restored?.active.relativePath == "School", "the scope came back wrong")
        #expect(restored?.active.browsePath.relativePath == "US/Aditi/Homework",
                "the column stack did not survive the quit")
        // What the user actually sees, and the only assertion that speaks in columns: the stack
        // draws one column per component on top of the scope's own.
        #expect(restored?.active.browsePath.depth == 3)
        // …and the joined location is unchanged, which is what keeps the header's path line reading
        // the same string it did before the quit.
        #expect(restored?.active.combinedRelativePath == "School/US/Aditi/Homework")
    }

    /// A tab that was never drilled into is all scope and no stack, and must stay that way — this is
    /// the ⌘T / Open in New Tab case, and restoring it with a stack would claim columns the user
    /// never opened.
    @Test func aTabOpenedAtAFolderRatherThanDrilledComesBackWithNoStack() {
        let defaults = ScratchDefaults("PaneTabsStore-noStack")
        PaneTabsStore.save(tabs: [PaneTab(providerId: "iCloud", relativePath: "Finance/US")],
                           selected: 0, isLeft: true, to: defaults)
        let loaded = PaneTabsStore.load(isLeft: true, from: defaults)
        #expect(loaded?.entries.first?.stackDepth == 0)
        let restored = PaneTabsStore.restore(entries: loaded?.entries ?? [], selected: 0,
                                             isKnownProvider: { _ in true },
                                             folderExists: { _, _ in true })
        #expect(restored?.active.relativePath == "Finance/US")
        #expect(restored?.active.browsePath.isEmpty == true)
    }

    /// **Old strip, new build.** A strip written before the stack was persisted has no `stackDepth`,
    /// and must decode rather than take the user's whole set of tabs with it — the same hazard
    /// `aStripWrittenBeforePinningStillDecodes` covers for the pin. It restores the way it always
    /// did: all scope, one column.
    @Test func aStripWrittenBeforeTheStackWasPersistedStillDecodes() {
        let defaults = ScratchDefaults("PaneTabsStore-legacyStack")
        defaults.set(#"[{"providerId":"iCloud","relativePath":"School/US/Aditi"}]"#,
                     forKey: PaneTabsStore.tabsKey)
        let loaded = PaneTabsStore.load(isLeft: true, from: defaults)
        #expect(loaded?.entries.count == 1, "a strip without the new key was rejected wholesale")
        #expect(loaded?.entries.first?.stackDepth == 0)
        let restored = PaneTabsStore.restore(entries: loaded?.entries ?? [], selected: 0,
                                             isKnownProvider: { _ in true },
                                             folderExists: { _, _ in true })
        #expect(restored?.active.relativePath == "School/US/Aditi")
        #expect(restored?.active.browsePath.isEmpty == true)
    }

    /// **New strip, old build.** The other direction, and the reason the format adds a depth beside
    /// `relativePath` instead of redefining it as the scope alone: a build that has never heard of
    /// `stackDepth` reads `relativePath` and must still land on the folder the user left, not on an
    /// ancestor of it. Asserted on the encoded JSON, which is the only thing that build would see.
    @Test func theStoredPathStaysTheWholeLocationSoAnOlderBuildLandsOnIt() {
        let defaults = ScratchDefaults("PaneTabsStore-forward")
        let tab = PaneTab(providerId: "iCloud",
                          relativePath: "School",
                          browsePath: PaneBrowsePath(relativePath: "US/Aditi/Homework"))
        PaneTabsStore.save(tabs: [tab], selected: 0, isLeft: true, to: defaults)
        let raw = defaults.string(forKey: PaneTabsStore.tabsKey) ?? ""
        #expect(raw.contains(#""relativePath":"School\/US\/Aditi\/Homework""#)
                    || raw.contains(#""relativePath":"School/US/Aditi/Homework""#),
                "the stored path is no longer the whole location: \(raw)")
    }

    /// `stackDepth` arrives from a file, so it is not trusted.
    ///
    /// **The negative case is the one with teeth**, and the two are worth telling apart: removing
    /// `max(0,` from the clamp makes this test die on a `dropLast` trap rather than fail — a `-1` in
    /// a hand-edited strip crashes the app inside launch's restore, before a window. Removing the
    /// upper clamp changes nothing at all, because `dropLast` and `suffix` already saturate; the
    /// over-the-end half below pins the resulting behaviour but guards no code of ours.
    @Test func aStackDepthOutOfRangeIsClampedRatherThanTrusted() {
        let negative = PaneTabsStore.split(relativePath: "A/B", stackDepth: -3)
        #expect(negative.scope == "A/B", "a negative depth should leave the whole path as scope")
        #expect(negative.stack.isEmpty == true)

        let deep = PaneTabsStore.split(relativePath: "A/B", stackDepth: 9)
        #expect(deep.scope == "", "a depth past the end should make the whole path the stack")
        #expect(deep.stack.relativePath == "A/B")
    }

    /// **The user's actual case, and the fixture whose absence hid a regression.** Drilling straight
    /// down from the root — no re-rooting — leaves the scope EMPTY and puts every component in the
    /// stack. Every other fixture here has a non-empty scope, so none of them exercised the shape
    /// where `relativePath` comes back `""` while the tab is four columns deep.
    ///
    /// That shape is what broke `restoreBrowseTabs`: its "is this the fresh-install strip?" guard
    /// read `relativePath`, saw `""`, and skipped the whole restore. `isSeedState` now owns the
    /// rule and the two tests below pin it.
    @Test func aTabDrilledFromTheRootKeepsEveryColumnAndReportsAnEmptyScope() {
        let defaults = ScratchDefaults("PaneTabsStore-rootDrilled")
        let tab = PaneTab(providerId: "iCloud",
                          browsePath: PaneBrowsePath(relativePath: "School/US/Aditi/Homework"))
        PaneTabsStore.save(tabs: [tab], selected: 0, isLeft: true, to: defaults)
        #expect(PaneTabsStore.load(isLeft: true, from: defaults)?.entries.first?.stackDepth == 4)

        let restored = PaneTabsStore.restore(entries: PaneTabsStore.load(isLeft: true, from: defaults)?.entries ?? [],
                                             selected: 0,
                                             isKnownProvider: { _ in true },
                                             folderExists: { _, _ in true })
        #expect(restored?.active.relativePath == "", "a root drill should re-root nothing")
        #expect(restored?.active.browsePath.depth == 4, "the columns did not survive")
        #expect(restored?.active.combinedRelativePath == "School/US/Aditi/Homework")
        // The guard that reads this: an empty SCOPE must not read as "this tab is at the root".
        #expect(restored?.isSeedState == false,
                "a strip holding a four-column tab was mistaken for a fresh install and skipped")
    }

    /// The other direction of that guard — the state it genuinely exists to detect, so the rule is
    /// pinned from both sides rather than only where it must say no.
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

    /// **The whole risk in persisting a second strip is the two writing over each other.** One pane
    /// saving must leave the other's stored strip untouched, in both directions — a shared key, or
    /// a `keys(isLeft:)` that ignored its argument, would show up here and nowhere else.
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

        // Re-saving one side must not disturb the other — the case a read-modify-write of a single
        // shared blob would break, which is why the two keys are separate.
        PaneTabsStore.save(tabs: [PaneTab(providerId: "iCloud", relativePath: "LeftAgain")],
                           selected: 0, isLeft: true, to: defaults)
        #expect(PaneTabsStore.load(isLeft: false, from: defaults)?.entries.first?.relativePath == "Right",
                "saving the left strip overwrote the right one")
    }

    /// The left keeps the original, side-less key names so no strip already on disk is orphaned by
    /// the right pane arriving. Pinned as a literal because that is exactly the kind of thing a
    /// later tidy-up renames for consistency, silently losing every existing user's tabs.
    @Test func theLeftPaneKeepsTheOriginalKeyNames() {
        #expect(PaneTabsStore.tabsKey == "browseTabs")
        #expect(PaneTabsStore.selectedKey == "browseSelectedTab")
        #expect(PaneTabsStore.rightTabsKey != PaneTabsStore.tabsKey)
        #expect(PaneTabsStore.rightSelectedKey != PaneTabsStore.selectedKey)
    }

    /// A right pane that has never been written reads as nothing stored, so the caller falls through
    /// to the older `lastRightFocusPath` restore rather than seeding an empty strip over it. This is
    /// the first-launch-after-upgrade path, where only the left key exists.
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

    /// A tab whose folder is gone loses the stack along with the scope. The components name folders
    /// *under* a path that no longer resolves, so there is nothing for them to be relative to — a
    /// stack kept here would point the pane's New Folder and paste at a path that does not exist.
    @Test func aTabWhoseFolderIsGoneLosesItsStackToo() {
        let entries = [PaneTabsStore.Entry(providerId: "iCloud",
                                           relativePath: "School/US/Aditi/Homework", stackDepth: 3)]
        let restored = PaneTabsStore.restore(entries: entries, selected: 0,
                                             isKnownProvider: { _ in true },
                                             folderExists: { _, _ in false })
        #expect(restored?.active.relativePath == "")
        #expect(restored?.active.browsePath.isEmpty == true)
    }
    /// The count "Close Other Tabs" acts on, which is **not** `count - 1`: pins survive it, so a
    /// strip of three whose other two are pinned has nothing to close. One rule, because the host
    /// logs this number and the strip gates its menu item on it — two spellings is how the menu and
    /// the log come to disagree about the same click.
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

/// Where a newly opened tab sits — the half that made "the columns are collapsed again after a
/// restart" a creation bug rather than a persistence one.
@MainActor
@Suite struct PaneTabOpeningTests {

    /// **⌘T from a pane four columns deep gives a tab four columns deep.** It gave one full-width
    /// column: `openTabHere` handed `combinedRelativePath` over as the SCOPE with no stack, so the
    /// tab was flattened the moment it was created and every save/restore round-tripped that
    /// flattening perfectly. His stored strip, verbatim:
    /// `Health/Medical/Included Health/Expert Opinions` at `stackDepth` 0.
    @Test func openingHereKeepsThePanesOwnColumnCut() {
        let stack = PaneBrowsePath(components: ["Health", "Medical", "Included Health", "Expert Opinions"])
        let cut = PaneTabOpening.location(of: "Health/Medical/Included Health/Expert Opinions",
                                          openedFromScope: "")
        #expect(cut.scope == "", "the whole location became scope, which draws exactly one column")
        #expect(cut.stack == stack)
        #expect(cut.stack.depth == 4, "a tab opened from four open columns came back with none")
    }

    /// The same when the pane's location is split the other way — scope deep, a shallow stack on
    /// top. The cut is the PANE's, not a fixed one.
    @Test func openingHereHonoursAScopeThatIsNotTheRoot() {
        let cut = PaneTabOpening.location(of: "Health/Medical/Included Health",
                                          openedFromScope: "Health")
        #expect(cut.scope == "Health")
        #expect(cut.stack.components == ["Medical", "Included Health"])
    }

    /// Open in New Tab on a folder UNDER the pane keeps the scope and puts the rest in the stack,
    /// so the new tab has the ancestor columns a column browser is for.
    @Test func openingAFolderUnderThePaneGivesItTheAncestorColumns() {
        let cut = PaneTabOpening.location(of: "Health/Medical/Included Health/Expert Opinions",
                                          openedFromScope: "Health")
        #expect(cut.scope == "Health")
        #expect(cut.stack.components == ["Medical", "Included Health", "Expert Opinions"])
    }

    /// A target that is not under the pane's scope keeps the old answer — all scope, no stack.
    /// The components would otherwise name folders under a path that does not contain them.
    @Test func aTargetOutsideTheScopeIsAllScope() {
        let cut = PaneTabOpening.location(of: "Legal/US", openedFromScope: "Family")
        #expect(cut.scope == "Legal/US")
        #expect(cut.stack.isEmpty)
    }

    /// A pane at its root opening its root is the seed state, and must stay it — otherwise the
    /// launch restore's `isSeedState` skip stops recognising a fresh install.
    @Test func openingTheRootFromTheRootIsStillTheRoot() {
        let cut = PaneTabOpening.location(of: "", openedFromScope: "")
        #expect(cut.scope == "")
        #expect(cut.stack.isEmpty)
    }

    /// **The round trip, end to end**: open a tab from a deep pane, save it, restore it — the
    /// columns survive. Both halves had to be right for this; the restore already was.
    @Test func aTabOpenedFromOpenColumnsSurvivesAQuit() throws {
        let cut = PaneTabOpening.location(of: "Health/Medical/Included Health/Expert Opinions",
                                          openedFromScope: "")
        let opened = PaneTab(providerId: "iCloud", relativePath: cut.scope, browsePath: cut.stack)
        let entry = PaneTabsStore.Entry(providerId: opened.providerId,
                                        relativePath: opened.combinedRelativePath,
                                        stackDepth: opened.browsePath.depth)
        #expect(entry.stackDepth == 4, "the strip on disk records no columns to bring back")
        let restored = try #require(PaneTabsStore.restore(entries: [entry], selected: 0,
                                                          isKnownProvider: { _ in true },
                                                          folderExists: { _, _ in true }))
        #expect(restored.active.browsePath.depth == 4)
        #expect(restored.active.combinedRelativePath == "Health/Medical/Included Health/Expert Opinions")
    }
}

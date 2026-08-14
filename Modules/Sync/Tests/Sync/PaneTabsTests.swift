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
        PaneTabsStore.save(tabs: tabs, selected: 1, to: defaults)

        let loaded = PaneTabsStore.load(from: defaults)
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
        PaneTabsStore.save(tabs: [deep], selected: 0, to: defaults)
        #expect(PaneTabsStore.load(from: defaults)?.entries.first?.relativePath == "Finance/US/2024")
    }

    /// No key at all is what tells the caller to seed from the pane's own stored provider, so it
    /// must be distinguishable from an empty strip — which cannot exist.
    @Test func nothingStoredReadsAsNothingRatherThanAsAnEmptyStrip() {
        let defaults = ScratchDefaults("PaneTabsStore-empty")
        #expect(PaneTabsStore.load(from: defaults) == nil)
    }

    @Test func aCorruptValueReadsAsNothingStored() {
        let defaults = ScratchDefaults("PaneTabsStore-corrupt")
        defaults.set("{not json", forKey: PaneTabsStore.tabsKey)
        #expect(PaneTabsStore.load(from: defaults) == nil)
    }

    /// A stored index past the end of a shortened list would crash `PaneTabList`'s precondition if
    /// it were trusted; both the load and the restore clamp it.
    @Test func aSelectionPastTheEndIsClamped() {
        let defaults = ScratchDefaults("PaneTabsStore-clamp")
        PaneTabsStore.save(tabs: [PaneTab(providerId: "iCloud")], selected: 0, to: defaults)
        defaults.set(7, forKey: PaneTabsStore.selectedKey)
        #expect(PaneTabsStore.load(from: defaults)?.selected == 0)
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
}

import Testing
import Foundation
@testable import Sync

/// Switching tabs against a real `FileSyncManager`, which is where the feature's one non-obvious
/// rule lives: **the active tab is the pane**, so a switch has to park the live position before it
/// applies the incoming one.
///
/// Every test here would still pass with `captureActive` deleted if it only checked where the pane
/// LANDS. So each one walks away and comes back: the second half of every assertion is that the
/// tab you left is still where you left it, which is the half that fails when a capture goes
/// missing.
@Suite struct PaneTabSwitchingTests {

    @MainActor
    private func manager(tabs: [PaneTab], isLeft: Bool = true) -> FileSyncManager {
        let manager = FileSyncManager(fileManager: MockFileManager())
        manager.setPaneTabs(PaneTabList(tabs: tabs), isLeft: isLeft)
        return manager
    }

    @MainActor
    @Test func switchingParksWhereYouWereAndRestoresItWhenYouComeBack() async throws {
        let manager = manager(tabs: [PaneTab(providerId: "iCloud"), PaneTab(providerId: "iCloud")])
        let first = manager.leftPaneTabs.tabs[0].id
        let second = manager.leftPaneTabs.tabs[1].id

        // Walk the live pane somewhere inside the first tab.
        manager.focusOn(relativePath: "Finance/US", isLeft: true)
        manager.selectedLeftPaths = ["/r/Finance/US/2024.pdf"]

        let arrived = manager.switchTab(to: second, isLeft: true, currentProviderId: "iCloud")
        #expect(arrived?.id == second)
        // The second tab has been nowhere, so the pane is at its root with nothing selected.
        #expect(manager.leftRelativePath == "")
        #expect(manager.selectedLeftPaths.isEmpty)

        let back = manager.switchTab(to: first, isLeft: true, currentProviderId: "iCloud")
        #expect(back?.id == first)
        #expect(manager.leftRelativePath == "Finance/US")
        #expect(manager.selectedLeftPaths == ["/r/Finance/US/2024.pdf"])
    }

    /// The column stack is a second position with its own meaning (`PaneBrowsePath`), and a tab
    /// that restored only the scope would come back one or more columns shallower.
    @MainActor
    @Test func aTabRemembersItsColumnStackAsWellAsItsScope() async throws {
        let manager = manager(tabs: [PaneTab(providerId: "iCloud"), PaneTab(providerId: "iCloud")])
        let first = manager.leftPaneTabs.tabs[0].id
        let second = manager.leftPaneTabs.tabs[1].id

        manager.setBrowsePath(isLeft: true, PaneBrowsePath(relativePath: "Photos/2019"))
        _ = manager.switchTab(to: second, isLeft: true, currentProviderId: "iCloud")
        #expect(manager.leftBrowsePath.relativePath == "")

        _ = manager.switchTab(to: first, isLeft: true, currentProviderId: "iCloud")
        #expect(manager.leftBrowsePath.relativePath == "Photos/2019")
    }

    /// Back in a tab walks that tab's own history. Two tabs sharing one history would let Back
    /// step into a folder this tab has never been in — a move you could not explain from anything
    /// on screen.
    @MainActor
    @Test func historyIsPerTab() async throws {
        let manager = manager(tabs: [PaneTab(providerId: "iCloud"), PaneTab(providerId: "iCloud")])
        let second = manager.leftPaneTabs.tabs[1].id

        manager.focusOn(relativePath: "A", isLeft: true)
        manager.focusOn(relativePath: "A/B", isLeft: true)
        #expect(manager.canGoBack(isLeft: true))

        _ = manager.switchTab(to: second, isLeft: true, currentProviderId: "iCloud")
        // A tab that has been nowhere has nowhere to go back to.
        #expect(!manager.canGoBack(isLeft: true))
    }

    @MainActor
    @Test func switchingToTheTabAlreadyLiveChangesNothing() async throws {
        let manager = manager(tabs: [PaneTab(providerId: "iCloud"), PaneTab(providerId: "iCloud")])
        let first = manager.leftPaneTabs.tabs[0].id
        manager.focusOn(relativePath: "Finance", isLeft: true)

        #expect(manager.switchTab(to: first, isLeft: true, currentProviderId: "iCloud") == nil)
        #expect(manager.leftRelativePath == "Finance")
    }

    // MARK: Opening and closing

    @MainActor
    @Test func openingATabMovesThePaneToItAndParksTheOldOne() async throws {
        let manager = manager(tabs: [PaneTab(providerId: "iCloud")])
        manager.focusOn(relativePath: "Finance", isLeft: true)
        let first = manager.leftPaneTabs.active.id

        let opened = manager.openTab(PaneTab(providerId: "iCloud", relativePath: "Photos"),
                                     isLeft: true, currentProviderId: "iCloud")
        #expect(manager.leftPaneTabs.count == 2)
        #expect(manager.leftRelativePath == "Photos")
        #expect(opened.relativePath == "Photos")

        _ = manager.switchTab(to: first, isLeft: true, currentProviderId: "iCloud")
        #expect(manager.leftRelativePath == "Finance")
    }

    @MainActor
    @Test func closingTheActiveTabMovesThePaneToItsNeighbour() async throws {
        let manager = manager(tabs: [PaneTab(providerId: "iCloud", relativePath: "A"),
                                     PaneTab(providerId: "iCloud", relativePath: "B"),
                                     PaneTab(providerId: "iCloud", relativePath: "C")])
        let second = manager.leftPaneTabs.tabs[1].id
        _ = manager.switchTab(to: second, isLeft: true, currentProviderId: "iCloud")
        #expect(manager.leftRelativePath == "B")

        let landed = manager.closeTab(id: second, isLeft: true, currentProviderId: "iCloud")
        #expect(landed?.relativePath == "C")
        #expect(manager.leftRelativePath == "C")
    }

    /// Closing a PARKED tab must not move the pane — and, the part that breaks silently, must not
    /// write the live pane's state into whichever tab slides into the vacated slot.
    @MainActor
    @Test func closingAParkedTabLeavesTheLivePaneWhereItIs() async throws {
        let manager = manager(tabs: [PaneTab(providerId: "iCloud", relativePath: "A"),
                                     PaneTab(providerId: "iCloud", relativePath: "B")])
        let first = manager.leftPaneTabs.tabs[0].id
        let second = manager.leftPaneTabs.tabs[1].id
        _ = manager.switchTab(to: second, isLeft: true, currentProviderId: "iCloud")
        manager.focusOn(relativePath: "B/Deep", isLeft: true)

        #expect(manager.closeTab(id: first, isLeft: true, currentProviderId: "iCloud") == nil)
        #expect(manager.leftRelativePath == "B/Deep")
        #expect(manager.leftPaneTabs.count == 1)
        #expect(manager.leftPaneTabs.active.id == second)
    }

    @MainActor
    @Test func theLastTabIsNeverClosedAndThePaneIsUntouched() async throws {
        let manager = manager(tabs: [PaneTab(providerId: "iCloud", relativePath: "A")])
        manager.focusOn(relativePath: "A/Deep", isLeft: true)
        #expect(manager.closeTab(id: manager.leftPaneTabs.active.id, isLeft: true,
                                 currentProviderId: "iCloud") == nil)
        #expect(manager.leftPaneTabs.count == 1)
        #expect(manager.leftRelativePath == "A/Deep")
    }

    @MainActor
    @Test func reopeningAClosedTabPutsThePaneBackWhereThatTabWas() async throws {
        let manager = manager(tabs: [PaneTab(providerId: "iCloud", relativePath: "A"),
                                     PaneTab(providerId: "iCloud", relativePath: "B")])
        let second = manager.leftPaneTabs.tabs[1].id
        _ = manager.closeTab(id: second, isLeft: true, currentProviderId: "iCloud")

        let reopened = manager.reopenClosedTab(isLeft: true, currentProviderId: "iCloud")
        #expect(reopened?.relativePath == "B")
        #expect(manager.leftRelativePath == "B")
    }

    /// Reordering touches the strip and nothing else — the pane keeps its folder, its selection
    /// and its history, because no tab was left and none was arrived at.
    @MainActor
    @Test func reorderingDoesNotMoveThePane() async throws {
        let manager = manager(tabs: [PaneTab(providerId: "iCloud", relativePath: "A"),
                                     PaneTab(providerId: "iCloud", relativePath: "B"),
                                     PaneTab(providerId: "iCloud", relativePath: "C")])
        let first = manager.leftPaneTabs.tabs[0].id
        manager.focusOn(relativePath: "A/Deep", isLeft: true)
        manager.selectedLeftPaths = ["/r/A/Deep/x.pdf"]

        manager.moveTab(id: first, to: 2, isLeft: true)

        #expect(manager.leftPaneTabs.tabs.map(\.relativePath) == ["B", "C", "A"])
        #expect(manager.leftRelativePath == "A/Deep", "the pane moved on a reorder")
        #expect(manager.selectedLeftPaths == ["/r/A/Deep/x.pdf"], "the selection was cleared by a reorder")
        #expect(manager.leftPaneTabs.active.relativePath == "A", "the live tab changed on a reorder")
    }

    // MARK: The two lists

    /// The right pane has its own list, and the left pane's verbs must not reach it — Browse's
    /// tabs are the left pane's, and Compare shows one strip per side.
    @MainActor
    @Test func theTwoPanesHoldSeparateLists() async throws {
        let manager = FileSyncManager(fileManager: MockFileManager())
        manager.setPaneTabs(PaneTabList(tabs: [PaneTab(providerId: "iCloud"),
                                               PaneTab(providerId: "iCloud")]), isLeft: true)
        manager.setPaneTabs(PaneTabList(single: PaneTab(providerId: "Dropbox")), isLeft: false)

        _ = manager.openTab(PaneTab(providerId: "iCloud", relativePath: "X"),
                            isLeft: true, currentProviderId: "iCloud")
        #expect(manager.leftPaneTabs.count == 3)
        #expect(manager.rightPaneTabs.count == 1)
        #expect(manager.rightRelativePath == "")
    }

    /// ⇄ swaps the two LISTS, not the two active tabs — it already moves each pane's location
    /// wholesale, and a strip left behind would list folders in the tree that just departed.
    @MainActor
    @Test func swappingThePanesSwapsTheirStrips() async throws {
        let manager = FileSyncManager(fileManager: MockFileManager())
        manager.setPaneTabs(PaneTabList(tabs: [PaneTab(providerId: "iCloud", relativePath: "L1"),
                                               PaneTab(providerId: "iCloud", relativePath: "L2")]),
                            isLeft: true)
        manager.setPaneTabs(PaneTabList(single: PaneTab(providerId: "Dropbox", relativePath: "R1")),
                            isLeft: false)

        manager.swapPanes()

        #expect(manager.leftPaneTabs.count == 1)
        #expect(manager.leftPaneTabs.active.relativePath == "R1")
        #expect(manager.rightPaneTabs.count == 2)
        #expect(manager.rightPaneTabs.tabs.map(\.relativePath) == ["L1", "L2"])
    }

    // MARK: The verbs that had no manager-level test at all
    //
    // Each of the five below was written because a mutation survived the whole 2,173-test suite:
    // `closeOtherTabs` never moving the pane, `duplicateTab` doing nothing, `setTabPinned` doing
    // nothing, `captureTab` ignoring the search snapshot, and `applyTab` no longer clearing the
    // comparison state. The model half of each was covered; the manager half — the half that moves
    // the actual pane — was not, which is the seam this file exists to hold.

    /// **Close Other Tabs from a PARKED tab has to move the pane.** The gesture is "leave me with
    /// this one", so the pane must end up looking at the tab that survived — not still showing a
    /// folder whose chip has just been closed out from under it.
    @MainActor
    @Test func closingTheOtherTabsFromAParkedOneMovesThePaneToIt() async throws {
        let manager = manager(tabs: [PaneTab(providerId: "iCloud"),
                                     PaneTab(providerId: "iCloud", relativePath: "Keep"),
                                     PaneTab(providerId: "iCloud")])
        let keep = manager.leftPaneTabs.tabs[1].id
        // Live on the FIRST tab, somewhere of its own, so "the pane moved" is unambiguous.
        manager.focusOn(relativePath: "Finance", isLeft: true)

        let arrived = manager.closeOtherTabs(keeping: keep, isLeft: true, currentProviderId: "iCloud")

        #expect(arrived?.id == keep, "the pane did not move to the tab that was kept")
        #expect(manager.leftPaneTabs.count == 1)
        #expect(manager.leftRelativePath == "Keep",
                "the pane is still showing the folder of a tab that no longer exists")
    }

    /// …and from the tab already live it must NOT move — the return is the host's signal to skip a
    /// reload, and a reload here would be work for a pane that has not gone anywhere.
    @MainActor
    @Test func closingTheOtherTabsFromTheLiveOneLeavesThePanePut() async throws {
        let manager = manager(tabs: [PaneTab(providerId: "iCloud"), PaneTab(providerId: "iCloud")])
        let live = manager.leftPaneTabs.active.id
        manager.focusOn(relativePath: "Finance", isLeft: true)

        let arrived = manager.closeOtherTabs(keeping: live, isLeft: true, currentProviderId: "iCloud")

        #expect(arrived == nil, "closing the others around the live tab reported a move")
        #expect(manager.leftPaneTabs.count == 1)
        #expect(manager.leftRelativePath == "Finance", "the pane moved when nothing asked it to")
    }

    /// Duplicate opens a second chip on the same folder and goes there. The half that fails when
    /// `duplicate` is a no-op is the COUNT — landing on the right folder is what the pane was
    /// already showing.
    @MainActor
    @Test func duplicatingATabOpensASecondChipOnTheSameFolderAndGoesThere() async throws {
        let manager = manager(tabs: [PaneTab(providerId: "iCloud")])
        manager.focusOn(relativePath: "Finance/US", isLeft: true)
        let original = manager.leftPaneTabs.active.id

        let arrived = manager.duplicateTab(id: original, isLeft: true, currentProviderId: "iCloud")

        #expect(manager.leftPaneTabs.count == 2, "duplicate did not open a second tab")
        #expect(arrived?.id != original, "the pane stayed on the original rather than the copy")
        #expect(manager.leftRelativePath == "Finance/US")
        // The original is left parked where it was, which is the capture doing its job.
        #expect(manager.leftPaneTabs.tabs[0].combinedRelativePath == "Finance/US")
    }

    /// Pinning through the manager reaches the list — and, because pinning REORDERS, the pane must
    /// still be on the tab it was on. That second half is the one a no-op mutation cannot fail, so
    /// it is asserted against a tab that genuinely moves position.
    ///
    /// **Asserted on identity, not on paths.** The first draft named the three tabs by folder and
    /// expected them back in that order; it failed with `["C", "", "B"]`, because switching away
    /// from the first tab captures the LIVE pane into it and this pane had been nowhere. That is
    /// the design working — the active tab is the pane, not a value beside it — so the fixture is
    /// what was wrong, and ids are the thing pinning is actually supposed to preserve.
    @MainActor
    @Test func pinningThroughTheManagerReordersTheStripWithoutMovingThePane() async throws {
        let manager = manager(tabs: [PaneTab(providerId: "iCloud"),
                                     PaneTab(providerId: "iCloud"),
                                     PaneTab(providerId: "iCloud")])
        let ids = manager.leftPaneTabs.tabs.map(\.id)
        manager.switchTab(to: ids[1], isLeft: true, currentProviderId: "iCloud")
        let liveBefore = manager.leftPaneTabs.active.id

        manager.setTabPinned(true, id: ids[2], isLeft: true)

        #expect(manager.leftPaneTabs.tabs.map(\.id) == [ids[2], ids[0], ids[1]],
                "pinning did not move the tab to the leading end")
        #expect(manager.leftPaneTabs.active.id == liveBefore,
                "the reorder took the live tab with it")
        #expect(manager.leftPaneTabs.tabs[0].isPinned)

        manager.setTabPinned(false, id: ids[2], isLeft: true)
        #expect(manager.leftPaneTabs.pinnedCount == 0, "unpinning through the manager did nothing")
        #expect(manager.leftPaneTabs.active.id == liveBefore, "unpinning moved the pane")
    }

    /// **The search field travels with the tab**, and the manager can only read it through the
    /// host's `paneSearchSnapshot` hook. Nothing else in the suite installs that hook, so without
    /// this the whole channel could be cut and every test would still pass.
    @MainActor
    @Test func aParkedTabKeepsTheSearchTheHostReportsForIt() async throws {
        let manager = manager(tabs: [PaneTab(providerId: "iCloud"), PaneTab(providerId: "iCloud")])
        manager.paneSearchSnapshot = { isLeft in
            isLeft ? (query: "invoice", isExpanded: true) : (query: "", isExpanded: false)
        }
        let first = manager.leftPaneTabs.tabs[0].id
        let second = manager.leftPaneTabs.tabs[1].id

        manager.switchTab(to: second, isLeft: true, currentProviderId: "iCloud")

        let parked = try #require(manager.leftPaneTabs.tabs.first { $0.id == first })
        #expect(parked.searchQuery == "invoice", "the parked tab lost the query the host reported")
        #expect(parked.searchIsExpanded, "the parked tab lost the field's expanded state")
        // And the tab arrived at carries its own — which for a tab that has been nowhere is empty.
        #expect(manager.leftPaneTabs.active.searchQuery == "")
        #expect(manager.leftPaneTabs.active.id == second)
    }

    /// **A switch inside one source at one scope keeps the pane's tree.**
    ///
    /// The tree is a walk of one root at one focus. Moving between two tabs that share both is a
    /// move *inside* the tree the pane already has, so dropping it buys a full re-walk to rebuild
    /// something identical — which is the visible "every tab switch refreshes the pane", and which
    /// also republishes the tree empty-then-shallow, straight into the republish prune that
    /// flattens the column stack the switch just restored. Two user-visible bugs from one
    /// over-broad invalidation.
    @MainActor
    @Test func switchingInsideOneSourceKeepsTheTreeItIsAlreadyShowing() async throws {
        let manager = manager(tabs: [PaneTab(providerId: "iCloud"), PaneTab(providerId: "iCloud")])
        manager.leftTree = [FileNode(id: "/r/Documents", name: "Documents", isDirectory: true, children: [])]
        manager.lastLoadedLeftFocusPath = ""

        manager.switchTab(to: manager.leftPaneTabs.tabs[1].id, isLeft: true, currentProviderId: "iCloud")

        #expect(!manager.leftTree.isEmpty,
                "the pane's tree was dropped for a move inside the tree it was already showing")
        #expect(manager.lastLoadedLeftFocusPath == "",
                "the pane was marked unloaded, so its next republish prunes the restored stack")
    }

    /// …and a switch that DOES change the source drops it, because then it is the wrong tree: it
    /// walks a root the pane is leaving, and every path in it names a file under that root.
    @MainActor
    @Test func switchingToAnotherSourceDropsTheTree() async throws {
        let manager = manager(tabs: [PaneTab(providerId: "iCloud"), PaneTab(providerId: "Dropbox")])
        manager.leftTree = [FileNode(id: "/r/Documents", name: "Documents", isDirectory: true, children: [])]
        manager.lastLoadedLeftFocusPath = ""

        manager.switchTab(to: manager.leftPaneTabs.tabs[1].id, isLeft: true, currentProviderId: "iCloud")

        #expect(manager.leftTree.isEmpty,
                "the pane kept a tree walked from the source it just left")
    }

    /// **Moving to another folder in the same source keeps the fast-path cache**, which is what
    /// makes the arriving tab paint from memory instead of from a ~100ms disk walk. The cache is
    /// keyed by absolute path, so every subtree in it still describes the same folders on the same
    /// disk — the same reason breadcrumb and drill-down navigation are already instant.
    @MainActor
    @Test func switchingFolderInsideOneSourceKeepsTheCacheThatMakesItPaintInstantly() async throws {
        let manager = manager(tabs: [PaneTab(providerId: "iCloud"),
                                     PaneTab(providerId: "iCloud", relativePath: "Elsewhere")])
        manager.prefetchedTrees["/r/Elsewhere"] = [
            FileNode(id: "/r/Elsewhere/a.pdf", name: "a.pdf", isDirectory: false, children: nil)
        ]

        manager.switchTab(to: manager.leftPaneTabs.tabs[1].id, isLeft: true, currentProviderId: "iCloud")

        #expect(manager.prefetchedTrees["/r/Elsewhere"] != nil,
                "the arriving folder's cached tree was thrown away, so the pane must walk the disk for it")
    }

    /// …and a SOURCE change drops it, because then the cache describes a disk the pane has left.
    @MainActor
    @Test func switchingSourceDropsTheCacheBecauseItDescribesAnotherRoot() async throws {
        let manager = manager(tabs: [PaneTab(providerId: "iCloud"),
                                     PaneTab(providerId: "Dropbox")])
        manager.prefetchedTrees["/r/Elsewhere"] = [
            FileNode(id: "/r/Elsewhere/a.pdf", name: "a.pdf", isDirectory: false, children: nil)
        ]

        manager.switchTab(to: manager.leftPaneTabs.tabs[1].id, isLeft: true, currentProviderId: "iCloud")

        #expect(manager.prefetchedTrees.isEmpty,
                "the pane kept cached subtrees of the source it just left")
    }

    // MARK: A tab whose source has been removed

    /// **A dead tab is discarded, not merely warned about.**
    ///
    /// The verbs apply a tab before the host can rule on its source, so by the time the host finds
    /// the source gone the pane is already pointed at that tab's folder path under the LIVE source's
    /// root — a path that usually exists nowhere. The branch used to only log, with a comment
    /// claiming the pane "stayed on its current source": true of the source, false of the folder,
    /// and the false half is the one that showed as an empty pane.
    @MainActor
    @Test func discardingADeadTabLeavesThePaneOnALiveOne() async throws {
        let manager = manager(tabs: [PaneTab(providerId: "iCloud", relativePath: "Keep"),
                                     PaneTab(providerId: "GoneDrive", relativePath: "Ghost")])
        let dead = manager.leftPaneTabs.tabs[1].id
        // The live pane has to actually BE at "Keep": switching away captures the pane into the
        // outgoing tab, so a fixture that only names the folder in the tab's initializer has that
        // name overwritten by wherever the pane really is — the active tab is the pane.
        manager.focusOn(relativePath: "Keep", isLeft: true)
        manager.switchTab(to: dead, isLeft: true, currentProviderId: "iCloud")
        // The pane has already been pointed at the dead tab's path — that is the state the host
        // discovers the problem in, and the one this has to get out of.
        #expect(manager.leftRelativePath == "Ghost")

        let landed = manager.discardTab(id: dead, isLeft: true, currentProviderId: "iCloud")

        #expect(manager.leftPaneTabs.count == 1, "the dead tab is still in the strip")
        #expect(manager.leftPaneTabs.active.providerId == "iCloud")
        #expect(landed.combinedRelativePath == "Keep")
        #expect(manager.leftRelativePath == "Keep",
                "the pane was left on the removed source's folder path")
    }

    /// The last tab is never closed — a pane always holds one — so a dead one is rebuilt on the
    /// pane's own source at its root, the one location certain to exist.
    @MainActor
    @Test func discardingTheOnlyTabRebuildsItOnTheLiveSourceAtItsRoot() async throws {
        let manager = manager(tabs: [PaneTab(providerId: "GoneDrive", relativePath: "Ghost")])
        let dead = manager.leftPaneTabs.active.id
        manager.focusOn(relativePath: "Ghost", isLeft: true)

        let landed = manager.discardTab(id: dead, isLeft: true, currentProviderId: "iCloud")

        #expect(manager.leftPaneTabs.count == 1)
        #expect(manager.leftPaneTabs.active.providerId == "iCloud",
                "the rebuilt tab still names the source that is gone")
        #expect(landed.combinedRelativePath == "")
        #expect(manager.leftRelativePath == "", "the pane stayed inside the removed source's folder")
    }

    /// **A tab switch drops the comparison.** The differences, the trees and the verification
    /// results were computed for the folder pair the pane is leaving; carried across a switch they
    /// would show one pane's new contents against the other pane's answer to the old question —
    /// and a stale "in sync" is the most expensive wrong answer this app can give.
    ///
    /// **The two tabs must be at different folders**, which the first version of this test got
    /// wrong: it used two tabs at the root, so nothing about the comparison's subject changed and
    /// the assertion was really "a switch always clears". That is not the claim — the claim is in
    /// the name, *built for the old folder* — and once a same-folder switch correctly stopped
    /// clearing anything, the fixture was the thing that had to move.
    @MainActor
    @Test func switchingTabsThrowsAwayTheComparisonBuiltForTheOldFolder() async throws {
        let manager = manager(tabs: [PaneTab(providerId: "iCloud"),
                                     PaneTab(providerId: "iCloud", relativePath: "Elsewhere")])
        manager.differences = [FileDifference(relativePath: "stale.pdf",
                                              leftItemPath: "/l/stale.pdf",
                                              rightItemPath: "/r/stale.pdf",
                                              type: .missingOnRight,
                                              action: .copyToRight,
                                              description: "missing")]
        manager.hasScanned = true

        manager.switchTab(to: manager.leftPaneTabs.tabs[1].id, isLeft: true, currentProviderId: "iCloud")

        #expect(manager.differences.isEmpty,
                "the previous folder's differences survived a tab switch")
        #expect(!manager.hasScanned,
                "the pane claims a scan it ran against the tab it just left")
    }

    /// …and the other side, which is what the user actually asked for: **a switch inside one folder
    /// keeps the comparison and asks for no scan.** The differences are about a pair of focused
    /// folders; a tab that shares the focus shares the answer. Refreshing is the Refresh button's
    /// job, and drilling through columns — which moves the same column stack a tab carries — has
    /// never rescanned either.
    @MainActor
    @Test func switchingInsideOneFolderKeepsTheComparisonAndAsksForNoScan() async throws {
        let manager = manager(tabs: [PaneTab(providerId: "iCloud"), PaneTab(providerId: "iCloud")])
        manager.differences = [FileDifference(relativePath: "real.pdf",
                                              leftItemPath: "/l/real.pdf",
                                              rightItemPath: "/r/real.pdf",
                                              type: .missingOnRight,
                                              action: .copyToRight,
                                              description: "missing")]
        manager.hasScanned = true

        manager.switchTab(to: manager.leftPaneTabs.tabs[1].id, isLeft: true, currentProviderId: "iCloud")

        #expect(manager.differences.count == 1,
                "a switch that did not change the folder pair threw the comparison away")
        #expect(manager.hasScanned, "the pane forgot a scan that is still true of what it shows")

        // And the rule the host reads to decide whether to run one at all agrees.
        #expect(!PaneTabArrival.needsReload(arrivingAt: manager.leftPaneTabs.active,
                                            fromProvider: "iCloud", fromFocus: ""),
                "the host would rescan for a move inside one folder")
        #expect(PaneTabArrival.needsReload(arrivingAt: PaneTab(providerId: "iCloud", relativePath: "Other"),
                                           fromProvider: "iCloud", fromFocus: ""),
                "a tab at another folder does not ask for a reload")
        #expect(PaneTabArrival.needsReload(arrivingAt: PaneTab(providerId: "Dropbox"),
                                           fromProvider: "iCloud", fromFocus: ""),
                "a tab on another source does not ask for a reload")
    }
}

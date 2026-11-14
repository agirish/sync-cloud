import Testing
import Foundation
@testable import Sync

/// Switching tabs against a real `FileSyncManager`. The active tab is the pane, so a switch must
/// park the live position before it applies the incoming one. Checking only where the pane lands
/// would pass with `captureActive` deleted, so each test walks away and comes back and checks the
/// tab it left is still where it was left.
@Suite struct PaneTabSwitchingTests {

    /// One pane holds a selection at a time, and a tab arriving with its own must keep that true:
    /// the transfer verbs rely on it, and it decides what ⌘⌫ and the copy arrows act on.
    ///
    /// Both directions are checked, so clearing the sibling unconditionally fails too: an empty
    /// arriving selection already satisfies the rule, and clearing there would discard a selection
    /// the switch never touched.
    @MainActor
    @Test func arrivingWithASelectionClearsTheSiblingsAndArrivingWithoutOneLeavesIt() async throws {
        let manager = manager(tabs: [PaneTab(providerId: "iCloud"), PaneTab(providerId: "iCloud")])
        let first = manager.leftPaneTabs.tabs[0].id
        let second = manager.leftPaneTabs.tabs[1].id

        // Left tab 1 remembers a selection; the right pane is holding one of its own.
        manager.selectedLeftPaths = ["/r/Finance/US/2024.pdf"]
        manager.selectedRightPaths = ["/r/Finance/US/2023.pdf"]

        // Tab 2 has been nowhere, so it arrives with nothing selected — the right pane keeps its own.
        _ = manager.switchTab(to: second, isLeft: true, currentProviderId: "iCloud")
        #expect(manager.selectedLeftPaths.isEmpty)
        #expect(manager.selectedRightPaths == ["/r/Finance/US/2023.pdf"],
                "an empty arriving selection cleared the sibling, discarding a selection the switch never touched")

        // Coming back restores tab 1's selection, and that is the write that has to clear the right.
        _ = manager.switchTab(to: first, isLeft: true, currentProviderId: "iCloud")
        #expect(manager.selectedLeftPaths == ["/r/Finance/US/2024.pdf"])
        #expect(manager.selectedRightPaths.isEmpty,
                "both panes hold a selection after a tab switch — ⌘⌫ and the copy arrows no longer have one answer for what they act on")
    }

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

    /// Back in a tab walks that tab's own history. A shared history would let Back step into a
    /// folder this tab has never been in.
    @MainActor
    @Test func historyIsPerTab() async throws {
        let manager = manager(tabs: [PaneTab(providerId: "iCloud"), PaneTab(providerId: "iCloud")])
        let second = manager.leftPaneTabs.tabs[1].id

        manager.focusOn(relativePath: "A", isLeft: true)
        manager.focusOn(relativePath: "A/B", isLeft: true)
        #expect(manager.canGoBack(isLeft: true, drawsColumns: true))

        _ = manager.switchTab(to: second, isLeft: true, currentProviderId: "iCloud")
        // A tab that has been nowhere has nowhere to go back to.
        #expect(!manager.canGoBack(isLeft: true, drawsColumns: true))
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

    /// Closing a parked tab must not move the pane, nor (the part that breaks silently) write the
    /// live pane's state into whichever tab slides into the vacated slot.
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
    // The model half of each verb is tested elsewhere; these pin the manager half, which moves the
    // actual pane. Each fails if its verb stops moving the pane, does nothing, ignores the search
    // snapshot, or stops clearing the comparison.

    /// Close Other Tabs from a parked tab moves the pane to the tab that survived, not leaving it
    /// on a folder whose chip was just closed.
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

    /// …and from the live tab it must not move: the nil return tells the host to skip a reload.
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

    /// Duplicate opens a second chip on the same folder and goes there. The count is what fails if
    /// `duplicate` is a no-op; the folder is where the pane already was.
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

    /// Pinning through the manager reaches the list, and because pinning reorders, the pane must
    /// stay on its tab; the pinned tab genuinely moves so a no-op fails. Asserted on ids, not paths:
    /// switching away captures the live pane into the outgoing tab, so paths would change anyway.
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

    /// The search field travels with the tab, read through the host's `paneSearchSnapshot` hook.
    /// Nothing else in the suite installs that hook.
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

    /// A switch inside one source at one scope keeps the pane's tree. Dropping it would re-walk
    /// something identical (a visible refresh on every switch) and republish the tree
    /// empty-then-shallow, into the prune that would flatten the column stack just restored. A
    /// switch that changes the source drops it: it walks a root the pane is leaving.
    @MainActor
    @Test(arguments: ["iCloud", "Dropbox"])
    func switchingKeepsTheTreeOnlyInsideOneSource(arrivingAt providerId: String) async throws {
        let manager = manager(tabs: [PaneTab(providerId: "iCloud"), PaneTab(providerId: providerId)])
        manager.leftTree = [FileNode(id: "/r/Documents", name: "Documents", isDirectory: true, children: [])]
        manager.lastLoadedLeftFocusPath = ""

        manager.switchTab(to: manager.leftPaneTabs.tabs[1].id, isLeft: true, currentProviderId: "iCloud")

        if providerId == "iCloud" {
            #expect(!manager.leftTree.isEmpty,
                    "the pane's tree was dropped for a move inside the tree it was already showing")
            #expect(manager.lastLoadedLeftFocusPath == "",
                    "the pane was marked unloaded, so its next republish prunes the restored stack")
        } else {
            #expect(manager.leftTree.isEmpty,
                    "the pane kept a tree walked from the source it just left")
        }
    }

    /// Moving to another folder in the same source keeps the fast-path cache, so the arriving tab
    /// paints from memory instead of a disk walk. The cache is keyed by absolute path, so every
    /// subtree in it still describes the same folders.
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

    /// …and a source change drops it, all but the other pane's walk, which that pane shows and the
    /// next Compare reads. Without it the scan would walk both folders from disk
    /// (`SourceSwitchKeepsTheStillPaneTests`).
    @MainActor
    @Test func switchingSourceDropsTheCacheButTheOtherPanesWalk() async throws {
        let manager = manager(tabs: [PaneTab(providerId: "iCloud"),
                                     PaneTab(providerId: "Dropbox")])
        manager.prefetchedTrees["/r/Elsewhere"] = [
            FileNode(id: "/r/Elsewhere/a.pdf", name: "a.pdf", isDirectory: false, children: nil)
        ]
        manager.prefetchedTrees["/o/Other"] = [
            FileNode(id: "/o/Other/b.pdf", name: "b.pdf", isDirectory: false, children: nil)
        ]
        manager.lastLoadedRightFocusPath = "/o/Other"

        manager.switchTab(to: manager.leftPaneTabs.tabs[1].id, isLeft: true, currentProviderId: "iCloud")

        #expect(Array(manager.prefetchedTrees.keys) == ["/o/Other"],
                "the pane kept cached subtrees of the source it just left, or dropped the other pane's walk")
    }

    /// A tab switch reloads only the pane it moved; walking the other again would rebuild something
    /// identical. `.both` stays the default for every other caller, so a file operation, a forced
    /// rescan and a sort change still rebuild both panes. The switch does drop the comparison: it
    /// was computed for the folder pair the pane is leaving, and a stale "in sync" is the most
    /// expensive wrong answer this app can give. The tabs are at different folders, since a
    /// same-folder switch keeps the comparison.
    @MainActor
    @Test func aTabSwitchInvalidatesOnlyThePaneItMoved() async throws {
        let manager = manager(tabs: [PaneTab(providerId: "iCloud"),
                                     PaneTab(providerId: "iCloud", relativePath: "Elsewhere")])
        manager.differences = [FileDifference(relativePath: "stale.pdf",
                                              leftItemPath: "/l/stale.pdf",
                                              rightItemPath: "/r/stale.pdf",
                                              type: .missingOnRight,
                                              action: .copyToRight,
                                              description: "missing")]
        manager.hasScanned = true
        manager.leftTree = [FileNode(id: "/l/A", name: "A", isDirectory: true, children: [])]
        manager.rightTree = [FileNode(id: "/r/B", name: "B", isDirectory: true, children: [])]
        manager.lastLoadedLeftFocusPath = ""
        manager.lastLoadedRightFocusPath = ""
        manager.leftItemCount = 1
        manager.rightItemCount = 1

        manager.switchTab(to: manager.leftPaneTabs.tabs[1].id, isLeft: true, currentProviderId: "iCloud")

        #expect(manager.leftTree.isEmpty, "the moving pane kept a tree walked for the folder it left")
        #expect(manager.lastLoadedLeftFocusPath == nil)
        #expect(!manager.rightTree.isEmpty,
                "the pane that did not move had its tree dropped, so it re-walks for nothing")
        #expect(manager.lastLoadedRightFocusPath == "",
                "the still pane was marked unloaded, which is what makes it re-walk")
        #expect(manager.rightItemCount == 1)
        // The comparison still goes: one pane moving DOES change the folder pair.
        #expect(manager.differences.isEmpty,
                "the previous folder's differences survived a tab switch")
        #expect(!manager.hasScanned,
                "the pane claims a scan it ran against the tab it just left")
    }

    /// The scope the host hands the refresh names that same pane, or a pane is invalidated and
    /// never reloaded.
    @MainActor
    @Test func theReloadScopeNamesTheMovedPane() {
        #expect(FileSyncManager.PaneReloadScope.movedPane(isLeft: true) == .leftOnly)
        #expect(FileSyncManager.PaneReloadScope.movedPane(isLeft: false) == .rightOnly)
        // Part of the refresh key, so a one-pane refresh in flight cannot swallow a two-pane one
        // as a duplicate and leave the other pane holding a tree nobody reloaded.
        let m = FileSyncManager()
        let l = CloudProvider(id: "L", displayName: "L", imageName: "", rootPath: "/l", type: .iCloud)
        let r = CloudProvider(id: "R", displayName: "R", imageName: "", rootPath: "/r", type: .iCloud)
        #expect(m.makeRefreshKey(left: l, right: r, reloading: .leftOnly)
                != m.makeRefreshKey(left: l, right: r, reloading: .both),
                "a one-pane refresh and a two-pane one share a key")
    }

    // MARK: A tab whose source has been removed

    /// A dead tab is discarded, not merely warned about. The verbs apply a tab before the host can
    /// rule on its source, so by then the pane points at that tab's folder path under the live
    /// source's root, usually a path that exists nowhere, and shows an empty pane.
    @MainActor
    @Test func discardingADeadTabLeavesThePaneOnALiveOne() async throws {
        let manager = manager(tabs: [PaneTab(providerId: "iCloud", relativePath: "Keep"),
                                     PaneTab(providerId: "GoneDrive", relativePath: "Ghost")])
        let dead = manager.leftPaneTabs.tabs[1].id
        // The live pane must actually be at "Keep": switching away captures the pane into the
        // outgoing tab, overwriting the folder named in the tab's initializer.
        manager.focusOn(relativePath: "Keep", isLeft: true)
        manager.switchTab(to: dead, isLeft: true, currentProviderId: "iCloud")
        // The pane already points at the dead tab's path: the state the host finds the problem in.
        #expect(manager.leftRelativePath == "Ghost")

        let landed = try #require(manager.discardTab(id: dead, isLeft: true,
                                                     currentProviderId: "iCloud"))

        #expect(manager.leftPaneTabs.count == 1, "the dead tab is still in the strip")
        #expect(manager.leftPaneTabs.active.providerId == "iCloud")
        #expect(landed.combinedRelativePath == "Keep")
        #expect(manager.leftRelativePath == "Keep",
                "the pane was left on the removed source's folder path")
    }

    /// The last tab is never closed, so a dead one is rebuilt on the pane's own source at its root,
    /// the one location certain to exist.
    @MainActor
    @Test func discardingTheOnlyTabRebuildsItOnTheLiveSourceAtItsRoot() async throws {
        let manager = manager(tabs: [PaneTab(providerId: "GoneDrive", relativePath: "Ghost")])
        let dead = manager.leftPaneTabs.active.id
        manager.focusOn(relativePath: "Ghost", isLeft: true)

        let landed = try #require(manager.discardTab(id: dead, isLeft: true,
                                                     currentProviderId: "iCloud"))

        #expect(manager.leftPaneTabs.count == 1)
        #expect(manager.leftPaneTabs.active.providerId == "iCloud",
                "the rebuilt tab still names the source that is gone")
        #expect(landed.combinedRelativePath == "")
        #expect(manager.leftRelativePath == "", "the pane stayed inside the removed source's folder")
    }

    /// An id this pane does not hold discards nothing, and the strip is left exactly as it was.
    /// Folded into the last-tab rebuild, an unknown id would replace the whole strip and its reopen
    /// stack with one fresh tab. No caller passes one today, but a guard whose failure throws the
    /// user's tabs away is one refactor from live.
    @MainActor
    @Test func discardingATabThisPaneDoesNotHoldChangesNothing() async throws {
        let manager = manager(tabs: [PaneTab(providerId: "iCloud", relativePath: "A"),
                                     PaneTab(providerId: "iCloud", relativePath: "B"),
                                     PaneTab(providerId: "iCloud", relativePath: "C")])
        manager.focusOn(relativePath: "A", isLeft: true)
        // A closed tab gives the reopen stack something to lose, so a wipe can't pass unseen.
        manager.closeTab(id: manager.leftPaneTabs.tabs[2].id, isLeft: true, currentProviderId: "iCloud")
        let before = manager.leftPaneTabs

        let landed = manager.discardTab(id: UUID(), isLeft: true, currentProviderId: "iCloud")

        #expect(landed == nil, "an unknown id reported a tab the pane had moved to")
        #expect(manager.leftPaneTabs == before, "an unknown id took the pane's whole strip with it")
        #expect(manager.leftPaneTabs.canReopen, "the reopen stack went with it")
        #expect(manager.leftRelativePath == "A", "the pane moved for a tab that does not exist")
    }

    /// A discarded tab does not go on the reopen stack, so Reopen Closed Tab drains. If it did,
    /// each press would pop the dead tab, the host would discard it again and push it back, and the
    /// menu item would stay enabled forever. The test drives that loop, not just `canReopen`.
    @MainActor
    @Test func aDiscardedTabIsNotOfferedBackByReopenClosedTab() async throws {
        let manager = manager(tabs: [PaneTab(providerId: "iCloud", relativePath: "Keep"),
                                     PaneTab(providerId: "GoneDrive", relativePath: "Ghost")])
        manager.focusOn(relativePath: "Keep", isLeft: true)
        let dead = manager.leftPaneTabs.tabs[1].id
        manager.switchTab(to: dead, isLeft: true, currentProviderId: "iCloud")

        manager.discardDeadTabs(startingAt: dead, isLeft: true, currentProviderId: "iCloud",
                                isAvailable: { $0 == "iCloud" })

        #expect(!manager.leftPaneTabs.canReopen,
                "a tab discarded as unusable is offered back by Reopen Closed Tab")
        #expect(manager.reopenClosedTab(isLeft: true, currentProviderId: "iCloud") == nil,
                "Reopen Closed Tab brought back a tab whose source is gone")
    }

    /// …and the tabs the user closed by hand survive the rebuild. The last-tab branch replaces the
    /// pane's position; a fresh `PaneTabList` would also empty `recentlyClosed`.
    @MainActor
    @Test func rebuildingTheLastTabKeepsWhatTheUserClosedByHand() async throws {
        let manager = manager(tabs: [PaneTab(providerId: "GoneDrive", relativePath: "A"),
                                     PaneTab(providerId: "iCloud", relativePath: "B")])
        manager.focusOn(relativePath: "A", isLeft: true)
        manager.closeTab(id: manager.leftPaneTabs.tabs[1].id, isLeft: true, currentProviderId: "iCloud")
        #expect(manager.leftPaneTabs.recentlyClosed.map(\.relativePath) == ["B"],
                "the fixture never got a hand-closed tab onto the stack")

        manager.discardTab(id: manager.leftPaneTabs.active.id, isLeft: true,
                           currentProviderId: "iCloud")

        #expect(manager.leftPaneTabs.recentlyClosed.map(\.relativePath) == ["B"],
                "the rebuild threw away the tab the user closed by hand")
        // And it really does come back — `canReopen` alone would pass with a stack of ghosts.
        let back = try #require(manager.reopenClosedTab(isLeft: true, currentProviderId: "iCloud"))
        #expect(back.combinedRelativePath == "B")
    }

    /// Every dead tab behind the first one goes too. The fallback is a neighbour, and with two tabs
    /// open on a removed source, discarding the first would land the pane on the second, just as
    /// dead, and the empty pane would come straight back. The live tab here is the first dead one,
    /// so the pane must walk past a second.
    @MainActor
    @Test func discardingADeadTabAlsoDropsTheDeadOneItWouldLandOn() async throws {
        let manager = manager(tabs: [PaneTab(providerId: "iCloud", relativePath: "Keep"),
                                     PaneTab(providerId: "GoneDrive", relativePath: "Ghost"),
                                     PaneTab(providerId: "GoneDrive", relativePath: "Ghost2")])
        manager.focusOn(relativePath: "Keep", isLeft: true)
        let dead = manager.leftPaneTabs.tabs[1].id
        manager.switchTab(to: dead, isLeft: true, currentProviderId: "iCloud")
        #expect(manager.leftRelativePath == "Ghost")

        let outcome = manager.discardDeadTabs(startingAt: dead, isLeft: true,
                                              currentProviderId: "iCloud",
                                              isAvailable: { $0 == "iCloud" })

        #expect(outcome.discarded == ["GoneDrive", "GoneDrive"],
                "the second tab on the removed source survived the discard")
        #expect(manager.leftPaneTabs.count == 1)
        #expect(manager.leftPaneTabs.active.providerId == "iCloud")
        #expect(outcome.landed?.combinedRelativePath == "Keep")
        #expect(manager.leftRelativePath == "Keep",
                "the pane was left on the second removed-source folder path")
    }

    /// …and it stops at the first tab it CAN show, rather than clearing the strip.
    @MainActor
    @Test func discardingStopsAtTheFirstSourceThePaneCanShow() async throws {
        let manager = manager(tabs: [PaneTab(providerId: "iCloud", relativePath: "Keep"),
                                     PaneTab(providerId: "GoneDrive", relativePath: "Ghost"),
                                     PaneTab(providerId: "iCloud", relativePath: "AlsoKeep")])
        manager.focusOn(relativePath: "Keep", isLeft: true)
        let dead = manager.leftPaneTabs.tabs[1].id
        manager.switchTab(to: dead, isLeft: true, currentProviderId: "iCloud")

        let outcome = manager.discardDeadTabs(startingAt: dead, isLeft: true,
                                              currentProviderId: "iCloud",
                                              isAvailable: { $0 == "iCloud" })

        #expect(outcome.discarded == ["GoneDrive"], "a live tab was discarded with the dead one")
        #expect(manager.leftPaneTabs.count == 2)
        #expect(outcome.landed?.combinedRelativePath == "AlsoKeep",
                "the neighbour to the right does not inherit the pane")
    }

    /// The tab a discard lands on need not be on the pane's own source: `discardDeadTabs` stops at
    /// the first neighbour the pane can show, a wider set than "is currently on". This is why
    /// `tabAction` adopts after a discard; otherwise the pane would show the landed tab's folder
    /// under the wrong root and save that tab with the wrong source id.
    @MainActor
    @Test func aDiscardCanLandOnATabFromAThirdLiveSource() async throws {
        let manager = manager(tabs: [PaneTab(providerId: "iCloud", relativePath: "Keep"),
                                     PaneTab(providerId: "GoneDrive", relativePath: "Ghost"),
                                     PaneTab(providerId: "GoogleDrive", relativePath: "Docs")])
        manager.focusOn(relativePath: "Keep", isLeft: true)
        let dead = manager.leftPaneTabs.tabs[1].id
        manager.switchTab(to: dead, isLeft: true, currentProviderId: "iCloud")

        // Both iCloud and GoogleDrive are enabled; only GoneDrive is switched off.
        let outcome = manager.discardDeadTabs(startingAt: dead, isLeft: true,
                                              currentProviderId: "iCloud",
                                              isAvailable: { $0 != "GoneDrive" })

        #expect(outcome.discarded == ["GoneDrive"])
        let landed = try #require(outcome.landed)
        #expect(landed.providerId == "GoogleDrive",
                "the pane landed on a source that is neither the dead tab's nor its own, so the host must adopt it")
        #expect(landed.combinedRelativePath == "Docs")
    }

    /// A strip whose every tab is on a removed source ends on one tab at the live source's root
    /// (the rebuild branch), rather than looping or leaving a dead one live.
    @MainActor
    @Test func discardingEveryDeadTabLandsOnTheLiveSourcesRoot() async throws {
        let manager = manager(tabs: [PaneTab(providerId: "GoneDrive", relativePath: "A"),
                                     PaneTab(providerId: "GoneDrive", relativePath: "B")])
        let dead = manager.leftPaneTabs.active.id
        manager.focusOn(relativePath: "A", isLeft: true)

        let outcome = manager.discardDeadTabs(startingAt: dead, isLeft: true,
                                              currentProviderId: "iCloud",
                                              isAvailable: { $0 == "iCloud" })

        #expect(outcome.discarded == ["GoneDrive", "GoneDrive"])
        #expect(manager.leftPaneTabs.count == 1)
        #expect(manager.leftPaneTabs.active.providerId == "iCloud")
        #expect(outcome.landed?.combinedRelativePath == "")
        #expect(manager.leftRelativePath == "")
    }

    /// A switch inside one folder keeps the comparison and asks for no scan: a tab that shares
    /// the focus shares the answer. Refreshing is the Refresh button's job, and drilling through
    /// columns, which moves the same stack a tab carries, doesn't rescan either.
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

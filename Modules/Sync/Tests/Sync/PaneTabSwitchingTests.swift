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
}

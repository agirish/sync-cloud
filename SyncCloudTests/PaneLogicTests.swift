import Testing
import AppKit
import Foundation
import FileExplorer
@testable import SyncCloud

@Suite struct PaneLogicTests {

    // MARK: copyTargetName

    @Test func testCopyTargetIsTheOppositePane() {
        let names = PaneProviderNames(leftName: "iCloud", rightName: "Dropbox")
        // Selection in the left pane copies to the right provider, and vice versa.
        #expect(PaneLogic.copyTargetName(activePane: .left, paneNames: names) == "Dropbox")
        #expect(PaneLogic.copyTargetName(activePane: .right, paneNames: names) == "iCloud")
    }

    @Test func testCopyTargetIsNilWithoutSelection() {
        let names = PaneProviderNames(leftName: "iCloud", rightName: "Dropbox")
        #expect(PaneLogic.copyTargetName(activePane: nil, paneNames: names) == nil)
    }

    @Test func testCopyTargetDisambiguatesSameProviderPanes() {
        // Both panes on the same provider: the target must still say which side.
        let names = PaneProviderNames(leftName: "iCloud", rightName: "iCloud")
        #expect(PaneLogic.copyTargetName(activePane: .left, paneNames: names) == "iCloud (right)")
        #expect(PaneLogic.copyTargetName(activePane: .right, paneNames: names) == "iCloud (left)")
    }

    // MARK: actionBarSymbols

    @Test func testActionBarSymbolsPointTowardTheTargetPane() {
        // Left-pane selection targets the right pane, so the icons point right — and vice versa.
        let fromLeft = PaneLogic.actionBarSymbols(activePane: .left)
        #expect(fromLeft.copy == "arrow.right.circle")
        #expect(fromLeft.move == "arrow.right.square")
        let fromRight = PaneLogic.actionBarSymbols(activePane: .right)
        #expect(fromRight.copy == "arrow.left.circle")
        #expect(fromRight.move == "arrow.left.square")
    }

    @Test func testActionBarSymbolsWithoutSelectionKeepNeutralDefaults() {
        let neutral = PaneLogic.actionBarSymbols(activePane: nil)
        #expect(neutral.copy == "arrow.right.doc.on.clipboard")
        #expect(neutral.move == "arrow.right.square")
    }

    @Test func testActionBarSymbolNamesExistInSFSymbols() {
        // A typo'd symbol name renders as a blank icon at runtime; pin that every name resolves.
        for pane in [PaneLogic.ActivePane.left, .right, nil] {
            let symbols = PaneLogic.actionBarSymbols(activePane: pane)
            #expect(NSImage(systemSymbolName: symbols.copy, accessibilityDescription: nil) != nil,
                    "missing SF Symbol \(symbols.copy)")
            #expect(NSImage(systemSymbolName: symbols.move, accessibilityDescription: nil) != nil,
                    "missing SF Symbol \(symbols.move)")
        }
    }

    // MARK: reconciledSelections

    @Test func testSettingNonEmptyLeftSelectionClearsRight() {
        let reconciled = PaneLogic.reconciledSelections(
            settingSelection: ["/l/a"],
            isLeft: true,
            currentLeft: [],
            currentRight: ["/r/b", "/r/c"])
        #expect(reconciled.left == ["/l/a"])
        #expect(reconciled.right.isEmpty)
    }

    @Test func testSettingNonEmptyRightSelectionClearsLeft() {
        let reconciled = PaneLogic.reconciledSelections(
            settingSelection: ["/r/b"],
            isLeft: false,
            currentLeft: ["/l/a"],
            currentRight: [])
        #expect(reconciled.left.isEmpty)
        #expect(reconciled.right == ["/r/b"])
    }

    @Test func testSettingEmptySelectionDoesNotClearTheOtherPane() {
        // Deselecting (or SwiftUI re-writing an unchanged empty set, e.g. on right-click)
        // must leave the other pane's selection alone — "Copy N items from other pane"
        // in the context menu depends on it surviving.
        let afterLeftDeselect = PaneLogic.reconciledSelections(
            settingSelection: [],
            isLeft: true,
            currentLeft: ["/l/a"],
            currentRight: ["/r/b"])
        #expect(afterLeftDeselect.left.isEmpty)
        #expect(afterLeftDeselect.right == ["/r/b"])

        let afterRightDeselect = PaneLogic.reconciledSelections(
            settingSelection: [],
            isLeft: false,
            currentLeft: ["/l/a"],
            currentRight: ["/r/b"])
        #expect(afterRightDeselect.left == ["/l/a"])
        #expect(afterRightDeselect.right.isEmpty)
    }

    // MARK: activePane

    @Test func testActivePaneFollowsSelectionWithLeftPriority() {
        #expect(PaneLogic.activePane(leftSelection: [], rightSelection: []) == nil)
        #expect(PaneLogic.activePane(leftSelection: ["/l/a"], rightSelection: []) == .left)
        #expect(PaneLogic.activePane(leftSelection: [], rightSelection: ["/r/b"]) == .right)
        // Left wins when both panes have selections.
        #expect(PaneLogic.activePane(leftSelection: ["/l/a"], rightSelection: ["/r/b"]) == .left)
    }

    // MARK: primarySelectionPath

    @Test func testPrimarySelectionPathIsAlphabeticalNotHashOrder() {
        // A multi-item selection must always preview the same (alphabetically first) file.
        #expect(PaneLogic.primarySelectionPath(
            leftSelection: ["/l/b.txt", "/l/a.txt", "/l/c.txt"],
            rightSelection: []) == "/l/a.txt")
        #expect(PaneLogic.primarySelectionPath(
            leftSelection: [],
            rightSelection: ["/r/b.txt", "/r/a.txt"]) == "/r/a.txt")
    }

    @Test func testPrimarySelectionPathPrefersLeftPaneAndHandlesEmpty() {
        #expect(PaneLogic.primarySelectionPath(
            leftSelection: ["/l/z.txt"],
            rightSelection: ["/r/a.txt"]) == "/l/z.txt")
        #expect(PaneLogic.primarySelectionPath(leftSelection: [], rightSelection: []) == nil)
    }

    // MARK: shouldAutoSwitchToDetails

    @Test func testAutoSwitchFiresOnSelectionWhenTabWasNotManuallyChosen() {
        // The default flow: bottom pane on Differences (automatically), user selects a file.
        #expect(PaneLogic.shouldAutoSwitchToDetails(
            hasSelection: true,
            bottomPaneVisible: true,
            currentTabIsDetails: false,
            differencesPickedManually: false))
    }

    @Test func testAutoSwitchIsSuppressedAfterManualDifferencesPick() {
        // Once the user manually picked Differences, selection changes must not steal the tab.
        #expect(!PaneLogic.shouldAutoSwitchToDetails(
            hasSelection: true,
            bottomPaneVisible: true,
            currentTabIsDetails: false,
            differencesPickedManually: true))
    }

    @Test func testAutoSwitchReArmsAfterManualDetailsPick() {
        // Manually picking Details clears the manual-Differences flag (the Picker setter
        // only raises it for .differences), so the next selection auto-switches again.
        let flagAfterManualDetailsPick = false
        #expect(PaneLogic.shouldAutoSwitchToDetails(
            hasSelection: true,
            bottomPaneVisible: true,
            currentTabIsDetails: false,
            differencesPickedManually: flagAfterManualDetailsPick))
    }

    @Test func testAutoSwitchNeverFiresWhenBottomPaneHidden() {
        #expect(!PaneLogic.shouldAutoSwitchToDetails(
            hasSelection: true,
            bottomPaneVisible: false,
            currentTabIsDetails: false,
            differencesPickedManually: false))
    }

    @Test func testAutoSwitchNeverFiresWhenSelectionIsEmpty() {
        #expect(!PaneLogic.shouldAutoSwitchToDetails(
            hasSelection: false,
            bottomPaneVisible: true,
            currentTabIsDetails: false,
            differencesPickedManually: false))
    }

    @Test func testAutoSwitchIsANoOpWhenAlreadyOnDetails() {
        #expect(!PaneLogic.shouldAutoSwitchToDetails(
            hasSelection: true,
            bottomPaneVisible: true,
            currentTabIsDetails: true,
            differencesPickedManually: false))
    }

    // MARK: fullPath

    @Test func testFullPathAppendsRelativePath() {
        #expect(PaneLogic.fullPath(root: "/docs", relativePath: "sub/dir") == "/docs/sub/dir")
    }

    @Test func testFullPathEmptyOrAbsoluteRelativeYieldsRoot() {
        // Empty relative path -> root.
        #expect(PaneLogic.fullPath(root: "/docs", relativePath: "") == "/docs")
        // An absolute "relative" path must not escape the pane root.
        #expect(PaneLogic.fullPath(root: "/docs", relativePath: "/etc") == "/docs")
    }

    @Test func testFullPathExpandsTildeInRoot() {
        let home = NSHomeDirectory()
        #expect(PaneLogic.fullPath(root: "~/Documents", relativePath: "x") == "\(home)/Documents/x")
    }

    // MARK: relativeIgnoreTargets

    @Test func testIgnoreTargetsStripBasePathAndLeadingSlash() {
        let targets = PaneLogic.relativeIgnoreTargets(
            nodeIds: ["/root/docs/a.txt", "/root/docs/sub/b.txt"],
            basePath: "/root/docs")
        #expect(targets == ["a.txt", "sub/b.txt"])
    }

    @Test func testIgnoreTargetsOutsideBasePassThrough() {
        let targets = PaneLogic.relativeIgnoreTargets(
            nodeIds: ["/elsewhere/c.txt"],
            basePath: "/root/docs")
        #expect(targets == ["/elsewhere/c.txt"])
    }

    // MARK: toggledIgnoredPaths

    @Test func testTogglingUnignoredTargetsIgnoresThem() {
        let updated = PaneLogic.toggledIgnoredPaths(targets: ["a", "b"], ignoredPaths: ["c"])
        #expect(updated == ["a", "b", "c"])
    }

    @Test func testTogglingFullyIgnoredTargetsUnignoresThem() {
        let updated = PaneLogic.toggledIgnoredPaths(targets: ["a", "b"], ignoredPaths: ["a", "b", "c"])
        #expect(updated == ["c"])
    }

    @Test func testMixedTargetsAreAllIgnoredNotToggledIndividually() {
        // "a" is already ignored, "b" is not -> the action ignores ALL (a stays ignored).
        let updated = PaneLogic.toggledIgnoredPaths(targets: ["a", "b"], ignoredPaths: ["a"])
        #expect(updated == ["a", "b"])
    }

    // MARK: swappedProviderIds

    @Test func testSwappedProviderIdsExchangeSides() {
        let swapped = PaneLogic.swappedProviderIds(leftProviderId: "iCloud", rightProviderId: "Dropbox")
        #expect(swapped.leftProviderId == "Dropbox")
        #expect(swapped.rightProviderId == "iCloud")
    }

    @Test func testSwappingProviderIdsTwiceRestoresOriginal() {
        let once = PaneLogic.swappedProviderIds(leftProviderId: "A", rightProviderId: "B")
        let twice = PaneLogic.swappedProviderIds(leftProviderId: once.leftProviderId, rightProviderId: once.rightProviderId)
        #expect(twice.leftProviderId == "A")
        #expect(twice.rightProviderId == "B")
    }

    @Test func testSwappingEqualProviderIdsIsANoOp() {
        // Both panes on the same provider: swapping the ids changes nothing, so neither pane's
        // id onChange fires — the swap action must not seed its suppression counter for this case.
        let swapped = PaneLogic.swappedProviderIds(leftProviderId: "iCloud", rightProviderId: "iCloud")
        #expect(swapped.leftProviderId == "iCloud")
        #expect(swapped.rightProviderId == "iCloud")
    }
}

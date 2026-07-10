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

    @Test func testActionBarSymbolsMoveArrowPointsTowardTheTargetPane() {
        // Copy uses the universal duplicate glyph in every state; only Move is directional,
        // pointing toward the pane it targets — right for a left selection, and vice versa.
        let fromLeft = PaneLogic.actionBarSymbols(activePane: .left)
        #expect(fromLeft.copy == "doc.on.doc")
        #expect(fromLeft.move == "arrow.right.square")
        let fromRight = PaneLogic.actionBarSymbols(activePane: .right)
        #expect(fromRight.copy == "doc.on.doc")
        #expect(fromRight.move == "arrow.left.square")
    }

    @Test func testActionBarSymbolsWithoutSelectionKeepNeutralDefaults() {
        let neutral = PaneLogic.actionBarSymbols(activePane: nil)
        #expect(neutral.copy == "doc.on.doc")
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

    // MARK: Resize split layout

    /// Fractions come out of CGFloat division, so compare with a tolerance rather than `==`.
    private func isClose(_ a: Double, _ b: Double, tol: Double = 1e-9) -> Bool { abs(a - b) < tol }

    // horizontalMinFraction

    @Test func testHorizontalMinFractionHonorsThePaneMinimum() {
        // A roomy window: the left pane's floor is minPane / totalWidth, well under 0.5.
        #expect(isClose(PaneLogic.horizontalMinFraction(totalWidth: 1000, minPane: 250), 0.25))
    }

    @Test func testHorizontalMinFractionCapsAtHalfInNarrowWindow() {
        // Narrower than 2×minPane: honoring minPane would demand > 0.5, which would push the
        // minimum past the symmetric upper bound and invert the clamp. The 0.5 cap prevents that.
        #expect(isClose(PaneLogic.horizontalMinFraction(totalWidth: 400, minPane: 250), 0.5))
        // Exactly 2×minPane sits right on the cap.
        #expect(isClose(PaneLogic.horizontalMinFraction(totalWidth: 500, minPane: 250), 0.5))
    }

    @Test func testHorizontalMinFractionIsZeroForDegenerateWidth() {
        // A zero-width window would divide by zero; the guard returns 0 so the math stays finite.
        #expect(PaneLogic.horizontalMinFraction(totalWidth: 0, minPane: 250) == 0)
    }

    // clampedFraction

    @Test func testClampedFractionPassesValuesInsideTheBounds() {
        #expect(isClose(PaneLogic.clampedFraction(0.3, lower: 0.25, upper: 0.75), 0.3))
    }

    @Test func testClampedFractionPinsToTheNearerBound() {
        #expect(isClose(PaneLogic.clampedFraction(0.1, lower: 0.25, upper: 0.75), 0.25))
        #expect(isClose(PaneLogic.clampedFraction(0.9, lower: 0.25, upper: 0.75), 0.75))
    }

    @Test func testClampedFractionPinsToUpperWhenBoundsInvert() {
        // Defensive: if a caller ever passes upper < lower, the outer min wins and the result
        // pins to upper — documenting that the larger section's minimum is the one sacrificed.
        #expect(isClose(PaneLogic.clampedFraction(0.5, lower: 0.6, upper: 0.4), 0.4))
    }

    @Test func testHorizontalSplitDegradesToEvenSplitInNarrowWindow() {
        // End-to-end: in a window too narrow for two full-width panes, a desired fraction that
        // would starve the left pane resolves to an even 0.5 split (both panes equally narrow)
        // rather than collapsing one pane to nothing.
        let totalWidth: CGFloat = 400
        let minFraction = PaneLogic.horizontalMinFraction(totalWidth: totalWidth, minPane: 250)
        let resolved = PaneLogic.clampedFraction(0.15, lower: minFraction, upper: 1 - minFraction)
        #expect(isClose(resolved, 0.5))
    }

    // verticalPanesHeight

    @Test func testVerticalPanesHeightSubtractsTheDivider() {
        #expect(PaneLogic.verticalPanesHeight(totalHeight: 800, dividerHeight: 1) == 799)
    }

    @Test func testVerticalPanesHeightNeverGoesNegative() {
        // A collapsed window shorter than the divider must floor at 0, not go negative.
        #expect(PaneLogic.verticalPanesHeight(totalHeight: 0, dividerHeight: 1) == 0)
    }

    // verticalMinFraction / verticalMaxFraction

    @Test func testVerticalMinFractionHonorsTheBottomMinimum() {
        #expect(isClose(PaneLogic.verticalMinFraction(panesHeight: 800, minBottom: 150), 0.1875))
    }

    @Test func testVerticalMinFractionCapsAndGuardsDegenerateHeight() {
        // Very short area: capped at 0.85 rather than demanding the whole height for the bottom.
        #expect(isClose(PaneLogic.verticalMinFraction(panesHeight: 100, minBottom: 150), 0.85))
        // Zero height divides by zero without the guard.
        #expect(PaneLogic.verticalMinFraction(panesHeight: 0, minBottom: 150) == 0)
    }

    @Test func testVerticalMaxFractionHonorsTheTopMinimum() {
        let minFraction = PaneLogic.verticalMinFraction(panesHeight: 800, minBottom: 150)
        // 1 - 220/800 leaves the top pane at least minTop tall.
        #expect(isClose(PaneLogic.verticalMaxFraction(panesHeight: 800, minTop: 220, minFraction: minFraction), 0.725))
    }

    @Test func testVerticalMaxFractionFloorsAtMinFractionWhenTooShort() {
        // The critical guard: when the area can't hold both minTop and minBottom, `1 - minTop/h`
        // drops below minFraction. Without the max() the clamp bounds would invert; with it the
        // upper bound is floored at minFraction so the two coincide and the split stays valid.
        let minFraction = PaneLogic.verticalMinFraction(panesHeight: 200, minBottom: 150) // 0.75
        let maxFraction = PaneLogic.verticalMaxFraction(panesHeight: 200, minTop: 220, minFraction: minFraction)
        #expect(isClose(minFraction, 0.75))
        #expect(isClose(maxFraction, 0.75))
    }

    @Test func testVerticalMaxFractionIsOneForDegenerateHeight() {
        #expect(PaneLogic.verticalMaxFraction(panesHeight: 0, minTop: 220, minFraction: 0) == 1)
    }

    @Test func testVerticalSplitKeepsBottomMinimumWhenWindowTooShort() {
        // End-to-end: in an area too short for both mins, the resolved fraction pins to the shared
        // bound so the bottom pane keeps its 150pt minimum (the top pane yields the remainder).
        let panesHeight = PaneLogic.verticalPanesHeight(totalHeight: 201, dividerHeight: 1) // 200
        let minFraction = PaneLogic.verticalMinFraction(panesHeight: panesHeight, minBottom: 150)
        let maxFraction = PaneLogic.verticalMaxFraction(panesHeight: panesHeight, minTop: 220, minFraction: minFraction)
        let resolved = PaneLogic.clampedFraction(0.4, lower: minFraction, upper: maxFraction)
        #expect(isClose(Double(panesHeight) * resolved, 150))
    }

    // Drag → fraction conversions

    @Test func testHorizontalDragFractionIsCursorShareOfWidth() {
        #expect(isClose(PaneLogic.horizontalDragFraction(locationX: 300, totalWidth: 1000), 0.3))
    }

    @Test func testVerticalDragFractionIsDistanceFromTheBottomNotTheTop() {
        // The bottom pane grows as the cursor moves up, so a cursor near the top yields a LARGE
        // bottom fraction. A distance-from-top reading would invert the drag.
        #expect(isClose(PaneLogic.verticalDragFraction(locationY: 200, panesHeight: 800), 0.75))
        #expect(isClose(PaneLogic.verticalDragFraction(locationY: 600, panesHeight: 800), 0.25))
    }
}

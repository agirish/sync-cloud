import Testing
import AppKit
import Foundation
import FileExplorer
import Sync
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
        // Both come from the shared TransferGlyph vocabulary so the toolbar can't drift from
        // the Differences header and the right-click menus.
        let fromLeft = PaneLogic.actionBarSymbols(activePane: .left)
        #expect(fromLeft.copy == TransferGlyph.copy)
        #expect(fromLeft.copy == "doc.on.doc")
        #expect(fromLeft.move == TransferGlyph.move(toRight: true))
        #expect(fromLeft.move == "arrow.right.square")
        let fromRight = PaneLogic.actionBarSymbols(activePane: .right)
        #expect(fromRight.copy == TransferGlyph.copy)
        #expect(fromRight.copy == "doc.on.doc")
        #expect(fromRight.move == TransferGlyph.move(toRight: false))
        #expect(fromRight.move == "arrow.left.square")
    }

    @Test func testActionBarSymbolsWithoutSelectionKeepNeutralDefaults() {
        let neutral = PaneLogic.actionBarSymbols(activePane: nil)
        #expect(neutral.copy == TransferGlyph.copy)
        #expect(neutral.copy == "doc.on.doc")
        // No selection yet → no direction; the move box falls back to right-pointing.
        #expect(neutral.move == TransferGlyph.move(toRight: true))
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

    // MARK: tidyTargetsRightPane

    @Test func testTidySingleSourceAlwaysTargetsLeftEvenWithStaleRightSelection() {
        // The Tidy rail IS the left pane, so single-source mode must never target the right pane —
        // even when a selection lingers in the hidden right pane from a prior Compare session (which
        // would otherwise make `activePane` resolve to `.right` and aim the scan at the wrong provider).
        #expect(!PaneLogic.tidyTargetsRightPane(isCompare: false, activePane: .right))
        #expect(!PaneLogic.tidyTargetsRightPane(isCompare: false, activePane: .left))
        #expect(!PaneLogic.tidyTargetsRightPane(isCompare: false, activePane: nil))
    }

    @Test func testTidyCompareFollowsTheFocusedPane() {
        // In compare mode a Tidy scan launched from a menu targets the pane the user is working in.
        #expect(PaneLogic.tidyTargetsRightPane(isCompare: true, activePane: .right))
        #expect(!PaneLogic.tidyTargetsRightPane(isCompare: true, activePane: .left))
        // No selection → left is the natural default (the caller falls back to the left pane).
        #expect(!PaneLogic.tidyTargetsRightPane(isCompare: true, activePane: nil))
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

    @Test func testIgnoreTargetsStripOnlyAtComponentBoundary() {
        // "/root/ab" is not an ancestor of "/root/abc/x" — a bare string prefix must not
        // alias a sibling root into a bogus relative target ("c/x").
        let targets = PaneLogic.relativeIgnoreTargets(
            nodeIds: ["/root/abc/x", "/root/ab/y"],
            basePath: "/root/ab")
        #expect(targets == ["/root/abc/x", "y"])
    }

    // MARK: ignoreBasePath — the base `relativeIgnoreTargets` is measured against
    //
    // `relativeIgnoreTargets` above is only as good as this base: a wrong one produces relative
    // paths that miss the base, get stored verbatim, and hide the wrong files from every future
    // comparison via the durable per-pair ignore store.

    @Test func testIgnoreBasePathAtAPaneRootIsTheExpandedRoot() {
        #expect(PaneLogic.ignoreBasePath(isLeft: true, leftRoot: "/Left", rightRoot: "/Right",
                                         leftRelativePath: "", rightRelativePath: "") == "/Left")
        #expect(PaneLogic.ignoreBasePath(isLeft: false, leftRoot: "/Left", rightRoot: "/Right",
                                         leftRelativePath: "", rightRelativePath: "") == "/Right")
    }

    @Test func testIgnoreBasePathAppendsThePanesOwnFocus() {
        // The cross-pairing catch: each side must take BOTH its root and its focus from its own
        // pane. Mixing them (left root + right focus) points the base at a folder that may not
        // even exist, and every node then falls through as an absolute path.
        #expect(PaneLogic.ignoreBasePath(isLeft: true, leftRoot: "/Left", rightRoot: "/Right",
                                         leftRelativePath: "Docs/2024", rightRelativePath: "Photos")
                == "/Left/Docs/2024")
        #expect(PaneLogic.ignoreBasePath(isLeft: false, leftRoot: "/Left", rightRoot: "/Right",
                                         leftRelativePath: "Docs/2024", rightRelativePath: "Photos")
                == "/Right/Photos")
    }

    @Test func testIgnoreBasePathExpandsATildeRoot() {
        // Provider roots are stored with `~`; an unexpanded base matches no node id on disk.
        let home = NSHomeDirectory()
        #expect(PaneLogic.ignoreBasePath(isLeft: true, leftRoot: "~/CloudStorage/iCloud", rightRoot: "/Right",
                                         leftRelativePath: "Docs", rightRelativePath: "")
                == "\(home)/CloudStorage/iCloud/Docs")
    }

    @Test func testIgnoreBaseFeedsRelativeTargetsEndToEnd() {
        // The composition and the stripper together, as `handleIgnore` runs them: nodes selected
        // in the RIGHT pane while it is focused on a subfolder must reduce to bare, pane-agnostic
        // relative paths — that is what makes one ignore apply to both sides.
        let base = PaneLogic.ignoreBasePath(isLeft: false, leftRoot: "~/Left", rightRoot: "~/Right",
                                            leftRelativePath: "Other", rightRelativePath: "Docs/2024")
        let home = NSHomeDirectory()
        let targets = PaneLogic.relativeIgnoreTargets(
            nodeIds: ["\(home)/Right/Docs/2024/receipt.pdf", "\(home)/Right/Docs/2024/sub/scan.png"],
            basePath: base)
        #expect(targets == ["receipt.pdf", "sub/scan.png"])
    }

    // MARK: paneFocusRestores — reopening last session's folders

    private func restore(_ relativePath: String, _ fullPath: String, isLeft: Bool) -> PaneLogic.PaneFocusRestore {
        PaneLogic.PaneFocusRestore(relativePath: relativePath, fullPath: fullPath, isLeft: isLeft)
    }

    @Test func testFocusRestoreComposesRootAndRelativePathPerPane() async {
        // The composed path is what gets validated and, once valid, becomes the coordinate system
        // for every later relative operation in the session — so both the pairing and the tilde
        // expansion are pinned here.
        let home = NSHomeDirectory()
        var probed: [String] = []
        let restores = await PaneLogic.paneFocusRestores(
            isEnabled: true,
            left: (relativePath: "Docs/2024", root: "~/Left"),
            right: (relativePath: "Photos", root: "/Right"),
            isRestorableDirectory: { probed.append($0); return true })

        #expect(probed == ["\(home)/Left/Docs/2024", "/Right/Photos"])
        #expect(restores == [restore("Docs/2024", "\(home)/Left/Docs/2024", isLeft: true),
                             restore("Photos", "/Right/Photos", isLeft: false)])
    }

    @Test func testFocusRestoreDoesNothingWhenTheSettingIsOff() async {
        var probed = 0
        let restores = await PaneLogic.paneFocusRestores(
            isEnabled: false,
            left: (relativePath: "Docs", root: "/Left"),
            right: (relativePath: "Photos", root: "/Right"),
            isRestorableDirectory: { _ in probed += 1; return true })
        #expect(restores.isEmpty)
        #expect(probed == 0)   // the setting gates before any disk work
    }

    @Test func testFocusRestoreSkipsPanesWithNothingRememberedOrNoRoot() async {
        // Nothing remembered (first launch) and an unresolved provider root both mean "stay at
        // the root" — and neither may be probed, since composing them yields the root itself,
        // which exists and would "restore" a pane onto a path it is already on.
        var probed: [String] = []
        let restores = await PaneLogic.paneFocusRestores(
            isEnabled: true,
            left: (relativePath: "", root: "/Left"),
            right: (relativePath: "Photos", root: ""),
            isRestorableDirectory: { probed.append($0); return true })
        #expect(restores.isEmpty)
        #expect(probed.isEmpty)
    }

    @Test func testFocusRestoreDropsThePaneWhoseFolderIsGone() async {
        // One pane's folder deleted since last session must not disturb the other's restore.
        let restores = await PaneLogic.paneFocusRestores(
            isEnabled: true,
            left: (relativePath: "Gone", root: "/Left"),
            right: (relativePath: "Photos", root: "/Right"),
            isRestorableDirectory: { $0 == "/Right/Photos" })
        #expect(restores == [restore("Photos", "/Right/Photos", isLeft: false)])
    }

    /// The real on-disk check (no injected predicate), which is what decides between reopening a
    /// folder and falling back to the provider root: a directory restores, a missing path doesn't,
    /// and neither does a FILE at that path (a folder replaced by a file of the same name would
    /// otherwise "restore" a pane onto something it cannot show).
    @Test func testFocusRestoreValidatesAgainstTheRealFileSystem() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pane-focus-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Reports"),
                                                withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appendingPathComponent("notes.txt"))
        defer { try? FileManager.default.removeItem(at: root) }

        let existing = await PaneLogic.paneFocusRestores(
            isEnabled: true,
            left: (relativePath: "Reports", root: root.path),
            right: (relativePath: "Gone", root: root.path))
        #expect(existing == [restore("Reports", root.appendingPathComponent("Reports").path, isLeft: true)])

        let fileNotFolder = await PaneLogic.paneFocusRestores(
            isEnabled: true,
            left: (relativePath: "notes.txt", root: root.path),
            right: (relativePath: "", root: root.path))
        #expect(fileNotFolder.isEmpty)
    }

    // The toggledIgnoredPaths cases moved to Sync's PersistentIgnoresTests alongside
    // `FileSyncManager.toggleIgnored(focusRelativePaths:)`, which superseded the helper.

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

    // inspectorDragWidth

    @Test func testInspectorDragLeftWidensRightNarrows() {
        // The handle is on the panel's leading edge: dragging left (negative translation) widens it,
        // dragging right (positive) narrows it.
        #expect(isClose(PaneLogic.inspectorDragWidth(base: 270, translation: -50), 320))
        #expect(isClose(PaneLogic.inspectorDragWidth(base: 270, translation: 50), 220))
    }

    @Test func testInspectorDragWidthClampsToBounds() {
        // A big drag can't push the panel below the content floor or past the window-safety cap.
        #expect(isClose(PaneLogic.inspectorDragWidth(base: 270, translation: 500), PaneLogic.inspectorMinWidth))
        #expect(isClose(PaneLogic.inspectorDragWidth(base: 270, translation: -1000), PaneLogic.inspectorMaxWidth))
    }

    // MARK: bootstrapSteps

    @Test func testFirstAppearanceRunsTheFullBootstrapInOrder() {
        // First launch must behave exactly as before the single-window change: launch
        // defaults, per-window wiring, then provider discovery with the distinct-pair
        // selection and initial scan. Order is part of the contract — the undo manager and
        // action handler must be wired before the discovery task can trigger a refresh.
        #expect(PaneLogic.bootstrapSteps(isFirstAppearance: true) == [
            .resetShowHiddenFilesFromDefault,
            .honorOpenSettingsOnLaunch,
            .createActionHandler,
            .rewireUndoManager,
            .syncProviderQuirkSettings,
            .discoverProvidersAndApplyInitialSelection,
        ])
    }

    @Test func testReappearanceRunsOnlyPerWindowWiring() {
        // A Dock-click reopen recreates ContentView mid-session. It must NOT re-run the
        // session steps: resetting showHiddenFiles would discard a mid-session toggle, and
        // re-applying the distinct-pair selection would silently flip a right pane the user
        // deliberately set to the same provider as the left.
        let steps = PaneLogic.bootstrapSteps(isFirstAppearance: false)
        #expect(steps == [
            .createActionHandler,
            .rewireUndoManager,
            .endProviderBootstrapGuard,
        ])
        #expect(!steps.contains(.resetShowHiddenFilesFromDefault))
        #expect(!steps.contains(.discoverProvidersAndApplyInitialSelection))
    }

    @Test func testEveryAppearanceRewiresTheWindowScopedState() {
        // The recreated window brings a fresh UndoManager and a nil @State action handler;
        // both must be rewired on every appearance, and the recreated view's
        // isBootstrappingProviders guard must be cleared exactly when no discovery will do it.
        for first in [true, false] {
            let steps = PaneLogic.bootstrapSteps(isFirstAppearance: first)
            #expect(steps.contains(.createActionHandler))
            #expect(steps.contains(.rewireUndoManager))
            #expect(steps.contains(.endProviderBootstrapGuard) != first)
        }
    }

    // MARK: - Duplicate-review keeper gate (trashRightCopy)

    @Test func testKeeperGateRefusesMissingKeeper() {
        // Gone entirely: refuse whether it was a file or a folder.
        #expect(!PaneLogic.duplicateKeeperMatchesScan(
            exists: false, isDirectory: false, statSucceeded: false, currentSize: nil, scannedSize: 100))
        #expect(!PaneLogic.duplicateKeeperMatchesScan(
            exists: false, isDirectory: true, statSucceeded: false, currentSize: nil, scannedSize: 100))
    }

    @Test func testKeeperGateRefusesDriftedFileSize() {
        // Round-4 fix: trashRightCopy used to check existence only, while the engine's
        // keeperStillExists also compares the file's current byte size against the scan
        // snapshot — an in-place edit or replacement means the right copy is no longer
        // provably identical to the keeper, so trashing it could trash the last copy of
        // the original content.
        #expect(!PaneLogic.duplicateKeeperMatchesScan(
            exists: true, isDirectory: false, statSucceeded: true, currentSize: 555, scannedSize: 100))
        #expect(PaneLogic.duplicateKeeperMatchesScan(
            exists: true, isDirectory: false, statSucceeded: true, currentSize: 100, scannedSize: 100))
    }

    @Test func testKeeperGateFolderIsExistenceOnly() {
        // A folder's stat size isn't its recursive content size (the engine's carve-out),
        // so folders never size-refuse — existence decides.
        #expect(PaneLogic.duplicateKeeperMatchesScan(
            exists: true, isDirectory: true, statSucceeded: true, currentSize: 555, scannedSize: 100))
        #expect(PaneLogic.duplicateKeeperMatchesScan(
            exists: true, isDirectory: true, statSucceeded: false, currentSize: nil, scannedSize: 100))
    }

    @Test func testKeeperGateStatEdgeCasesMatchEngine() {
        // A failed attributes read refuses for a file (engine: `guard let attrs ... else
        // { return false }`); a successful stat with no size value falls back to the
        // existence check rather than over-refuse (engine: `if let currentSize`).
        #expect(!PaneLogic.duplicateKeeperMatchesScan(
            exists: true, isDirectory: false, statSucceeded: false, currentSize: nil, scannedSize: 100))
        #expect(PaneLogic.duplicateKeeperMatchesScan(
            exists: true, isDirectory: false, statSucceeded: true, currentSize: nil, scannedSize: 100))
    }

    // MARK: Escape clears the selection

    @Test func testEscapeOnTheSingleSourceRailReadsThePanesOwnSelection() {
        // The rail has no action bar, so `barSelectionNodes` — which is hard-gated to compare mode —
        // is always empty there. Gating Escape on it meant the ONE surface with no ✕ and no action
        // bar was also the one where Escape did nothing: a picked folder could never be un-picked.
        #expect(PaneLogic.escapeClearsSelection(
            isSingleSource: true, hasActionBarSelection: false, paneHasSelection: true))
        // Nothing selected: Escape must bubble (a sheet or the window may want it).
        #expect(!PaneLogic.escapeClearsSelection(
            isSingleSource: true, hasActionBarSelection: false, paneHasSelection: false))
    }

    @Test func testEscapeInCompareModeStillGatesOnTheActionBarExactly() {
        // Unchanged on the compare side, deliberately: a selected path the action bar cannot resolve
        // to a node leaves Escape to bubble, exactly as before.
        #expect(PaneLogic.escapeClearsSelection(
            isSingleSource: false, hasActionBarSelection: true, paneHasSelection: true))
        #expect(!PaneLogic.escapeClearsSelection(
            isSingleSource: false, hasActionBarSelection: false, paneHasSelection: true))
    }
}

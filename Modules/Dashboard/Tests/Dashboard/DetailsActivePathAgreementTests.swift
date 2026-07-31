import Testing
import Foundation
import Sync
@testable import Dashboard

/// The Info inspector and Space must name the SAME file.
///
/// They did not. `activePath` hand-derived the pane selection under a comment claiming it matched
/// `PaneLogic.primarySelectionPath`, while Space resolved whatever surface happened to hold key
/// focus — so the inspector showed the pane's file and Space previewed the Differences row. These
/// pin the agreement rather than each side's arithmetic, because the disagreement WAS the bug.
///
/// Constructed, never rendered: `DetailsSidebar` stats synchronously on appear and wedges a test
/// host. `activePath` is a pure read over `syncManager`, so it needs no mount.
@MainActor
@Suite struct DetailsActivePathAgreementTests {

    private func sidebar(_ manager: FileSyncManager,
                         overridePath: String? = nil,
                         singleSource: Bool = false) -> DetailsSidebar {
        DetailsSidebar(syncManager: manager,
                       leftPath: "/left/root",
                       rightPath: "/right/root",
                       overridePath: overridePath,
                       singleSource: singleSource)
    }

    /// The reported case: a multi-item left-pane selection. Both sides must land on the same file,
    /// and specifically on the alphabetically first one rather than an arbitrary `Set` element.
    @Test func inspectorAndResolverAgreeOnAMultiItemPaneSelection() {
        let manager = FileSyncManager()
        manager.selectedLeftPaths = ["/left/mike.txt", "/left/alpha.txt", "/left/zulu.txt"]

        let resolved = CurrentSelection.primaryPanePath(
            left: manager.selectedLeftPaths, right: manager.selectedRightPaths)

        #expect(resolved == "/left/alpha.txt")
        #expect(sidebar(manager).activePath == resolved)
    }

    /// Left-over-right, agreed by both.
    @Test func inspectorAndResolverAgreeWhenBothPanesHoldSomething() {
        let manager = FileSyncManager()
        manager.selectedLeftPaths = ["/left/zeta.txt"]
        manager.selectedRightPaths = ["/right/alpha.txt"]

        let resolved = CurrentSelection.primaryPanePath(
            left: manager.selectedLeftPaths, right: manager.selectedRightPaths)

        #expect(resolved == "/left/zeta.txt")
        #expect(sidebar(manager).activePath == resolved)
    }

    /// The rail's hidden right pane, agreed by both — this is the rule that used to be written out
    /// three separate times (here, the rail's Space handler, and the resolver).
    @Test func inspectorAndResolverAgreeThatSingleSourceIgnoresTheRightPane() {
        let manager = FileSyncManager()
        manager.selectedRightPaths = ["/right/leftover.txt"]

        #expect(CurrentSelection.primaryPanePath(
            left: manager.selectedLeftPaths,
            right: manager.selectedRightPaths,
            singleSource: true) == nil)
        // With no pane selection to show, the inspector falls back to the navigated folder — it
        // must NOT surface the hidden pane's leftover.
        #expect(sidebar(manager, singleSource: true).activePath == "/left/root")
    }

    /// "Get Info" on a Differences row still overrides everything: that row has no pane selection
    /// of its own, so the override is the only way the inspector can point at it.
    @Test func getInfoOverrideStillBeatsThePaneSelection() {
        let manager = FileSyncManager()
        manager.selectedLeftPaths = ["/left/alpha.txt"]
        #expect(sidebar(manager, overridePath: "/diff/target.txt").activePath == "/diff/target.txt")
    }

    /// Nothing selected: the inspector falls back to the navigated folder while the resolver says
    /// nil. They do not disagree — nil is "no selected file", which is exactly the state the
    /// fallback exists to describe, and Space returns `.ignored` for it.
    @Test func emptySelectionFallsBackToTheNavigatedFolder() {
        let manager = FileSyncManager()
        #expect(CurrentSelection.primaryPanePath(
            left: manager.selectedLeftPaths, right: manager.selectedRightPaths) == nil)
        #expect(sidebar(manager).activePath == "/left/root")
        #expect(sidebar(manager).isShowingFocusedFolderFallback)
    }

    // MARK: The caption must answer for the same branches activePath takes

    /// "Get Info" on a differences row sets the override precisely when no pane holds a selection,
    /// so the caption's hand-derived "nothing is selected" test called that a focused-folder
    /// fallback — captioning a file the user explicitly asked about "— focused folder", which is
    /// wrong twice: it is not the focused folder, and it IS an item they chose.
    @Test func aGetInfoTargetIsNotAFocusedFolderFallback() {
        let manager = FileSyncManager()
        let view = sidebar(manager, overridePath: "/diff/target.txt")
        #expect(view.activePath == "/diff/target.txt")
        #expect(view.isShowingFocusedFolderFallback == false)
    }

    /// The caption and `activePath` must agree in every combination, not just the reported one.
    ///
    /// The expectation is deliberately NOT a restatement of the caption's own condition — that
    /// would pass against any implementation that matched itself. It ties the caption to the
    /// observable outcome instead: the caption claims a focused-folder fallback exactly when
    /// `activePath` actually returned the navigated folder. No fixture selection or override
    /// equals `/left/root`, so that comparison can only be true by falling back.
    @Test func theCaptionAgreesWithActivePathAcrossEveryBranch() {
        for override in [nil, "", "/diff/target.txt"] {
            for left in [Set<String>(), ["/left/a.txt"]] {
                for right in [Set<String>(), ["/right/b.txt"]] {
                    for singleSource in [false, true] {
                        let manager = FileSyncManager()
                        manager.selectedLeftPaths = left
                        manager.selectedRightPaths = right
                        let view = sidebar(manager, overridePath: override, singleSource: singleSource)
                        #expect(view.isShowingFocusedFolderFallback == (view.activePath == "/left/root"),
                                "override=\(override ?? "nil") left=\(left) right=\(right) single=\(singleSource)")
                    }
                }
            }
        }
    }
}

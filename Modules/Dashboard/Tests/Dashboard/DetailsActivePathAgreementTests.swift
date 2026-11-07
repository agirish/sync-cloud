import Testing
import Foundation
import Sync
@testable import Dashboard

/// The Info inspector and Space must name the same file. These pin the agreement between
/// `activePath` and `CurrentSelection.primaryPanePath`, not each side's arithmetic, since two
/// rules that each look right can still name different files.
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

    /// A multi-item left-pane selection: both sides land on the alphabetically first file, not an
    /// arbitrary `Set` element.
    @Test func inspectorAndResolverAgreeOnAMultiItemPaneSelection() {
        let manager = FileSyncManager()
        manager.selectedLeftPaths = ["/left/mike.txt", "/left/alpha.txt", "/left/zulu.txt"]

        let resolved = CurrentSelection.primaryPanePath(
            left: manager.selectedLeftPaths, right: manager.selectedRightPaths)

        #expect(resolved == "/left/alpha.txt")
        #expect(sidebar(manager).activePath == resolved)
    }

    /// Left-over-right, agreed by both. With the left cleared, the right pane's item wins.
    @Test func inspectorAndResolverAgreeWhenBothPanesHoldSomething() {
        let manager = FileSyncManager()
        manager.selectedLeftPaths = ["/left/zeta.txt"]
        manager.selectedRightPaths = ["/right/alpha.txt"]

        let resolved = CurrentSelection.primaryPanePath(
            left: manager.selectedLeftPaths, right: manager.selectedRightPaths)

        #expect(resolved == "/left/zeta.txt")
        #expect(sidebar(manager).activePath == resolved)

        manager.selectedLeftPaths = []
        #expect(sidebar(manager).activePath == "/right/alpha.txt")
    }

    /// Single-source ignores the rail's hidden right pane, agreed by both.
    @Test func inspectorAndResolverAgreeThatSingleSourceIgnoresTheRightPane() {
        let manager = FileSyncManager()
        manager.selectedRightPaths = ["/right/leftover.txt"]

        #expect(CurrentSelection.primaryPanePath(
            left: manager.selectedLeftPaths,
            right: manager.selectedRightPaths,
            singleSource: true) == nil)
        // With no pane selection, the inspector falls back to the navigated folder and must not
        // surface the hidden pane's leftover.
        #expect(sidebar(manager, singleSource: true).activePath == "/left/root")
    }

    /// Following the right pane: with both panes holding something, the inspector describes the
    /// right pane's item, not the left one the left-first rule would pick. An empty right pane
    /// still falls through to the left.
    @Test func followingTheRightPaneDescribesItFirst() {
        let manager = FileSyncManager()
        manager.selectedLeftPaths = ["/left/zeta.txt"]
        manager.selectedRightPaths = ["/right/alpha.txt"]
        let following = DetailsSidebar(syncManager: manager, leftPath: "/left/root", rightPath: "/right/root",
                                       followsRight: true)
        #expect(following.activePath == "/right/alpha.txt")
        #expect(!following.isShowingFocusedFolderFallback)

        manager.selectedRightPaths = []
        #expect(following.activePath == "/left/zeta.txt")
    }

    @Test func followingTheRightPaneSummarizesItsSelection() {
        let manager = FileSyncManager()
        manager.selectedLeftPaths = ["/left/a.txt", "/left/b.txt", "/left/c.txt"]
        manager.selectedRightPaths = ["/right/one.txt"]
        let following = DetailsSidebar(syncManager: manager, leftPath: "/left/root", rightPath: "/right/root",
                                       followsRight: true)
        #expect(following.selectionSummary == nil,
                "a single right-pane item was summarized as the left pane's three")
        #expect(DetailsSidebar(syncManager: manager, leftPath: "/left/root", rightPath: "/right/root")
            .selectionSummary != nil, "the left pane's three were not summarized — the case above is vacuous")
    }

    /// "Get Info" on a Differences row still overrides everything: that row has no pane selection
    /// of its own, so the override is the only way the inspector can point at it.
    @Test func getInfoOverrideStillBeatsThePaneSelection() {
        let manager = FileSyncManager()
        manager.selectedLeftPaths = ["/left/alpha.txt"]
        #expect(sidebar(manager, overridePath: "/diff/target.txt").activePath == "/diff/target.txt")
    }

    /// Nothing selected: the inspector falls back to the navigated folder while the resolver says
    /// nil. That is agreement: nil means "no selected file", the state the fallback describes, and
    /// Space returns `.ignored` for it.
    @Test func emptySelectionFallsBackToTheNavigatedFolder() {
        let manager = FileSyncManager()
        #expect(CurrentSelection.primaryPanePath(
            left: manager.selectedLeftPaths, right: manager.selectedRightPaths) == nil)
        #expect(sidebar(manager).activePath == "/left/root")
        #expect(sidebar(manager).isShowingFocusedFolderFallback)
    }

    // MARK: The caption must answer for the same branches activePath takes

    /// "Get Info" on a differences row sets the override when no pane holds a selection. A caption
    /// keyed on "nothing is selected" would call that file "— focused folder", which is wrong
    /// twice: it isn't the focused folder, and the user chose it.
    @Test func aGetInfoTargetIsNotAFocusedFolderFallback() {
        let manager = FileSyncManager()
        let view = sidebar(manager, overridePath: "/diff/target.txt")
        #expect(view.activePath == "/diff/target.txt")
        #expect(view.isShowingFocusedFolderFallback == false)
    }

    /// The caption and `activePath` agree in every combination. The expectation ties the caption to
    /// the outcome, not to its own condition (which would always match itself): it claims a
    /// fallback exactly when `activePath` returned the navigated folder. No fixture equals
    /// `/left/root`, so that can only be true by falling back.
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

    /// A Get Info target beats a pane's multi-selection summary too; otherwise Get Info with three
    /// files selected in a pane shows "3 items" and seems to do nothing.
    @Test func getInfoBeatsAMultiSelectionSummary() {
        let manager = FileSyncManager()
        manager.selectedLeftPaths = ["/left/a.txt", "/left/b.txt", "/left/c.txt"]
        let plain = DetailsSidebar(syncManager: manager, leftPath: "/left/root", rightPath: "/right/root")
        #expect(plain.selectionSummary != nil, "three items were not summarized — the case below is vacuous")
        let info = DetailsSidebar(syncManager: manager, leftPath: "/left/root", rightPath: "/right/root",
                                  overridePath: "/diff/target.txt")
        #expect(info.selectionSummary == nil)
        #expect(info.activePath == "/diff/target.txt")
    }

    /// Following the right pane with nothing selected: the right pane's folder, the pane the caption
    /// names.
    @Test func followingTheRightPaneWithNothingSelectedShowsItsFolder() {
        let manager = FileSyncManager()
        let following = DetailsSidebar(syncManager: manager, leftPath: "/left/root", rightPath: "/right/root",
                                       followsRight: true)
        #expect(following.activePath == "/right/root")
        #expect(following.isShowingFocusedFolderFallback)
        #expect(DetailsSidebar(syncManager: manager, leftPath: "/left/root", rightPath: "/right/root")
            .activePath == "/left/root")
    }
}

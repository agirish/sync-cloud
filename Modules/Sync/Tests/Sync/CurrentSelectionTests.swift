import Testing
import Foundation
@testable import Sync

/// The rule that decides which file the app means when a pane and the Differences table both hold
/// a selection — the ambiguity that made Space preview one file while the Info inspector showed
/// another.
@Suite struct CurrentSelectionTests {

    // MARK: primaryPanePath

    /// Left wins over right. The one-pane-selected invariant means both are rarely populated at
    /// once, but a swap and a deferred cross-pane clear can both leave them briefly overlapping.
    @Test func leftPaneWinsOverRight() {
        #expect(CurrentSelection.primaryPanePath(left: ["/a/zeta"], right: ["/a/alpha"]) == "/a/zeta")
    }

    @Test func fallsBackToRightWhenLeftIsEmpty() {
        #expect(CurrentSelection.primaryPanePath(left: [], right: ["/a/alpha"]) == "/a/alpha")
    }

    /// `Set.first` is arbitrary per hash seed, so a multi-item selection resolved through `first`
    /// previews a different file on every launch. Asserted over enough elements that a seed-order
    /// coincidence is not what makes this pass.
    @Test func multiSelectionResolvesToTheAlphabeticallyFirstPath() {
        let many: Set<String> = ["/a/mike", "/a/alpha", "/a/zulu", "/a/bravo", "/a/november"]
        #expect(CurrentSelection.primaryPanePath(left: many, right: []) == "/a/alpha")
    }

    /// The single-source rail hides the right pane, so a selection left behind in it must not surface.
    /// Both the rail's Space handler and the Info inspector rely on this.
    @Test func singleSourceIgnoresTheHiddenRightPane() {
        #expect(CurrentSelection.primaryPanePath(left: [], right: ["/a/alpha"], singleSource: true) == nil)
        #expect(CurrentSelection.primaryPanePath(left: ["/a/zeta"], right: ["/a/alpha"], singleSource: true) == "/a/zeta")
    }

    @Test func noPaneSelectionResolvesToNil() {
        #expect(CurrentSelection.primaryPanePath(left: [], right: []) == nil)
    }

    // MARK: quickLookPath — the tie-break

    /// THE BUG. Both surfaces hold a selection and the user last picked in a pane: Space must
    /// preview the pane's file, which is also what the Info inspector is showing.
    @Test func paneWinsWhenItWasTouchedLast() {
        #expect(CurrentSelection.quickLookPath(
            lastInteracted: .pane,
            panePath: "/pane/file.txt",
            differencesPath: "/diff/other.txt") == "/pane/file.txt")
    }

    /// The mirror case, and the one that must not regress: working in the Differences table with a
    /// stale pane selection still previews the Differences row.
    @Test func differencesWinsWhenItWasTouchedLast() {
        #expect(CurrentSelection.quickLookPath(
            lastInteracted: .differences,
            panePath: "/pane/file.txt",
            differencesPath: "/diff/other.txt") == "/diff/other.txt")
    }

    /// A surface can hold the token and yet be empty — clearing a selection deliberately does not
    /// hand the token away. Falling through keeps Space working instead of going dead.
    @Test func anEmptyTokenHolderFallsThroughToTheOtherSurface() {
        #expect(CurrentSelection.quickLookPath(
            lastInteracted: .differences,
            panePath: "/pane/file.txt",
            differencesPath: nil) == "/pane/file.txt")
        #expect(CurrentSelection.quickLookPath(
            lastInteracted: .pane,
            panePath: nil,
            differencesPath: "/diff/other.txt") == "/diff/other.txt")
    }

    /// Before the first selection of the session there is no token. A fresh window is looking at
    /// the panes, so they are the default — not "preview nothing".
    @Test func noTokenYetPrefersThePanes() {
        #expect(CurrentSelection.quickLookPath(
            lastInteracted: nil,
            panePath: "/pane/file.txt",
            differencesPath: "/diff/other.txt") == "/pane/file.txt")
    }

    /// Nothing selected anywhere is the ONLY case that previews nothing. Every caller turns this
    /// into `.ignored`, which is what keeps Space available to text fields.
    @Test func nothingSelectedAnywhereResolvesToNil() {
        for token: SelectionSurface? in [nil, .pane, .differences] {
            #expect(CurrentSelection.quickLookPath(
                lastInteracted: token, panePath: nil, differencesPath: nil) == nil,
                "token \(String(describing: token)) should resolve to nil")
        }
    }

    // MARK: - Following the selection with the panel already open

    /// The whole point: an open panel is a view of the CURRENT file, not a snapshot of the file
    /// that was current when Space was pressed.
    @Test func anOpenPanelFollowsThePaneSelection() {
        #expect(CurrentSelection.previewFollow(
            showing: "/pane/old.txt", followsPane: true, panePath: "/pane/new.txt")
            == .retarget("/pane/new.txt"))
    }

    /// Deselecting leaves nothing for a preview to be OF. Keeping the last file up is the stale
    /// panel; blanking it leaves a window to dismiss by hand. Finder closes it.
    @Test func clearingTheSelectionClosesThePanel() {
        #expect(CurrentSelection.previewFollow(
            showing: "/pane/old.txt", followsPane: true, panePath: nil) == .close)
    }

    /// **The arm that must never do anything else.** A selection change with no panel open must not
    /// OPEN one — a preview nobody asked for is the defect this whole area was fixed for.
    @Test func aClosedPanelIsNeverOpenedByASelection() {
        for follows in [true, false] {
            #expect(CurrentSelection.previewFollow(
                showing: nil, followsPane: follows, panePath: "/pane/new.txt") == .stay,
                "followsPane \(follows) opened a panel nobody asked for")
            #expect(CurrentSelection.previewFollow(
                showing: nil, followsPane: follows, panePath: nil) == .stay)
        }
    }

    /// A preview a Differences row or the Info inspector put up is not the pane's to move. Both
    /// selections can be live at once (that is why `quickLookPath` exists at all), so a pane click
    /// is not a statement about what the other surface is showing.
    @Test func aPanelOpenedElsewhereIsLeftAlone() {
        #expect(CurrentSelection.previewFollow(
            showing: "/diff/row.txt", followsPane: false, panePath: "/pane/new.txt") == .stay)
        #expect(CurrentSelection.previewFollow(
            showing: "/diff/row.txt", followsPane: false, panePath: nil) == .stay,
            "clearing the PANE selection must not close a DIFFERENCES preview")
    }

    /// Re-selecting the file already showing is not a change. Without this the panel is handed the
    /// same URL on every republish that touches the selection, and `QLPreviewView` restarts its
    /// extension's render for each one.
    @Test func reselectingTheSameFileIsNotAMove() {
        #expect(CurrentSelection.previewFollow(
            showing: "/pane/same.txt", followsPane: true, panePath: "/pane/same.txt") == .stay)
    }
}

import Testing
import Foundation
@testable import Sync

/// Which file the app means when a pane and the Differences table both hold a selection, so Space
/// never previews one file while the Info inspector shows another.
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

    /// `Set.first` is arbitrary per hash seed, so resolving through it would preview a different
    /// file each launch. Enough elements that seed order can't make this pass by chance.
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

    /// Both surfaces hold a selection and the user last picked in a pane: Space previews the pane's
    /// file, which is also what the Info inspector shows.
    @Test func paneWinsWhenItWasTouchedLast() {
        #expect(CurrentSelection.quickLookPath(
            lastInteracted: .pane,
            panePath: "/pane/file.txt",
            differencesPath: "/diff/other.txt") == "/pane/file.txt")
    }

    /// The mirror case: working in the Differences table with a stale pane selection still
    /// previews the Differences row.
    @Test func differencesWinsWhenItWasTouchedLast() {
        #expect(CurrentSelection.quickLookPath(
            lastInteracted: .differences,
            panePath: "/pane/file.txt",
            differencesPath: "/diff/other.txt") == "/diff/other.txt")
    }

    /// A surface can hold the token and be empty, since clearing a selection doesn't hand the token
    /// away. Falling through keeps Space working instead of going dead.
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

    /// Before the session's first selection there is no token. A fresh window shows the panes, so
    /// they are the default, not "preview nothing".
    @Test func noTokenYetPrefersThePanes() {
        #expect(CurrentSelection.quickLookPath(
            lastInteracted: nil,
            panePath: "/pane/file.txt",
            differencesPath: "/diff/other.txt") == "/pane/file.txt")
    }

    /// Nothing selected anywhere is the only case that previews nothing. Every caller turns it into
    /// `.ignored`, which keeps Space available to text fields.
    @Test func nothingSelectedAnywhereResolvesToNil() {
        for token: SelectionSurface? in [nil, .pane, .differences] {
            #expect(CurrentSelection.quickLookPath(
                lastInteracted: token, panePath: nil, differencesPath: nil) == nil,
                "token \(String(describing: token)) should resolve to nil")
        }
    }

    // MARK: - Following the selection with the panel already open

    /// An open panel shows the current file, not a snapshot of the one current when Space was
    /// pressed.
    @Test func anOpenPanelFollowsThePaneSelection() {
        #expect(CurrentSelection.previewFollow(
            showing: "/pane/old.txt", followsPane: true, panePath: "/pane/new.txt")
            == .retarget("/pane/new.txt"))
    }

    /// Deselecting leaves nothing to preview. Keeping the last file up is stale, and blanking it
    /// leaves a window to dismiss by hand, so it closes, as Finder's does.
    @Test func clearingTheSelectionClosesThePanel() {
        #expect(CurrentSelection.previewFollow(
            showing: "/pane/old.txt", followsPane: true, panePath: nil) == .close)
    }

    /// A selection change with no panel open never opens one: a preview nobody asked for is the
    /// defect this guards against.
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
    /// selections can be live at once (why `quickLookPath` exists), so a pane click says nothing
    /// about what the other surface shows.
    @Test func aPanelOpenedElsewhereIsLeftAlone() {
        #expect(CurrentSelection.previewFollow(
            showing: "/diff/row.txt", followsPane: false, panePath: "/pane/new.txt") == .stay)
        #expect(CurrentSelection.previewFollow(
            showing: "/diff/row.txt", followsPane: false, panePath: nil) == .stay,
            "clearing the PANE selection must not close a DIFFERENCES preview")
    }

    /// Re-selecting the file already showing is not a change; otherwise every republish touching
    /// the selection hands the panel the same URL, and `QLPreviewView` restarts its render each time.
    @Test func reselectingTheSameFileIsNotAMove() {
        #expect(CurrentSelection.previewFollow(
            showing: "/pane/same.txt", followsPane: true, panePath: "/pane/same.txt") == .stay)
    }
}

import Testing
import Foundation
import Sync
@testable import FileExplorer

/// **The armed file is not a selection, and every test here is a way of saying so.**
///
/// The cross-pane compare was reachable only by right-click, because a left-click in the other pane
/// writes a selection and `applySelectionWrite` clears the first pane in the same update. Pick mode
/// keeps the armed file outside both sets, so the click that used to destroy the state completes it
/// instead — and the one-pane-selected invariant is untouched.
@Suite struct ComparePickTests {

    private func node(_ path: String, isDirectory: Bool = false) -> FileNode {
        FileNode(id: path, name: (path as NSString).lastPathComponent, isDirectory: isDirectory)
    }

    private func pick(_ path: String = "/left/Lease — Signed.pdf", isLeft: Bool = true) -> ComparePick {
        ComparePick(armed: node(path), armedPaneIsLeft: isLeft)
    }

    // MARK: The three outcomes

    /// A file in the OTHER pane completes the pick — the gesture that used to lose the armed half.
    @Test func aFileInTheOtherPaneCompletesThePair() throws {
        let outcome = pick().outcome(clicking: node("/right/lease-final-scan.pdf"), inLeftPane: false,
                                     leftPaneName: "iCloud", rightPaneName: "Dropbox")
        guard case .paired(let pair) = outcome else {
            Issue.record("expected a pair, got \(outcome)")
            return
        }
        // Ordered by PANE SIDE, so the viewer's columns match its subtitle.
        #expect(pair.leftPath == "/left/Lease — Signed.pdf")
        #expect(pair.rightPath == "/right/lease-final-scan.pdf")
    }

    /// Armed in the RIGHT pane, clicked in the left: the armed file must land in the right column,
    /// not the first one. This is the case a "clicked always leads" ordering gets backwards.
    @Test func theArmedFileFollowsItsOwnPaneNotTheClickOrder() throws {
        let outcome = pick("/right/scan.pdf", isLeft: false)
            .outcome(clicking: node("/left/original.pdf"), inLeftPane: true,
                     leftPaneName: "iCloud", rightPaneName: "Dropbox")
        guard case .paired(let pair) = outcome else {
            Issue.record("expected a pair, got \(outcome)")
            return
        }
        #expect(pair.leftPath == "/left/original.pdf")
        #expect(pair.rightPath == "/right/scan.pdf",
                "the armed file was ordered by click order, so the columns contradict the subtitle")
    }

    /// A same-pane pick leads with the ARMED file — the one the reader chose first, and the one the
    /// strip has been naming since.
    @Test func aSamePanePairLeadsWithTheArmedFile() throws {
        let outcome = pick().outcome(clicking: node("/left/Addendum.pdf"), inLeftPane: true,
                                     leftPaneName: "iCloud", rightPaneName: "Dropbox")
        guard case .paired(let pair) = outcome else {
            Issue.record("expected a pair, got \(outcome)")
            return
        }
        #expect(pair.leftPath == "/left/Lease — Signed.pdf")
        #expect(pair.rightPath == "/left/Addendum.pdf")
    }

    /// **Clicking the armed row again cancels** — the marker is the off switch, which is the only
    /// undo a mode anchored to one row can offer without a second control.
    @Test func clickingTheArmedRowAgainCancels() {
        #expect(pick().outcome(clicking: node("/left/Lease — Signed.pdf"), inLeftPane: true,
                               leftPaneName: "iCloud", rightPaneName: "Dropbox") == .cancelled)
        // Even from the other pane, if the same path is somehow shown there: identity is the path.
        #expect(pick().outcome(clicking: node("/left/Lease — Signed.pdf"), inLeftPane: false,
                               leftPaneName: "iCloud", rightPaneName: "Dropbox") == .cancelled)
    }

    /// **A folder leaves the mode standing.** Finding the counterpart usually means navigating, so
    /// a folder click that cancelled the pick would make the feature unusable for exactly the pair
    /// it exists to serve — two files in different folders.
    @Test func aFolderClickLeavesTheModeStanding() {
        #expect(pick().outcome(clicking: node("/left/Addenda", isDirectory: true), inLeftPane: true,
                               leftPaneName: "iCloud", rightPaneName: "Dropbox") == .standing)
        #expect(pick().outcome(clicking: node("/right/Scans", isDirectory: true), inLeftPane: false,
                               leftPaneName: "iCloud", rightPaneName: "Dropbox") == .standing)
    }

    // MARK: What the reader sees

    /// The indicator is handed the NAME, not a finished sentence.
    ///
    /// **Because the name is the part that has to truncate.** Real filenames run long — the one
    /// this was found on was "Irrigation system check 10-10-2024 ( Clock C ) readvised new
    /// templet.3-18.pdf" — and a sentence with the name buried inside it truncates the sentence
    /// too, taking the instruction with it. The strip bounds the name alone and composes the words
    /// around it.
    @Test func theIndicatorIsGivenTheNameAloneToBound() {
        #expect(pick().armedName == "Lease — Signed.pdf")
        let long = ComparePick(armed: node("/left/Irrigation system check 10-10-2024 ( Clock C ) readvised new templet.3-18.pdf"),
                               armedPaneIsLeft: true)
        #expect(long.armedName == "Irrigation system check 10-10-2024 ( Clock C ) readvised new templet.3-18.pdf",
                "the name arrived pre-shortened — truncation belongs to the view, which knows the width")
    }

    /// The row marker is keyed on the armed path, so it survives the selection moving away, a
    /// scroll, and a navigation — none of which it is derived from.
    @Test func theMarkerFollowsTheArmedPathAlone() {
        let p = pick()
        #expect(p.marks("/left/Lease — Signed.pdf"))
        #expect(!p.marks("/left/Addendum.pdf"))
    }
}

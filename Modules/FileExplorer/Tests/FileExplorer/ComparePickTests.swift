import Testing
import Foundation
import Sync
@testable import FileExplorer

/// The armed file is not a selection. A left-click in the other pane writes a selection, and
/// `applySelectionWrite` clears the first pane in the same update; pick mode keeps the armed file
/// outside both sets, so that click completes the pair and one-pane-selected still holds.
@Suite struct ComparePickTests {

    private func node(_ path: String, isDirectory: Bool = false) -> FileNode {
        FileNode(id: path, name: (path as NSString).lastPathComponent, isDirectory: isDirectory)
    }

    private func pick(_ path: String = "/left/Lease — Signed.pdf", isLeft: Bool = true) -> ComparePick {
        ComparePick(armed: node(path), armedPaneIsLeft: isLeft)
    }

    // MARK: The three outcomes

    /// A click that completes the pick, ordered by PANE SIDE so the viewer's columns match its
    /// subtitle: a file in the other pane; the armed file in the right pane and the click in the left,
    /// which a "clicked always leads" ordering gets backwards; and a same-pane pick, which leads with
    /// the armed file, the one chosen first and named by the strip.
    @Test(arguments: [
        (armed: "/left/Lease — Signed.pdf", armedIsLeft: true, clicked: "/right/lease-final-scan.pdf",
         clickedIsLeft: false, left: "/left/Lease — Signed.pdf", right: "/right/lease-final-scan.pdf"),
        (armed: "/right/scan.pdf", armedIsLeft: false, clicked: "/left/original.pdf",
         clickedIsLeft: true, left: "/left/original.pdf", right: "/right/scan.pdf"),
        (armed: "/left/Lease — Signed.pdf", armedIsLeft: true, clicked: "/left/Addendum.pdf",
         clickedIsLeft: true, left: "/left/Lease — Signed.pdf", right: "/left/Addendum.pdf"),
    ])
    func aClickCompletesThePairInPaneOrder(
        _ c: (armed: String, armedIsLeft: Bool, clicked: String, clickedIsLeft: Bool, left: String, right: String)
    ) throws {
        let outcome = pick(c.armed, isLeft: c.armedIsLeft)
            .outcome(clicking: node(c.clicked), inLeftPane: c.clickedIsLeft,
                     leftPaneName: "iCloud", rightPaneName: "Dropbox")
        guard case .paired(let pair) = outcome else {
            Issue.record("expected a pair, got \(outcome)")
            return
        }
        #expect(pair.leftPath == c.left)
        #expect(pair.rightPath == c.right, "the columns contradict the subtitle")
    }

    /// Clicking the armed row again cancels: the marker is the off switch, the only undo a mode
    /// anchored to one row can offer without a second control.
    @Test func clickingTheArmedRowAgainCancels() {
        #expect(pick().outcome(clicking: node("/left/Lease — Signed.pdf"), inLeftPane: true,
                               leftPaneName: "iCloud", rightPaneName: "Dropbox") == .cancelled)
        // Even from the other pane, if the same path is somehow shown there: identity is the path.
        #expect(pick().outcome(clicking: node("/left/Lease — Signed.pdf"), inLeftPane: false,
                               leftPaneName: "iCloud", rightPaneName: "Dropbox") == .cancelled)
    }

    /// A folder click leaves the mode standing: finding the counterpart usually means navigating,
    /// and two files in different folders are the pair this exists for.
    @Test func aFolderClickLeavesTheModeStanding() {
        #expect(pick().outcome(clicking: node("/left/Addenda", isDirectory: true), inLeftPane: true,
                               leftPaneName: "iCloud", rightPaneName: "Dropbox") == .standing)
        #expect(pick().outcome(clicking: node("/right/Scans", isDirectory: true), inLeftPane: false,
                               leftPaneName: "iCloud", rightPaneName: "Dropbox") == .standing)
    }

    // MARK: What the reader sees

    /// The indicator is handed the name, not a finished sentence, because the name is the part
    /// that truncates. A sentence with the name inside it would lose the instruction too; the strip
    /// bounds the name alone and composes the words around it.
    @Test func theIndicatorIsGivenTheNameAloneToBound() {
        #expect(pick().armedName == "Lease — Signed.pdf")
        let long = ComparePick(armed: node("/left/Irrigation system check 10-10-2024 ( Clock C ) readvised new templet.3-18.pdf"),
                               armedPaneIsLeft: true)
        #expect(long.armedName == "Irrigation system check 10-10-2024 ( Clock C ) readvised new templet.3-18.pdf",
                "the name arrived pre-shortened — truncation belongs to the view, which knows the width")
    }

    /// The row marker is keyed on the armed path alone, so it survives the selection moving, a
    /// scroll and a navigation.
    @Test func theMarkerFollowsTheArmedPathAlone() {
        let p = pick()
        #expect(p.marks("/left/Lease — Signed.pdf"))
        #expect(!p.marks("/left/Addendum.pdf"))
    }
}

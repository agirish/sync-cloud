import Foundation
import Sync
import Testing
@testable import FileExplorer

/// The panes' two Compare items: which pair a row offers, and how it reaches the viewer.
///
/// Every test here is really about an item that must not appear. A Compare item wrongly absent
/// looks exactly like one correctly withheld, so each refusal is paired with the nearest case that
/// must still be offered, and neither a rule wired to `nil` nor one wired to "always" would survive
/// the suite.
@MainActor
@Suite struct PaneComparePairMenuTests {

    private func file(_ path: String) -> FileNode { Self.node(path) }

    /// A file, or a folder when the path ends in "/".
    private static func node(_ path: String) -> FileNode {
        let isFolder = path.hasSuffix("/")
        let id = isFolder ? String(path.dropLast()) : path
        return FileNode(id: id, name: (id as NSString).lastPathComponent, isDirectory: isFolder)
    }

    private func tree(_ nodes: [FileNode], side: PaneTree.Side = .right) -> PaneTree {
        PaneTree(side: side, version: 1, nodes: nodes)
    }

    // MARK: Cross-pane

    @Test func oneFileSelectedInTheOtherPaneIsTheCounterpart() throws {
        let other = tree([file("/R/scan.pdf"), file("/R/other.pdf")])
        let counterpart = try #require(PaneComparePairMenu.crossPaneCounterpart(
            clicked: file("/L/lease.pdf"), otherTree: other,
            otherSelection: ["/R/scan.pdf"], isSingleSource: false))
        #expect(counterpart.id == "/R/scan.pdf")
    }

    /// Each case offers no counterpart: (why, clicked row, the other pane's rows, its selection,
    /// single-source).
    @Test(arguments: [
        // The rail has no opposite pane, so `otherSelection` describes a tree nobody can see: the
        // same gate as the cross-pane copy item. The case above but for the flag.
        ("the single-source rail", "/L/lease.pdf", ["/R/scan.pdf"], ["/R/scan.pdf"], true),
        // Two selected over there makes "compare with which?" a question the menu cannot ask.
        ("two selected over there", "/L/lease.pdf", ["/R/a.pdf", "/R/b.pdf"], ["/R/a.pdf", "/R/b.pdf"], false),
        ("nothing selected over there", "/L/lease.pdf", ["/R/a.pdf"], [], false),
        // `selectedNodes(at:)` answers with what is in the tree: a stale path is no counterpart.
        ("the selection names a vanished row", "/L/lease.pdf", ["/R/a.pdf"], ["/R/gone.pdf"], false),
        // The count is the selection's, not what survived resolving it: a rule counting resolved
        // nodes would offer the survivor.
        ("two selected, one since gone", "/L/lease.pdf", ["/R/a.pdf"], ["/R/a.pdf", "/R/gone.pdf"], false),
        // Folders are out on both sides, each refused on its own: the viewer renders nothing for
        // one, and Compare already owns two folders.
        ("the clicked row is a folder", "/L/Reports/", ["/R/a.pdf"], ["/R/a.pdf"], false),
        ("the counterpart is a folder", "/L/lease.pdf", ["/R/Reports/"], ["/R/Reports"], false),
        // Two panes on one folder can name the same path twice; a file compared with itself is
        // "identical" about nothing.
        ("a file with itself", "/same/x.pdf", ["/same/x.pdf"], ["/same/x.pdf"], false),
    ] as [(String, String, [String], Set<String>, Bool)])
    func aCrossPaneRefusalOffersNothing(why: String, clicked: String, other: [String],
                                        selection: Set<String>, isSingleSource: Bool) {
        #expect(PaneComparePairMenu.crossPaneCounterpart(
            clicked: file(clicked), otherTree: tree(other.map(file)),
            otherSelection: selection, isSingleSource: isSingleSource) == nil, "\(why)")
    }

    // MARK: Same pane

    /// The entry that needs no new rules: a pane's selection is a `Set`, so two files in one tree
    /// is already reachable. The counterpart is found by id, not index, because `selectedNodes` is in tree order and the
    /// clicked row isn't reliably its head. Clicking either end must give the other; an index-based
    /// rule passes one of these and fails the other.
    @Test func eitherRowOfThePairFindsTheOther() throws {
        let nodes = [file("/L/a.pdf"), file("/L/b.pdf")]
        let fromFirst = try #require(PaneComparePairMenu.samePaneCounterpart(
            clicked: nodes[0], selectedNodes: nodes))
        let fromSecond = try #require(PaneComparePairMenu.samePaneCounterpart(
            clicked: nodes[1], selectedNodes: nodes))
        #expect(fromFirst.id == "/L/b.pdf")
        #expect(fromSecond.id == "/L/a.pdf")
    }

    /// Only exactly two is a pair; a clicked third row while two others are selected is not a pair
    /// anybody chose; a folder in the pair is refused.
    @Test(arguments: [
        ("one selected", "/L/f0.pdf", ["/L/f0.pdf"]),
        ("three selected", "/L/f0.pdf", ["/L/f0.pdf", "/L/f1.pdf", "/L/f2.pdf"]),
        ("the clicked row is outside the selection", "/L/c.pdf", ["/L/a.pdf", "/L/b.pdf"]),
        ("a folder in the selection", "/L/a.pdf", ["/L/a.pdf", "/L/Reports/"]),
    ])
    func aSamePaneRefusalOffersNothing(why: String, clicked: String, selected: [String]) {
        #expect(PaneComparePairMenu.samePaneCounterpart(clicked: file(clicked),
                                                        selectedNodes: selected.map(file)) == nil, "\(why)")
    }

    // MARK: How the pair reaches the viewer

    /// Ordered by pane side, not by which row was clicked. The viewer names its two columns
    /// left-to-right in the subtitle; a clicked-row-leads rule would put the right pane's file in
    /// the left column half the time and make the subtitle disagree with what is drawn.
    @Test(arguments: [true, false])
    func aCrossPanePairIsOrderedByPaneSide(clickedPaneIsLeft: Bool) {
        let clicked = file(clickedPaneIsLeft ? "/L/lease.pdf" : "/R/scan.pdf")
        let counterpart = file(clickedPaneIsLeft ? "/R/scan.pdf" : "/L/lease.pdf")
        let pair = PaneComparePairMenu.pair(
            clicked: clicked, counterpart: counterpart, counterpartIsInOtherPane: true,
            clickedPaneIsLeft: clickedPaneIsLeft,
            leftPaneName: "iCloud", rightPaneName: "Dropbox")
        #expect(pair.leftPath == "/L/lease.pdf", "the left PANE's file takes the left column")
        #expect(pair.rightPath == "/R/scan.pdf")
        #expect(pair.subtitle == "iCloud vs Dropbox")
    }

    /// A same-pane pair has no side to match, so the clicked row leads, and the subtitle names the
    /// one pane once, because "iCloud vs iCloud" would name nothing.
    @Test(arguments: [(true, "/L", "Both in iCloud"), (false, "/R", "Both in Dropbox")])
    func aSamePanePairLeadsWithTheClickedRowAndNamesItsPane(clickedPaneIsLeft: Bool, dir: String, subtitle: String) {
        let pair = PaneComparePairMenu.pair(
            clicked: file("\(dir)/b.pdf"), counterpart: file("\(dir)/a.pdf"),
            counterpartIsInOtherPane: false, clickedPaneIsLeft: clickedPaneIsLeft,
            leftPaneName: "iCloud", rightPaneName: "Dropbox")
        #expect(pair.leftPath == "\(dir)/b.pdf")
        #expect(pair.rightPath == "\(dir)/a.pdf")
        #expect(pair.subtitle == subtitle)
    }

    // MARK: The title, which the header's glyph is derived from

    /// The header glyph reads the title's extension, so the title must stay a file name. Two
    /// differently named files take the left one's, and the facts strip's Name row shows the
    /// difference; a title like "a.pdf ↔ b.png" would draw one of the two types over both.
    @Test func aPairOfDifferentlyNamedFilesTakesTheLeftName() {
        let pair = PaneComparePairMenu.pair(
            clicked: file("/L/Lease — Signed.pdf"), counterpart: file("/R/lease-final-scan.pdf"),
            counterpartIsInOtherPane: true, clickedPaneIsLeft: true,
            leftPaneName: "iCloud", rightPaneName: "Dropbox")
        #expect(pair.title == "Lease — Signed.pdf")
        #expect(!pair.title.contains("lease-final-scan"), "not both names in one title")
    }

    /// The Differences host is unchanged by any of this: same file on two roots, so the title is
    /// still the shared name and the subtitle still the two panes.
    @Test func theDifferencesHostStillTitlesFromTheSharedRelativePath() throws {
        let pair = try #require(DifferencesPairCompare.pair(
            for: FileDifference(relativePath: "Reports/Q3.pdf",
                                leftItemPath: "/L/Reports/Q3.pdf",
                                rightItemPath: "/R/Reports/Q3.pdf",
                                type: .differentDates, action: .copyToRight,
                                description: "differs", enclosedItemCount: nil),
            paneNames: PaneProviderNames(leftName: "iCloud", rightName: "Dropbox")))
        #expect(pair.title == "Q3.pdf")
        #expect(pair.subtitle == "iCloud vs Dropbox")
    }
}

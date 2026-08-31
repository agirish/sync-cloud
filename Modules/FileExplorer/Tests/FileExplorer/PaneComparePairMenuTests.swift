import Foundation
import Sync
import Testing
@testable import FileExplorer

/// The panes' two Compare items — which pair a row offers, and how it reaches the viewer.
///
/// **Every test here is really about an item that must NOT appear.** A Compare item that is
/// wrongly absent looks exactly like one correctly withheld, and this module has already shipped a
/// menu item that was unreachable from the day it was written; so each refusal is paired with the
/// nearest case that must still be offered, and neither a rule wired to `nil` nor one wired to
/// "always" would survive the suite.
@Suite struct PaneComparePairMenuTests {

    private func file(_ path: String) -> FileNode {
        FileNode(id: path, name: (path as NSString).lastPathComponent, isDirectory: false)
    }

    private func folder(_ path: String) -> FileNode {
        FileNode(id: path, name: (path as NSString).lastPathComponent, isDirectory: true)
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

    /// **The rail has no opposite pane**, so `otherSelection` describes a tree nobody can see —
    /// the same gate the cross-pane copy item beside this one takes. Paired with the case above,
    /// which is identical but for the flag.
    @Test func theSingleSourceRailOffersNoCrossPaneCompare() {
        let other = tree([file("/R/scan.pdf")])
        #expect(PaneComparePairMenu.crossPaneCounterpart(
            clicked: file("/L/lease.pdf"), otherTree: other,
            otherSelection: ["/R/scan.pdf"], isSingleSource: true) == nil)
    }

    /// Two selected over there makes "compare with which?" a question the menu cannot ask.
    @Test func twoFilesSelectedInTheOtherPaneOfferNothing() {
        let other = tree([file("/R/a.pdf"), file("/R/b.pdf")])
        #expect(PaneComparePairMenu.crossPaneCounterpart(
            clicked: file("/L/lease.pdf"), otherTree: other,
            otherSelection: ["/R/a.pdf", "/R/b.pdf"], isSingleSource: false) == nil)
    }

    @Test func anEmptyOtherSelectionOffersNothing() {
        #expect(PaneComparePairMenu.crossPaneCounterpart(
            clicked: file("/L/lease.pdf"), otherTree: tree([file("/R/a.pdf")]),
            otherSelection: [], isSingleSource: false) == nil)
    }

    /// A selection can name a row that has since gone; `selectedNodes(at:)` answers with what is
    /// actually in the tree, so a stale path is no counterpart rather than a crash or a phantom.
    @Test func aSelectionNamingAVanishedRowOffersNothing() {
        #expect(PaneComparePairMenu.crossPaneCounterpart(
            clicked: file("/L/lease.pdf"), otherTree: tree([file("/R/a.pdf")]),
            otherSelection: ["/R/gone.pdf"], isSingleSource: false) == nil)
    }

    /// Folders are out on BOTH sides — the viewer has nothing to render for one, and Compare owns
    /// two folders already. Each side is refused on its own, so a check covering only one would
    /// leave the other open.
    @Test func aFolderOnEitherSideIsRefused() {
        #expect(PaneComparePairMenu.crossPaneCounterpart(
            clicked: folder("/L/Reports"), otherTree: tree([file("/R/a.pdf")]),
            otherSelection: ["/R/a.pdf"], isSingleSource: false) == nil,
            "the clicked row is a folder")
        #expect(PaneComparePairMenu.crossPaneCounterpart(
            clicked: file("/L/lease.pdf"), otherTree: tree([folder("/R/Reports")]),
            otherSelection: ["/R/Reports"], isSingleSource: false) == nil,
            "the counterpart is a folder")
    }

    /// Two panes pointed at one folder can name the same path twice, and a viewer comparing a file
    /// with itself reports "identical" about nothing.
    @Test func aFileIsNotComparableWithItself() {
        #expect(PaneComparePairMenu.crossPaneCounterpart(
            clicked: file("/same/x.pdf"), otherTree: tree([file("/same/x.pdf")]),
            otherSelection: ["/same/x.pdf"], isSingleSource: false) == nil)
    }

    // MARK: Same pane

    /// The entry that needs no new rules: a pane's selection is a `Set`, so two files in one tree
    /// is already reachable.
    @Test func twoFilesSelectedInOnePaneAreAPair() throws {
        let nodes = [file("/L/a.pdf"), file("/L/b.pdf")]
        let counterpart = try #require(PaneComparePairMenu.samePaneCounterpart(
            clicked: nodes[1], selectedNodes: nodes))
        #expect(counterpart.id == "/L/a.pdf", "the counterpart is the OTHER one, by id")
    }

    /// The counterpart is found by id rather than by index, because `selectedNodes` is in tree
    /// order and the clicked row is not reliably its head. Clicking either end must give the
    /// other — an index-based rule passes one of these two and fails the other.
    @Test func eitherRowOfThePairFindsTheOther() throws {
        let nodes = [file("/L/a.pdf"), file("/L/b.pdf")]
        let fromFirst = try #require(PaneComparePairMenu.samePaneCounterpart(
            clicked: nodes[0], selectedNodes: nodes))
        let fromSecond = try #require(PaneComparePairMenu.samePaneCounterpart(
            clicked: nodes[1], selectedNodes: nodes))
        #expect(fromFirst.id == "/L/b.pdf")
        #expect(fromSecond.id == "/L/a.pdf")
    }

    @Test(arguments: [1, 3]) func onlyExactlyTwoIsAPair(count: Int) {
        let nodes = (0..<count).map { file("/L/f\($0).pdf") }
        #expect(PaneComparePairMenu.samePaneCounterpart(clicked: nodes[0],
                                                        selectedNodes: nodes) == nil)
    }

    /// Right-clicking a third row while two others are selected is not a pair anybody chose.
    @Test func aClickedRowOutsideTheSelectionOffersNothing() {
        let selected = [file("/L/a.pdf"), file("/L/b.pdf")]
        #expect(PaneComparePairMenu.samePaneCounterpart(clicked: file("/L/c.pdf"),
                                                        selectedNodes: selected) == nil)
    }

    @Test func aFolderInASamePaneSelectionIsRefused() {
        let nodes = [file("/L/a.pdf"), folder("/L/Reports")]
        #expect(PaneComparePairMenu.samePaneCounterpart(clicked: nodes[0],
                                                        selectedNodes: nodes) == nil)
    }

    // MARK: How the pair reaches the viewer

    /// **Ordered by pane side, not by which row was clicked.** The viewer names its two columns
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

    /// A same-pane pair has no side to match, so the clicked row leads — and the subtitle names
    /// the one pane once, because "iCloud vs iCloud" would name nothing.
    @Test func aSamePanePairLeadsWithTheClickedRowAndNamesOnePane() {
        let pair = PaneComparePairMenu.pair(
            clicked: file("/L/b.pdf"), counterpart: file("/L/a.pdf"),
            counterpartIsInOtherPane: false, clickedPaneIsLeft: true,
            leftPaneName: "iCloud", rightPaneName: "Dropbox")
        #expect(pair.leftPath == "/L/b.pdf")
        #expect(pair.rightPath == "/L/a.pdf")
        #expect(pair.subtitle == "Both in iCloud")
    }

    @Test func aSamePanePairInTheRightPaneNamesTheRightPane() {
        let pair = PaneComparePairMenu.pair(
            clicked: file("/R/b.pdf"), counterpart: file("/R/a.pdf"),
            counterpartIsInOtherPane: false, clickedPaneIsLeft: false,
            leftPaneName: "iCloud", rightPaneName: "Dropbox")
        #expect(pair.subtitle == "Both in Dropbox")
    }

    // MARK: The title, which the header's glyph is derived from

    /// **The header glyph reads the title's extension**, so the title has to stay a file NAME.
    /// Two differently-named files take the left one's, and the facts strip's Name row states the
    /// difference with its ≠ spine — a title in the shape "a.pdf ↔ b.png" would draw one of the
    /// two types over both.
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

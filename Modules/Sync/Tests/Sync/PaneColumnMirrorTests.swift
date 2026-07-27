import Testing
import Foundation
import Events
@testable import Sync

/// With the panes linked, walking into a folder on one side should walk the other side there too —
/// which is the whole reason columns earn their place in a comparison app: two synchronized stacks
/// let you read *where* the divergence is.
///
/// The interesting case is the one a naive copy gets wrong. The two sides are being compared
/// precisely because they differ, so the folder just opened may not exist over there. Mirroring
/// must degrade to the deepest folder the panes still share rather than pointing a column at
/// something absent.
@MainActor
@Suite struct PaneColumnMirrorTests {

    private let root = "/other"

    /// The other pane has `Documents/Invoices` but no `2025` inside it, and no `Photos` at all.
    private func otherIndex() -> PaneChildrenIndex {
        let invoices = FileNode(id: "/other/Documents/Invoices", name: "Invoices", isDirectory: true,
                                children: [FileNode(id: "/other/Documents/Invoices/a.pdf", name: "a.pdf", isDirectory: false)])
        let documents = FileNode(id: "/other/Documents", name: "Documents", isDirectory: true, children: [invoices])
        return PaneChildrenIndex(tree: PaneTree(side: .right, version: 1, nodes: [documents]), treeRoot: root)
    }

    @Test func testMirrorOffMovesOnlyTheClickedPane() {
        let m = FileSyncManager()
        m.applyColumnNavigation(PaneBrowsePath(components: ["Documents"]), isLeft: true,
                                mirror: false, otherIndex: otherIndex(), otherTreeRoot: root)
        #expect(m.leftBrowsePath.components == ["Documents"])
        #expect(m.rightBrowsePath.isEmpty, "unlinked, the sibling must not move")
    }

    /// An unmirrored click must not even ASK for the other pane's index. Building it is a full walk
    /// of that pane's tree — ~40k nodes in the real app — and the call site sits inside the click
    /// handler, so an eagerly-evaluated argument spent that on the main thread on every column click
    /// whether or not the seam link wanted a mirror.
    @Test func testMirrorOffNeverBuildsTheOtherPanesIndex() {
        let m = FileSyncManager()
        var built = 0
        m.applyColumnNavigation(PaneBrowsePath(components: ["Documents"]), isLeft: true,
                                mirror: false,
                                otherIndex: { built += 1; return otherIndex() }(),
                                otherTreeRoot: root)
        #expect(built == 0, "an unlinked click still paid for the other pane's index")

        // …and it is still built when the mirror genuinely needs it.
        m.applyColumnNavigation(PaneBrowsePath(components: ["Documents"]), isLeft: true,
                                mirror: true,
                                otherIndex: { built += 1; return otherIndex() }(),
                                otherTreeRoot: root)
        #expect(built == 1)
    }

    @Test func testMirrorOnCarriesTheOtherPaneToTheSameFolder() {
        let m = FileSyncManager()
        m.applyColumnNavigation(PaneBrowsePath(components: ["Documents", "Invoices"]), isLeft: true,
                                mirror: true, otherIndex: otherIndex(), otherTreeRoot: root)
        #expect(m.leftBrowsePath.components == ["Documents", "Invoices"])
        #expect(m.rightBrowsePath.components == ["Documents", "Invoices"])
    }

    /// The case a plain copy gets wrong: the clicked folder is missing on the other side, so the
    /// mirror stops at the deepest folder the two still share.
    @Test func testMirrorPrunesToTheDeepestSharedFolder() {
        let m = FileSyncManager()
        m.applyColumnNavigation(PaneBrowsePath(components: ["Documents", "Invoices", "2025"]), isLeft: true,
                                mirror: true, otherIndex: otherIndex(), otherTreeRoot: root)
        #expect(m.leftBrowsePath.components == ["Documents", "Invoices", "2025"],
                "the clicked pane goes where it was clicked, regardless of the sibling")
        #expect(m.rightBrowsePath.components == ["Documents", "Invoices"],
                "the sibling stops where its own tree stops")
    }

    /// Nothing in common: the sibling returns to its resting column rather than showing a column
    /// for a folder it does not have.
    @Test func testMirrorWithNothingInCommonReturnsTheSiblingToItsRoot() {
        let m = FileSyncManager()
        m.rightBrowsePath.drill(into: "Documents", atDepth: 0)
        m.applyColumnNavigation(PaneBrowsePath(components: ["Photos"]), isLeft: true,
                                mirror: true, otherIndex: otherIndex(), otherTreeRoot: root)
        #expect(m.leftBrowsePath.components == ["Photos"])
        #expect(m.rightBrowsePath.isEmpty)
    }

    /// Mirroring works from either side, into the other.
    @Test func testMirrorWorksFromTheRightPaneToo() {
        let m = FileSyncManager()
        m.applyColumnNavigation(PaneBrowsePath(components: ["Documents"]), isLeft: false,
                                mirror: true, otherIndex: otherIndex(), otherTreeRoot: root)
        #expect(m.rightBrowsePath.components == ["Documents"])
        #expect(m.leftBrowsePath.components == ["Documents"])
    }

    /// Stepping back out mirrors too — a linked pair must not drift apart on the way up.
    @Test func testMirroringAShallowerPathWalksTheSiblingBackOut() {
        let m = FileSyncManager()
        m.applyColumnNavigation(PaneBrowsePath(components: ["Documents", "Invoices"]), isLeft: true,
                                mirror: true, otherIndex: otherIndex(), otherTreeRoot: root)
        #expect(m.rightBrowsePath.components == ["Documents", "Invoices"])

        m.applyColumnNavigation(PaneBrowsePath(components: ["Documents"]), isLeft: true,
                                mirror: true, otherIndex: otherIndex(), otherTreeRoot: root)
        #expect(m.rightBrowsePath.components == ["Documents"])
    }

    /// Mirroring is navigation, never a re-root: the sibling's comparison scope must survive it,
    /// or a linked click would silently rescan the other pane.
    @Test func testMirroringNeverRerootsTheSibling() {
        let m = FileSyncManager()
        m.focusOn(relativePath: "Scope", isLeft: false)
        m.applyColumnNavigation(PaneBrowsePath(components: ["Documents"]), isLeft: true,
                                mirror: true, otherIndex: otherIndex(), otherTreeRoot: root)
        #expect(m.rightRelativePath == "Scope")
    }
}

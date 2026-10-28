import Testing
import Foundation
import Sync
import UniformTypeIdentifiers
@testable import FileExplorer

/// Which file a TREE pane previews — the half of `ColumnPreview` that Columns does not exercise.
///
/// The shared rule (exactly one selected file, never a folder) is pinned by `ColumnPreviewTests`
/// through the columns entry point; these are about the part that genuinely differs. A column's
/// selection lives in one flat list, so finding it is a scan. A tree's lives at any depth of a
/// projection a pane routinely holds ~40,000 rows of, so finding it is a walk — and a walk has ways
/// to be wrong that a scan does not: entering the wrong sibling, mistaking a string prefix for a
/// path prefix, or reading the whole tree to answer a question about one file.
@Suite struct TreePreviewTargetTests {

    private static let root = "/Users/x/Documents"

    /// A tree deep enough that the walk has to make a real choice at every level, with a sibling
    /// (`Invoices2024`) whose path is a string prefix neighbour of the one being looked for.
    private static func rows() -> [PaneRow] {
        let deep = FileNode(id: "\(root)/Work/Invoices/Q3/march.pdf", name: "march.pdf",
                            isDirectory: false,
                            modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
                            fileSize: 37_000, kind: "com.adobe.pdf")
        let quarter = FileNode(id: "\(root)/Work/Invoices/Q3", name: "Q3", isDirectory: true,
                               children: [deep])
        let invoices = FileNode(id: "\(root)/Work/Invoices", name: "Invoices", isDirectory: true,
                                children: [quarter])
        // The trap: `…/Invoices` is a string prefix of `…/Invoices2024`, so a bare `hasPrefix`
        // descends into this one looking for a file that is in its neighbour.
        let decoy = FileNode(id: "\(root)/Work/Invoices2024", name: "Invoices2024",
                             isDirectory: true,
                             children: [FileNode(id: "\(root)/Work/Invoices2024/stale.pdf",
                                                 name: "stale.pdf", isDirectory: false)])
        let work = FileNode(id: "\(root)/Work", name: "Work", isDirectory: true,
                            children: [invoices, decoy])
        let loose = FileNode(id: "\(root)/notes.txt", name: "notes.txt", isDirectory: false)
        return PaneRow.project([work, loose], side: .left, version: 1)
    }

    @Test func testAFileSelectedDeepInTheOutlineIsThePreviewTarget() throws {
        let path = "\(Self.root)/Work/Invoices/Q3/march.pdf"
        let item = try #require(ColumnPreview.item(selection: [path], treeRows: Self.rows()))
        #expect(item.path == path)
        #expect(item.name == "march.pdf")
        // The identity block's scalars survive the walk — a preview captioned with nothing is most
        // of the feature missing.
        #expect(item.kind == UTType.pdf.localizedDescription)
        #expect(item.fileSize == 37_000)
    }

    /// A top-level file needs no descent at all, which is the case a walk written only for depth
    /// gets wrong.
    @Test func testAFileAtTheTopLevelIsFound() throws {
        let item = try #require(ColumnPreview.item(selection: ["\(Self.root)/notes.txt"],
                                                   treeRows: Self.rows()))
        #expect(item.name == "notes.txt")
    }

    /// **`/a/b` is a prefix of `/a/bc` as a string and not as a path.** With a bare `hasPrefix` the
    /// walk enters `Invoices2024` looking for a file in `Invoices`, finds nothing there, and returns
    /// nil — the preview silently never appears for anything under the earlier-sorted neighbour.
    @Test func testTheWalkDoesNotEnterASiblingThatMerelySharesAPrefix() throws {
        let item = try #require(ColumnPreview.item(
            selection: ["\(Self.root)/Work/Invoices/Q3/march.pdf"], treeRows: Self.rows()))
        #expect(item.path.hasSuffix("/Invoices/Q3/march.pdf"))
    }

    /// The walk touches one directory's rows per level, never the tree: it enters only the
    /// directory on the path. Pinned by a decoy rather than a clock — `Bulk`, sorted first, holds a
    /// row carrying the wanted file's own path, so a walk that enters any directory off the path
    /// (or scans the whole projection) returns the decoy instead of `Other`'s file.
    ///
    /// This was a 20,000-row subtree and `elapsed < 0.05` until 2026-10-28, when it failed at load
    /// 29 after waiting its turn for 66 s: a wall-clock limit on one call measures the machine. A
    /// clock still has a place for the cost, and it is `ColumnClickCostBenchmark`, which is
    /// machine-pinned for that reason.
    @Test func testTheWalkDoesNotReadTheWholeTree() {
        let wanted = "\(Self.root)/Other/a.txt"
        let decoy = FileNode(id: wanted, name: "decoy-in-Bulk.txt", isDirectory: false)
        let bulk = FileNode(id: "\(Self.root)/Bulk", name: "Bulk", isDirectory: true,
                            children: [FileNode(id: "\(Self.root)/Bulk/f0.txt", name: "f0.txt",
                                                isDirectory: false), decoy])
        let other = FileNode(id: "\(Self.root)/Other", name: "Other", isDirectory: true,
                             children: [FileNode(id: wanted, name: "a.txt", isDirectory: false)])
        let rows = PaneRow.project([bulk, other], side: .left, version: 1)

        let item = ColumnPreview.item(selection: [wanted], treeRows: rows)

        #expect(item?.name == "a.txt",
                "the walk entered Bulk, a directory off the path, and found \(item?.name ?? "nothing")")
    }

    /// A folder is never previewed, whichever presentation resolved it — the tree's own copy of the
    /// rule, because it comes through a different entry point.
    @Test func testAFolderIsNeverPreviewed() {
        #expect(ColumnPreview.item(selection: ["\(Self.root)/Work/Invoices"],
                                   treeRows: Self.rows()) == nil)
    }

    @Test func testAMultiSelectionHasNoPreviewTarget() {
        let selection: Set<String> = ["\(Self.root)/notes.txt",
                                      "\(Self.root)/Work/Invoices/Q3/march.pdf"]
        #expect(ColumnPreview.item(selection: selection, treeRows: Self.rows()) == nil)
    }

    @Test func testAnEmptySelectionHasNoPreviewTarget() {
        #expect(ColumnPreview.item(selection: [], treeRows: Self.rows()) == nil)
    }

    /// A path the projection does not hold — a selection left over from a republish that dropped the
    /// file — resolves to nothing rather than to a preview of a file that is gone.
    @Test func testAPathTheTreeDoesNotHoldIsNotPreviewed() {
        #expect(ColumnPreview.item(selection: ["\(Self.root)/Work/Invoices/Q3/absent.pdf"],
                                   treeRows: Self.rows()) == nil)
    }
}

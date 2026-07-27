import Testing
import Foundation
import Sync
@testable import Dashboard

/// Pins DetailsSelectionSummary — the pure multi-select rollup behind the Details sidebar:
/// when it engages (2+ selected), the files/folders breakdown, the files-only byte total
/// (folders are never walked), and the display strings.
@Suite struct DetailsSelectionSummaryTests {

    private func file(_ path: String, size: Int?) -> FileNode {
        FileNode(id: path, name: (path as NSString).lastPathComponent, isDirectory: false, fileSize: size)
    }

    private func folder(_ path: String, children: [FileNode] = []) -> FileNode {
        FileNode(id: path, name: (path as NSString).lastPathComponent, isDirectory: true, children: children)
    }

    private func formatted(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    @Test func emptyAndSingleSelectionsProduceNoSummary() {
        let tree = [file("/vault/a.txt", size: 10)]
        #expect(DetailsSelectionSummary.make(selectedPaths: [], in: tree) == nil)
        #expect(DetailsSelectionSummary.make(selectedPaths: ["/vault/a.txt"], in: tree) == nil)
    }

    /// The sidebar reads this from `body`, so what it costs per render is a property worth
    /// pinning, not an implementation detail: the resolver runs ONCE for a multi-selection and
    /// NOT AT ALL below the threshold.
    ///
    /// The zero case is the one that matters. `make` guards on the count before resolving, which
    /// is what keeps a single selection from paying anything — reordering those two lines is free
    /// to write and invisible without this.
    @Test func theResolverRunsOnceAndOnlyForAMultiSelection() {
        var calls = 0
        let resolve: (Set<String>) -> [FileNode] = { paths in
            calls += 1
            return paths.map { file($0, size: 5) }
        }

        _ = DetailsSelectionSummary.make(selectedPaths: [], resolving: resolve)
        _ = DetailsSelectionSummary.make(selectedPaths: ["/vault/a.txt"], resolving: resolve)
        #expect(calls == 0, "a selection too small to summarize must not resolve anything")

        let summary = DetailsSelectionSummary.make(selectedPaths: ["/vault/a.txt", "/vault/b.txt"],
                                                   resolving: resolve)
        #expect(calls == 1)
        #expect(summary?.fileCount == 2)
    }

    /// The two spellings must agree. The sidebar moved onto the resolver form so it could go
    /// through the manager's cached path→node index instead of walking the tree per render; that
    /// substitution is only safe if nothing here depends on `findNodes`' pre-order, which the
    /// index does not promise.
    @Test func theResolverFormMatchesTheTreeForm() {
        let tree = [
            folder("/vault/docs", children: [file("/vault/docs/deep.txt", size: 900)]),
            file("/vault/a.txt", size: 10),
            file("/vault/b.txt", size: 32),
        ]
        let paths: Set<String> = ["/vault/a.txt", "/vault/b.txt", "/vault/docs"]

        let viaTree = DetailsSelectionSummary.make(selectedPaths: paths, in: tree)
        // Deliberately REVERSED against the tree's pre-order, which is the difference the index
        // is allowed to have.
        let viaResolver = DetailsSelectionSummary.make(selectedPaths: paths) { requested in
            tree.findNodes(at: requested).reversed()
        }

        #expect(viaTree == viaResolver)
        #expect(viaTree?.fileCount == 2)
        #expect(viaTree?.folderCount == 1)
        #expect(viaTree?.totalFileBytes == 42, "the folder's child must not leak into the total")
    }

    @Test func countsFilesAndFoldersAndSumsOnlyFileBytes() {
        // The folder's own children must not leak into the byte total — the summary is
        // metadata-only, never a directory walk.
        let tree = [
            file("/vault/a.txt", size: 1_000),
            file("/vault/b.txt", size: 2_500),
            folder("/vault/photos", children: [file("/vault/photos/huge.raw", size: 900_000)]),
        ]
        let summary = DetailsSelectionSummary.make(
            selectedPaths: ["/vault/a.txt", "/vault/b.txt", "/vault/photos"], in: tree
        )

        #expect(summary?.itemCount == 3)
        #expect(summary?.fileCount == 2)
        #expect(summary?.folderCount == 1)
        #expect(summary?.totalFileBytes == 3_500)
    }

    @Test func findsNodesNestedInsideExpandedFolders() {
        let tree = [folder("/vault/docs", children: [
            file("/vault/docs/a.txt", size: 100),
            file("/vault/docs/b.txt", size: 200),
        ])]
        let summary = DetailsSelectionSummary.make(
            selectedPaths: ["/vault/docs/a.txt", "/vault/docs/b.txt"], in: tree
        )

        #expect(summary?.fileCount == 2)
        #expect(summary?.totalFileBytes == 300)
    }

    @Test func unresolvedPathsCountAsItemsButAddNothing() {
        let tree = [file("/vault/a.txt", size: 42)]
        let summary = DetailsSelectionSummary.make(
            selectedPaths: ["/vault/a.txt", "/vault/vanished.txt"], in: tree
        )

        #expect(summary?.itemCount == 2)
        #expect(summary?.fileCount == 1)
        #expect(summary?.folderCount == 0)
        #expect(summary?.totalFileBytes == 42)
    }

    @Test func fileWithUnknownSizeContributesZero() {
        let tree = [file("/vault/a.txt", size: nil), file("/vault/b.txt", size: 7)]
        let summary = DetailsSelectionSummary.make(
            selectedPaths: ["/vault/a.txt", "/vault/b.txt"], in: tree
        )

        #expect(summary?.fileCount == 2)
        #expect(summary?.totalFileBytes == 7)
    }

    @Test func titleIsItemCountSelected() {
        let tree = [file("/vault/a.txt", size: 1), file("/vault/b.txt", size: 1)]
        let summary = DetailsSelectionSummary.make(
            selectedPaths: ["/vault/a.txt", "/vault/b.txt"], in: tree
        )
        #expect(summary?.title == "2 items selected")
    }

    @Test func kindDescriptionPluralizesAndJoins() {
        #expect(
            DetailsSelectionSummary(itemCount: 3, fileCount: 2, folderCount: 1, totalFileBytes: 0)
                .kindDescription == "2 files, 1 folder"
        )
        #expect(
            DetailsSelectionSummary(itemCount: 3, fileCount: 1, folderCount: 2, totalFileBytes: 0)
                .kindDescription == "1 file, 2 folders"
        )
        #expect(
            DetailsSelectionSummary(itemCount: 2, fileCount: 2, folderCount: 0, totalFileBytes: 0)
                .kindDescription == "2 files"
        )
        #expect(
            DetailsSelectionSummary(itemCount: 2, fileCount: 0, folderCount: 2, totalFileBytes: 0)
                .kindDescription == "2 folders"
        )
        // Nothing resolved in the tree: fall back to the raw item count.
        #expect(
            DetailsSelectionSummary(itemCount: 2, fileCount: 0, folderCount: 0, totalFileBytes: 0)
                .kindDescription == "2 items"
        )
    }

    @Test func sizeDescriptionMarksFilesOnlyWhenFoldersPresent() {
        let mixed = DetailsSelectionSummary(itemCount: 3, fileCount: 2, folderCount: 1, totalFileBytes: 3_500)
        #expect(mixed.sizeDescription == "\(formatted(3_500)) (files only)")

        let filesOnly = DetailsSelectionSummary(itemCount: 2, fileCount: 2, folderCount: 0, totalFileBytes: 3_500)
        #expect(filesOnly.sizeDescription == formatted(3_500))

        let foldersOnly = DetailsSelectionSummary(itemCount: 2, fileCount: 0, folderCount: 2, totalFileBytes: 0)
        #expect(foldersOnly.sizeDescription == "—")
    }
}

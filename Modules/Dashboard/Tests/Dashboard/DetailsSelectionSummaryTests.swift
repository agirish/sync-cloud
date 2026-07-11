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

import Testing
import SwiftUI
import Sync
@testable import FileExplorer

private func diff(
    _ relativePath: String,
    type: FileDifference.DifferenceType = .missingOnRight
) -> FileDifference {
    FileDifference(
        relativePath: relativePath,
        leftItemPath: "/left/\(relativePath)",
        rightItemPath: "/right/\(relativePath)",
        type: type,
        action: type == .missingOnLeft ? .copyToLeft : .copyToRight,
        description: "test"
    )
}

@Suite struct DiffStatusIndexTests {

    @Test func testMapsRelativePathsOntoTheRoot() {
        let index = DiffStatusIndex(
            differences: [
                diff("a.txt", type: .missingOnRight),
                diff("sub/b.txt", type: .missingOnLeft),
                diff("sub/deep/c.txt", type: .differentDates),
            ],
            rootPath: "/Users/me/Documents"
        )
        #expect(index.status(forNodeId: "/Users/me/Documents/a.txt") == .missingOnRight)
        #expect(index.status(forNodeId: "/Users/me/Documents/sub/b.txt") == .missingOnLeft)
        #expect(index.status(forNodeId: "/Users/me/Documents/sub/deep/c.txt") == .differentDates)
        // In-sync nodes and the relative path itself resolve to nothing.
        #expect(index.status(forNodeId: "/Users/me/Documents/other.txt") == nil)
        #expect(index.status(forNodeId: "a.txt") == nil)
    }

    @Test func testAncestorDirectoriesGetContainedCounts() {
        let index = DiffStatusIndex(
            differences: [
                diff("sub/deep/c.txt"),
                diff("sub/deep/d.txt"),
                diff("sub/e.txt"),
                diff("top.txt"),
            ],
            rootPath: "/root"
        )
        #expect(index.containedDiffCount(forNodeId: "/root/sub/deep") == 2)
        #expect(index.containedDiffCount(forNodeId: "/root/sub") == 3)
        // The pane root itself is never shown as a row, so it is not indexed.
        #expect(index.containedDiffCount(forNodeId: "/root") == 0)
        // Files and clean directories report zero.
        #expect(index.containedDiffCount(forNodeId: "/root/sub/deep/c.txt") == 0)
        #expect(index.containedDiffCount(forNodeId: "/root/clean") == 0)
    }

    @Test func testDirectoryDiffGetsDirectStatusAndCreditsAncestors() {
        // A folder missing on one side appears as a single diff for the folder path.
        let index = DiffStatusIndex(
            differences: [diff("sub/missing-folder", type: .missingOnLeft)],
            rootPath: "/root"
        )
        #expect(index.status(forNodeId: "/root/sub/missing-folder") == .missingOnLeft)
        #expect(index.containedDiffCount(forNodeId: "/root/sub") == 1)
        #expect(index.containedDiffCount(forNodeId: "/root/sub/missing-folder") == 0)
    }

    @Test func testTrailingSlashOnRootAndStraySlashesOnRelativePathAreNormalized() {
        let index = DiffStatusIndex(
            differences: [diff("/sub/a.txt/"), diff("b.txt")],
            rootPath: "/root/"
        )
        #expect(index.status(forNodeId: "/root/sub/a.txt") == .missingOnRight)
        #expect(index.status(forNodeId: "/root/b.txt") == .missingOnRight)
        #expect(index.containedDiffCount(forNodeId: "/root/sub") == 1)
    }

    @Test func testDifferentRootsIndexTheSameDifferencesIndependently() {
        // The same differences list is indexed once per pane; each pane resolves
        // only its own absolute paths.
        let differences = [diff("sub/a.txt")]
        let left = DiffStatusIndex(differences: differences, rootPath: "/left-root")
        let right = DiffStatusIndex(differences: differences, rootPath: "/right-root")
        #expect(left.status(forNodeId: "/left-root/sub/a.txt") == .missingOnRight)
        #expect(left.status(forNodeId: "/right-root/sub/a.txt") == nil)
        #expect(right.status(forNodeId: "/right-root/sub/a.txt") == .missingOnRight)
        #expect(right.containedDiffCount(forNodeId: "/right-root/sub") == 1)
    }

    @Test func testEmptyIndexAndDegenerateInputsReturnNothing() {
        #expect(DiffStatusIndex.empty.status(forNodeId: "/any/path") == nil)
        #expect(DiffStatusIndex.empty.containedDiffCount(forNodeId: "/any") == 0)

        // Empty root (no pane path yet) indexes nothing.
        let noRoot = DiffStatusIndex(differences: [diff("a.txt")], rootPath: "")
        #expect(noRoot.status(forNodeId: "/a.txt") == nil)
        #expect(noRoot.status(forNodeId: "a.txt") == nil)

        // An empty relative path (degenerate diff) is skipped rather than
        // badging the root itself.
        let emptyRelative = DiffStatusIndex(differences: [diff("")], rootPath: "/root")
        #expect(emptyRelative.status(forNodeId: "/root") == nil)
        #expect(emptyRelative.containedDiffCount(forNodeId: "/root") == 0)
    }

    @Test func testFilesystemRootAsPaneRootStillResolves() {
        let index = DiffStatusIndex(differences: [diff("sub/a.txt")], rootPath: "/")
        #expect(index.status(forNodeId: "/sub/a.txt") == .missingOnRight)
        #expect(index.containedDiffCount(forNodeId: "/sub") == 1)
    }

    @Test func testBadgePresentationCoversAllDifferenceTypes() {
        // Shape encodes meaning (colorblind-safe), color matches DifferenceRow.
        #expect(FileRowView.badgeSymbol(for: .missingOnRight) == "arrow.right.circle")
        #expect(FileRowView.badgeSymbol(for: .missingOnLeft) == "arrow.left.circle")
        #expect(FileRowView.badgeSymbol(for: .differentDates) == "arrow.triangle.2.circlepath")
        #expect(FileRowView.badgeColor(for: .missingOnRight) == .blue)
        #expect(FileRowView.badgeColor(for: .missingOnLeft) == .purple)
        #expect(FileRowView.badgeColor(for: .differentDates) == .orange)
    }
}

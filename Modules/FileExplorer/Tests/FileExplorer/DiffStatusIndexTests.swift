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

    @Test func testFoldedFallbackBadgesCaseVariantDestinationFolders() {
        // A missing row's expected path carries the SOURCE side's ancestor casing ("Docs/x.txt"
        // credited under <root>/Docs), so the destination pane's REAL folder — spelled "docs" —
        // matched no exact key and showed no contained-diff badge. With foldsCase (the pane's
        // volume is case-insensitive) the folded fallback finds it; without it (case-sensitive
        // volume, where "Docs" and "docs" are distinct real folders) the exact behavior stands.
        let differences = [diff("Docs/x.txt", type: .missingOnRight)]

        let folding = DiffStatusIndex(differences: differences, rootPath: "/r", foldsCase: true)
        #expect(folding.containedDiffCount(forNodeId: "/r/docs") == 1)
        #expect(folding.containedDiffCount(forNodeId: "/r/Docs") == 1)   // exact still wins first

        let exact = DiffStatusIndex(differences: differences, rootPath: "/r")
        #expect(exact.containedDiffCount(forNodeId: "/r/docs") == 0)
        #expect(exact.containedDiffCount(forNodeId: "/r/Docs") == 1)
    }

    @Test func testNameConflictBadgesBothSidesRealSpellings() {
        // A name conflict's two sides spell the name differently; relativePath carries only
        // the LEFT spelling. Each pane's index must badge its OWN node's real path.
        let conflict = FileDifference(
            relativePath: "Fitness/Swimming ",
            leftItemPath: "/left/Fitness/Swimming ",
            rightItemPath: "/right/Fitness/Swimming",
            type: .nameConflict,
            action: .copyToRight,
            description: "test"
        )
        let leftIndex = DiffStatusIndex(differences: [conflict], rootPath: "/left")
        #expect(leftIndex.status(forNodeId: "/left/Fitness/Swimming ") == .nameConflict)
        #expect(leftIndex.containedDiffCount(forNodeId: "/left/Fitness") == 1)

        let rightIndex = DiffStatusIndex(differences: [conflict], rootPath: "/right")
        #expect(rightIndex.status(forNodeId: "/right/Fitness/Swimming") == .nameConflict)
        // The naive join (root + left-spelled relative) must NOT be what the right pane
        // badges — no node has that id there.
        #expect(rightIndex.status(forNodeId: "/right/Fitness/Swimming ") == nil)
        #expect(rightIndex.containedDiffCount(forNodeId: "/right/Fitness") == 1)
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

    @Test func testSiblingDirectoryNamePrefixesDoNotCollide() {
        // "/root/sub" is a string prefix of "/root/subfolder"; containment must
        // follow path components, not string prefixes.
        let index = DiffStatusIndex(
            differences: [diff("subfolder/a.txt")],
            rootPath: "/root"
        )
        #expect(index.containedDiffCount(forNodeId: "/root/subfolder") == 1)
        #expect(index.containedDiffCount(forNodeId: "/root/sub") == 0)
        #expect(index.status(forNodeId: "/root/sub") == nil)
    }

    @Test func testCaseVariantPairKeysEachPaneWithItsOwnSideCasing() {
        // relativePath always carries LEFT-side casing; on a case-insensitive volume the
        // right side of a pair can differ in case, and the right pane's node ids carry
        // that right-side casing.
        let difference = FileDifference(
            relativePath: "Sub/File.txt",
            leftItemPath: "/left/Sub/File.txt",
            rightItemPath: "/right/sub/file.txt",
            type: .differentDates,
            action: .copyToRight,
            description: "test"
        )
        let left = DiffStatusIndex(differences: [difference], rootPath: "/left")
        let right = DiffStatusIndex(differences: [difference], rootPath: "/right")

        #expect(left.status(forNodeId: "/left/Sub/File.txt") == .differentDates)
        #expect(left.containedDiffCount(forNodeId: "/left/Sub") == 1)
        // Badge and ancestor count must land on the right pane's actual node ids, not on
        // a left-cased join that matches no row.
        #expect(right.status(forNodeId: "/right/sub/file.txt") == .differentDates)
        #expect(right.containedDiffCount(forNodeId: "/right/sub") == 1)
        #expect(right.status(forNodeId: "/right/Sub/File.txt") == nil)
    }

    @Test func testSideAlignedPathPrefersExactThenCaseInsensitiveSideMatch() {
        // Exact match keeps the join byte-identical (left index unchanged by the fix).
        #expect(DiffStatusIndex.sideAlignedPath(
            joined: "/l/A.txt", left: "/l/A.txt", right: "/r/a.txt") == "/l/A.txt")
        // Case-insensitive side match re-aligns to that side's real casing.
        #expect(DiffStatusIndex.sideAlignedPath(
            joined: "/r/A.txt", left: "/l/A.txt", right: "/r/a.txt") == "/r/a.txt")
        // A join matching neither side (distinct roots) stays untouched.
        #expect(DiffStatusIndex.sideAlignedPath(
            joined: "/x/A.txt", left: "/l/A.txt", right: "/r/a.txt") == "/x/A.txt")
    }

    @Test func testPathsWithSpacesAndNonASCIINamesResolve() {
        let index = DiffStatusIndex(
            differences: [diff("Süb Fólder/日本語 メモ.txt", type: .differentDates)],
            rootPath: "/Users/mé/My Documents"
        )
        #expect(index.status(forNodeId: "/Users/mé/My Documents/Süb Fólder/日本語 メモ.txt") == .differentDates)
        #expect(index.containedDiffCount(forNodeId: "/Users/mé/My Documents/Süb Fólder") == 1)
    }

    @Test func testBadgePresentationCoversAllDifferenceTypes() {
        // Symbol/color come straight from DifferenceGlyph (pinned in DifferenceGlyphTests);
        // the badge's own contribution is the tooltip/accessibility wording.
        #expect(FileRowView.badgeHelp(for: .missingOnRight) == "Missing on right")
        #expect(FileRowView.badgeHelp(for: .missingOnLeft) == "Missing on left")
        #expect(FileRowView.badgeHelp(for: .differentDates) == "Different dates or sizes")
    }
}

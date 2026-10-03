import Testing
import Foundation
@testable import Sync

/// **Compare finds the `/` in a relative path by scalar, never by Character.**
///
/// A name can open with a combining mark (U+0301), and one can end with a Prepend character
/// (U+0600, ARABIC NUMBER SIGN). Either joins the `/` beside it into one Character, so a search
/// for the Character `/` walks past that boundary, a split on it leaves the two names fused, and a
/// Character count dropped off the front of a path takes the `/` with it. The disk walk and the warm
/// keying already cut keys by scalar (`getFilesInDirectory`, `TreeShape.leaf`), so these keys are
/// real; each case below takes one apart the way `computeDifferences` does.
@Suite struct SlashByScalarDiffTests {

    private let leftURL = URL(fileURLWithPath: "/left")
    private let rightURL = URL(fileURLWithPath: "/right")
    private let date = Date(timeIntervalSince1970: 1_000_000)

    /// A folder and a child name whose `/` between them is not a Character boundary.
    struct Shape: Sendable, CustomTestStringConvertible {
        let folder: String
        let child: String
        let testDescription: String
    }

    static let shapes = [
        Shape(folder: "F", child: "\u{301}x", testDescription: "a child opening with a combining mark"),
        Shape(folder: "F\u{600}", child: "x", testDescription: "a folder ending in a Prepend character"),
    ]

    /// Two spellings of one folder that meet on a near-name (an invisible trailing space), the
    /// first of them spelled so its `/` is not a Character boundary.
    struct ConflictShape: Sendable, CustomTestStringConvertible {
        let fused: String
        let partner: String
        let child: String
        let testDescription: String
    }

    static let conflictShapes = [
        ConflictShape(fused: "A ", partner: "A", child: "\u{301}x",
                      testDescription: "a child opening with a combining mark"),
        ConflictShape(fused: "X\u{600}", partner: "X\u{600} ", child: "f.txt",
                      testDescription: "a folder ending in a Prepend character"),
    ]

    private func info(_ root: URL, _ path: String, isDir: Bool = false, size: Int = 10,
                      isUnexplored: Bool = false) -> FileDiffEngine.FileInfo {
        FileDiffEngine.FileInfo(url: root.appendingPathComponent(path), modificationDate: date,
                                fileSize: isDir ? nil : size, isDirectory: isDir, isUnexplored: isUnexplored)
    }

    private func compute(_ left: [String: FileDiffEngine.FileInfo], _ right: [String: FileDiffEngine.FileInfo],
                         caseInsensitive: Bool = false) -> [FileDifference] {
        FileDiffEngine.computeDifferences(
            left: CloudProvider(id: "l", displayName: "iCloud", imageName: "folder", rootPath: "/left", type: .iCloud),
            leftURL: leftURL,
            right: CloudProvider(id: "r", displayName: "Dropbox", imageName: "folder", rootPath: "/right", type: .dropBox),
            rightURL: rightURL, leftFilesInfo: left, rightFilesInfo: right, caseInsensitive: caseInsensitive)
    }

    // MARK: - The collapse

    @Test(arguments: shapes)
    func everythingInsideAMissingFolderCollapsesIntoItsRow(_ shape: Shape) {
        let fused = shape.folder + "/" + shape.child
        let left = [
            shape.folder: info(leftURL, shape.folder, isDir: true),
            fused: info(leftURL, fused),
            shape.folder + "/plain": info(leftURL, shape.folder + "/plain"),
        ]

        let diffs = compute(left, [:], caseInsensitive: true)

        #expect(diffs.map(\.relativePath) == [shape.folder])
        #expect(diffs.first?.type == .missingOnRight)
        #expect(diffs.first?.enclosedItemCount == 2)
    }

    // MARK: - A folder nobody could list

    @Test(arguments: shapes)
    func nothingInsideAnUnreadableFolderIsReportedMissing(_ shape: Shape) {
        let left = [
            shape.folder: info(leftURL, shape.folder, isDir: true),
            shape.folder + "/" + shape.child: info(leftURL, shape.folder + "/" + shape.child),
        ]
        let right = [shape.folder: info(rightURL, shape.folder, isDir: true, isUnexplored: true)]

        #expect(compute(left, right).isEmpty)
    }

    /// The folded half of the same suppression: the unreadable folder on the right is the left
    /// one's case variant, so only `hasUnexploredFoldedAncestor` can recognize it.
    @Test(arguments: shapes)
    func nothingInsideAnUnreadableCaseVariantFolderIsReportedMissing(_ shape: Shape) {
        let lower = shape.folder.lowercased()
        #expect(lower != shape.folder)
        let left = [
            shape.folder: info(leftURL, shape.folder, isDir: true),
            shape.folder + "/" + shape.child: info(leftURL, shape.folder + "/" + shape.child),
        ]
        let right = [lower: info(rightURL, lower, isDir: true, isUnexplored: true)]

        #expect(compute(left, right, caseInsensitive: true).isEmpty)
    }

    // MARK: - Which name differs

    /// Only the folders' case differs, so the identical child under them is no row at all — not
    /// "Names differ only by case", which is the child's leaf against the other's.
    @Test(arguments: shapes)
    func aChildUnderCaseVariantFoldersIsNotACaseDifference(_ shape: Shape) {
        let lower = shape.folder.lowercased()
        let left = [
            shape.folder: info(leftURL, shape.folder, isDir: true),
            shape.folder + "/" + shape.child: info(leftURL, shape.folder + "/" + shape.child),
        ]
        let right = [
            lower: info(rightURL, lower, isDir: true),
            lower + "/" + shape.child: info(rightURL, lower + "/" + shape.child),
        ]

        #expect(compute(left, right, caseInsensitive: true).isEmpty)
    }

    /// The child pairs across the conflicted folders and is compared like any other content: one
    /// `.differentDates` row on both real paths, not a name conflict of its own, and not two
    /// Missing rows that each copy onto the other side's file.
    @Test(arguments: conflictShapes)
    func aChildUnderConflictedFoldersPairsAcross(_ shape: ConflictShape) {
        let left = [
            shape.fused: info(leftURL, shape.fused, isDir: true),
            shape.fused + "/" + shape.child: info(leftURL, shape.fused + "/" + shape.child, size: 1),
        ]
        let right = [
            shape.partner: info(rightURL, shape.partner, isDir: true),
            shape.partner + "/" + shape.child: info(rightURL, shape.partner + "/" + shape.child, size: 2),
        ]

        let diffs = compute(left, right)

        #expect(diffs.map(\.type) == [.nameConflict, .differentDates])
        let child = diffs.first { $0.type == .differentDates }
        #expect(child?.relativePath == shape.fused + "/" + shape.child)
        #expect(child?.leftItemPath == "/left/" + shape.fused + "/" + shape.child)
        #expect(child?.rightItemPath == "/right/" + shape.partner + "/" + shape.child)
    }

    // MARK: - Where a one-sided child is copied to

    /// Re-aimed at the right side's real folder spelling, with the `/` kept: dropping the fused
    /// folder's Character count from the front took the slash too, and the copy went BESIDE the
    /// folder (`X؀ f.txt`); failing to see the boundary at all left it aimed at the left's
    /// spelling, minting the doppelganger folder the conflict row exists to prevent.
    @Test(arguments: conflictShapes)
    func aLeftOnlyChildIsCopiedIntoTheRightSidesFolder(_ shape: ConflictShape) {
        let left = [
            shape.fused: info(leftURL, shape.fused, isDir: true),
            shape.fused + "/" + shape.child: info(leftURL, shape.fused + "/" + shape.child),
        ]
        let right = [shape.partner: info(rightURL, shape.partner, isDir: true)]

        let missing = compute(left, right).first { $0.type == .missingOnRight }

        #expect(missing?.relativePath == shape.fused + "/" + shape.child)
        #expect(missing?.rightItemPath == "/right/" + shape.partner + "/" + shape.child)
    }

    @Test(arguments: conflictShapes)
    func aRightOnlyChildIsCopiedIntoTheLeftSidesFolder(_ shape: ConflictShape) {
        let left = [shape.partner: info(leftURL, shape.partner, isDir: true)]
        let right = [
            shape.fused: info(rightURL, shape.fused, isDir: true),
            shape.fused + "/" + shape.child: info(rightURL, shape.fused + "/" + shape.child),
        ]

        let missing = compute(left, right).first { $0.type == .missingOnLeft }

        #expect(missing?.relativePath == shape.fused + "/" + shape.child)
        #expect(missing?.leftItemPath == "/left/" + shape.partner + "/" + shape.child)
    }
}

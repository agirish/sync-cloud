import Testing
import Foundation
@testable import Sync

/// Pins the diff engine's `.nameConflict` classification: cross-pane pairs whose names differ
/// only invisibly (trailing/leading whitespace, trailing dots, Unicode NFC/NFD) surface as a
/// single conflict row with both REAL item paths — not as two "missing" rows whose copy offer
/// would mint an identical-looking, provider-unsyncable duplicate (the iCloud `Swimming ` vs
/// Dropbox `Swimming` doppelganger).
@Suite struct NameConflictDiffTests {

    private let leftURL = URL(fileURLWithPath: "/left")
    private let rightURL = URL(fileURLWithPath: "/right")
    private let baseDate = Date(timeIntervalSince1970: 1_000_000)

    private func leftProvider() -> CloudProvider {
        CloudProvider(id: "l", displayName: "iCloud", imageName: "folder", rootPath: "/left", type: .iCloud)
    }
    private func rightProvider() -> CloudProvider {
        CloudProvider(id: "r", displayName: "Dropbox", imageName: "folder", rootPath: "/right", type: .dropBox)
    }

    /// FileInfo for `relativePath` under the given root.
    private func info(
        _ root: URL, _ relativePath: String,
        isDir: Bool = false, date: Date? = nil, size: Int? = nil
    ) -> FileDiffEngine.FileInfo {
        FileDiffEngine.FileInfo(
            url: root.appendingPathComponent(relativePath),
            modificationDate: date ?? baseDate,
            fileSize: isDir ? nil : (size ?? 10),
            isDirectory: isDir
        )
    }

    private func compute(
        left: [String: FileDiffEngine.FileInfo],
        right: [String: FileDiffEngine.FileInfo],
        caseInsensitive: Bool = false
    ) -> [FileDifference] {
        FileDiffEngine.computeDifferences(
            left: leftProvider(), leftURL: leftURL,
            right: rightProvider(), rightURL: rightURL,
            leftFilesInfo: left, rightFilesInfo: right,
            caseInsensitive: caseInsensitive
        )
    }

    // MARK: - Classification

    @Test func testTrailingSpaceFolderPairIsOneNameConflictNotTwoMissingRows() {
        // The confirmed real-world shape: iCloud stores "Swimming " (trailing space), the
        // Dropbox server normalized its copy to "Swimming"; identical content inside.
        let left = [
            "Fitness": info(leftURL, "Fitness", isDir: true),
            "Fitness/Swimming ": info(leftURL, "Fitness/Swimming ", isDir: true),
            "Fitness/Swimming /log.txt": info(leftURL, "Fitness/Swimming /log.txt"),
        ]
        let right = [
            "Fitness": info(rightURL, "Fitness", isDir: true),
            "Fitness/Swimming": info(rightURL, "Fitness/Swimming", isDir: true),
            "Fitness/Swimming/log.txt": info(rightURL, "Fitness/Swimming/log.txt"),
        ]

        let diffs = compute(left: left, right: right)

        // Exactly one row: the folder conflict. The identical children pair up through the
        // normalized ancestor and produce nothing.
        #expect(diffs.count == 1)
        let conflict = diffs[0]
        #expect(conflict.type == .nameConflict)
        #expect(conflict.relativePath == "Fitness/Swimming ")
        // Both paths are REAL items, so a sync targets the existing counterpart (a normal
        // collision), never a to-be-created doppelganger.
        #expect(conflict.leftItemPath == "/left/Fitness/Swimming ")
        #expect(conflict.rightItemPath == "/right/Fitness/Swimming")
        #expect(conflict.description.contains("trailing space"))
        #expect(conflict.description.contains("iCloud"))
        #expect(conflict.description.contains("Dropbox"))
    }

    @Test func testNewerRightSideSuggestsCopyToLeft() {
        let left = ["Report ": info(leftURL, "Report ")]
        let right = ["Report": info(rightURL, "Report", date: baseDate.addingTimeInterval(60))]

        let diffs = compute(left: left, right: right)

        #expect(diffs.count == 1)
        #expect(diffs[0].type == .nameConflict)
        #expect(diffs[0].action == .copyToLeft)
    }

    @Test func testEqualDatesDefaultToCopyToRight() {
        let left = ["Report ": info(leftURL, "Report ")]
        let right = ["Report": info(rightURL, "Report")]

        let diffs = compute(left: left, right: right)
        #expect(diffs.first?.action == .copyToRight)
    }

    @Test func testUnicodeFormVariantsAlreadyMatchAsExactPairs() {
        // Swift String equality (and Dictionary hashing) is canonical: an NFD key and its
        // NFC twin are THE SAME key, so the engine's exact-match pass pairs them before any
        // near-name logic could — identical metadata produces no rows at all. This pins the
        // guarantee that NFC/NFD form differences can never mint phantom "missing" rows.
        let nfd = "Cafe\u{0301}.txt"
        let nfc = "Café.txt"
        #expect(Array(nfd.utf8) != Array(nfc.utf8)) // different bytes on disk…
        #expect(nfd == nfc)                          // …but one Swift string identity
        let left = [nfd: info(leftURL, nfd)]
        let right = [nfc: info(rightURL, nfc)]

        let diffs = compute(left: left, right: right)

        #expect(diffs.isEmpty)
    }

    @Test func testTrailingPeriodPairClassified() {
        let left = ["Notes.": info(leftURL, "Notes.")]
        let right = ["Notes": info(rightURL, "Notes")]

        let diffs = compute(left: left, right: right)

        #expect(diffs.count == 1)
        #expect(diffs[0].type == .nameConflict)
        #expect(diffs[0].description.contains("period"))
    }

    @Test func testCaseAndWhitespaceComboClassifiedOnCaseInsensitiveVolumes() {
        let left = ["SWIMMING ": info(leftURL, "SWIMMING ", isDir: true)]
        let right = ["swimming": info(rightURL, "swimming", isDir: true)]

        let diffs = compute(left: left, right: right, caseInsensitive: true)

        #expect(diffs.count == 1)
        #expect(diffs[0].type == .nameConflict)
    }

    @Test func testCaseOnlyDifferenceIsNotANameConflict() {
        // Pure case variants stay the case-variant story (existing behavior): equal-content
        // files surface as the comparable "Names differ only by case" row, not a conflict.
        let left = ["readme.txt": info(leftURL, "readme.txt")]
        let right = ["README.txt": info(rightURL, "README.txt")]

        let diffs = compute(left: left, right: right, caseInsensitive: true)

        #expect(diffs.count == 1)
        #expect(diffs[0].type == .differentDates)
        #expect(diffs[0].description == "Names differ only by case")
    }

    // MARK: - Contents of a conflicted folder pair

    @Test func testDifferingChildUnderConflictedFoldersComparesWithRealPaths() {
        let left = [
            "Swimming ": info(leftURL, "Swimming ", isDir: true),
            "Swimming /log.txt": info(leftURL, "Swimming /log.txt", size: 10),
        ]
        let right = [
            "Swimming": info(rightURL, "Swimming", isDir: true),
            "Swimming/log.txt": info(rightURL, "Swimming/log.txt", size: 999),
        ]

        let diffs = compute(left: left, right: right)

        #expect(diffs.count == 2)
        let folder = diffs.first { $0.type == .nameConflict }
        let child = diffs.first { $0.type == .differentDates }
        #expect(folder?.relativePath == "Swimming ")
        #expect(child?.relativePath == "Swimming /log.txt")
        // The child's paths point at both real files, each under its own side's spelling.
        #expect(child?.leftItemPath == "/left/Swimming /log.txt")
        #expect(child?.rightItemPath == "/right/Swimming/log.txt")
    }

    @Test func testLeftOnlyChildTargetsTheRightSidesRealFolderSpelling() {
        let left = [
            "Swimming ": info(leftURL, "Swimming ", isDir: true),
            "Swimming /new.txt": info(leftURL, "Swimming /new.txt"),
        ]
        let right = [
            "Swimming": info(rightURL, "Swimming", isDir: true)
        ]

        let diffs = compute(left: left, right: right)

        let missing = diffs.first { $0.type == .missingOnRight }
        #expect(missing?.relativePath == "Swimming /new.txt")
        // Re-aimed at the destination's REAL folder — the naive join would have been
        // "/right/Swimming /new.txt", creating the doppelganger folder on copy.
        #expect(missing?.rightItemPath == "/right/Swimming/new.txt")
    }

    @Test func testRightOnlyChildTargetsTheLeftSidesRealFolderSpelling() {
        let left = [
            "Swimming ": info(leftURL, "Swimming ", isDir: true)
        ]
        let right = [
            "Swimming": info(rightURL, "Swimming", isDir: true),
            "Swimming/extra.txt": info(rightURL, "Swimming/extra.txt"),
        ]

        let diffs = compute(left: left, right: right)

        let missing = diffs.first { $0.type == .missingOnLeft }
        #expect(missing?.relativePath == "Swimming/extra.txt")
        #expect(missing?.leftItemPath == "/left/Swimming /extra.txt")
    }

    /// Two conflicted folders, one inside the other: the deeper pair already spells both levels
    /// the right side's way, so it is the one the child is re-aimed through.
    @Test func testAChildTwoConflictedFoldersDownTargetsBothRealSpellings() {
        let left = [
            "Fitness ": info(leftURL, "Fitness ", isDir: true),
            "Fitness /Swimming ": info(leftURL, "Fitness /Swimming ", isDir: true),
            "Fitness /Swimming /new.txt": info(leftURL, "Fitness /Swimming /new.txt"),
        ]
        let right = [
            "Fitness": info(rightURL, "Fitness", isDir: true),
            "Fitness/Swimming": info(rightURL, "Fitness/Swimming", isDir: true),
        ]

        let diffs = compute(left: left, right: right)

        #expect(diffs.map(\.type) == [.nameConflict, .nameConflict, .missingOnRight])
        let missing = diffs.first { $0.type == .missingOnRight }
        #expect(missing?.relativePath == "Fitness /Swimming /new.txt")
        #expect(missing?.rightItemPath == "/right/Fitness/Swimming/new.txt")
    }

    // MARK: - Guards

    @Test func testExactPairOwnsItsKeysOverNearNameMatching() {
        // Left holds BOTH spellings (the post-bug doppelganger state on one side); the right
        // "Swimming" belongs to its exact left twin, so the trailing-space folder stays a
        // plain missing row rather than stealing the match.
        let left = [
            "Swimming": info(leftURL, "Swimming", isDir: true),
            "Swimming ": info(leftURL, "Swimming ", isDir: true),
        ]
        let right = [
            "Swimming": info(rightURL, "Swimming", isDir: true)
        ]

        let diffs = compute(left: left, right: right)

        #expect(diffs.count == 1)
        #expect(diffs[0].type == .missingOnRight)
        #expect(diffs[0].relativePath == "Swimming ")
    }

    /// The same folders with a file inside. The trailing-space folder pairs with nothing, but the
    /// near-name of its `log.txt` is claimed once on each side, so the file paired across into the
    /// folder the exact pair owns: a both-sides row inside a folder reported missing, never
    /// collapsed into it. Syncing the two rows handled `log.txt` twice, and the right side's own
    /// `log.txt`, which the left `Swimming` lacks, was never reported at all.
    @Test(arguments: [false, true])
    func testAChildOfAFolderThatPairsWithNothingStaysInItsMissingRow(caseInsensitive: Bool) {
        let left = [
            "Swimming": info(leftURL, "Swimming", isDir: true),
            "Swimming ": info(leftURL, "Swimming ", isDir: true),
            "Swimming /log.txt": info(leftURL, "Swimming /log.txt", size: 1),
        ]
        let right = [
            "Swimming": info(rightURL, "Swimming", isDir: true),
            "Swimming/log.txt": info(rightURL, "Swimming/log.txt", size: 2),
        ]

        let diffs = compute(left: left, right: right, caseInsensitive: caseInsensitive)

        #expect(diffs.map(\.relativePath) == ["Swimming ", "Swimming/log.txt"])
        let byPath = Dictionary(uniqueKeysWithValues: diffs.map { ($0.relativePath, $0) })
        #expect(byPath["Swimming "]?.type == .missingOnRight)
        #expect(byPath["Swimming "]?.enclosedItemCount == 1)
        #expect(byPath["Swimming/log.txt"]?.type == .missingOnLeft)
    }

    /// Mirrored: the doppelganger pair is on the RIGHT, and the left `log.txt` paired across into
    /// the right's unpaired folder.
    @Test func testAChildOfARightFolderThatPairsWithNothingStaysInItsMissingRow() {
        let left = [
            "Swimming": info(leftURL, "Swimming", isDir: true),
            "Swimming/log.txt": info(leftURL, "Swimming/log.txt", size: 1),
        ]
        let right = [
            "Swimming": info(rightURL, "Swimming", isDir: true),
            "Swimming ": info(rightURL, "Swimming ", isDir: true),
            "Swimming /log.txt": info(rightURL, "Swimming /log.txt", size: 2),
        ]

        let diffs = compute(left: left, right: right)

        #expect(diffs.map(\.relativePath) == ["Swimming ", "Swimming/log.txt"])
        let byPath = Dictionary(uniqueKeysWithValues: diffs.map { ($0.relativePath, $0) })
        #expect(byPath["Swimming "]?.type == .missingOnLeft)
        #expect(byPath["Swimming "]?.enclosedItemCount == 1)
        #expect(byPath["Swimming/log.txt"]?.type == .missingOnRight)
    }

    /// The folder that pairs with nothing is two levels up, and the level between pairs on its
    /// own near-name — so every folder above the key is checked, not only its parent.
    @Test func testEveryFolderAboveAChildMustPairNotOnlyItsParent() {
        let left = [
            "Swimming": info(leftURL, "Swimming", isDir: true),
            "Swimming ": info(leftURL, "Swimming ", isDir: true),
            "Swimming /2026": info(leftURL, "Swimming /2026", isDir: true),
            "Swimming /2026/log.txt": info(leftURL, "Swimming /2026/log.txt", size: 1),
        ]
        let right = [
            "Swimming": info(rightURL, "Swimming", isDir: true),
            "Swimming/2026": info(rightURL, "Swimming/2026", isDir: true),
            "Swimming/2026/log.txt": info(rightURL, "Swimming/2026/log.txt", size: 2),
        ]

        let diffs = compute(left: left, right: right)

        #expect(diffs.map(\.relativePath) == ["Swimming ", "Swimming/2026"])
        let byPath = Dictionary(uniqueKeysWithValues: diffs.map { ($0.relativePath, $0) })
        #expect(byPath["Swimming "]?.type == .missingOnRight)
        #expect(byPath["Swimming "]?.enclosedItemCount == 2)
        #expect(byPath["Swimming/2026"]?.type == .missingOnLeft)
        #expect(byPath["Swimming/2026"]?.enclosedItemCount == 1)
    }

    /// The boundary of that rule: an ambiguous near-name is not a disqualification by itself.
    /// `Swimming` is claimed twice on the left, but it pairs EXACTLY, so a file inside it still
    /// pairs across on its own invisible difference.
    @Test func testAChildOfAnExactlyPairedFolderStillPairsOnItsOwnNearName() {
        let left = [
            "Swimming": info(leftURL, "Swimming", isDir: true),
            "Swimming ": info(leftURL, "Swimming ", isDir: true),
            "Swimming/log.txt ": info(leftURL, "Swimming/log.txt "),
        ]
        let right = [
            "Swimming": info(rightURL, "Swimming", isDir: true),
            "Swimming/log.txt": info(rightURL, "Swimming/log.txt"),
        ]

        let diffs = compute(left: left, right: right)

        #expect(diffs.map(\.relativePath) == ["Swimming ", "Swimming/log.txt "])
        let byPath = Dictionary(uniqueKeysWithValues: diffs.map { ($0.relativePath, $0) })
        #expect(byPath["Swimming "]?.type == .missingOnRight)
        #expect(byPath["Swimming "]?.enclosedItemCount == nil)
        #expect(byPath["Swimming/log.txt "]?.type == .nameConflict)
        #expect(byPath["Swimming/log.txt "]?.rightItemPath == "/right/Swimming/log.txt")
    }

    /// The same boundary for a folder that pairs as a case variant: `Docs` and `docs ` claim one
    /// folded near-name, but `Docs` pairs with the right's `docs` by case alone, so the file inside
    /// still pairs across.
    @Test func testAChildOfACaseVariantPairedFolderStillPairsBesideAnAmbiguousSpelling() {
        let left = [
            "Docs": info(leftURL, "Docs", isDir: true),
            "docs ": info(leftURL, "docs ", isDir: true),
            "Docs/log.txt ": info(leftURL, "Docs/log.txt "),
        ]
        let right = [
            "docs": info(rightURL, "docs", isDir: true),
            "docs/log.txt": info(rightURL, "docs/log.txt"),
        ]

        let diffs = compute(left: left, right: right, caseInsensitive: true)

        #expect(diffs.map(\.relativePath) == ["Docs/log.txt ", "docs "])
        let byPath = Dictionary(uniqueKeysWithValues: diffs.map { ($0.relativePath, $0) })
        #expect(byPath["Docs/log.txt "]?.type == .nameConflict)
        #expect(byPath["Docs/log.txt "]?.rightItemPath == "/right/docs/log.txt")
        #expect(byPath["docs "]?.type == .missingOnRight)
    }

    @Test func testAmbiguousCandidatesFallBackToPlainMissingRows() {
        // Two right keys share one normalized form: matching either would be arbitrary, so
        // near-name matching stands down deterministically.
        let left = [
            "Swimming.": info(leftURL, "Swimming.")
        ]
        let right = [
            "Swimming": info(rightURL, "Swimming"),
            "Swimming ": info(rightURL, "Swimming "),
        ]

        let diffs = compute(left: left, right: right)

        #expect(diffs.count == 3)
        #expect(diffs.allSatisfy { $0.type == .missingOnRight || $0.type == .missingOnLeft })
    }

    // MARK: - Pane swap

    @Test func testMirroredPreservesNameConflict() {
        let left = ["Report ": info(leftURL, "Report ")]
        let right = ["Report": info(rightURL, "Report")]

        guard let conflict = compute(left: left, right: right).first else {
            Issue.record("expected a name-conflict row")
            return
        }
        let mirrored = conflict.mirrored()

        #expect(mirrored.type == .nameConflict)
        #expect(mirrored.leftItemPath == conflict.rightItemPath)
        #expect(mirrored.rightItemPath == conflict.leftItemPath)
        #expect(mirrored.action == conflict.action.mirrored)
        #expect(mirrored.id == conflict.id)
    }
}

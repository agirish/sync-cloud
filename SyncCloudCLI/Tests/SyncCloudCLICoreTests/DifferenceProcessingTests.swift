import Testing
import Foundation
import Sync
@testable import SyncCloudCLICore

private func diff(
    _ relativePath: String,
    type: FileDifference.DifferenceType = .missingOnRight,
    action: FileDifference.SyncAction = .copyToRight,
    leftSize: Int? = nil,
    rightSize: Int? = nil
) -> FileDifference {
    FileDifference(
        relativePath: relativePath,
        leftItemPath: "/left/\(relativePath)",
        rightItemPath: "/right/\(relativePath)",
        type: type,
        action: action,
        description: "test",
        leftFileSize: leftSize,
        rightFileSize: rightSize
    )
}

// MARK: - filterDifferences

@Suite struct FilterDifferencesTests {

    @Test func testAutoDirectionKeepsBothActions() {
        let diffs = [diff("a", action: .copyToRight), diff("b", action: .copyToLeft)]
        let result = DifferenceProcessing.filterDifferences(diffs, direction: .auto, showHidden: true, ignore: [])
        #expect(result.map(\.relativePath) == ["a", "b"])
    }

    @Test func testDirectionFiltersOppositeAction() {
        let diffs = [diff("a", action: .copyToRight), diff("b", action: .copyToLeft)]
        #expect(DifferenceProcessing.filterDifferences(diffs, direction: .toRight, showHidden: true, ignore: [])
            .map(\.relativePath) == ["a"])
        #expect(DifferenceProcessing.filterDifferences(diffs, direction: .toLeft, showHidden: true, ignore: [])
            .map(\.relativePath) == ["b"])
    }

    @Test func testHiddenPathsDroppedUnlessShowHidden() {
        // Hidden = any dot-prefixed component, including in a parent directory.
        let diffs = [diff(".DS_Store"), diff("docs/.git/config"), diff("visible.txt")]
        #expect(DifferenceProcessing.filterDifferences(diffs, direction: .auto, showHidden: false, ignore: [])
            .map(\.relativePath) == ["visible.txt"])
        #expect(DifferenceProcessing.filterDifferences(diffs, direction: .auto, showHidden: true, ignore: [])
            .count == 3)
    }

    @Test func testIgnoreMatchesExactAndDirectoryPrefix() {
        let diffs = [diff("build/out.o"), diff("build"), diff("builder/x"), diff("src/main.swift")]
        let result = DifferenceProcessing.filterDifferences(
            diffs, direction: .auto, showHidden: true, ignore: ["build"])
        // "build" and "build/..." are ignored; "builder/x" is not a prefix-directory match.
        #expect(result.map(\.relativePath) == ["builder/x", "src/main.swift"])
    }

    // The Drive date-noise cases mirror FileSyncManager.computeFilteredState's
    // dropDriveDateNoise predicate: drop only ".differentDates + sizesMatch + copyToLeft"
    // and only when the setting is on and the right side is Google Drive.

    @Test func testDriveDateNoiseDroppedWhenSettingOnAndRightIsGoogleDrive() {
        let diffs = [
            // Exactly "right newer, same size" -> noise, dropped.
            diff("noise.txt", type: .differentDates, action: .copyToLeft, leftSize: 10, rightSize: 10),
            // Left newer, same size -> kept (only right-newer is Drive date noise).
            diff("left-newer.txt", type: .differentDates, action: .copyToRight, leftSize: 10, rightSize: 10),
            // Right newer but sizes differ -> a real content change, kept.
            diff("real-change.txt", type: .differentDates, action: .copyToLeft, leftSize: 10, rightSize: 20),
            // Right newer but a size is unknown -> sizesMatch is false, kept.
            diff("no-size.txt", type: .differentDates, action: .copyToLeft, rightSize: 10),
            // copyToLeft for a missing file is not a date difference, kept.
            diff("missing.txt", type: .missingOnLeft, action: .copyToLeft, leftSize: 10, rightSize: 10),
        ]
        let result = DifferenceProcessing.filterDifferences(
            diffs, direction: .auto, showHidden: true, ignore: [],
            ignoreGoogleDriveNewerDateOnly: true, rightProviderType: .googleDrive)
        #expect(result.map(\.relativePath) == ["left-newer.txt", "real-change.txt", "no-size.txt", "missing.txt"])
    }

    @Test func testDriveDateNoiseKeptWhenSettingOff() {
        let diffs = [diff("noise.txt", type: .differentDates, action: .copyToLeft, leftSize: 10, rightSize: 10)]
        let result = DifferenceProcessing.filterDifferences(
            diffs, direction: .auto, showHidden: true, ignore: [],
            ignoreGoogleDriveNewerDateOnly: false, rightProviderType: .googleDrive)
        #expect(result.count == 1)
    }

    @Test func testDriveDateNoiseKeptWhenRightIsNotGoogleDrive() {
        let diffs = [diff("noise.txt", type: .differentDates, action: .copyToLeft, leftSize: 10, rightSize: 10)]
        for rightType: CloudProvider.ProviderType? in [.iCloud, .oneDrive, .dropBox, nil] {
            let result = DifferenceProcessing.filterDifferences(
                diffs, direction: .auto, showHidden: true, ignore: [],
                ignoreGoogleDriveNewerDateOnly: true, rightProviderType: rightType)
            #expect(result.count == 1)
        }
    }

    @Test func testFiltersCompose() {
        let diffs = [
            diff(".hidden", action: .copyToRight),
            diff("ignored/a", action: .copyToRight),
            diff("kept", action: .copyToRight),
            diff("wrong-way", action: .copyToLeft),
        ]
        let result = DifferenceProcessing.filterDifferences(
            diffs, direction: .toRight, showHidden: false, ignore: ["ignored"])
        #expect(result.map(\.relativePath) == ["kept"])
    }
}

// MARK: - partitionByVerification

@Suite struct PartitionByVerificationTests {

    @Test func testIdenticalDateOnlyDifferencesAreDropped() async {
        let diffs = [
            diff("same.bin", type: .differentDates, leftSize: 10, rightSize: 10),
            diff("differs.bin", type: .differentDates, leftSize: 10, rightSize: 10),
        ]
        let (kept, count) = await DifferenceProcessing.partitionByVerification(diffs) { d in
            d.relativePath == "same.bin" // only same.bin verifies identical
        }
        #expect(kept.map(\.relativePath) == ["differs.bin"])
        #expect(count == 1)
    }

    @Test func testOnlySizeMatchedDateDifferencesAreVerified() async {
        let diffs = [
            diff("missing.txt", type: .missingOnRight),
            diff("size-differs.txt", type: .differentDates, leftSize: 10, rightSize: 20),
            diff("no-sizes.txt", type: .differentDates),
        ]
        var verified: [String] = []
        let (kept, count) = await DifferenceProcessing.partitionByVerification(diffs) { d in
            verified.append(d.relativePath)
            return true
        }
        // None are candidates, so the verifier is never consulted and all are kept.
        #expect(verified.isEmpty)
        #expect(kept.count == 3)
        #expect(count == 0)
    }

    @Test func testUnverifiableIsKept() async {
        // nil = verification not possible (e.g. unreadable file) -> keep the difference.
        let diffs = [diff("unreadable.bin", type: .differentDates, leftSize: 5, rightSize: 5)]
        let (kept, count) = await DifferenceProcessing.partitionByVerification(diffs) { _ in nil }
        #expect(kept.count == 1)
        #expect(count == 0)
    }

    @Test func testOrderPreserved() async {
        let diffs = [
            diff("a", type: .differentDates, leftSize: 1, rightSize: 1),
            diff("b", type: .missingOnRight),
            diff("c", type: .differentDates, leftSize: 1, rightSize: 1),
        ]
        let (kept, count) = await DifferenceProcessing.partitionByVerification(diffs) { d in
            d.relativePath == "a"
        }
        #expect(kept.map(\.relativePath) == ["b", "c"])
        #expect(count == 1)
    }
}

// MARK: - sourceAndTarget / name mappings

@Suite struct DifferenceMappingTests {

    @Test func testSourceAndTargetFollowAction() {
        let toRight = diff("x", action: .copyToRight)
        #expect(DifferenceProcessing.sourceAndTarget(for: toRight) == ("/left/x", "/right/x"))

        let toLeft = diff("x", action: .copyToLeft)
        #expect(DifferenceProcessing.sourceAndTarget(for: toLeft) == ("/right/x", "/left/x"))
    }

    @Test func testTargetRelativePathUsesDestinationSpelling() {
        // Trailing-space doppelganger: left "Swimming " vs Dropbox-normalized right "Swimming".
        // The copyToRight write target is the right's own EXISTING valid path, so the name
        // validated against the destination provider must be "Swimming" (not skipped) — the
        // old code validated diff.relativePath ("Swimming ") and falsely skipped the copy.
        let conflict = FileDifference(
            relativePath: "Swimming ",
            leftItemPath: "/left/Swimming ",
            rightItemPath: "/right/Swimming",
            type: .nameConflict,
            action: .copyToRight,
            description: "test",
            leftFileSize: 1,
            rightFileSize: 1
        )
        let validated = DifferenceProcessing.targetRelativePath(
            for: conflict, targetRoot: URL(fileURLWithPath: "/right"))
        #expect(validated == "Swimming")
        // The left spelling IS a Dropbox violation, the destination's own spelling is not:
        // the fixed validation keeps this row syncable.
        #expect(ProviderNameRules.violation(inRelativePath: "Swimming ", for: .dropBox) != nil)
        #expect(ProviderNameRules.violation(inRelativePath: validated, for: .dropBox) == nil)

        // copyToLeft mirrors: the target is the LEFT item path relative to the left root.
        let toLeft = FileDifference(
            relativePath: "Swimming",
            leftItemPath: "/left/Swimming",
            rightItemPath: "/right/Swimming ",
            type: .nameConflict,
            action: .copyToLeft,
            description: "test",
            leftFileSize: 1,
            rightFileSize: 1
        )
        #expect(DifferenceProcessing.targetRelativePath(
            for: toLeft, targetRoot: URL(fileURLWithPath: "/left/")) == "Swimming")
    }

    @Test func testTargetRelativePathFallsBackWhenTargetOutsideRoot() {
        let d = diff("nested/x", action: .copyToRight) // target /right/nested/x
        #expect(DifferenceProcessing.targetRelativePath(
            for: d, targetRoot: URL(fileURLWithPath: "/elsewhere")) == "nested/x")
        // Ordinary rows under the real root reduce to the plain relative path.
        #expect(DifferenceProcessing.targetRelativePath(
            for: d, targetRoot: URL(fileURLWithPath: "/right")) == "nested/x")
    }

    /// Edge cases of the round-4 target-path derivation (5f76853): the validated path must be
    /// the DESTINATION's own spelling for nested and root-level conflicts alike, byte-exact
    /// through unicode names, and must fall back safely for degenerate roots.
    @Test func testTargetRelativePathEdgeCases() {
        func conflict(rel: String, leftPath: String, rightPath: String,
                      action: FileDifference.SyncAction) -> FileDifference {
            FileDifference(relativePath: rel, leftItemPath: leftPath, rightItemPath: rightPath,
                           type: .nameConflict, action: action, description: "test",
                           leftFileSize: 1, rightFileSize: 1)
        }

        // NESTED conflict: only the leaf differs invisibly; every ancestor segment must survive.
        let nested = conflict(rel: "docs/reports/Q1 ",
                              leftPath: "/left/docs/reports/Q1 ",
                              rightPath: "/right/docs/reports/Q1",
                              action: .copyToRight)
        #expect(DifferenceProcessing.targetRelativePath(
            for: nested, targetRoot: URL(fileURLWithPath: "/right")) == "docs/reports/Q1")

        // ROOT-LEVEL conflict: a single-segment path reduces to the destination's bare leaf.
        let rootLevel = conflict(rel: "A ", leftPath: "/left/A ", rightPath: "/right/A",
                                 action: .copyToRight)
        #expect(DifferenceProcessing.targetRelativePath(
            for: rootLevel, targetRoot: URL(fileURLWithPath: "/right")) == "A")

        // UNICODE: multi-scalar characters in the ROOT and the path must strip byte-exactly —
        // an off-by-one in the prefix drop corrupts the first character of the result.
        let unicode = conflict(rel: "文件 ", leftPath: "/left/Ünïcode dir/文件 ",
                               rightPath: "/right/Ünïcode dir/文件",
                               action: .copyToRight)
        #expect(DifferenceProcessing.targetRelativePath(
            for: unicode, targetRoot: URL(fileURLWithPath: "/right/Ünïcode dir")) == "文件")

        // copyToLeft mirrors with a nested path: the LEFT item path is the target.
        let toLeft = conflict(rel: "docs/Q1", leftPath: "/left/docs/Q1",
                              rightPath: "/right/docs/Q1 ", action: .copyToLeft)
        #expect(DifferenceProcessing.targetRelativePath(
            for: toLeft, targetRoot: URL(fileURLWithPath: "/left")) == "docs/Q1")

        // Degenerate root "/": stripping trailing slashes empties it → safe relativePath fallback
        // (never a leading-slash "absolute relative" path).
        let underRoot = conflict(rel: "x ", leftPath: "/x ", rightPath: "/x", action: .copyToRight)
        #expect(DifferenceProcessing.targetRelativePath(
            for: underRoot, targetRoot: URL(fileURLWithPath: "/")) == "x ")
    }

    @Test func testStableOutputNames() {
        #expect(DifferenceProcessing.typeString(.missingOnRight) == "missing-on-right")
        #expect(DifferenceProcessing.typeString(.missingOnLeft) == "missing-on-left")
        #expect(DifferenceProcessing.typeString(.differentDates) == "different")
        #expect(DifferenceProcessing.actionString(.copyToRight) == "copy-to-right")
        #expect(DifferenceProcessing.actionString(.copyToLeft) == "copy-to-left")
        // Raw values are part of the CLI surface (--direction/--strategy).
        #expect(Direction(rawValue: "to-right") == .toRight)
        #expect(CollisionStrategy(rawValue: "keep-both") == .keepBoth)
    }
}

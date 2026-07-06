import Testing
import Sync
@testable import FileExplorer

private func diff(
    _ name: String,
    type: FileDifference.DifferenceType = .missingOnRight,
    action: FileDifference.SyncAction = .copyToRight,
    isSyncing: Bool = false,
    size: Int? = nil,
    rightSize: Int? = nil
) -> FileDifference {
    FileDifference(
        relativePath: name,
        leftItemPath: "/l/\(name)",
        rightItemPath: "/r/\(name)",
        type: type,
        action: action,
        description: "test",
        isSyncing: isSyncing,
        leftFileSize: size,
        rightFileSize: rightSize ?? size
    )
}

@Suite struct DifferencesSummaryTests {

    @Test func testCopyCountsFollowActions() {
        let summary = DifferencesSummary(
            differences: [
                diff("a", action: .copyToRight),
                diff("b", action: .copyToRight),
                diff("c", type: .missingOnLeft, action: .copyToLeft),
            ],
            filter: .all)
        #expect(summary.copyToRightCount == 2)
        #expect(summary.copyToLeftCount == 1)
    }

    @Test func testCopyCountsRespectTheActiveFilter() {
        let differences = [
            diff("missing", type: .missingOnRight, action: .copyToRight),
            diff("changed", type: .differentDates, action: .copyToRight, size: 5),
        ]
        // Filtered to missing-on-right, the changed item must not be counted:
        // the Copy button syncs exactly the filtered subset.
        let summary = DifferencesSummary(differences: differences, filter: .missingOnRight)
        #expect(summary.copyToRightCount == 1)
    }

    @Test func testSyncingAndVerifiableIgnoreTheFilter() {
        let differences = [
            diff("syncing", type: .missingOnLeft, action: .copyToLeft, isSyncing: true),
            diff("verifiable", type: .differentDates, action: .copyToRight, size: 10),
        ]
        // The filter hides both items, but syncing state and Verify All operate on
        // all differences, so both must still be reported.
        let summary = DifferencesSummary(differences: differences, filter: .missingOnRight)
        #expect(summary.copyToRightCount == 0)
        #expect(summary.anySyncing)
        #expect(summary.verifiableCount == 1)
    }

    @Test func testVerifiableRequiresDateTypeAndMatchingSizes() {
        let summary = DifferencesSummary(
            differences: [
                diff("candidate", type: .differentDates, size: 10),
                diff("size-differs", type: .differentDates, size: 10, rightSize: 20),
                diff("no-sizes", type: .differentDates),
                diff("missing", type: .missingOnRight, size: 10),
            ],
            filter: .all)
        #expect(summary.verifiableCount == 1)
    }

    @Test func testEmptyDifferences() {
        let summary = DifferencesSummary(differences: [], filter: .all)
        #expect(summary == DifferencesSummary(differences: [], filter: .missingOnLeft))
        #expect(summary.copyToRightCount == 0)
        #expect(!summary.anySyncing)
        #expect(summary.verifiableCount == 0)
    }
}

@Suite struct CanVerifyTests {

    private let candidate = diff("x", type: .differentDates, size: 8)

    @Test func testVerifiableRowAllowsVerify() {
        #expect(DifferencesSummary.canVerify(candidate, isRowVerifying: false, isVerifyAllInProgress: false))
    }

    @Test func testAnyBlockingConditionDisablesVerify() {
        // Wrong type.
        #expect(!DifferencesSummary.canVerify(
            diff("m", type: .missingOnRight, size: 8), isRowVerifying: false, isVerifyAllInProgress: false))
        // Sizes differ.
        #expect(!DifferencesSummary.canVerify(
            diff("s", type: .differentDates, size: 8, rightSize: 9), isRowVerifying: false, isVerifyAllInProgress: false))
        // Row already syncing.
        #expect(!DifferencesSummary.canVerify(
            diff("y", type: .differentDates, isSyncing: true, size: 8), isRowVerifying: false, isVerifyAllInProgress: false))
        // Row already verifying.
        #expect(!DifferencesSummary.canVerify(candidate, isRowVerifying: true, isVerifyAllInProgress: false))
        // Bulk verify running.
        #expect(!DifferencesSummary.canVerify(candidate, isRowVerifying: false, isVerifyAllInProgress: true))
    }
}

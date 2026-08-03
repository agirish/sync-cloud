import Testing
import Foundation
import Events
@testable import Sync

/// Pins the bulk-failure alert aggregation: `currentError` holds one error at a time, so a
/// bulk run with several failures must present a single aggregate summary (every failure is
/// still logged individually) instead of presenting per failure and leaving only the last
/// one visible.
@Suite struct BulkFailureAggregationTests {

    private func makeMissingSourceDiff(_ name: String) -> FileDifference {
        FileDifference(
            relativePath: name,
            leftItemPath: "/src/\(name)",
            rightItemPath: "/dst/\(name)",
            type: .missingOnRight,
            action: .copyToRight,
            description: "Missing"
        )
    }

    @MainActor
    @Test func testSyncAllWithTwoFailuresPresentsOneAggregateError() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)

        // Neither source exists on the virtual disk, so both copies fail.
        let diffs = [makeMissingSourceDiff("a.txt"), makeMissingSourceDiff("b.txt")]
        manager.rawDifferences = diffs
        manager.differences = diffs

        await manager.syncAll(direction: .copyToRight)

        let error = try #require(manager.currentError)
        #expect(error.title == "Sync Failed")
        #expect(error.message.contains("2 items"))
        #expect(error.message.contains("Activity Log"))
        // The alert carries the first failure's details (worker order is nondeterministic,
        // so "first" is whichever the run collected first — one of the two sources).
        #expect(error.path == "/src/a.txt" || error.path == "/src/b.txt")
        #expect(error.reason?.isEmpty == false)
        #expect(error.isRetryable == false)
    }

    @MainActor
    @Test func testSyncAllWithSingleFailureKeepsPerItemError() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)

        let diff = makeMissingSourceDiff("only.txt")
        manager.rawDifferences = [diff]
        manager.differences = [diff]

        await manager.syncAll(direction: .copyToRight)

        let error = try #require(manager.currentError)
        #expect(error.title == "Sync Failed")
        #expect(error.message == "Couldn't sync \"only.txt\".")
        #expect(error.path == "/src/only.txt")
    }

    /// A bulk run whose ONLY failure is a single file must still land in the persistent audit log,
    /// not just the (ephemeral) alert. The single-failure branch relies on `present()` to write the
    /// error line — unlike the `> 1` branch, it logs no line of its own — so these tests guard the
    /// invariant end-to-end: if either the branch stops calling `present()` or `present()` stops
    /// logging, a one-file failure would silently vanish from the log and these would fail.
    @MainActor
    @Test func testSyncAllSingleFailureIsLoggedAsError() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)

        let diff = makeMissingSourceDiff("onlySyncLog.txt")
        manager.rawDifferences = [diff]
        manager.differences = [diff]

        await manager.syncAll(direction: .copyToRight)

        #expect(await loggerHasError(containing: "onlySyncLog.txt"))
    }

    @MainActor
    @Test func testBulkCopySingleFailureIsLoggedAsError() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)

        // Current stamp: this test is about the per-file failure log, not the staleness guard.
        await manager.bulkCopyDifferencesLeftToRight(
            [makeMissingSourceDiff("onlyCopyLog.txt")], asOf: manager.fileOperationsEpoch
        )

        #expect(await loggerHasError(containing: "onlyCopyLog.txt"))
    }

    /// True when the shared Logger holds an ERROR entry whose message contains `fragment`.
    /// Awaiting a fresh log task first guarantees everything enqueued before it is visible; the
    /// fragment is a per-test unique file name, so accumulated cross-test entries can't false-match.
    @MainActor
    private func loggerHasError(containing fragment: String) async -> Bool {
        await Logger.shared.debug("bulk-failure-test flush marker").value
        return Logger.shared.entries.contains { $0.level == .error && $0.message.contains(fragment) }
    }

    @Test func testBulkFailedConstructorShape() {
        let error = SyncError.bulkFailed(
            verb: "copy",
            failureCount: 3,
            firstItem: "a.txt",
            firstPath: "/src/a.txt",
            firstReason: "disk full"
        )
        #expect(error.title == "Copy Failed")
        #expect(error.message == "Couldn't copy 3 items. The first failure was \"a.txt\"; the rest are in the Activity Log.")
        #expect(error.path == "/src/a.txt")
        #expect(error.reason == "disk full")
        #expect(error.isRetryable == false)
    }
}

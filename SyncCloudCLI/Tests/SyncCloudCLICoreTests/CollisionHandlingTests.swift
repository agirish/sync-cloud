import Testing
@testable import SyncCloudCLICore

@Suite struct CollisionHandlingTests {

    @Test func testDefaultStrategyIsReplace() {
        // The CLI's core use case is updating modified files, which always have an existing
        // destination — a skip default would make `sync` a no-op for them.
        #expect(CollisionStrategy.cliDefault == .replace)
    }

    @Test func testFreeTargetAlwaysProceeds() {
        for strategy: CollisionStrategy in [.skip, .replace, .keepBoth] {
            #expect(resolveCollision(strategy: strategy, targetExists: false) == .proceed)
        }
    }

    @Test func testExistingTargetFollowsStrategy() {
        #expect(resolveCollision(strategy: .skip, targetExists: true) == .skip)
        #expect(resolveCollision(strategy: .replace, targetExists: true) == .proceed)
        #expect(resolveCollision(strategy: .keepBoth, targetExists: true) == .copyToUnique)
    }

    @Test func testTallyAccounting() {
        var tally = SyncTally()
        #expect((tally.copied, tally.skipped, tally.failed) == (0, 0, 0))

        tally.recordCopied()
        tally.recordCopied(replacedExisting: true)
        tally.recordSkipped(relativePath: "a.txt")
        tally.recordSkipped(relativePath: "b/c.txt")
        tally.recordFailed()

        #expect(tally.copied == 2)
        #expect(tally.replaced == 1)
        #expect(tally.skipped == 2)
        #expect(tally.failed == 1)
        #expect(tally.skippedPaths == ["a.txt", "b/c.txt"])
    }
}

@Suite struct SyncSummaryTests {

    private func tally(copied: Int = 0, replaced: Int = 0, skipped: [String] = [], failed: Int = 0) -> SyncTally {
        var t = SyncTally()
        for i in 0..<copied { t.recordCopied(replacedExisting: i < replaced) }
        for path in skipped { t.recordSkipped(relativePath: path) }
        for _ in 0..<failed { t.recordFailed() }
        return t
    }

    @Test func testCleanRunIsOneLineAndExitsZero() {
        let s = syncSummary(tally: tally(copied: 3), strategy: .replace)
        #expect(s.stdoutLines == ["Sync complete. Copied: 3, Skipped: 0, Failed: 0."])
        #expect(s.stderrLines.isEmpty)
        #expect(!s.exitNonzero)
    }

    @Test func testFailuresGoToStderrAndExitNonzero() {
        let s = syncSummary(tally: tally(copied: 1, failed: 2), strategy: .replace)
        #expect(s.stdoutLines.first == "Sync complete. Copied: 1, Skipped: 0, Failed: 2.")
        #expect(s.stderrLines == ["2 file(s) failed to sync (errors above); exiting with a non-zero status."])
        #expect(s.exitNonzero)
    }

    @Test func testSkipStrategySkipsExplainTheFix() {
        let s = syncSummary(tally: tally(skipped: ["a.txt", "b/c.txt"]), strategy: .skip)
        #expect(s.stdoutLines.contains(
            "Skipped 2 file(s) (existing files left untouched; use --strategy replace to update them):"))
        #expect(s.stdoutLines.suffix(2) == ["  a.txt", "  b/c.txt"])
        #expect(!s.exitNonzero)
    }

    @Test func testReplacedCountMentionsTrashRecovery() {
        let s = syncSummary(tally: tally(copied: 4, replaced: 2), strategy: .replace)
        #expect(s.stdoutLines.contains(
            "Replaced 2 existing file(s); previous versions are recoverable from the Trash (exact paths in ~/sync-cloud.log)."))
    }

    @Test func testNoSkipExplanationWhenNothingSkipped() {
        let s = syncSummary(tally: tally(copied: 1), strategy: .skip)
        #expect(s.stdoutLines.count == 1)
    }
}

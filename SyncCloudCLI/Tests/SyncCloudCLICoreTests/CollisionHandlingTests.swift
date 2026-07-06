import Testing
@testable import SyncCloudCLICore

@Suite struct CollisionHandlingTests {

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
        tally.recordCopied()
        tally.recordSkipped(relativePath: "a.txt")
        tally.recordSkipped(relativePath: "b/c.txt")
        tally.recordFailed()

        #expect(tally.copied == 2)
        #expect(tally.skipped == 2)
        #expect(tally.failed == 1)
        #expect(tally.skippedPaths == ["a.txt", "b/c.txt"])
    }
}

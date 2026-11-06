import Testing

/// Pins `waitUntil`'s poll floor, which the many waits in this target depend on, and its twin in
/// `SyncCloudTests/TestSupport.swift` with it.
///
/// A deadline is in seconds while what these waits wait for arrives on main-actor turns, and under
/// load the two come apart (`docs/flaky-tests.md`, "Fixed pumps and fixed sleeps"). That failure
/// needs congestion to reproduce, but the floor's guarantee doesn't: a counter and an already-spent
/// deadline prove it on an idle machine, in milliseconds.
///
/// The demand below is a literal, never derived from the floor: zeroing the floor would zero the
/// requirement too, and the test would pass against the change it exists to catch.
///
/// There is no "a condition that never holds still gets a verdict" case: `waitUntil` reports
/// expiry by recording a failure, not by returning a Bool, so such a test would fail by
/// construction.
@MainActor
@Suite struct WaitUntilFloorTests {

    /// How many polls the condition below demands: a literal, not derived from `waitPollFloor`
    /// (see the suite comment).
    private static let pollsDemanded = 25

    /// Keeps that literal meaningful: it must be reachable within the floor, or the test below
    /// would be measuring the deadline instead.
    ///
    /// It is also the only thing that catches a floor lowered to just under the demand: the loop
    /// evaluates the condition once more after the deadline, in the `#expect`, so a floor of 24
    /// still buys a 25th evaluation. The real guarantee is `waitPollFloor + 1`.
    @Test func theDemandUsedByThisTestSitsBelowTheFloor() {
        #expect(Self.pollsDemanded < waitPollFloor,
                "\(Self.pollsDemanded) polls is not reachable within a floor of \(waitPollFloor) — the floor test below would be measuring the deadline")
    }

    /// The load-bearing property: with the deadline already spent, a condition that needs turns
    /// still gets them, which is what a congested run has too few of. `waitUntil` records its own
    /// labeled failure if it gives up, so a broken floor turns this red; the count says by how much.
    @Test func theFloorOutlivesAnExpiredDeadline() async {
        var polls = 0
        await waitUntil("a condition needing \(Self.pollsDemanded) polls never held", timeout: 0) {
            polls += 1
            return polls >= Self.pollsDemanded
        }
        #expect(polls >= Self.pollsDemanded,
                "the condition was evaluated only \(polls) times against a floor of \(waitPollFloor)")
    }
}

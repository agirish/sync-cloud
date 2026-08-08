import Testing
@testable import Sync

/// Pins `waitUntil`'s poll floor — the constant ~150 call sites in this target depend on, and its
/// twin in `SyncCloudTests/TestSupport.swift` with it.
///
/// The floor exists because a deadline is in seconds while everything these waits wait for arrives
/// on main-actor turns, and under load the two units come apart (`docs/flaky-tests.md`, mechanism
/// 2). That failure only reproduces under congestion, which is exactly why it must not be the thing
/// the fix is argued from: the floor's *guarantee* is deterministic even though the bug it prevents
/// is not — a property of this loop, provable with a counter and an already-spent deadline, on an
/// idle machine, in milliseconds.
///
/// Modelled on `LayoutPumpWaitTests` in the FileExplorer target, including the trap it records:
/// the demand below is a literal and must not be derived from the floor, or zeroing the floor also
/// zeroes the requirement and the test passes against the exact change it exists to catch.
///
/// **There is no "a condition that never holds still gets a verdict" case here**, unlike that
/// suite: `waitUntil` reports expiry by recording a failure rather than returning a Bool, so a test
/// that drove it to expiry would fail by construction. That half was verified by hand instead —
/// with the floor in place and a condition of `false`, the wait gives up naming its poll count.
@MainActor
@Suite struct WaitUntilFloorTests {

    /// How many polls the condition below demands — a LITERAL, deliberately not derived from
    /// `waitPollFloor`. See the suite comment.
    private static let pollsDemanded = 25

    /// Keeps that literal meaningful: it must be reachable within the floor, or the test below
    /// would be measuring the deadline instead.
    ///
    /// This guard is also the only thing that catches a floor lowered to just *under* the demand.
    /// The loop evaluates the condition once more after the deadline, in the `#expect`, so a floor
    /// of 24 still buys a 25th evaluation and the floor test below stays green — the real guarantee
    /// is `waitPollFloor + 1`.
    @Test func theDemandUsedByThisTestSitsBelowTheFloor() {
        #expect(Self.pollsDemanded < waitPollFloor,
                "\(Self.pollsDemanded) polls is not reachable within a floor of \(waitPollFloor) — the floor test below would be measuring the deadline")
    }

    /// The load-bearing property. With the deadline ALREADY spent, a condition that needs turns
    /// still gets them — which is precisely what a congested run has too few of.
    ///
    /// Both halves matter. `waitUntil` records its own labeled failure if it gives up, so a broken
    /// floor turns this red without any assertion of mine; the count below then says by how much.
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

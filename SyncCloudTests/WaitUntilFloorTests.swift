import Testing

/// Pins this target's `waitUntil` poll floor — the twin of the suite of the same name in
/// `Modules/Sync/Tests/Sync`, and duplicated for the same reason the helper itself is: the app
/// target cannot import the Sync package's test support.
///
/// **The duplication is the point.** `TestSupport.swift` here and its Sync copy are kept
/// byte-identical by convention alone, and a convention is exactly what a floor lowered on one side
/// slips past. Without this suite, `waitPollFloor` here could be zeroed — reverting every
/// app-target wait to the wall-clock behaviour that flaked — with nothing in this target to say so.
///
/// The Sync copy's comment carries the measurements and the mutation results; both suites reproduce
/// them identically, including that a floor one *under* the demand is caught only by the premise
/// guard, because the loop's post-deadline re-check buys one more evaluation.
@MainActor
@Suite struct WaitUntilFloorTests {

    /// A LITERAL, deliberately not derived from `waitPollFloor`: a demand that moves with the thing
    /// under test cannot measure it.
    private static let pollsDemanded = 25

    /// Keeps that literal meaningful, and is the only thing that catches a floor lowered to just
    /// under the demand.
    @Test func theDemandUsedByThisTestSitsBelowTheFloor() {
        #expect(Self.pollsDemanded < waitPollFloor,
                "\(Self.pollsDemanded) polls is not reachable within a floor of \(waitPollFloor) — the floor test below would be measuring the deadline")
    }

    /// With the deadline ALREADY spent, a condition that needs turns still gets them.
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

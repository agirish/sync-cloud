import Testing

/// Pins this target's `waitUntil` poll floor: the twin of the suite of the same name in
/// `Modules/Sync/Tests/Sync`, duplicated because the app target cannot import the Sync package's
/// test support.
///
/// The two helper copies are kept in step by convention alone, so without this suite
/// `waitPollFloor` here could be zeroed, putting every app-target wait back on the wall clock, and
/// nothing in this target would say so. A floor just under the demand is caught only by the
/// premise guard, because the loop's post-deadline re-check buys one more evaluation.
@MainActor
@Suite struct WaitUntilFloorTests {

    /// A literal, not derived from `waitPollFloor`: a demand that moves with the thing under test
    /// cannot measure it.
    private static let pollsDemanded = 25

    /// Keeps that literal meaningful, and is the only thing that catches a floor lowered to just
    /// under the demand.
    @Test func theDemandUsedByThisTestSitsBelowTheFloor() {
        #expect(Self.pollsDemanded < waitPollFloor,
                "\(Self.pollsDemanded) polls is not reachable within a floor of \(waitPollFloor) — the floor test below would be measuring the deadline")
    }

    /// With the deadline already spent, a condition that needs turns still gets them.
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

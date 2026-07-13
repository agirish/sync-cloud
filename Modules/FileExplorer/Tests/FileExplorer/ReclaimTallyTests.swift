import Testing
@testable import FileExplorer

/// Coverage for the Tidy reclaimed-space tally (H5) — the pure view-level accumulator behind the
/// count-up payoff. The animation/glow live in the view; only the math and caption are testable here.
@Suite struct ReclaimTallyTests {

    @Test func startsEmpty() {
        let tally = ReclaimTally()
        #expect(tally.totalBytes == 0)
        #expect(tally.hasReclaimed == false)
        // Nothing reclaimed yet ⇒ no caption to show.
        #expect(tally.freedCaption("0 bytes") == nil)
    }

    @Test func creditsAccumulate() {
        var tally = ReclaimTally()
        tally.credit(100)
        tally.credit(250)
        #expect(tally.totalBytes == 350)
        #expect(tally.hasReclaimed)
    }

    @Test func nonPositiveCreditsAreIgnored() {
        var tally = ReclaimTally()
        // A failed resolve (0 reclaimed) or a nonsense negative delta must never move the counter.
        tally.credit(0)
        tally.credit(-500)
        #expect(tally.totalBytes == 0)
        #expect(tally.hasReclaimed == false)
        // A real credit still lands after ignored ones.
        tally.credit(42)
        #expect(tally.totalBytes == 42)
    }

    @Test func resetClearsTheSession() {
        var tally = ReclaimTally()
        tally.credit(1_000)
        tally.reset()
        #expect(tally.totalBytes == 0)
        #expect(tally.hasReclaimed == false)
    }

    @Test func captionAppearsOnlyOnceReclaimed() {
        var tally = ReclaimTally()
        #expect(tally.freedCaption("1.2 GB") == nil)
        tally.credit(1)
        // The formatted string is passed through verbatim (locale-independent, deterministic).
        #expect(tally.freedCaption("1.2 GB") == "1.2 GB freed this session")
    }
}

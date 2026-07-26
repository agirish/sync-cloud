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

    @Test func aBatchWithNothingElseRunningCreditsTheWholeDrop() {
        var tally = ReclaimTally()
        tally.credit(2_000)                 // earlier work this session
        let banked = tally.totalBytes

        // Nothing landed while the batch ran, so the engine's whole drop belongs to the batch.
        let net = tally.netBatchCredit(reclaimableDrop: 900, bankedAtStart: banked)
        #expect(net == 900)
    }

    @Test func aBatchDoesNotDoubleCountAPerCardResolveThatLandedWhileItRan() {
        var tally = ReclaimTally()
        tally.credit(2_000)
        let banked = tally.totalBytes       // read as the batch starts

        // A per-card "apply" finishes mid-batch: it credits its own group.reclaimableBytes here…
        tally.credit(300)
        // …and lowers the engine's still-reclaimable figure by the same 300, so the drop the batch
        // measures (900) already contains it. Crediting the raw drop would bank those bytes twice.
        let net = tally.netBatchCredit(reclaimableDrop: 900, bankedAtStart: banked)
        #expect(net == 600)

        tally.credit(net)
        #expect(tally.totalBytes == 2_900)  // 2 000 + 300 + 600 — not 3 200
    }

    @Test func aBatchThatOnlyRedidConcurrentWorkCreditsNothing() {
        var tally = ReclaimTally()
        let banked = tally.totalBytes
        // Every group the batch was going to erase was resolved per-card while it ran: the drop and
        // the meanwhile-credit are the same bytes, so the batch adds nothing rather than doubling.
        tally.credit(750)
        let net = tally.netBatchCredit(reclaimableDrop: 750, bankedAtStart: banked)
        #expect(net == 0)
        tally.credit(net)                   // non-positive credits are ignored
        #expect(tally.totalBytes == 750)
    }

    @Test func captionAppearsOnlyOnceReclaimed() {
        var tally = ReclaimTally()
        #expect(tally.freedCaption("1.2 GB") == nil)
        tally.credit(1)
        // The formatted string is passed through verbatim (locale-independent, deterministic).
        #expect(tally.freedCaption("1.2 GB") == "1.2 GB freed this session")
    }
}

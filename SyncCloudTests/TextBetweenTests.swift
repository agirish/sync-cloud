import Testing

/// Pins `textBetween`'s one job: answering **nil** for positions that come back out of order,
/// instead of trapping.
///
/// **Without this suite the guard is free to delete.** Measured, not assumed: with this file
/// absent, removing `guard from <= to else { return nil }` from `TestSupport.swift` and running the
/// whole target left 563 tests in 44 suites and the same single known failure — not one of the five
/// call sites noticed, because every one of them passes its ranges in the RIGHT order while the
/// code they scan is correct. The guard only ever runs on the failure path, which is exactly the path
/// no green suite visits. A later "simplification" back to `String(source[from..<to])` would
/// restore the crash for all five, silently, and the first sign of it would be another pair of
/// `.ips` files.
///
/// **The out-of-order test proves itself.** If `textBetween` ever traps again, this suite does not
/// fail — the test host dies and the run reports the crash, which is the very outcome the helper
/// exists to prevent. Either way it cannot pass quietly.
@Suite struct TextBetweenTests {

    /// The real shape, not a synthetic pair of indices: two INDEPENDENT `range(of:)` searches over
    /// one string, which is the only way this hazard ever arises. Here the second literal sits
    /// first, so `from` lands after `to` — the state `restoreBrowseTabs` was in on 2026-08-16, when
    /// this slice took the test host down.
    @Test func positionsThatComeBackOutOfOrderAnswerNilInsteadOfTrapping() throws {
        let body = """
            Logger.warning("Restored the left browse tab at its source root")
            guard let restored = outcome?.list, !restored.isSeedState else {
                Logger.warning("Did not restore the left browse tab")
            }
            """
        let claim = try #require(body.range(of: "at its source root"))
        let abandoned = try #require(body.range(of: "Did not restore the"))
        #expect(claim.lowerBound < abandoned.lowerBound,
                "the fixture no longer puts the claim first, so it is not the out-of-order case at all")
        #expect(textBetween(body, from: abandoned.lowerBound, to: claim.lowerBound) == nil,
                "out-of-order positions did not answer nil — if this line was reached at all")
    }

    /// **The call sites' exact idiom**, end to end: `?.contains(_:) == true` over a nil must come
    /// out FALSE. Trading a crash for a vacuous green is the worse of the two outcomes, and nothing
    /// else in this suite says which one a nil produces.
    ///
    /// **The needle sits between the two literals on purpose, and that is the whole test.** It
    /// first asked for `.contains("anything")` over a fixture containing no such word, so the
    /// expectation held whichever way `textBetween` answered — nil and any real span alike came out
    /// false — and it could not fail for its stated reason. With the needle actually there, the
    /// obvious "helpful" rewrite is caught: an implementation that swaps the bounds and answers
    /// about the span rather than refusing it finds the needle and fails this.
    ///
    /// Both directions are asked, because only the pair shows the idiom DISCRIMINATES rather than
    /// always saying no — which is the other way this could pass while meaning nothing.
    @Test func aNilAnswerFailsTheCallSiteExpressionRatherThanPassingIt() throws {
        let body = "second RETURNS first"
        let first = try #require(body.range(of: "first"))
        let second = try #require(body.range(of: "second"))
        #expect(first.upperBound > second.lowerBound,
                "the fixture no longer puts the literals out of order, so the call below is not the nil case at all")
        #expect((textBetween(body, from: first.upperBound, to: second.lowerBound)?
                    .contains("RETURNS") == true) == false,
                "out-of-order positions did not come out false through the call sites' `== true` idiom — either a nil passes vacuously, or the helper answered about the span it was asked to refuse")
        #expect((textBetween(body, from: second.upperBound, to: first.lowerBound)?
                    .contains("RETURNS") == true) == true,
                "the same idiom over ORDERED positions did not find what sits between them, so the check above passes for the wrong reason")
    }

    /// Ordered positions still answer the text itself — the half that stops "return nil always"
    /// from being a passing implementation.
    @Test func orderedPositionsAnswerExactlyWhatSitsBetweenThem() throws {
        let body = "opened { the middle } closed"
        let open = try #require(body.range(of: "opened {"))
        let close = try #require(body.range(of: "} closed"))
        #expect(textBetween(body, from: open.upperBound, to: close.lowerBound) == " the middle ",
                "the text between two ordered positions is not what sits there")
    }

    /// Touching positions answer `""`, NOT nil — two call sites read this answer as
    /// `.trimmingCharacters(in:).isEmpty == true` to mean "the guarded line is the first thing in
    /// its branch". Were nil returned here, both would fail on correct code.
    @Test func touchingPositionsAnswerAnEmptyStringRatherThanNil() throws {
        let body = "if moves {Logger.shared.debug("
        let gate = try #require(body.range(of: "if moves {"))
        let log = try #require(body.range(of: "Logger.shared.debug("))
        #expect(gate.upperBound == log.lowerBound,
                "the fixture no longer has the two touching, so it is not measuring the empty case")
        #expect(textBetween(body, from: gate.upperBound, to: log.lowerBound) == "",
                "touching positions did not answer an empty string, so the nesting checks that read `.isEmpty` fail on correct code")
    }
}

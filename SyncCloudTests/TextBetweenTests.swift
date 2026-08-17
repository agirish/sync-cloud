import Testing

/// Pins `textBetween`'s one job: answering **nil** for positions that come back out of order,
/// instead of trapping.
///
/// **Without this suite the guard is free to delete.** Measured, not assumed: removing
/// `guard from <= to else { return nil }` from `TestSupport.swift` and running the whole target
/// leaves 563 tests in 44 suites and the same single known failure — not one of the five call
/// sites notices, because every one of them passes its ranges in the RIGHT order while the code
/// they scan is correct. The guard only ever runs on the failure path, which is exactly the path
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

    /// **The call sites' exact idiom**, end to end: `?.contains(_:) == true` over a nil must be
    /// FALSE. A helper that answered nil into an expectation that passed anyway would trade a crash
    /// for a vacuous green, which is the worse of the two.
    @Test func aNilAnswerFailsTheCallSiteExpressionRatherThanPassingIt() throws {
        let body = "second first"
        let first = try #require(body.range(of: "first"))
        let second = try #require(body.range(of: "second"))
        #expect((textBetween(body, from: first.upperBound, to: second.lowerBound)?
                    .contains("anything") == true) == false,
                "a nil answered into the call sites' `== true` idiom does not fail, so an out-of-order scan would pass vacuously")
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

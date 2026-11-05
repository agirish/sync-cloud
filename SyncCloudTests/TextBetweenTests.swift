import Testing

/// Pins `textBetween`'s one job: answering nil for positions that come back out of order, instead
/// of trapping.
///
/// Nothing else guards it: every call site passes its ranges in the right order while the code it
/// scans is correct, so removing `guard from <= to else { return nil }` from `TestSupport.swift`
/// leaves the rest of the target green. If `textBetween` traps, the out-of-order test takes the
/// test host down rather than failing, so it still cannot pass quietly.
@Suite struct TextBetweenTests {

    /// The real shape, not a synthetic pair of indices: two independent `range(of:)` searches over
    /// one string, the only way this hazard arises. The second literal sits first, so `from` lands
    /// after `to`.
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

    /// The call sites' exact idiom, end to end: `?.contains(_:) == true` over a nil must come out
    /// false, since a vacuous green is worse than a crash.
    ///
    /// The needle sits between the two literals on purpose, so an implementation that swaps the
    /// bounds and answers about the span instead of refusing it fails. Both directions are asked,
    /// so the idiom is shown to discriminate rather than always say no.
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

    /// Ordered positions still answer the text itself, so "return nil always" cannot pass.
    @Test func orderedPositionsAnswerExactlyWhatSitsBetweenThem() throws {
        let body = "opened { the middle } closed"
        let open = try #require(body.range(of: "opened {"))
        let close = try #require(body.range(of: "} closed"))
        #expect(textBetween(body, from: open.upperBound, to: close.lowerBound) == " the middle ",
                "the text between two ordered positions is not what sits there")
    }

    /// Touching positions answer `""`, not nil: call sites read
    /// `.trimmingCharacters(in:).isEmpty == true` as "the guarded line is the first thing in its
    /// branch", and a nil would fail them on correct code.
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

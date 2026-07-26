import Testing
@testable import FileExplorer

/// What VoiceOver reads for a `StatPill`.
///
/// The pill collapses to a single accessibility element, so this one string is the ENTIRE spoken
/// content of the differences header's most important control — there is no second element to
/// correct a wrong one.
@Suite struct StatPillAccessibilityTests {

    @Test func testACountAndLabelWithNoDetailSpeaksJustThat() {
        #expect(StatPill.accessibilityLabel(count: 7, label: "Differences", spokenDetail: nil)
                == "7 Differences")
    }

    @Test func testTheSpokenDetailIsAppendedAfterAComma() {
        #expect(StatPill.accessibilityLabel(count: 576, label: "Differences",
                                            spokenDetail: "scanned 29m ago")
                == "576 Differences, scanned 29m ago")
    }

    /// The regression. The label used to compose the spoken form itself as "scanned \(detail)",
    /// which is right for an age and nonsense for the in-flight state: the differences pill puts
    /// "scanning…" in that slot while a scan runs, so VoiceOver announced
    /// "576 Differences, scanned scanning…". The pill no longer writes the grammar — it is handed
    /// a phrase and reads it — so an in-progress scan can be announced in the present tense.
    @Test func testAnInFlightScanIsNotAnnouncedAsAlreadyScanned() {
        let spoken = StatPill.accessibilityLabel(count: 576, label: "Differences",
                                                 spokenDetail: "scanning for changes")
        #expect(spoken == "576 Differences, scanning for changes")
        #expect(!spoken.contains("scanned"))
    }

    /// Nothing may be glued onto an empty phrase: a trailing ", " reads as a pause before content
    /// that never arrives.
    @Test func testAnEmptySpokenDetailIsDroppedRatherThanPunctuated() {
        #expect(StatPill.accessibilityLabel(count: 3, label: "conflicts", spokenDetail: "")
                == "3 conflicts")
    }

    /// Counts are spoken the way they are shown — through `formatted()`, so the grouping separator
    /// matches the digits on screen. Compared against the formatter rather than a literal: the
    /// separator is locale-dependent and a hardcoded "1,284" would fail off en_US.
    @Test func testTheCountIsSpokenTheWayItIsShown() {
        #expect(StatPill.accessibilityLabel(count: 1284, label: "identical", spokenDetail: nil)
                == "\(1284.formatted()) identical")
    }
}

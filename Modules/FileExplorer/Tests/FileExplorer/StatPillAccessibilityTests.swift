import Testing
@testable import FileExplorer

/// What VoiceOver reads for a `StatPill`. The pill collapses to a single accessibility element, so
/// this one string is all that is spoken for the differences header's most important control, with
/// no second element to correct a wrong one.
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

    /// The pill reads the phrase it is handed and adds no grammar, so a running scan is announced
    /// in the present tense. Prefixing "scanned" itself would suit an age but turn the in-flight
    /// phrase into "576 Differences, scanned scanning…".
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

    /// Counts are spoken the way they are shown, through `formatted()`, so the grouping separator
    /// matches the digits on screen. Compared against the formatter, not a literal, because the
    /// separator depends on the locale.
    @Test func testTheCountIsSpokenTheWayItIsShown() {
        #expect(StatPill.accessibilityLabel(count: 1284, label: "identical", spokenDetail: nil)
                == "\(1284.formatted()) identical")
    }
}

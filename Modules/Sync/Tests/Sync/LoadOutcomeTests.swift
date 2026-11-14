import Testing
@testable import Sync

/// Which pane loads are written at Info. The start line and an ordinary outcome stay Debug, one
/// per navigation; a slow load and one that never reached a known exit are the only record of a
/// pane that hung or came up empty.
@Suite struct LoadOutcomeTests {
    /// A load is reported from two seconds, or with no known ending, or with a stranded spinner.
    @Test(arguments: [
        (0.2, "walked 40 node(s)", false, false),
        (1.99, "walked", false, false),
        (2.0, "walked", false, true),
        (0, LoadOutcome.unknownExit, false, true),
        (0, "cancelled", true, true),
    ])
    func aLoadIsReportedOnlyWhenSlowOrUnended(activeSeconds: Double, outcome: String,
                                              strandedSpinner: Bool, reported: Bool) {
        #expect(LoadOutcome.isWorthReporting(activeSeconds: activeSeconds, outcome: outcome,
                                             strandedSpinner: strandedSpinner) == reported)
    }
}

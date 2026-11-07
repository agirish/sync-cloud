import Testing
@testable import Sync

/// Which pane loads are written at Info. The start line and an ordinary outcome stay Debug, one
/// per navigation; a slow load and one that never reached a known exit are the only record of a
/// pane that hung or came up empty.
@Suite struct LoadOutcomeTests {
    @Test func aQuickLoadWithAKnownEndingStaysDebug() {
        #expect(!LoadOutcome.isWorthReporting(activeSeconds: 0.2, outcome: "walked 40 node(s)", strandedSpinner: false))
    }

    @Test func aSlowLoadIsReportedFromTwoSeconds() {
        #expect(!LoadOutcome.isWorthReporting(activeSeconds: 1.99, outcome: "walked", strandedSpinner: false))
        #expect(LoadOutcome.isWorthReporting(activeSeconds: 2.0, outcome: "walked", strandedSpinner: false))
    }

    @Test func aLoadWithNoKnownEndingOrAStrandedSpinnerIsReported() {
        #expect(LoadOutcome.isWorthReporting(activeSeconds: 0, outcome: LoadOutcome.unknownExit, strandedSpinner: false))
        #expect(LoadOutcome.isWorthReporting(activeSeconds: 0, outcome: "cancelled", strandedSpinner: true))
    }
}

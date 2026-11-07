import Testing
import AppKit
@testable import FileExplorer

@Suite struct CountPillChevronTests {

    @Test func testNoChevronBeforeAScanHasRun() {
        // Before a scan the pill does nothing, so no chevron may invite a click, whatever the
        // stale expansion state.
        #expect(CountPillChevron.symbol(hasScanned: false, expanded: false) == nil)
        #expect(CountPillChevron.symbol(hasScanned: false, expanded: true) == nil)
    }

    @Test func testChevronPointsTheWayTheTotalsWillGo() {
        // The per-side totals expand to the right of the pill and collapse back left, so the
        // chevron points the way the next click moves them.
        #expect(CountPillChevron.symbol(hasScanned: true, expanded: false) == "chevron.right")
        #expect(CountPillChevron.symbol(hasScanned: true, expanded: true) == "chevron.left")
        // A typo'd symbol name renders as a blank icon at runtime; pin that every name resolves.
        for symbol in ["chevron.right", "chevron.left"] {
            #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil,
                    "missing SF Symbol \(symbol)")
        }
    }
}

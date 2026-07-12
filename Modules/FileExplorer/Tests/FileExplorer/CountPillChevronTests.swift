import Testing
import AppKit
@testable import FileExplorer

@Suite struct CountPillChevronTests {

    @Test func testNoChevronBeforeAScanHasRun() {
        // Pre-scan the pill is a dead control (clicking does nothing), so no chevron may
        // invite a click — regardless of any stale expansion state.
        #expect(CountPillChevron.symbol(hasScanned: false, expanded: false) == nil)
        #expect(CountPillChevron.symbol(hasScanned: false, expanded: true) == nil)
    }

    @Test func testChevronPointsTheWayTheTotalsWillGo() {
        // The per-side totals expand inline to the RIGHT of the pill and collapse back LEFT,
        // so the affordance mirrors the motion of the next click: right when collapsed
        // (clicking expands rightward), left when expanded (clicking collapses leftward).
        #expect(CountPillChevron.symbol(hasScanned: true, expanded: false) == "chevron.right")
        #expect(CountPillChevron.symbol(hasScanned: true, expanded: true) == "chevron.left")
    }

    @Test func testChevronSymbolsExistInSFSymbols() throws {
        // A typo'd symbol name renders as a blank icon at runtime; pin that every name resolves.
        for expanded in [false, true] {
            let symbol = try #require(CountPillChevron.symbol(hasScanned: true, expanded: expanded))
            #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil,
                    "missing SF Symbol \(symbol)")
        }
    }
}

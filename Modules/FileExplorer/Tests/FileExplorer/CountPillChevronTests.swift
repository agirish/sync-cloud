import Testing
import AppKit
@testable import FileExplorer

@Suite struct CountPillChevronTests {

    @Test func testChevronPointsTheWayTheTotalsWillGo() {
        // The per-side totals expand inline to the RIGHT of the pill and collapse back LEFT,
        // so the affordance mirrors the motion of the next click: right when collapsed
        // (clicking expands rightward), left when expanded (clicking collapses leftward).
        #expect(CountPillChevron.symbol(expanded: false) == "chevron.right")
        #expect(CountPillChevron.symbol(expanded: true) == "chevron.left")
    }

    @Test func testChevronSymbolsExistInSFSymbols() {
        // A typo'd symbol name renders as a blank icon at runtime; pin that every name resolves.
        for expanded in [false, true] {
            let symbol = CountPillChevron.symbol(expanded: expanded)
            #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil,
                    "missing SF Symbol \(symbol)")
        }
    }
}

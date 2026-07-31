import Testing
@testable import Dashboard

/// What a drop onto the customize sheet's track actually does to the arrangement.
///
/// The gestures need a real event loop, so the sheet's drag behaviour is only ever verifiable by
/// hand — which is precisely why the arithmetic and the parsing underneath them do not live in the
/// sheet. Everything the user can express with a drag funnels through these two functions, so an
/// off-by-one or a mis-parsed payload here is a wrong bar, silently, on a path nothing else covers.
@Suite struct PaneBarDropTests {

    private let bar = PaneBarArrangement([.backForward, .scan, .sort])

    // MARK: Payload round-trip

    @Test func testThePayloadsTheSheetHandsOutAreTheOnesItAcceptsBack() {
        // The two ends are written in different places — `.draggable(...)` on the pill, the parser
        // here — and a drag that produces a string the parser shrugs at fails silently and looks
        // exactly like "drag and drop doesn't work on this Mac".
        #expect(PaneBarDrop.applying([PaneBarDrop.payload(forItemAt: 2)], at: 0, to: bar)?.items
                == [.sort, .backForward, .scan])
        #expect(PaneBarDrop.applying([PaneBarDrop.payload(for: .hiddenFiles)], at: 1, to: bar)?.items
                == [.backForward, .hiddenFiles, .scan, .sort])
    }

    // MARK: Moving within the bar

    @Test func testMovingAnItemLandsItInTheAimedSlot() {
        #expect(PaneBarDrop.applying(["bar:0"], at: 3, to: bar)?.items == [.scan, .sort, .backForward])
    }

    @Test func testADropOnAnItemsOwnSlotsChangesNothing() {
        // Both slots that border an item are no-ops for it. Reporting success for these would make
        // the pill animate into place over a bar that never moved.
        #expect(PaneBarDrop.applying(["bar:1"], at: 1, to: bar) == nil)
        #expect(PaneBarDrop.applying(["bar:1"], at: 2, to: bar) == nil)
    }

    @Test func testAStaleIndexIsRefusedRatherThanClamped() {
        // The bar can change under a drag in flight — the other pane's header renders the same
        // arrangement, and both are live. Clamping `bar:99` to the end would silently move whatever
        // item happens to sit last; the drag is stale, so the answer is no.
        #expect(PaneBarDrop.applying(["bar:99"], at: 0, to: bar) == nil)
        #expect(PaneBarDrop.applying(["bar:-1"], at: 0, to: bar) == nil)
    }

    // MARK: Adding from the palette

    @Test func testAPaletteItemAlreadyOnTheBarMovesInsteadOfDuplicating() {
        #expect(PaneBarDrop.applying(["palette:sort"], at: 0, to: bar)?.items
                == [.sort, .backForward, .scan])
    }

    @Test func testSpacersCanBeAddedRepeatedly() throws {
        // `#require`, not `!`. A force-unwrap here would take the whole test *host* down the day this
        // regressed, turning one red assertion into a run with no results at all.
        let once = try #require(PaneBarDrop.applying(["palette:flexibleSpace"], at: 0, to: bar))
        #expect(once.items == [.flexibleSpace, .backForward, .scan, .sort])
        let twice = PaneBarDrop.applying(["palette:flexibleSpace"], at: 4, to: once)
        #expect(twice?.items == [.flexibleSpace, .backForward, .scan, .sort, .flexibleSpace])
    }

    // MARK: Refusals

    @Test(arguments: ["", "sort", "bar:", "bar:two", "bar: 1", "palette:", "palette:teleport", "BAR:0"])
    func testAMalformedPayloadIsRefusedRatherThanGuessedAt(payload: String) {
        #expect(PaneBarDrop.applying([payload], at: 0, to: bar) == nil)
        #expect(PaneBarDrop.removing([payload], from: bar) == nil)
    }

    @Test func testAnEmptyDropIsRefused() {
        #expect(PaneBarDrop.applying([], at: 0, to: bar) == nil)
        #expect(PaneBarDrop.removing([], from: bar) == nil)
    }

    // MARK: Dragging off the bar

    @Test func testDraggingAnItemOffTheBarRemovesIt() {
        #expect(PaneBarDrop.removing(["bar:2"], from: bar)?.items == [.backForward, .scan])
    }

    @Test func testDraggingScanOffTheBarIsRefused() {
        // Not merely ignored — refused, so the pill springs back. Appearing to accept a removal that
        // did not happen is worse than declining it.
        #expect(PaneBarDrop.removing(["bar:1"], from: bar) == nil)
    }

    @Test func testOnlyBarPayloadsCanRemove() {
        // A palette tile dropped back onto the palette must not remove whatever sits at that index.
        #expect(PaneBarDrop.removing(["palette:sort"], from: bar) == nil)
    }

    @Test func testRemovingAStaleIndexIsRefused() {
        #expect(PaneBarDrop.removing(["bar:9"], from: bar) == nil)
    }
}

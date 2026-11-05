import Testing
@testable import Dashboard

/// What a drop onto the customize sheet's track does to the arrangement. The gestures need a real
/// event loop and can only be checked by hand, so their arithmetic and parsing live outside the
/// sheet. Every drag funnels through these two functions, so an off-by-one or a mis-parsed payload
/// here silently makes a wrong bar on a path nothing else covers.
@Suite struct PaneBarDropTests {

    private let bar = PaneBarArrangement([.backForward, .scan, .sort])

    // MARK: Payload round-trip

    @Test func testThePayloadsTheSheetHandsOutAreTheOnesItAcceptsBack() {
        // The two ends live in different places (`.draggable(...)` on the pill, the parser here),
        // and a string the parser rejects fails silently, like drag and drop not working at all.
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
        // Both slots that border an item are no-ops for it. Reporting success would animate the
        // pill into place over a bar that never moved.
        #expect(PaneBarDrop.applying(["bar:1"], at: 1, to: bar) == nil)
        #expect(PaneBarDrop.applying(["bar:1"], at: 2, to: bar) == nil)
    }

    @Test func testAStaleIndexIsRefusedRatherThanClamped() {
        // The bar can change under a drag in flight, since the other pane's header renders the
        // same live arrangement. Clamping `bar:99` would silently move whatever sits last.
        #expect(PaneBarDrop.applying(["bar:99"], at: 0, to: bar) == nil)
        #expect(PaneBarDrop.applying(["bar:-1"], at: 0, to: bar) == nil)
    }

    // MARK: Adding from the palette

    @Test func testAPaletteItemAlreadyOnTheBarMovesInsteadOfDuplicating() {
        #expect(PaneBarDrop.applying(["palette:sort"], at: 0, to: bar)?.items
                == [.sort, .backForward, .scan])
    }

    @Test func testSpacersCanBeAddedRepeatedly() throws {
        // `#require`, not `!`: a failed force-unwrap would take down the whole test host, leaving a
        // run with no results instead of one red assertion.
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
        // Refused, not ignored, so the pill springs back instead of seeming to accept a removal
        // that didn't happen.
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

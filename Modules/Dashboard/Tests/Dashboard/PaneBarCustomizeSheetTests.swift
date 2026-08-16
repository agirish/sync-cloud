import AppKit
import SwiftUI
import Testing
@testable import Dashboard

/// The customize sheet, as far as a test host can see it: that it lays out at all, and that every
/// palette tile it offers is an item the bar can actually place.
///
/// Deliberately not a click-through: the drag gestures and the drop targets need a real event loop,
/// and a test that pretended otherwise would be the kind of false green this suite exists to avoid.
/// What is checked here is the part that can be: composition and geometry.
@MainActor
@Suite(.serialized) struct PaneBarCustomizeSheetTests {

    /// Renders the sheet against an injected defaults domain.
    ///
    /// Without this the sheet's `@AppStorage` reads `UserDefaults.standard` — i.e. **the arrangement
    /// on the machine running the tests**. A developer who had customized their own bar would render
    /// a different sheet from CI's, and the height assertion below would be a coin flip on their
    /// machine. Same reason `DashboardSnapshotTests` injects the preview setting.
    private func laidOut(_ view: some View) -> CGSize {
        let defaults = ScratchDefaults("PaneBarCustomizeSheetTests-layout")
        defaults.set(PaneBarArrangement.default.encoded, forKey: PaneBar.arrangementKey)
        let host = NSHostingView(rootView: AnyView(view.defaultAppStorage(defaults)))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 800),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    @Test func testItemsTheEditingPaneCannotDrawAreStillOfferedButMarked() {
        // Collapse Pane is in the DEFAULT arrangement and only the single-source rail draws it, so a Compare
        // pane's sheet necessarily shows a pill its own bar does not have. That is honest — the
        // arrangement is shared — but it has to be visibly explained rather than looking like a bug
        // in the sheet.
        let comparePane = PaneBarCustomizeSheet(
            availableHere: [.viewMode, .backForward, .scan, .newFolder, .sort, .hiddenFiles])
        #expect(comparePane.explainsItemsFromElsewhere,
                "a pane that cannot draw Collapse or Preview showed no explanation for them")

        let everything = PaneBarCustomizeSheet(availableHere: Set(PaneBarItem.allCases))
        #expect(!everything.explainsItemsFromElsewhere,
                "a pane that can draw everything still spent space explaining nothing")
    }

    @Test func testTheSheetLaysOutAtAWorkableSize() {
        let size = laidOut(PaneBarCustomizeSheet())
        // 600 is not a taste call: it was the window's own `minWidth` when this was chosen, so
        // anything wider was a sheet wider than the window it belongs to at the size a user could
        // actually drag theirs down to. The window floor is 760 now, which only widens the margin —
        // the number stays because the track's metrics were tightened around it.
        // (The `<= 600` restatement that sat here was noise — it cannot fail while the line above
        // passes. One assertion, and the reason for the number in prose beside it.)
        #expect(size.width == 600, "the sheet should hold its declared width, got \(size.width)")
        // Tall enough to be a real sheet, short enough not to run off a laptop screen.
        #expect(size.height > 300 && size.height < 760, "sheet height \(size.height) is out of range")
    }

    @Test func testEveryPaletteItemIsSomethingTheBarCanPlace() {
        // A tile for an item the bar cannot draw would be a dead affordance: you would drag it on and
        // nothing would appear.
        let palette = PaneBarCustomizeSheet.palette
        #expect(Set(palette).count == palette.count, "the palette repeats an item")
        for item in palette {
            #expect(PaneBarItem.allCases.contains(item))
        }
    }

    @Test func testThePaletteOffersEveryRemovableControl() {
        // The other direction, and the one that rots: add a control to the bar, forget the tile, and
        // anyone who removes it can never put it back.
        for item in PaneBarItem.allCases where !item.isSpacer {
            #expect(PaneBarCustomizeSheet.palette.contains(item),
                    "\(item.displayName) can be on the bar but has no palette tile")
        }
    }

    @Test func testEveryPaletteGlyphIsARealSFSymbol() {
        // A typo'd symbol name doesn't fail anywhere — it draws nothing, and the tile becomes a
        // labelled blank. `PaneGlyphTests` pins the pane's other glyphs for exactly this reason.
        for item in PaneBarItem.allCases {
            #expect(NSImage(systemSymbolName: item.paletteSymbol, accessibilityDescription: nil) != nil,
                    "\(item.displayName) names a symbol that does not exist: \(item.paletteSymbol)")
        }
    }

    @Test func testScanIsOfferedButInert() {
        // Present so its absence from the removable set is explained, rather than leaving someone
        // hunting for a control that was never offered.
        #expect(PaneBarCustomizeSheet.palette.contains(.scan))
        #expect(!PaneBarItem.scan.isRemovable)
    }

    // MARK: Can you actually aim at it

    /// Right-clicks the centre of one track pill and reports the menu that came back, if any.
    ///
    /// This is the one interaction in this sheet a test *can* drive. The header note above is still
    /// right that the drags need a live event loop — but a context menu does not: SwiftUI answers
    /// `NSView.menu(for:)` on the hosting view, and it answers it by hit-testing the point. So the
    /// menu is a direct readout of whether the pill is aimable, which is the thing that was broken.
    /// A pill drawn as an unfilled outline is hit-testable only along the outline itself.
    private func menuAtCentre(of item: PaneBarItem) -> NSMenu? {
        let defaults = ScratchDefaults("PaneBarCustomizeSheetTests-aim")
        defaults.set(PaneBarArrangement([.space, .scan, .flexibleSpace, .sort]).encoded,
                     forKey: PaneBar.arrangementKey)
        let sheet = PaneBarCustomizeSheet()
        let host = NSHostingView(rootView: AnyView(sheet.trackItem(item, at: 0)
                                                       .defaultAppStorage(defaults)))
        // Borderless, and never ordered in. A `.titled` window cannot be parked off screen —
        // `constrainFrameRect` drags it back onto his desktop, over whatever he is doing.
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 80),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()

        let centre = CGPoint(x: host.bounds.midX, y: host.bounds.midY)
        guard let event = NSEvent.mouseEvent(with: .rightMouseDown,
                                             location: host.convert(centre, to: nil),
                                             modifierFlags: [],
                                             timestamp: 0,
                                             windowNumber: window.windowNumber,
                                             context: nil,
                                             eventNumber: 0,
                                             clickCount: 1,
                                             pressure: 1) else {
            Issue.record("could not synthesize a right-click")
            return nil
        }
        return host.menu(for: event)
    }

    @Test func theSpaceOnTheTrackCanBeAimedAt() {
        // The bug this is here for: a fixed space could be added to the bar and never taken off.
        // Its pill is a dashed outline around an empty fill, so the drag, the drop and the context
        // menu were all attached to a 1pt ring, and every click in the middle of it went through to
        // the track behind. Nothing else in the sheet reaches a space — it has no palette check to
        // click off, and Restore is all-or-nothing.
        //
        // Both spacers, because only one of them was broken and the difference was an accident of
        // fill opacity, not a decision anyone made.
        for spacer in [PaneBarItem.space, .flexibleSpace] {
            let titles = menuAtCentre(of: spacer)?.items.map(\.title) ?? []
            #expect(titles.contains("Remove"),
                    "right-clicking the centre of \(spacer.displayName) offered \(titles); with no Remove there is no way to take it off the bar")
        }
    }

    @Test func soCanAControl() {
        // The control pills were never broken — they are drawn on a filled capsule. Here so that a
        // failure above is read as "the space is unaimable" rather than "the probe measures nothing",
        // which is the failure mode that would let the test pass while proving nothing.
        let titles = menuAtCentre(of: .sort)?.items.map(\.title) ?? []
        #expect(titles.contains("Remove"), "a control pill offered \(titles)")
    }
}

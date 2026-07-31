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

    private func laidOut(_ view: some View) -> CGSize {
        let host = NSHostingView(rootView: AnyView(view))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 800),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    @Test func testTheSheetLaysOutAtAWorkableSize() {
        let size = laidOut(PaneBarCustomizeSheet())
        #expect(size.width == 560, "the sheet should hold its declared width, got \(size.width)")
        // Tall enough to be a real sheet, short enough not to run off a laptop screen.
        #expect(size.height > 240 && size.height < 700, "sheet height \(size.height) is out of range")
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
}

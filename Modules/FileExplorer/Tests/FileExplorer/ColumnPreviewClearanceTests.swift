import AppKit
import Design
import SwiftUI
import Sync
import Testing
import UniformTypeIdentifiers
@testable import FileExplorer

/// The preview column holds a band clear at its bottom for the pane's action bar.
///
/// The bar is an overlay across the whole pane, so on a comparison pane it lands on top of this
/// column — and always, not occasionally: the preview requires exactly one selected file, which is
/// exactly the state that raises the bar. Measured in a 940pt pane, the bar spans x 10…930 while the
/// preview holds x 438…940, so it covers 492 of the preview's 502 points over the bottom band, which
/// is where the identity rows live. The bar's ✕ clears the selection, which dismisses the preview
/// too, so there is no way to read those rows while the preview is up.
///
/// Two halves, because the fix is a constant plus a wiring, and either can rot on its own.
@MainActor
@Suite(.serialized) struct ColumnPreviewClearanceTests {

    /// A path that need not exist: the probe classifies a missing file as `.missing`, which renders
    /// the icon placeholder instead of mounting Quick Look. That is the point — this suite measures
    /// where the IDENTITY rows land, and a real Quick Look mount would put an unpredictable
    /// extension-drawn image in the frame above them.
    private static let item = ColumnPreviewItem(
        row: PaneRow(side: .left, version: 1,
                     node: FileNode(id: "/tmp/ColumnPreviewClearance/note.txt", name: "note.txt",
                                    isDirectory: false, fileSize: 5,
                                    kind: UTType.plainText.identifier),
                     children: nil))

    /// The constant is big enough for the bar it is reserving for — asserted against the bar's own
    /// laid-out height, not against another constant.
    ///
    /// `+ 20` is the padding ContentView puts around the bar inside the overlay (`.padding(10)`), so
    /// this compares the whole band the bar occupies. Without this test `actionBarClearance` is a
    /// magic number that a wider bar — one more button, a larger text size — would silently outgrow,
    /// and the symptom would be the same hidden metadata rows this suite exists to prevent.
    @Test func theClearanceCoversTheBarsRealHeight() {
        let bar = PaneActionBar(
            summaryText: "1 selected · 307 KB",
            showsCompare: true,
            copyTitle: "Copy to Dropbox", moveTitle: "Move to Dropbox",
            copySymbol: TransferGlyph.copy, moveSymbol: TransferGlyph.move(toRight: true),
            transferHelp: "Puts each item where its counterpart belongs",
            onCompare: {}, onCopy: {}, onMove: {}, onDelete: {}, onClear: {})

        let host = NSHostingView(rootView: AnyView(bar.frame(width: 920)))
        host.frame = CGRect(x: 0, y: 0, width: 920, height: 400)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()

        let band = host.fittingSize.height + 20
        #expect(band <= ColumnPreviewColumn.actionBarClearance,
                "the bar now occupies \(band)pt; raise actionBarClearance to match")
        withExtendedLifetime(window) {}
    }

    /// And the clearance reaches the rendered column: with it, the painted content stops higher up
    /// the column than it does without.
    ///
    /// Read off the PIXELS rather than a frame, because what has to move is the identity block, and
    /// SwiftUI `Text` puts no view in the AppKit tree to measure — the same reason the header's
    /// control count is taken from `_FocusRingView`. The assertion is the DIFFERENCE between two
    /// renders: an absolute "last painted row" would depend on the font, the icon and the date
    /// format, none of which this fix is about.
    @Test func theClearanceLiftsThePaintedContent() throws {
        let plain = try lastPaintedRow(clearance: 0)
        let reserved = try lastPaintedRow(clearance: ColumnPreviewColumn.actionBarClearance)
        // Ink stops higher when the band is held clear. Compared with a tolerance because glyph
        // antialiasing can put a stray sub-pixel row either side of the exact inset.
        let lifted = plain - reserved
        #expect(abs(lifted - ColumnPreviewColumn.actionBarClearance) <= 2,
                "expected the content to lift by \(ColumnPreviewColumn.actionBarClearance)pt, lifted \(lifted)")
        // Non-vacuous: something was actually painted in both, so this is not two blank renders
        // agreeing with each other.
        #expect(plain > 0)
        #expect(reserved > 0)
    }

    /// The y of the lowest row holding any non-background pixel, in points from the top.
    func lastPaintedRow(clearance: CGFloat) throws -> CGFloat {
        let size = CGSize(width: 500, height: 600)
        let subject = ColumnPreviewColumn(item: Self.item, actionBarClearance: clearance)
            .frame(width: size.width, height: size.height)
            .background(Color.white)
            .environment(\.colorScheme, .light)

        let host = NSHostingView(rootView: AnyView(subject))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.colorSpace = NSColorSpace.sRGB
        window.contentView = host
        host.layoutSubtreeIfNeeded()

        // A real window, or the layer never gets a backing store and every render comes back blank —
        // which would make this comparison pass vacuously (`PaneActionBarStabilityTests` documents
        // the same trap).
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)

        let lowest = lowestPaintedRow(in: rep, pointHeight: size.height)
        withExtendedLifetime(window) {}
        return lowest
    }
}

/// The y of the lowest row holding ink, in points from the top, optionally restricted to a band of
/// columns. Shared with `ColumnPreviewLayoutTests`, which asks the same question of a whole mounted
/// pane rather than of the preview column alone.
///
/// Returns 0 when nothing is painted, which callers must treat as a failure rather than a position —
/// an all-blank render is the vacuous pass this kind of measurement invites.
@MainActor
func lowestPaintedRow(in rep: NSBitmapImageRep, pointHeight: CGFloat,
                      pointXRange: Range<CGFloat>? = nil) -> CGFloat {
    // One backing scale for both axes, taken from the axis whose point size the caller knows.
    let scale = CGFloat(rep.pixelsHigh) / pointHeight
    let xLower = pointXRange.map { max(0, Int($0.lowerBound * scale)) } ?? 0
    let xUpper = pointXRange.map { min(rep.pixelsWide, Int($0.upperBound * scale)) } ?? rep.pixelsWide
    guard xUpper > xLower else { return 0 }
    for y in stride(from: rep.pixelsHigh - 1, through: 0, by: -1) {
        for x in stride(from: xLower, to: xUpper, by: 2) {
            guard let colour = rep.colorAt(x: x, y: y) else { continue }
            // Anything meaningfully off the white ground counts as ink.
            if colour.redComponent < 0.92 || colour.greenComponent < 0.92 || colour.blueComponent < 0.92 {
                return CGFloat(y) * pointHeight / CGFloat(rep.pixelsHigh)
            }
        }
    }
    return 0
}

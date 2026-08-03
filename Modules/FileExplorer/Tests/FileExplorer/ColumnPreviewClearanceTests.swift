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
@Suite(.serialized, .machinePinned(.pixelSampling)) struct ColumnPreviewClearanceTests {

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

    /// The padding ContentView puts around the bar inside the overlay (`.padding(10)`).
    static let overlayPadding: CGFloat = 10

    /// The constant is big enough for the bar it is reserving for — asserted against the bar's own
    /// laid-out height, not against another constant.
    ///
    /// Twice the overlay padding here, because this compares the whole band the overlay occupies.
    /// Without this test `actionBarClearance` is a magic number that a wider bar — one more button, a
    /// larger text size — would silently outgrow, and the symptom would be the same hidden metadata
    /// rows this suite exists to prevent.
    @Test func theClearanceCoversTheBarsRealHeight() throws {
        let band = try barHeight() + 2 * Self.overlayPadding
        #expect(band <= ColumnPreviewColumn.actionBarClearance,
                "the bar now occupies \(band)pt; raise actionBarClearance to match")
    }

    /// The real bar's laid-out height at a comparison pane's width.
    private func barHeight() throws -> CGFloat {
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
        defer { withExtendedLifetime(window) {} }
        return host.fittingSize.height
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
        // `try #require` rather than a `> 0` check: nothing painted is now `nil`, so a blank render
        // fails here instead of arriving as a plausible-looking 0.
        let plain = try #require(lastPaintedRow(clearance: 0))
        let reserved = try #require(lastPaintedRow(clearance: ColumnPreviewColumn.actionBarClearance))
        // Ink stops higher when the band is held clear. Compared with a tolerance because glyph
        // antialiasing can put a stray sub-pixel row either side of the exact inset.
        let lifted = plain - reserved
        #expect(abs(lifted - ColumnPreviewColumn.actionBarClearance) <= 2,
                "expected the content to lift by \(ColumnPreviewColumn.actionBarClearance)pt, lifted \(lifted)")
    }

    /// The reservation is ENOUGH, not merely applied: the identity ink ends above the bar's painted
    /// top edge.
    ///
    /// Measured against the bar's own laid-out height, and deliberately NOT against
    /// `height - actionBarClearance`. That was this test's first form and it is a tautology: the ink
    /// bottom moves up by exactly the clearance, and so does that limit, so it holds for a clearance
    /// of 72, 20 or 0 alike — it would have passed a reservation far too small to clear anything. The
    /// bar's edge is fixed in the pane whatever this column reserves, which is what makes it the
    /// thing worth comparing to.
    ///
    /// `+ overlayPadding` once, not twice: the band from the pane's bottom to the bar's TOP is the
    /// bar plus the padding beneath it. The padding above the bar is outside what has to be cleared.
    @Test(arguments: [CGFloat(600), CGFloat(400), CGFloat(240), CGFloat(200)])
    func theIdentityClearsTheBarsPaintedEdge(height: CGFloat) throws {
        let barTopFromBottom = try barHeight() + Self.overlayPadding
        let ink = try #require(inkBounds(clearance: ColumnPreviewColumn.actionBarClearance,
                                         height: height))
        #expect(ink.bottom <= height - barTopFromBottom,
                "identity ink at \(ink.bottom) reaches under the bar (top at \(height - barTopFromBottom)) in a \(height)pt column")
        // Non-vacuous: a blank render fails `#require`, and a full-bleed one puts ink on the last row,
        // which the expectation above rejects.
        #expect(ink.top < ink.bottom)
    }

    /// Below the floor the column gives up the ICON, not the identity rows.
    ///
    /// The reservation is a fixed 72pt while the column's height is not, so past some height the
    /// content genuinely does not fit and something has to lose. Measured against the bar's painted
    /// edge, the identity clears it down to a ~190pt column; below that the squeeze starts eating
    /// into it (3pt at 180). Ink starts running off the TOP at 210 — with no clearance at all that
    /// overflow starts at 140, so reserving the band brings it on ~70pt earlier. That is the honest
    /// cost of the fix, and it is the right way round: the Quick Look area is a scaled image and the
    /// placeholder a 96pt icon, both of which survive cropping, while the identity rows are the text
    /// the bar was hiding in the first place. A version that squeezed the bottom instead would have
    /// moved the bug rather than fixed it.
    ///
    /// So this pins the SHAPE of the degradation rather than the exact overlap: the ink runs off the
    /// top, and the identity still ends inside the column's own 16pt padding. Not the precise
    /// intrusion, which is a number with no meaning to defend. A 180pt preview column is a degenerate
    /// size — the icon alone is 96pt — reachable only by shrinking the window to near nothing.
    @Test(arguments: [CGFloat(180), CGFloat(170)])
    func aColumnTooShortToHoldTheReservationCropsTheIconFirst(height: CGFloat) throws {
        let ink = try #require(inkBounds(clearance: ColumnPreviewColumn.actionBarClearance,
                                         height: height))
        #expect(ink.top == 0, "the icon should be what runs off the top, ink starts at \(ink.top)")
        #expect(ink.bottom < height - 16,
                "the identity rows must stay inside the column's padding, ink ends at \(ink.bottom)")
    }

    /// The y of the lowest row holding any non-background pixel, in points from the top.
    func lastPaintedRow(clearance: CGFloat, height: CGFloat = 600) -> CGFloat? {
        inkBounds(clearance: clearance, height: height)?.bottom
    }

    /// Both edges of the rendered column's ink, in points from the top.
    ///
    /// A real window, or the layer never gets a backing store and every render comes back blank —
    /// which would make these comparisons pass vacuously (`PaneActionBarStabilityTests` documents the
    /// same trap). `nil` for a blank render, so a caller's `#require` catches it rather than a zero
    /// arriving as a plausible position.
    func inkBounds(clearance: CGFloat, height: CGFloat) -> (top: CGFloat, bottom: CGFloat)? {
        let size = CGSize(width: 500, height: height)
        let subject = ColumnPreviewColumn(item: Self.item, actionBarClearance: clearance,
                                          paneToken: .left)
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
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        defer { withExtendedLifetime(window) {} }
        guard let top = PaintedInk.highestRow(in: rep, pointHeight: size.height),
              let bottom = PaintedInk.lowestRow(in: rep, pointHeight: size.height)
        else { return nil }
        return (top, bottom)
    }
}

/// Reading ink out of a rendered bitmap. Namespaced rather than free functions: this is a test target
/// of 80-odd suites, and `lowestPaintedRow` is a name another one could plausibly want.
@MainActor
enum PaintedInk {

    /// The y of the lowest row holding ink, in points from the top, optionally restricted to a band of
    /// columns. Shared by `ColumnPreviewClearanceTests` and `ColumnPreviewLayoutTests`, which ask the
    /// same question of the preview column alone and of a whole mounted pane.
    ///
    /// `nil` means nothing was painted — NOT a position. An earlier version returned 0 for that and
    /// told callers to treat 0 as failure, which is a claim the return type could not keep: ink
    /// genuinely sitting on row 0 returns 0 too, and that is exactly what a short column does when its
    /// content overflows the top. An all-blank render is the vacuous pass this kind of measurement
    /// invites, so the two cases must not share a value.
    static func lowestRow(in rep: NSBitmapImageRep, pointHeight: CGFloat,
                          pointXRange: Range<CGFloat>? = nil) -> CGFloat? {
        // One backing scale for both axes, taken from the axis whose point size the caller knows.
        let scale = CGFloat(rep.pixelsHigh) / pointHeight
        let xLower = pointXRange.map { max(0, Int($0.lowerBound * scale)) } ?? 0
        let xUpper = pointXRange.map { min(rep.pixelsWide, Int($0.upperBound * scale)) } ?? rep.pixelsWide
        guard xUpper > xLower else { return nil }
        for y in stride(from: rep.pixelsHigh - 1, through: 0, by: -1) {
            for x in stride(from: xLower, to: xUpper, by: 2) {
                guard let colour = rep.colorAt(x: x, y: y) else { continue }
                // Anything meaningfully off the white ground counts as ink.
                if colour.redComponent < 0.92 || colour.greenComponent < 0.92 || colour.blueComponent < 0.92 {
                    return CGFloat(y) * pointHeight / CGFloat(rep.pixelsHigh)
                }
            }
        }
        return nil
    }

    /// The y of the HIGHEST row holding ink. Row 0 means the content is running off the top of its
    /// frame, which is how a preview column too short to hold its reservation degrades.
    static func highestRow(in rep: NSBitmapImageRep, pointHeight: CGFloat) -> CGFloat? {
        for y in 0..<rep.pixelsHigh {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                guard let colour = rep.colorAt(x: x, y: y) else { continue }
                if colour.redComponent < 0.92 || colour.greenComponent < 0.92 || colour.blueComponent < 0.92 {
                    return CGFloat(y) * pointHeight / CGFloat(rep.pixelsHigh)
                }
            }
        }
        return nil
    }
}

import AppKit
import Design
import SwiftUI
import Testing
@testable import SyncCloud

/// The setup card's three rows begin and end on one vertical line.
///
/// **Measured off a rendered bitmap, because this is a defect no layout assertion can see.** The
/// crumb strip, the screen's own heading and the footer's first control each sat behind their own
/// `padding`, and two of those numbers were 14 while the third was 22 — a card whose chrome hugged
/// its edges more tightly than its content did. Nothing failed: every view was correct in
/// isolation, and the only thing that was wrong was where they landed relative to each other.
///
/// So the check is the pixels. Each band of the card is scanned for its first and last column of
/// ink, rows that span the whole width (dividers, fills) are skipped, and the three bands must
/// agree.
@MainActor
@Suite struct SetupCardAlignmentTests {

    /// The card at its own size, with no surface behind it so ink is the only thing with alpha.
    private func render(width: CGFloat = SetupSheetMetrics.cardWidth,
                        height: CGFloat = SetupSheetMetrics.cardHeight) throws -> Ink {
        let card = SetupScreenCard(
            crumbs: SetupFlow.crumbs,
            current: .locations,
            fontSize: .constant(.medium),
            tint: .blue,
            onBack: {},
            primaryTitle: "Continue",
            onPrimary: {},
            onDismiss: {}) {
                SetupHeading(title: "SyncCloud found nine locations on this Mac",
                             blurb: "Switch off any you don't use.")
            }
        let host = NSHostingView(rootView: card.frame(width: width, height: height))
        host.frame = CGRect(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds),
                               "the card would not render — every measurement below is vacuous")
        host.cacheDisplay(in: host.bounds, to: rep)
        return Ink(rep: rep)
    }

    /// Where a rendered view has ink, row by row.
    struct Ink {
        let rep: NSBitmapImageRep
        var threshold: CGFloat = 0.35

        /// Each pixel's alpha as `colorAt` reports it, asked once per distinct pixel value
        /// (`PixelMemo`) rather than of every pixel of every scanned row, on the main actor.
        private let alpha: PixelMemo<CGFloat?>

        init(rep: NSBitmapImageRep) {
            self.rep = rep
            alpha = PixelMemo(rep) { $0?.alphaComponent }
        }

        /// `(first, last)` ink column for one row, or nil for a row with no ink — or one that is a
        /// divider.
        ///
        /// **A divider is told by how much of the row it inks, not by how far apart its ends are.**
        /// The first spelling of this rejected any row whose ink spanned most of the width, which
        /// is exactly what a row holding the crumb strip *and* the ✕ looks like — so it threw away
        /// every row the test exists to measure and reported the leftovers.
        func columns(row y: Int) -> (first: Int, last: Int)? {
            var first: Int?, last: Int?
            var inked = 0
            for x in 0..<rep.pixelsWide {
                guard let level = alpha(x, y), level > threshold else { continue }
                if first == nil { first = x }
                last = x
                inked += 1
            }
            guard let first, let last else { return nil }
            guard Double(inked) < Double(rep.pixelsWide) * 0.6 else { return nil }
            return (first, last)
        }

        /// Runs of ink in one row, split wherever there is a clear gap of `gap` pixels — Back, the
        /// lock line and the buttons, as three groups.
        func clusters(row y: Int, gap: Int) -> [(first: Int, last: Int)] {
            var out: [(first: Int, last: Int)] = []
            var start: Int?
            var lastInk: Int?
            for x in 0..<rep.pixelsWide {
                let inked = (alpha(x, y) ?? 0) > threshold
                if inked {
                    if start == nil { start = x }
                    lastInk = x
                } else if let s = start, let l = lastInk, x - l > gap {
                    out.append((s, l))
                    start = nil
                    lastInk = nil
                }
            }
            if let s = start, let l = lastInk { out.append((s, l)) }
            return out
        }

        /// The leftmost and rightmost ink across a band of rows.
        func bounds(rows: Range<Int>) -> (first: Int, last: Int)? {
            var first = Int.max, last = Int.min
            for y in rows {
                guard let c = columns(row: y) else { continue }
                first = Swift.min(first, c.first)
                last = Swift.max(last, c.last)
            }
            return first <= last ? (first, last) : nil
        }
    }

    /// The card's own scale: `bitmapImageRepForCachingDisplay` renders at the backing scale, so a
    /// point is two pixels on this Mac and one on a non-Retina display. Every number below is in
    /// pixels, so the inset is converted rather than assumed.
    private func scale(_ ink: Ink, width: CGFloat) -> CGFloat {
        CGFloat(ink.rep.pixelsWide) / width
    }

    /// The two kinds of thing that begin at the card's inset, each measured for what it is.
    ///
    /// **Text against text, bezel against bezel.** A bordered button's *label* never lands where a
    /// paragraph does — its bezel does, and the label sits inside that — so one threshold cannot
    /// ask both questions. At 0.35 only glyphs survive, which is the crumb strip against the
    /// heading; at 0.05 the translucent bezels appear, which is the Back button against the card.
    @Test func theChromeAndTheContentBeginOnOneLine() throws {
        let width = SetupSheetMetrics.cardWidth, height = SetupSheetMetrics.cardHeight
        var ink = try render(width: width, height: height)
        let s = scale(ink, width: width)
        let inset = SetupSheetMetrics.horizontalInset
        let topRows = 0..<Int(36 * s)
        let contentRows = Int(46 * s)..<Int(120 * s)
        let footerRows = Int((height - 48) * s)..<Int((height - 6) * s)

        ink.threshold = 0.35
        let crumbText = try #require(ink.bounds(rows: topRows), "the crumb strip drew nothing")
        let headingText = try #require(ink.bounds(rows: contentRows), "the heading drew nothing")
        #expect(abs(CGFloat(crumbText.first) / s - inset) <= 2,
                "the crumb strip's text starts at \(CGFloat(crumbText.first) / s)pt against a \(inset)pt inset")
        #expect(abs(crumbText.first - headingText.first) <= Int(2 * s),
                "the crumb strip and the heading do not share a left edge (\(crumbText.first)px vs \(headingText.first)px)")

        ink.threshold = 0.05
        let footer = try #require(ink.bounds(rows: footerRows), "the footer drew nothing")
        #expect(abs(CGFloat(footer.first) / s - inset) <= 2,
                "the footer's first control starts at \(CGFloat(footer.first) / s)pt against a \(inset)pt inset")
        #expect(abs(CGFloat(width) - CGFloat(footer.last) / s - inset) <= 2,
                "the primary button ends \(CGFloat(width) - CGFloat(footer.last) / s)pt from the card's edge against a \(inset)pt inset")
    }

    /// The top bar's trailing control ends where the footer's does, allowing for the ✕'s own inset.
    ///
    /// **The allowance is measured, not chosen.** `CloseButton` draws its glyph inside a larger hit
    /// area, so its ink stops short of its frame; rendering it alone is what says by how much,
    /// which keeps this from being a magic number that quietly absorbs a real regression.
    @Test func theTopBarsTrailingControlEndsWhereTheFooterDoes() throws {
        let width = SetupSheetMetrics.cardWidth, height = SetupSheetMetrics.cardHeight
        var ink = try render(width: width, height: height)
        let s = scale(ink, width: width)
        ink.threshold = 0.35
        let topBar = try #require(ink.bounds(rows: 0..<Int(36 * s)))
        let glyphInset = try closeButtonGlyphInset()

        let expected = SetupSheetMetrics.horizontalInset + glyphInset
        let measured = width - CGFloat(topBar.last) / s
        #expect(glyphInset < 14, "the ✕ is drawing \(glyphInset)pt inside its own frame — that is a gap, not an inset")
        #expect(abs(measured - expected) <= 3,
                "the top bar's trailing control ends \(measured)pt from the card's edge; the ✕ on the card's \(SetupSheetMetrics.horizontalInset)pt inset would end at \(expected)pt")
    }

    /// **Every step in the crumb strip is readable, at every text size.**
    ///
    /// The strip carries about 186pt of chrome that had nothing to do with the type — seven gaps,
    /// sixteen capsule insets and eight number-to-name gaps, all fixed points — inside a card whose
    /// width *is* the type's. So the size that broke it was the small one: at 90% the card gives up
    /// 72pt, the padding gives up nothing, and the words pay the difference. Rendered, the strip
    /// read "1 Locat… 5 Count… Workspac… Appeara…" — four of the eight steps unreadable, at the
    /// setting chosen by someone trying to fit more on screen.
    ///
    /// Measured against the real top bar's budget rather than a chosen number: the card at this
    /// size, less its inset, less the two controls at the trailing end and the gaps the `HStack`
    /// puts between them.
    @Test func theCrumbStripFitsTheTopBarAtEveryTextSize() throws {
        let window = CGSize(width: 1200, height: 740)
        // The widest set the strip can be asked to draw — every screen that gets a crumb.
        let crumbs = SetupFlow.crumbs
        for size in FontSize.allCases {
            let scale = size.scale

            func width<V: View>(_ view: V) -> CGFloat {
                let host = NSHostingView(rootView:
                    view.environment(\.appFontScale, scale).fixedSize())
                host.layoutSubtreeIfNeeded()
                return host.fittingSize.width
            }

            let wanted = width(SetupCrumbStrip(screens: crumbs, current: crumbs[0], tint: .blue))
            let trailing = width(TextSizeStepper(size: .constant(size), tint: .blue))
                + width(CloseButton {})
            // The top bar is `HStack(spacing: 10) { strip; Spacer(minLength: 8); stepper; ✕ }`,
            // inset both sides, with the strip's leading capsule inset cancelled.
            let available = SetupSheetMetrics.resolvedWidth(availableSize: window, scale: scale)
                - SetupSheetMetrics.inset(scale: scale) * 2
                + SetupCrumbStrip.capsuleInset * scale
                - trailing - 10 * 3 - 8

            #expect(wanted <= available,
                    "at \(size.percent)% the crumb strip wants \(Int(wanted))pt and the top bar has \(Int(available))pt — steps will truncate to \"Locat…\"")
        }
    }

    /// How far `CloseButton`'s ink stops short of its own trailing edge.
    private func closeButtonGlyphInset() throws -> CGFloat {
        let box: CGFloat = 60
        let host = NSHostingView(rootView: CloseButton {}
            .frame(width: box, height: box, alignment: .trailing))
        host.frame = CGRect(x: 0, y: 0, width: box, height: box)
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        var ink = Ink(rep: rep)
        ink.threshold = 0.35
        let bounds = try #require(ink.bounds(rows: 0..<rep.pixelsHigh), "the close button drew nothing")
        return box - CGFloat(bounds.last) / (CGFloat(rep.pixelsWide) / box)
    }

    /// The footer's three pieces do not touch, at the widest primary title and the largest text.
    ///
    /// **The lock line is an overlay, so it reserves no width** — which is what keeps it centred on
    /// the card rather than sliding with the buttons, and is also the one way it could come to sit
    /// under one of them. This renders the widest footer there is and requires clear air on both
    /// sides of the centre.
    @Test func theFooterPiecesDoNotCollide() throws {
        for scale in [1.0, 1.35] as [CGFloat] {
            let width = SetupSheetMetrics.cardWidth * scale
            let height = SetupSheetMetrics.footerHeight * scale
            let footer = SetupFooter(onBack: {}, skipTitle: "Skip", onSkip: {},
                                     primaryTitle: "Save and start reading", onPrimary: {})
                .environment(\.appFontScale, scale)
                .frame(width: width, height: height)
            let host = NSHostingView(rootView: footer)
            host.frame = CGRect(x: 0, y: 0, width: width, height: height)
            host.layoutSubtreeIfNeeded()
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            var ink = Ink(rep: rep)
            // Below the text threshold the other assertions use: the closing line is `.tertiary`,
            // which is about a quarter opacity, so a scan tuned for body text cannot see it at all
            // — and a test that cannot see the thing it is about would have passed on a footer
            // that had lost it.
            ink.threshold = 0.15

            // The row through the middle of the footer, where all three pieces have ink.
            let clusters = ink.clusters(row: rep.pixelsHigh / 2, gap: Int(6 * (CGFloat(rep.pixelsWide) / width)))
            #expect(clusters.count >= 3,
                    "at \(Int(scale * 100))% the footer drew \(clusters.count) group(s) of ink — Back, the closing line and the buttons should be at least three")
            // The group nearest the card's centre is the lock line — chosen by distance rather
            // than by "contains the midpoint", because the midpoint can land in the gap between
            // the padlock and the words.
            let midpoint = rep.pixelsWide / 2
            func distance(_ cluster: (first: Int, last: Int)) -> Int {
                let centre: Int = (cluster.first + cluster.last) / 2
                return abs(centre - midpoint)
            }
            let nearest = clusters.min { distance($0) < distance($1) }
            let centre = try #require(nearest, "the footer drew nothing")
            let offCentre = distance(centre)
            #expect(offCentre < Int(60 * (CGFloat(rep.pixelsWide) / width)),
                    "at \(Int(scale * 100))% the closing line's centre is \(offCentre)px from the card's — it is sliding with the buttons again")
            #expect(clusters.contains { $0.last < centre.first },
                    "at \(Int(scale * 100))% nothing is drawn left of the closing line — Back has been swallowed")
            #expect(clusters.contains { $0.first > centre.last },
                    "at \(Int(scale * 100))% nothing is drawn right of the closing line — it is overlapping the buttons")
        }
    }

    /// The top bar really is no taller than the height the content budget is computed from.
    ///
    /// The companion to `theFooterFitsTheHeightTheOpeningIsComputedFrom`, and it exists because the
    /// bar was not in that budget at all: `contentHeight` subtracted only the footer, so every fit
    /// measurement was optimistic by a whole row of chrome and the Structure screen overflowed the
    /// card while its own fit test passed.
    @Test func theTopBarFitsTheHeightTheOpeningIsComputedFrom() throws {
        for scale in [1.0, 1.35] as [CGFloat] {
            let width = SetupSheetMetrics.cardWidth * scale
            let bar = SetupScreenCard(
                crumbs: SetupFlow.crumbs, current: .locations, fontSize: .constant(.extraLarge),
                tint: .blue, onBack: {}, primaryTitle: "Continue", onPrimary: {}, onDismiss: {},
                content: { Color.clear.frame(height: 1) })
                .environment(\.appFontScale, scale)
                .frame(width: width)
            let host = NSHostingView(rootView: bar)
            host.frame = CGRect(x: 0, y: 0, width: width, height: 400)
            host.layoutSubtreeIfNeeded()
            var ink = Ink(rep: try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds)))
            host.cacheDisplay(in: host.bounds, to: ink.rep)
            ink.threshold = 0.05
            let s = CGFloat(ink.rep.pixelsWide) / width

            // The first row with no ink after the bar's own: where the top chrome ends.
            var lastInkedRow = 0
            for y in 0..<Int(120 * s) where ink.columns(row: y) != nil { lastInkedRow = y }
            let measured = CGFloat(lastInkedRow) / s
            #expect(measured > 0, "the top bar drew nothing at all")
            #expect(measured <= SetupSheetMetrics.topBarHeight * scale,
                    "at \(Int(scale * 100))% the top bar is \(Int(measured))pt against a \(Int(SetupSheetMetrics.topBarHeight * scale))pt budget — every height this sheet computes is optimistic by the difference")
        }
    }

    /// A screen too tall for the card scrolls; it never takes the chrome with it.
    ///
    /// **Reported from a real Mac: nine locations at 110% text.** A `VStack` taller than its frame
    /// is not clipped at the bottom — it is centred and clipped at *both* ends — so the first
    /// things to disappear were the crumb strip and the primary button, which are how a person
    /// leaves the screen. The card's height is deliberately fixed, so the answer is that the
    /// content column scrolls.
    @Test func aScreenTallerThanTheCardKeepsItsChrome() throws {
        for scale in [1.0, 1.1, 1.35] as [CGFloat] {
            let width = SetupSheetMetrics.cardWidth * scale
            let height = SetupSheetMetrics.cardHeight * scale
            // Far more rows than any card could hold, so the overflow is not in doubt.
            let card = SetupScreenCard(
                crumbs: SetupFlow.crumbs, current: .locations, fontSize: .constant(.medium),
                tint: .blue, onBack: {}, primaryTitle: "Continue", onPrimary: {}, onDismiss: {}) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(0..<40, id: \.self) { row in
                            Text("Location \(row)").scaledFont(.callout)
                        }
                    }
                }
                .environment(\.appFontScale, scale)
                .frame(width: width, height: height)
            let host = NSHostingView(rootView: card)
            host.frame = CGRect(x: 0, y: 0, width: width, height: height)
            host.layoutSubtreeIfNeeded()
            var ink = Ink(rep: try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds)))
            host.cacheDisplay(in: host.bounds, to: ink.rep)
            ink.threshold = 0.15
            let s = CGFloat(ink.rep.pixelsWide) / width
            let pixelsHigh = ink.rep.pixelsHigh

            // The crumb strip lives in the first few points of the card, and the primary button in
            // the last few. A centred overflow eats exactly those.
            let topBand = ink.bounds(rows: 0..<Int(6 * s))
            let bottomBand = ink.bounds(rows: (pixelsHigh - Int(6 * s))..<pixelsHigh)
            #expect(topBand == nil,
                    "at \(Int(scale * 100))% something is drawn in the card's top \(6)pt — the content has pushed the chrome off the edge")
            #expect(bottomBand == nil,
                    "at \(Int(scale * 100))% something is drawn in the card's bottom \(6)pt — the primary button is being clipped")

            // And the chrome itself is still there, whole: a crumb strip at the top and a button
            // at the bottom, inside their own rows.
            let crumbs = try #require(ink.bounds(rows: Int(8 * s)..<Int(30 * s)),
                                      "at \(Int(scale * 100))% the crumb strip is gone")
            let footer = try #require(ink.bounds(rows: (pixelsHigh - Int(44 * s))..<(pixelsHigh - Int(8 * s))),
                                      "at \(Int(scale * 100))% the footer is gone")
            #expect(crumbs.first < Int(60 * s), "the crumb strip has moved")
            #expect(footer.last > Int((width - 120) * s), "the primary button has moved")
        }
    }

    /// The control: the scan can see a card whose rows disagree.
    ///
    /// Without it, a renderer that returned a blank bitmap — or a `colorAt` that always answered
    /// clear — would let both assertions above pass over any layout at all.
    @Test func theScanCanSeeAMisalignedRow() throws {
        let width = SetupSheetMetrics.cardWidth
        let host = NSHostingView(rootView: VStack(alignment: .leading, spacing: 0) {
            Text("chrome").padding(.leading, 14)
            Text("content").padding(.leading, 22)
        }
            .frame(width: width, height: 80, alignment: .topLeading))
        host.frame = CGRect(x: 0, y: 0, width: width, height: 80)
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let ink = Ink(rep: rep)
        let s = CGFloat(rep.pixelsWide) / width

        let top = try #require(ink.bounds(rows: 0..<Int(20 * s)), "the fixture drew nothing")
        let bottom = try #require(ink.bounds(rows: Int(20 * s)..<Int(44 * s)))
        #expect(abs(top.first - bottom.first) > Int(4 * s),
                "the scan cannot tell a 14pt inset from a 22pt one, so it cannot have proved anything above")
    }
}

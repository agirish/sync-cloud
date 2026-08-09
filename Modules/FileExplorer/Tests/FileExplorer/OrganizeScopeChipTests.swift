import Testing
import Foundation
import AppKit
import SwiftUI
import Design
@testable import FileExplorer

/// The scope chip, **rendered and read back**.
///
/// ## Why pixels, and why not just "is it inked?"
///
/// This exact header has truncated its contents to identical stubs once already: the rail took row
/// 1, the trailing controls overran it, SwiftUI clipped the flexible side, and "Refine with Opus"
/// and "Refine with Haiku" rendered as the same clipped stub. **Four tests compared those two
/// renders and passed**, because they compared identical truncated images. A probe asking only
/// whether the action band carried ink saw nothing wrong either. *Ink presence is not label
/// fidelity.*
///
/// So every claim here is discriminating by construction: two chips that must differ are rendered
/// and compared, and the test fails if they come back the same. A chip clipped to a stub makes them
/// equal, which is precisely the failure being hunted.
@Suite(.serialized, .machinePinned(.pixelSampling))
@MainActor
struct OrganizeScopeChipTests {

    static func chip(_ name: String, folderCount: Int?) -> some View {
        ScopeChipLabel(name: name, folderCount: folderCount, accent: .blue, onClear: {})
    }

    /// Renders at the chip's natural size and returns the bitmap.
    static func render(_ view: some View, width: CGFloat = 320, height: CGFloat = 28)
        -> NSBitmapImageRep {
        let host = NSHostingView(rootView: AnyView(
            view.frame(width: width, height: height, alignment: .leading)
                .background(Color.white)
                .environment(\.colorScheme, .light)))
        host.frame = CGRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.colorSpace = .sRGB
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            fatalError("no bitmap rep")
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// Columns carrying any non-background ink, as a set — the chip's painted footprint.
    static func inkedColumns(_ rep: NSBitmapImageRep) -> Set<Int> {
        var columns = Set<Int>()
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                // Anything meaningfully off pure white counts as ink — the chip's wash included.
                if c.redComponent < 0.97 || c.greenComponent < 0.97 || c.blueComponent < 0.97 {
                    columns.insert(x)
                    break
                }
            }
        }
        return columns
    }

    static func inkExtent(_ rep: NSBitmapImageRep) -> Int {
        let cols = inkedColumns(rep)
        guard let lo = cols.min(), let hi = cols.max() else { return 0 }
        return hi - lo + 1
    }

    static func pixelsEqual(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Bool {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else { return false }
        guard let da = a.tiffRepresentation, let db = b.tiffRepresentation else { return false }
        return da == db
    }

    // MARK: The chip is really drawn

    @Test func theChipPaintsSomething() {
        let rep = Self.render(Self.chip("Legal", folderCount: 12))
        #expect(Self.inkExtent(rep) > 40, "the chip painted almost nothing")
    }

    // MARK: The NAME is real, not a stub

    @Test func twoDifferentScopeNamesRenderDifferently() {
        // The direct answer to the identical-stub failure. If the name were clipped away, or
        // rendered as a fixed glyph, these two would be pixel-identical.
        let legal = Self.render(Self.chip("Legal", folderCount: 12))
        let immigration = Self.render(Self.chip("Immigration", folderCount: 12))
        #expect(!Self.pixelsEqual(legal, immigration),
                "two different scope names rendered identically — the name is not being drawn")
        // And the longer name genuinely takes more room, so neither is being truncated to a
        // common width.
        #expect(Self.inkExtent(immigration) > Self.inkExtent(legal),
                "the longer scope name did not render wider — it is being clipped")
    }

    @Test func aLongScopeNameIsNotClippedToTheSameWidthAsAShortOne() {
        // A real folder from his tree, and a deliberately long one, both with room to spare.
        let short = Self.render(Self.chip("US", folderCount: 3), width: 520)
        let long = Self.render(Self.chip("Income Tax Supporting Documents", folderCount: 3),
                               width: 520)
        #expect(Self.inkExtent(long) > Self.inkExtent(short) + 40)
    }

    /// The chip shares row 2 with a readout that will happily take the whole row.
    ///
    /// **This is the test that actually pins `.fixedSize()`**, and the first version of it did not:
    /// rendering the chip alone in a 520pt frame leaves so much slack that nothing compresses, so
    /// deleting `fixedSize` changed no pixel and the mutation survived. A greedy sibling and a tight
    /// row is the condition under which a flexible chip gives up its own width — which is exactly
    /// the shape of the truncation that once turned "Refine with Opus" and "Refine with Haiku" into
    /// the same stub.
    @Test func theChipKeepsItsWidthWhenTheRowIsTightAndASiblingIsGreedy() {
        @MainActor func row(width: CGFloat) -> NSBitmapImageRep {
            Self.render(
                HStack(spacing: 8) {
                    Self.chip("Income Tax Supporting Documents", folderCount: 3013)
                    Text("18 ready · 6 unsure · 4 new folders · scanned 3,013 folders")
                        .scaledFont(.system(size: 11))
                    Spacer(minLength: 0)
                },
                width: width)
        }
        // The chip's own footprint is the leading run of ink, up to the first gap wider than the
        // capsule's internal spacing. Measuring the whole row would just measure the row.
        func leadingRunWidth(_ rep: NSBitmapImageRep) -> Int {
            let cols = Self.inkedColumns(rep).sorted()
            guard let first = cols.first else { return 0 }
            var last = first
            for c in cols.dropFirst() {
                if c - last > 6 { break }
                last = c
            }
            return last - first + 1
        }
        let roomy = leadingRunWidth(row(width: 900))
        let tight = leadingRunWidth(row(width: 340))
        #expect(roomy > 100, "the chip did not render at a plausible width")
        // Same chip, same content: a fixed-size chip is the same width in both rows.
        #expect(abs(roomy - tight) <= 2,
                "the chip narrowed from \(roomy)px to \(tight)px when the row tightened — it is being compressed, and a truncated scope name is a claim you cannot read")
    }

    // MARK: It fits the row it was given

    /// **The chip must not grow row 2.**
    ///
    /// `LensHeaderCard` is 81pt at rest — `12 + 27 + 8 + 22 + 12` — and that number is not
    /// decorative: the card's bottom edge is pinned to the file pane's header↔list boundary, so a
    /// summary row that outgrows its 22pt budget shifts a boundary two panes away.
    ///
    /// Measured off the render rather than reasoned from the font sizes, which is the same rule
    /// `OrganizeRailMetrics.reservedTrailing` was re-derived under after its first estimate was
    /// wrong by enough to disable the shedding it existed to perform.
    @Test func theChipFitsTheSummaryRowsHeightBudget() {
        let host = NSHostingView(rootView: AnyView(Self.chip("Income Tax", folderCount: 3013)))
        let natural = host.fittingSize
        #expect(natural.height > 0, "the chip measured as zero-height — nothing was laid out")
        #expect(natural.height <= LensHeaderMetrics.summaryRow,
                "the scope chip is \(natural.height)pt tall against a \(LensHeaderMetrics.summaryRow)pt summary row — the header's 81pt resting height would move")
    }

    /// Row **1** is the rail's row, and the chip is not on it.
    ///
    /// `OrganizeRailMetrics.reservedTrailing` (420) is measured against row 1's trailing controls —
    /// Rescan, Refine, File all N, the search toggle. The scope chip lives on row 2, so that
    /// arithmetic is untouched by this change; this test states that as a fact rather than leaving
    /// it as an assumption, and `OrganizeScopeCallSiteTests` pins the chip's actual draw site.
    @Test func theRailsWidthArithmeticIsUnchangedByTheChip() {
        #expect(OrganizeRailMetrics.reservedTrailing == 420)
        // The shed threshold at the default text size is where it was: the rail still spells its
        // items out on a wide canvas and sheds on a narrow one. **Every lens badged**, which is now
        // reachable — `railCount(.restructure)` stopped returning a hard 0 in this same change, so
        // five is the real ceiling rather than a hypothetical one.
        let everyBadge: (OrganizeLens) -> Int? = { $0.badge(count: 7) }
        let leading = OrganizeRailMetrics.leadingWidth(scale: 1, hasIntro: true, badge: everyBadge)
        #expect(OrganizeRailMetrics.style(contentWidth: 1400, leadingWidth: leading) == .full)
        #expect(OrganizeRailMetrics.style(contentWidth: 900, leadingWidth: leading) == .iconOnly)
    }

    // MARK: The COUNT is real

    @Test func twoDifferentFolderCountsRenderDifferently() {
        // Scope honesty was the original requirement: the chip must say how much of the tree it
        // covers, and a count that never reached the pixels would leave that claim unmade.
        let three = Self.render(Self.chip("Legal", folderCount: 3))
        let ninety = Self.render(Self.chip("Legal", folderCount: 91))
        #expect(!Self.pixelsEqual(three, ninety),
                "different folder counts rendered identically — the count is not being drawn")
    }

    @Test func aChipWithNoProfileOmitsTheCountRatherThanSayingZero() {
        // nil is "there is no profile to count against", which must NOT render as "0 folders" —
        // a zero here would be a claim the chip cannot support, the same distinction the rail
        // badge draws between absent and zero.
        let none = Self.render(Self.chip("Legal", folderCount: nil))
        let zero = Self.render(Self.chip("Legal", folderCount: 0))
        #expect(!Self.pixelsEqual(none, zero))
        #expect(Self.inkExtent(none) < Self.inkExtent(zero),
                "the countless chip should be narrower than one that spells out a count")
    }

    @Test func theCountPluralizes() {
        #expect(ScopeChipLabel.folderCountText(1) == "1 folder")
        #expect(ScopeChipLabel.folderCountText(0) == "0 folders")
        #expect(ScopeChipLabel.folderCountText(3013) == "3013 folders")
    }

    // MARK: The clear control is present

    /// Columns holding **glyph** ink — pixels meaningfully darker than the capsule's own wash.
    ///
    /// The distinction matters: the capsule fill is `accent.opacity(0.14)`, so a band containing
    /// nothing but background is still "inked" against white. Counting wash as ink is exactly how a
    /// probe concludes a control is present when only its container is.
    ///
    /// **Perceptual luminance, not `brightnessComponent`.** The first attempt used the latter and
    /// found no glyph pixels at all: `brightnessComponent` is HSB value, i.e. `max(r,g,b)`, which
    /// for a saturated blue glyph is 1.0 — identical to white. Weighted luminance separates them
    /// with room to spare: the accent glyph lands near 0.40, the wash over white near 0.92.
    static func luminance(_ c: NSColor) -> CGFloat {
        0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
    }

    static func glyphColumns(_ rep: NSBitmapImageRep) -> Set<Int> {
        var columns = Set<Int>()
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                if luminance(c) < 0.70 { columns.insert(x); break }
            }
        }
        return columns
    }

    /// Guards the threshold itself: a discriminator that classified everything, or nothing, as
    /// glyph would make every assertion built on it meaningless in one direction or the other.
    @Test func theGlyphDiscriminatorSeparatesGlyphFromWash() {
        let rep = Self.render(Self.chip("Legal", folderCount: 12))
        let wash = Self.inkedColumns(rep)
        let glyphs = Self.glyphColumns(rep)
        #expect(!glyphs.isEmpty, "no glyph pixels found — the threshold classifies nothing")
        #expect(glyphs.count < wash.count,
                "every inked column counted as glyph — the threshold is not discriminating")
    }

    @Test func theClearControlIsDrawnInsideTheCapsulesTrailingEdge() {
        // **The ✕ IS the global view** — there is no seventh rail place and no "Everything" item —
        // so a chip that dropped it would leave the scoped state reachable only from the context
        // menu.
        //
        // Measured as GLYPH ink in the trailing band rather than by comparing against a
        // differently-built view, which is what the first version did: that comparison view had no
        // capsule behind it, so the real chip was wider for reasons unrelated to the ✕ and deleting
        // the button changed nothing the assertion could see. A `Button` is not an `NSControl` and
        // SwiftUI's tree is not inspectable from here, so pixels are the instrument — but they have
        // to be the glyph's pixels, not the capsule's.
        // The reference is the SAME capsule with the SAME padding and the SAME content, minus the
        // button — so the only thing that can move a measurement is the ✕ itself. Comparing
        // against a differently-built view is what made the first version undiscriminating: it had
        // no capsule behind it, so the real chip was wider for reasons that had nothing to do with
        // the control, and deleting the button changed nothing the assertion could see.
        //
        // An absolute pixel threshold was the other false start: these render on a 2× backing, so
        // the capsule's 7pt trailing padding is ~14px and any "gap must be under 12" reads as a
        // failure on a correct chip. Two renders of the same thing need no unit conversion.
        let withClear = Self.render(Self.chip("Legal", folderCount: 12))
        let withoutClear = Self.render(
            HStack(spacing: 4) {
                Image(systemName: "scope").scaledFont(.system(size: 9.5, weight: .semibold))
                Text("Legal").scaledFont(.system(size: 11, weight: .semibold))
                Text(ScopeChipLabel.folderCountText(12))
                    .scaledFont(.system(size: 10.5)).monospacedDigit().foregroundStyle(.secondary)
            }
            .foregroundStyle(Color.blue)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.blue.opacity(0.14)))
            .fixedSize())

        // **Width is the only signal here, and finding that out took a measurement.** The obvious
        // check — "the trailing glyph should sit closer to the capsule's edge when a ✕ is there" —
        // reads 16px in both renders, because whatever the last element is, it is one 7pt padding
        // from the edge. The gap is a property of the padding, not of the contents. What the button
        // genuinely changes is how much capsule there is.
        let clearControlWidth = Self.inkExtent(withClear) - Self.inkExtent(withoutClear)
        #expect(clearControlWidth > 12,
                "the chip is only \(clearControlWidth)px wider than the same capsule without a ✕ — the clear control is missing")
        // And the ✕ is genuinely glyph ink rather than more wash, so it is a mark you can see.
        #expect(Self.glyphColumns(withClear).count > Self.glyphColumns(withoutClear).count,
                "the extra width carries no glyph ink — the ✕ is not being drawn")
    }
}

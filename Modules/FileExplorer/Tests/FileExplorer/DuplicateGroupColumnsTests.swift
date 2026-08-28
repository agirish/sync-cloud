import Testing
import AppKit
import SwiftUI
import Design
@testable import FileExplorer
@testable import Sync

/// The invisible-column slots behind the Duplicates group header. The model's one claim: a
/// slot is exactly wide enough for the widest member of its vocabulary — derived by measuring,
/// so no badge or verb can overflow its slot and break the columns downstream of it.
@MainActor
@Suite struct DuplicateGroupColumnsTests {

    /// - Note: **Both halves are true by construction, and nothing here measures a drawn badge.**
    ///   `badgeSlotWidth` is the maximum of this very expression over this very vocabulary, so
    ///   `width <= slot` cannot fail while the two remain the same formula — and a maximum is
    ///   always attained, so "the slot equals a real member" cannot fail either. What that buys is
    ///   real but narrow: the slot and the drawing stay the same arithmetic.
    ///
    ///   It is NOT evidence that a badge fits. If `LabelMetrics` under-measured by a fifth, slot
    ///   and assertions would shrink together and every badge would overflow with this green.
    ///   `DuplicateGroupBadgeRenderTests` is what closes that: it draws the badge and reads its painted
    ///   width back, so the model has to agree with a renderer that never saw it. An earlier
    ///   version of this note said such a sibling existed when none did — kept here, corrected,
    ///   because "there is a test that measures the paint" is exactly the claim worth being able
    ///   to check.
    @Test func everyBadgeFitsItsSlot() {
        let slot = DuplicateGroupColumns.badgeSlotWidth(scale: 1)
        for type in DuplicateGroupColumns.badgeVocabulary {
            #expect(DuplicateGroupColumns.badgeWidth(type, scale: 1) <= slot,
                    "\(type) overflows the badge slot")
        }
        // And the slot is spent on a real member, not padding — it equals the widest one.
        #expect(DuplicateGroupColumns.badgeVocabulary.contains {
            DuplicateGroupColumns.badgeWidth($0, scale: 1) == slot
        })
    }

    /// A new `DuplicateMatchType` case must join the badge vocabulary, or its badge can overflow
    /// the slot silently.
    ///
    /// **Swept over `Kind.allCases`, not over a list written here.** It was a hand-copied array of
    /// the five shapes the enum had, which is the same hand copy as the vocabulary it is checking:
    /// a sixth case left both stale together and this test green — a "every X does Y" scan that
    /// cannot see the X it is missing.
    @Test func theVocabularyCoversEveryBadgeWearingMatchType() {
        let represented = Set(DuplicateGroupColumns.badgeVocabulary
            .compactMap { DuplicateMatchStyle.badgeLabel($0) })
        for kind in DuplicateMatchType.Kind.allCases {
            let type = Self.sample(of: kind)
            guard let label = DuplicateMatchStyle.badgeLabel(type) else {
                // The one badge-less case is the majority one, by design (ROADMAP.md, the
                // Identical-badge item) — a second kind going badge-less silently would put an
                // unmeasured badge back outside the slot model.
                #expect(kind == .identical, "\(kind) has no badge label — only identical may")
                continue
            }
            #expect(represented.contains(label),
                    "\(kind) is not represented in the badge vocabulary")
        }
    }

    /// One `DuplicateMatchType` per `Kind`, exhaustively — the switch is the point, because it is
    /// what stops compiling when a case is added, which is how this stays honest without anyone
    /// remembering to come back here.
    static func sample(of kind: DuplicateMatchType.Kind) -> DuplicateMatchType {
        switch kind {
        case .identical: return .identical
        case .sameText: return .sameText
        case .overlapping: return .overlapping(sharedFraction: 1.0)
        case .nameOnly: return .nameOnly
        case .versions: return .versions
        }
    }

    @Test func slotsScaleWithTheFont() {
        // At a larger scale every slot must grow — a fixed slot under a grown font truncates.
        #expect(DuplicateGroupColumns.badgeSlotWidth(scale: 1.35) > DuplicateGroupColumns.badgeSlotWidth(scale: 1))
        #expect(DuplicateGroupColumns.verbSlotWidth(scale: 1.35) > DuplicateGroupColumns.verbSlotWidth(scale: 1))
        #expect(DuplicateGroupColumns.digitsSlotWidth(scale: 1.35) > DuplicateGroupColumns.digitsSlotWidth(scale: 1))
    }
}

/// The badge slot, measured **off the render** — the claim `everyBadgeFitsItsSlot` cannot make.
///
/// That test compares `badgeSlotWidth` against the expression `badgeSlotWidth` maximises, so it is
/// two readings of one formula: an error in the ingredients moves the slot and the assertion
/// together and every badge overflows with the suite green. This one never evaluates the formula.
/// It draws `DuplicateTypeBadge` — the view `DuplicateGroupCard` draws, not a copy of it — and finds the
/// rightmost painted pixel, so what the model claims has to agree with what AppKit actually inked.
///
/// The canvas is deliberately wider than the slot: the card applies the slot as a `minWidth`, so a
/// badge that outgrows it overflows rather than truncating, and a canvas cut to the slot would clip
/// the very evidence away.
///
/// `.machinePinned(.pixelSampling)` — it reads pixels back out of a live renderer, so its verdict
/// belongs to the Mac that recorded it. Its own suite rather than a marker on the pure tests above,
/// which need no such pinning and must keep running wherever they are selected.
@MainActor
@Suite(.serialized, .machinePinned(.pixelSampling)) struct DuplicateGroupBadgeRenderTests {

    /// Where the rightmost ink of `view` lands, in points from the leading edge of the canvas —
    /// nil when nothing painted at all.
    ///
    /// The background is sampled from the far corner rather than assumed, exactly as the overview's
    /// render suite does: what counts as "inked" is "differs from the surface this was drawn on",
    /// which stays true if the surface's colour ever changes.
    private static func paintedWidth(of view: some View, canvasWidth: CGFloat) -> CGFloat? {
        // **Whole points, because the last pixel column of a fractional canvas is not the drawing.**
        // At 238.4pt the backing store rounds up, leaving a sliver column the content never covered
        // — and it reads as "inked" against a background sampled from inside the drawn area, so
        // every badge measured as exactly the canvas width. Rounding up costs nothing and removes
        // the sliver.
        let canvas = CGSize(width: canvasWidth.rounded(.up), height: 30)
        let subject = AnyView(
            view.frame(width: canvas.width, height: canvas.height, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor))
                .environment(\.colorScheme, .light))
        let host = NSHostingView(rootView: subject)
        host.frame = CGRect(origin: .zero, size: canvas)
        // Without a window the content composites against the borderless window's own buffer and
        // every reading comes back as "nothing painted" — see `OrganizeOverviewRenderTests`.
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.colorSpace = .sRGB
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let background = rep.colorAt(x: rep.pixelsWide - 3, y: rep.pixelsHigh - 3) else {
            return nil
        }
        let scale = CGFloat(rep.pixelsWide) / canvas.width
        for x in stride(from: rep.pixelsWide - 1, through: 0, by: -1) {
            for y in 0..<rep.pixelsHigh {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                let delta = max(abs(c.redComponent - background.redComponent),
                                max(abs(c.greenComponent - background.greenComponent),
                                    abs(c.blueComponent - background.blueComponent)))
                // The pill's own fill is the tint at 14%, so the badge's widest ink is faint by
                // design and the threshold has to be well under that — the capsule's edge IS the
                // badge's edge, and measuring the text alone would under-read it by the padding.
                if delta > 0.02 { return (CGFloat(x) + 1) / scale }
            }
        }
        return nil
    }

    /// **No drawn badge reaches past the slot the card gives it.**
    @Test func aDrawnBadgeStaysInsideItsSlot() throws {
        let slot = DuplicateGroupColumns.badgeSlotWidth(scale: 1)
        for type in DuplicateGroupColumns.badgeVocabulary {
            let painted = try #require(
                Self.paintedWidth(of: DuplicateTypeBadge(matchType: type), canvasWidth: slot + 120),
                "\(type) painted nothing — the render, not the badge, is what failed")
            // A badge is a glyph, a word and two paddings; anything under 30pt means the label
            // never drew and the reading below would pass on an empty capsule. And it must stop
            // short of the canvas: a reading that lands on the far edge is the harness measuring
            // its own boundary rather than the badge, which is exactly what a fractional canvas
            // produced before this measured in whole points.
            #expect(painted > 30, "\(type) painted only \(Int(painted))pt — no label")
            #expect(painted < slot + 119,
                    "\(type)'s ink reaches the canvas edge — the harness is measuring itself")
            let report = "\(type) paints \(String(format: "%.1f", painted))pt into a "
                + "\(String(format: "%.1f", slot))pt slot"
            #expect(painted <= slot + 1, "\(report)")
        }
    }

    /// **And the slot is the size of the badge it is meant to hold** — within a point of it.
    ///
    /// This is the half that catches a systematically wrong model. `aDrawnBadgeStaysInsideItsSlot`
    /// passes on any slot that is too *large*, and `everyBadgeFitsItsSlot` passes on any model that
    /// is wrong in one direction consistently — a `LabelMetrics` under-measuring by a fifth shrinks
    /// the slot and the expected width together. Holding the widest painted badge to the slot ties
    /// the model to the renderer: the two must agree to within antialiasing.
    @Test func theSlotIsTheWidthOfTheWidestBadgeAsDrawn() throws {
        let slot = DuplicateGroupColumns.badgeSlotWidth(scale: 1)
        var widest: CGFloat = 0
        for type in DuplicateGroupColumns.badgeVocabulary {
            let painted = try #require(
                Self.paintedWidth(of: DuplicateTypeBadge(matchType: type), canvasWidth: slot + 120))
            widest = max(widest, painted)
        }
        let report = "the widest badge paints \(String(format: "%.1f", widest))pt against a "
            + "modelled \(String(format: "%.1f", slot))pt slot — model and renderer disagree"
        #expect(abs(widest - slot) <= 1, "\(report)")
    }
}

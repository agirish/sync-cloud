import Testing
import Foundation
import AppKit
import SwiftUI
import Design
@testable import FileExplorer

/// The scope chip, rendered and read back. Ink presence is not label fidelity: a chip clipped to a
/// stub renders two labels the same. So every claim is discriminating: two chips that must differ
/// are rendered and compared.
@Suite(.serialized)
@MainActor
struct OrganizeScopeChipTests {

    static func chip(_ name: String, folderCount: Int?, suspended: Bool = false) -> some View {
        ScopeChipLabel(name: name, folderCount: folderCount, accent: .blue,
                       isSuspended: suspended,
// The live chip's ✕ and the suspended chip's lack of one, as `LensWorkspaceView` passes them.
                       onClear: suspended ? nil : {})
    }

/// Renders at the chip's natural size. The backdrop follows the scheme, so "ink" means off the
/// backdrop in both (``inkedColumns(_:scheme:)``); light by default, as the assertions were measured.
    static func render(_ view: some View, width: CGFloat = 320, height: CGFloat = 28,
                       scheme: ColorScheme = .light) -> NSBitmapImageRep {
        PixelDiff.render(view.frame(width: width, height: height, alignment: .leading)
                            .background(scheme == .dark ? Color.black : Color.white)
                            .environment(\.colorScheme, scheme),
                         size: CGSize(width: width, height: height),
                         appearance: scheme == .dark ? .darkAqua : .aqua)!
    }

    /// Columns carrying any non-background ink, as a set: the chip's painted footprint.
    static func inkedColumns(_ rep: NSBitmapImageRep, scheme: ColorScheme = .light) -> Set<Int> {
        var columns = Set<Int>()
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                // Anything meaningfully off the backdrop counts as ink, the chip's wash included.
                let off = scheme == .dark
                    ? (c.redComponent > 0.03 || c.greenComponent > 0.03 || c.blueComponent > 0.03)
                    : (c.redComponent < 0.97 || c.greenComponent < 0.97 || c.blueComponent < 0.97)
                if off {
                    columns.insert(x)
                    break
                }
            }
        }
        return columns
    }

    static func inkExtent(_ rep: NSBitmapImageRep, scheme: ColorScheme = .light) -> Int {
        let cols = inkedColumns(rep, scheme: scheme)
        guard let lo = cols.min(), let hi = cols.max() else { return 0 }
        return hi - lo + 1
    }

    static func pixelsEqual(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Bool {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else { return false }
        guard let da = a.tiffRepresentation, let db = b.tiffRepresentation else { return false }
        return da == db
    }

    // MARK: The suspended chip — ROADMAP 15's "closing must put it back"

/// Suspended must look different from live, in both schemes: a suspended chip drawn like a live one
/// would have the lists stop obeying a chip that looks like it applies. Same name and count, so
/// only the state can move a pixel.
    @Test(.machinePinned(.pixelSampling), arguments: [ColorScheme.light, ColorScheme.dark])
    func aSuspendedScopeDoesNotLookLikeALiveOne(scheme: ColorScheme) {
        let live = Self.render(Self.chip("Legal", folderCount: 12), scheme: scheme)
        let paused = Self.render(Self.chip("Legal", folderCount: 12, suspended: true), scheme: scheme)
        #expect(!Self.pixelsEqual(live, paused),
                "the suspended chip renders identically to the live one in \(scheme) — the lists have stopped obeying a chip that still looks like it applies")
        // Non-vacuity: both actually painted, so the inequality above is not between blanks.
        #expect(Self.inkExtent(live, scheme: scheme) > 40, "the live chip painted almost nothing in \(scheme)")
        #expect(Self.inkExtent(paused, scheme: scheme) > 40, "the suspended chip painted almost nothing in \(scheme)")
    }

    /// The scope's name survives the suspension: the chip stays on screen to say which folder comes
    /// back, and a generic "paused" label would lose that.
    @Test(.machinePinned(.pixelSampling), arguments: [ColorScheme.light, ColorScheme.dark])
    func theSuspendedChipStillNamesTheFolder(scheme: ColorScheme) {
        let legal = Self.render(Self.chip("Legal", folderCount: 12, suspended: true), scheme: scheme)
        let immigration = Self.render(Self.chip("Immigration", folderCount: 12, suspended: true),
                                      scheme: scheme)
        #expect(!Self.pixelsEqual(legal, immigration),
                "two different scope names render identically while suspended — the name is gone")
        #expect(Self.inkExtent(immigration, scheme: scheme) > Self.inkExtent(legal, scheme: scheme),
                "the longer name did not render wider while suspended — it is being clipped")
    }

    // MARK: The NAME is real, not a stub

    @Test(.machinePinned(.pixelSampling)) func twoDifferentScopeNamesRenderDifferently() {
// Clipped away, or a fixed glyph, these two would be identical.
        let legal = Self.render(Self.chip("Legal", folderCount: 12))
        let immigration = Self.render(Self.chip("Immigration", folderCount: 12))
        #expect(!Self.pixelsEqual(legal, immigration),
                "two different scope names rendered identically — the name is not being drawn")
        // And the longer name takes more room, so neither is truncated to a common width.
        #expect(Self.inkExtent(immigration) > Self.inkExtent(legal),
                "the longer scope name did not render wider — it is being clipped")
    }

    @Test(.machinePinned(.pixelSampling)) func aLongScopeNameIsNotClippedToTheSameWidthAsAShortOne() {
        // A real folder from his tree, and a deliberately long one, both with room to spare.
        let short = Self.render(Self.chip("US", folderCount: 3), width: 520)
        let long = Self.render(Self.chip("Income Tax Supporting Documents", folderCount: 3),
                               width: 520)
        #expect(Self.inkExtent(long) > Self.inkExtent(short) + 40)
    }

/// Pins `.fixedSize()`: the chip shares row 2 with a readout that takes the whole row, and only a
/// greedy sibling in a tight row shows a flexible chip giving up its width.
    @Test(.machinePinned(.pixelSampling)) func theChipKeepsItsWidthWhenTheRowIsTightAndASiblingIsGreedy() {
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
        // The chip's footprint is the leading run of ink, up to the first gap wider than the
        // capsule's internal spacing; measuring the whole row would just measure the row.
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

/// The chip must not grow row 2: `LensHeaderCard` is 81pt at rest and its bottom edge is pinned to
/// the file pane's header↔list boundary, so a summary row past its 22pt budget shifts a boundary
/// two panes away.
    @Test(.machinePinned(.layoutMetrics)) func theChipFitsTheSummaryRowsHeightBudget() {
        let host = NSHostingView(rootView: AnyView(Self.chip("Income Tax", folderCount: 3013)))
        let natural = host.fittingSize
        #expect(natural.height > 0, "the chip measured as zero-height — nothing was laid out")
        #expect(natural.height <= LensHeaderMetrics.summaryRow,
                "the scope chip is \(natural.height)pt tall against a \(LensHeaderMetrics.summaryRow)pt summary row — the header's 81pt resting height would move")
    }

    // MARK: The COUNT is real

    @Test(.machinePinned(.pixelSampling)) func twoDifferentFolderCountsRenderDifferently() {
// A count that never reached the pixels leaves the coverage claim unmade.
        let three = Self.render(Self.chip("Legal", folderCount: 3))
        let ninety = Self.render(Self.chip("Legal", folderCount: 91))
        #expect(!Self.pixelsEqual(three, ninety),
                "different folder counts rendered identically — the count is not being drawn")
    }

    @Test(.machinePinned(.pixelSampling)) func aChipWithNoProfileOmitsTheCountRatherThanSayingZero() {
// nil is "no profile to count against" and must not render as "0 folders".
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

/// Columns holding glyph ink: pixels meaningfully darker than the capsule's `accent.opacity(0.14)`
/// wash. Perceptual luminance, not `brightnessComponent` (HSB value, 1.0 for a saturated blue glyph
/// as for white).
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

/// Guards the threshold: a discriminator that called everything, or nothing, glyph would void the
/// assertions built on it.
    @Test(.machinePinned(.pixelSampling)) func theGlyphDiscriminatorSeparatesGlyphFromWash() {
        let rep = Self.render(Self.chip("Legal", folderCount: 12))
        let wash = Self.inkedColumns(rep)
        let glyphs = Self.glyphColumns(rep)
        #expect(!glyphs.isEmpty, "no glyph pixels found — the threshold classifies nothing")
        #expect(glyphs.count < wash.count,
                "every inked column counted as glyph — the threshold is not discriminating")
    }

    @Test(.machinePinned(.pixelSampling)) func theClearControlIsDrawnInsideTheCapsulesTrailingEdge() {
// The ✕ is the only way back to the global view. The reference is the same capsule minus the
// button, so only the ✕ moves a measurement; pixels because a `Button` is not an `NSControl`, and
// a comparison because an absolute threshold would double at 2×.
        let withClear = Self.render(Self.chip("Legal", folderCount: 12))
        let withoutClear = Self.render(
            HStack(spacing: 4) {
                Image(systemName: "scope").scaledFont(.system(size: 9.5, weight: .semibold))
                Text("Legal").scaledFont(.system(size: 11, weight: .semibold))
                Text(ScopeChipLabel.folderCountText(12))
                    .scaledFont(.system(size: 10.5)).monospacedDigit().foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)   // the chip's words are label colour
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.blue.opacity(0.14)))
            .fixedSize())

// Width is the only signal: the trailing padding is the same whatever the last element is.
        let clearControlWidth = Self.inkExtent(withClear) - Self.inkExtent(withoutClear)
        #expect(clearControlWidth > 12,
                "the chip is only \(clearControlWidth)px wider than the same capsule without a ✕ — the clear control is missing")
        // And the ✕ is glyph ink rather than more wash, so it is a mark you can see.
        #expect(Self.glyphColumns(withClear).count > Self.glyphColumns(withoutClear).count,
                "the extra width carries no glyph ink — the ✕ is not being drawn")
    }
}

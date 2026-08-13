import Testing
import SwiftUI
import AppKit
import Design
@testable import FileExplorer

/// `SummaryRun`'s one rule, in pixels: **the colour is on the glyph and never on the words.**
///
/// That is the whole reason the type exists. The readout used to be `StatPill`s, and the obvious
/// de-capsuling — keep the semantic colour, drop the wash — makes the row *less* legible, because
/// `SemanticColor.caution` is `Color.yellow` and the pill's 0.14 wash is most of what gives yellow
/// text a shape on a white card. So the tint moved to the glyph, which is a non-text indicator
/// answering to 3:1, and the words took the standard label hierarchy.
///
/// **Nothing but a render can hold that.** The rule is a claim about which pixels a colour reaches;
/// the view exposes no seam for it, and `.foregroundStyle(Color.primary)` on the count is one token
/// away from `.foregroundStyle(color)` — a change that alters no geometry, no accessibility label
/// and no test in this target. Rendering it is also the only way to catch the reverse mistake, a
/// glyph that quietly stopped taking the tint at all.
///
/// ## How the claim is measured
///
/// Two renders that differ **only** in `color`, and two that differ only in `count`. Where the
/// colour-swap moves pixels is the region the tint reaches; where the count-swap moves them is the
/// region the words occupy. The rule is that those two regions do not overlap — the colour must
/// stop before the text starts. That is a comparison between two measurements of the subject rather
/// than a number copied out of the current layout, so it survives a font change, and it cannot be
/// satisfied by a view that draws nothing: both diffs are required to be non-empty first.
///
/// `.machinePinned(.pixelSampling)`, like every suite here that reads a live renderer back.
@MainActor
@Suite(.serialized, .machinePinned(.pixelSampling)) struct SummaryRunRenderTests {

    /// Wide enough that `fixedSize()` never clips, short enough that a wrapped second line is
    /// unmistakable in the row tally.
    private static let canvas = CGSize(width: 320, height: 60)

    private func bitmap(_ view: some View, size: CGSize = canvas) -> NSBitmapImageRep? {
        let subject = view
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: AnyView(subject))
        host.frame = CGRect(origin: .zero, size: size)
        // A real window, for the reason `OrganizeOverviewRenderTests` records: without one the
        // content composites against the borderless window's own buffer and every comparison below
        // reads as zero difference — "nothing painted", whatever the code did. No
        // `layoutIfNeeded()`: it disarms AppKit's runaway guards.
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
        return rep
    }

    /// The x coordinates, in points, at which two renders of the same subject differ.
    private func differingColumns(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> [CGFloat] {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else { return [] }
        let scale = CGFloat(a.pixelsWide) / Self.canvas.width
        var columns: [CGFloat] = []
        for x in 0..<a.pixelsWide {
            var differs = false
            for y in 0..<a.pixelsHigh where !differs {
                guard let p = a.colorAt(x: x, y: y), let q = b.colorAt(x: x, y: y) else { continue }
                let delta = max(abs(p.redComponent - q.redComponent),
                                max(abs(p.greenComponent - q.greenComponent),
                                    abs(p.blueComponent - q.blueComponent)))
                if delta > 0.04 { differs = true }
            }
            if differs { columns.append(CGFloat(x) / scale) }
        }
        return columns
    }

    /// Rows carrying ink, measured against a background sampled where content never reaches.
    private func inkedRows(_ rep: NSBitmapImageRep, background: NSColor) -> [Int] {
        var rows: [Int] = []
        for y in 0..<rep.pixelsHigh {
            var n = 0
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                let delta = max(abs(c.redComponent - background.redComponent),
                                max(abs(c.greenComponent - background.greenComponent),
                                    abs(c.blueComponent - background.blueComponent)))
                if delta > 0.04 { n += 1 }
            }
            if n >= 2 { rows.append(y) }
        }
        return rows
    }

    private func run(count: Int = 4, label: String = "unsure", color: Color) -> SummaryRun {
        SummaryRun(count: count, label: label, color: color,
                   systemImage: "questionmark.circle")
    }

    // MARK: The colour stops at the glyph

    /// **Swapping the tint moves only glyph pixels; swapping the count moves only word pixels.**
    ///
    /// Two saturated, maximally distinguishable tints so the glyph diff cannot be lost in
    /// anti-aliasing, and two counts of equal digit length (`4` and `8`) so the count swap moves the
    /// *ink* of the number without moving the label after it — `monospacedDigit()` guarantees the
    /// widths match, which is what keeps the word region a fixed target.
    ///
    /// The assertion is the disjointness of the two regions, not a hard-coded boundary: had the
    /// count been tinted, the colour diff would reach into the columns the count diff occupies, and
    /// `firstTintedColumn < lastWordColumn` is exactly that overlap. Both regions are required to be
    /// non-empty first — a subject that painted nothing would otherwise satisfy a disjointness
    /// claim perfectly.
    @Test func theGlyphTakesTheTintAndTheWordsDoNot() throws {
        let magenta = try #require(bitmap(run(color: Color(red: 1, green: 0, blue: 1))))
        let green = try #require(bitmap(run(color: Color(red: 0, green: 0.6, blue: 0))))
        let four = try #require(bitmap(run(count: 4, color: Color(red: 1, green: 0, blue: 1))))
        let eight = try #require(bitmap(run(count: 8, color: Color(red: 1, green: 0, blue: 1))))

        let tinted = differingColumns(magenta, green)
        let words = differingColumns(four, eight)
        #expect(!tinted.isEmpty,
                "changing the colour changed no pixel at all — the glyph is not taking the tint")
        #expect(!words.isEmpty,
                "changing the count changed no pixel at all — the number is not being drawn")

        let lastTinted = try #require(tinted.last)
        let firstWord = try #require(words.first)
        #expect(lastTinted < firstWord,
                "the tint reaches to \(Int(lastTinted))pt, past where the count starts drawing at \(Int(firstWord))pt — the words are taking the semantic colour")
    }

    /// **The label is drawn too**, and after the count.
    ///
    /// Cheap, and it closes the one way the test above could be read as satisfied by half a view:
    /// it compares the tint region against the *count*, so a run that drew a glyph and a number and
    /// dropped the noun entirely would pass it. Two labels of obviously different length, so what is
    /// measured is the noun and not the spacing around it.
    @Test func theLabelIsDrawnAfterTheCount() throws {
        let short = try #require(bitmap(run(label: "ready", color: SemanticColor.success)))
        let long = try #require(bitmap(run(label: "folders to rename", color: SemanticColor.success)))
        let moved = differingColumns(short, long)
        let first = try #require(moved.first, "the two labels render identically — no noun is drawn")
        let last = try #require(moved.last)
        #expect(last - first > 40,
                "the label occupies only \(Int(last - first))pt however long it is — it is being truncated away")
    }

    // MARK: One line, always

    /// **A run stays on one line however long its noun**, because it rides a row whose height
    /// `LensHeaderCard` pins and a wrapping run would push past it.
    ///
    /// `lineLimit(1)` and `fixedSize()` together are what hold that, and neither is visible to any
    /// other check here. The pair is what this pins, deliberately: with only `fixedSize()` the run
    /// overflows its width rather than wrapping, and with only `lineLimit(1)` it truncates — either
    /// one alone still keeps the row a row, so a test claiming to pin them individually would be
    /// claiming more than it can measure.
    ///
    /// **The canvas is narrow on purpose, and that is the whole test.** At the suite's 320pt width
    /// this measured nothing: the noun fitted, so it did not wrap with the modifiers deleted either,
    /// and the check passed against the mutation it exists to catch. The width below is under the
    /// noun's natural length, which is the only condition where wrapping is on the table at all.
    ///
    /// Inked rows rather than `fittingSize`: a height query answers what the view *asked* for, and
    /// the failure being guarded against is a second row of text actually appearing.
    @Test func aLongNounDoesNotWrapOntoASecondRow() throws {
        let narrow = CGSize(width: 180, height: Self.canvas.height)
        let short = try #require(bitmap(run(label: "ready", color: SemanticColor.success),
                                        size: narrow))
        let long = try #require(bitmap(run(label: "folders whose names this provider will not accept",
                                           color: SemanticColor.success),
                                       size: narrow))
        let bg = try #require(short.colorAt(x: short.pixelsWide - 3, y: short.pixelsHigh - 3))
        let scale = CGFloat(short.pixelsHigh) / narrow.height
        let shortRows = CGFloat(inkedRows(short, background: bg).count) / scale
        let longRows = CGFloat(inkedRows(long, background: bg).count) / scale
        #expect(shortRows > 4,
                "even the short run inked only \(Int(shortRows))pt of rows — the harness drew nothing")
        #expect(longRows < shortRows + 4,
                "a long noun grew the run from \(Int(shortRows))pt to \(Int(longRows))pt of inked rows — it is wrapping, and will push past the header row's pinned height")
    }
}

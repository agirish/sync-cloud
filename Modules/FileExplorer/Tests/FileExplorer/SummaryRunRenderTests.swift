import Testing
import SwiftUI
import AppKit
import Design
import DesignTestSupport
@testable import FileExplorer

/// `SummaryRun`'s one rule, in pixels: the colour is on the glyph and never on the words. Yellow
/// text without a pill's wash has little shape on a white card, so the tint goes on the glyph, a
/// non-text indicator answering to 3:1, and the words take the label hierarchy. Only a render can
/// hold that: tinting the count is a one-token change that alters no geometry or label, as is a
/// glyph that stops taking the tint. Two renders differing only in `color` and two only in `count`
/// must change disjoint, non-empty regions, a comparison that survives a font change.
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
        // A real window, as `OrganizeOverviewRenderTests` explains: without one the content
        // composites against the borderless window's own buffer and every comparison below reads
        // zero difference, whatever the code did. No `layoutIfNeeded()`: it disarms AppKit's
        // runaway guards.
        return ProbeRig(AnyView(subject), size: size).capture()
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

    /// Swapping the tint moves only glyph pixels; swapping the count moves only word pixels. Two
    /// saturated tints so the glyph diff can't be lost in anti-aliasing, and two one-digit counts
    /// (`monospacedDigit()` keeps their widths equal) so the label after the number stays put. A
    /// tinted count would push the colour diff into the count diff's columns. Both diffs must be
    /// non-empty first, or a view that painted nothing would pass.
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

    /// The label is drawn too, after the count. The test above compares the tint against the count
    /// only, so a run that dropped its noun would pass it. Two labels of clearly different length,
    /// so what is measured is the noun, not the spacing around it.
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

    /// A run stays on one line however long its noun, because it rides a row whose height
    /// `LensHeaderCard` pins. `lineLimit(1)` and `fixedSize()` hold that as a pair; either alone
    /// still keeps the row a row (one overflows, the other truncates), so this pins the pair. The
    /// canvas is narrower than the noun's natural length, the only condition where it could wrap.
    /// Inked rows, not `fittingSize`, because what must not appear is a second row of text.
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

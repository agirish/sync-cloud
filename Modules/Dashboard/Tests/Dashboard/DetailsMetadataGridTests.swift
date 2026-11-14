import AppKit
import Design
import SwiftUI
import Testing
@testable import Dashboard

/// The Info card's label column takes its widest label's width, at every text size, so no label
/// wraps ("Where it lives:" is wider than a fixed 80pt column at the default 13pt). Measured as
/// heights: given the same one-line value, the longest label lays out as tall as a short one; a
/// wrapped label adds a line.
@MainActor
@Suite struct DetailsMetadataGridTests {

    private static func height(_ lines: [DetailsMetadataLine], scale: CGFloat, width: CGFloat = 210) -> CGFloat {
        height(of: DetailsMetadataGrid(lines: lines), scale: scale, width: width)
    }

    private static func height(of view: some View, scale: CGFloat, width: CGFloat) -> CGFloat {
        let host = NSHostingView(rootView: view
            .frame(width: width)
            .environment(\.appFontScale, scale))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 400)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    /// Too narrow for both columns, each label goes above its value: at the inspector's 200pt
    /// minimum and the largest text, side by side would leave the values a few letters a line.
    /// Stacked there, side by side at the default width and size.
    @Test func aNarrowLargeCardStacksAndADefaultOneDoesNot() {
        let lines: [DetailsMetadataLine] = [.fact("Where it lives:", "In iCloud Drive, downloaded"),
                                            .divider, .fact("Kind:", "PDF document")]
        let grid = DetailsMetadataGrid(lines: lines)
        let largest = FontSize(percent: FontSize.maximumPercent).scale

        let narrow = Self.height(of: grid, scale: largest, width: 140)
        let narrowStacked = Self.height(of: grid.stacked, scale: largest, width: 140)
        let narrowColumns = Self.height(of: grid.columns, scale: largest, width: 140)
        #expect(narrowStacked != narrowColumns, "the two branches measure alike — this test cannot tell them apart")
        #expect(narrow == narrowStacked,
                "at 140pt and the largest text the card laid out \(narrow)pt; stacked is \(narrowStacked)pt, side by side \(narrowColumns)pt")

        let wide = Self.height(of: grid, scale: 1, width: 210)
        let wideStacked = Self.height(of: grid.stacked, scale: 1, width: 210)
        let wideColumns = Self.height(of: grid.columns, scale: 1, width: 210)
        #expect(wideStacked != wideColumns)
        #expect(wide == wideColumns,
                "at the default width and size the card stacked (\(wide)pt; side by side is \(wideColumns)pt)")
    }

    /// The rule's threshold: the widest label, the gap, and the value column's floor.
    @Test func theSideBySideWidthIsTheWidestLabelPlusAUsableValueColumn() {
        let short = DetailsMetadataGrid.columnsWidth(labels: ["Kind:"], scale: 1)
        let long = DetailsMetadataGrid.columnsWidth(labels: ["Kind:", "Where it lives:"], scale: 1)
        #expect(long > short)
        #expect(long == LabelMetrics.width(of: "Where it lives:", font: .body, scale: 1)
                + DetailsMetadataGrid.columnSpacing + DetailsMetadataGrid.minimumValueWidth)
    }

    @Test(arguments: [CGFloat(1), FontSize(percent: FontSize.maximumPercent).scale])
    func theLongestLabelDoesNotWrap(scale: CGFloat) {
        let short = Self.height([.fact("Kind:", "PDF")], scale: scale)
        let longest = Self.height([.fact("Where it lives:", "PDF")], scale: scale)
        #expect(longest == short, """
                at text scale \(scale), "Where it lives:" laid out \(longest)pt tall against \
                \(short)pt for "Kind:" — the label wrapped
                """)
        // The control: a value too long for its column does wrap, so the measurement can see a
        // second line.
        let wrapped = Self.height([.fact("Kind:", String(repeating: "Portable Document ", count: 6))],
                                  scale: scale)
        #expect(wrapped > short, "a long value did not wrap — the heights above prove nothing")
    }
}

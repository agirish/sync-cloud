import AppKit
import Design
import SwiftUI
import Testing
@testable import Dashboard

/// **The Info card's labels take their widest label's width, at every text size (BR17).**
///
/// They sat in a fixed 80pt column, and "Where it lives:" is 85.3pt at the default 13pt — so it
/// wrapped onto two lines at the default size. Measured as heights: a fact whose label is the
/// longest must lay out exactly as tall as one whose label is short, given the same one-line value.
/// A label that wrapped adds a line.
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

    /// **Too narrow for both columns, each label goes above its value.** The inspector's minimum
    /// width is 200pt, and the card's padding leaves this table 140pt of it; at the largest text
    /// size the label column took all but ~17pt and the values wrapped a few letters to a line.
    /// Measured against both branches drawn alone: the card must lay out as the stacked branch at
    /// that width and as the side-by-side one at the default inspector width and size.
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
        // The control: a value too long for its column DOES wrap, so the measurement can see a
        // second line when there is one.
        let wrapped = Self.height([.fact("Kind:", String(repeating: "Portable Document ", count: 6))],
                                  scale: scale)
        #expect(wrapped > short, "a long value did not wrap — the heights above prove nothing")
    }
}

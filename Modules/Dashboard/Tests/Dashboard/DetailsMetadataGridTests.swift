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
        let host = NSHostingView(rootView: DetailsMetadataGrid(lines: lines)
            .frame(width: width)
            .environment(\.appFontScale, scale))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 400)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
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

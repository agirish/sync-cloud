import AppKit
import SwiftUI
import Testing
import Design
@testable import FileExplorer

/// The action bar's summary changes on every click, so its width is reserved (a hidden twin) to keep
/// the buttons after it from moving under the cursor. Asserted on rendered pixels, since only a real
/// render shows the twin and the visible text agree.
@MainActor
@Suite(.serialized) struct PaneActionBarStabilityTests {

    private static let width: CGFloat = 900
    private static let height: CGFloat = 60

    private func bar(summary: String, showsCompare: Bool = true) -> some View {
        PaneActionBar(
            summaryText: summary,
            showsCompare: showsCompare,
            copyTitle: "Copy to OneDrive",
            moveTitle: "Move to OneDrive",
            copySymbol: TransferGlyph.copy,
            moveSymbol: TransferGlyph.move(toRight: true),
            onCompare: {}, onCopy: {}, onMove: {}, onDelete: {}, onClear: {}
        )
        // `.content`, not the bar itself: the glass capsule renders empty offscreen and takes its
        // content with it, so a snapshot of the whole bar shows only the stroke.
        .content
        .frame(width: Self.width)
        .padding(8)
    }

    /// Renders offscreen through a real `NSHostingView`, the way the app resolves dynamic colours
    /// and SF Symbols.
    private func render(_ view: some View) -> NSBitmapImageRep {
        let size = CGSize(width: Self.width + 16, height: Self.height)
        let subject = view
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light)
        // A blank rep would make every comparison match (`testTheComparisonCanActuallyFail`).
        return PixelDiff.render(subject, size: size)!
    }

    /// True when two renders are identical over a horizontal slice, given as fractions of the width.
    private func regionMatches(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep,
                               from: Double, to: Double) -> Bool {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else { return false }
        let x0 = Int(Double(a.pixelsWide) * from), x1 = Int(Double(a.pixelsWide) * to)
        for y in stride(from: 0, to: a.pixelsHigh, by: 2) {
            for x in stride(from: x0, to: x1, by: 2) {
                if a.colorAt(x: x, y: y) != b.colorAt(x: x, y: y) { return false }
            }
        }
        return true
    }

    /// The widest summary swing the bar can realistically show must leave every button where it
    /// was. The compared slice starts past the reserved summary zone, so the differing text can't
    /// mask a difference or manufacture one.
    @Test(.machinePinned(.pixelSampling)) func testButtonsHoldStillAcrossTheFullSummarySwing() {
        let summaries = [
            "1 selected",                 // no size at all — the shortest the bar ever shows
            "1 selected · 10.7 MB",       // a typical size
            "1 selected · 972.2 MB",      // the swing that would move Compare ~18pt
            "128 selected · 1.2 GB",      // three-digit count
            "3 selected · 999 bytes"      // the widest unit word
        ]
        let baseline = render(bar(summary: summaries[0]))
        for summary in summaries.dropFirst() {
            #expect(regionMatches(baseline, render(bar(summary: summary)), from: 0.35, to: 1.0),
                    "buttons moved for summary: \(summary)")
        }
    }

    /// Guards the guard: if the compared slice were blank or the renders degenerate, the test above
    /// would pass no matter what. Two genuinely different bars must not match over the same slice.
    @Test(.machinePinned(.pixelSampling)) func testTheComparisonCanActuallyFail() {
        let withCompare = render(bar(summary: "1 selected · 10.7 MB", showsCompare: true))
        let without = render(bar(summary: "1 selected · 10.7 MB", showsCompare: false))
        #expect(regionMatches(withCompare, without, from: 0.35, to: 1.0) == false,
                "the slice must be sensitive to a real layout change, or the stability test is vacuous")
    }

    /// The reserved zone must be wide enough that ordinary summaries aren't truncated: a reference
    /// string too narrow would stabilise the layout by clipping every label.
    @Test func testReferenceStringIsWiderThanRealisticSummaries() {
        let reference = PaneActionBar.summaryWidthReference
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let width = { (s: String) in (s as NSString).size(withAttributes: [.font: font]).width }

        for summary in ["1 selected", "1 selected · 972.2 MB", "128 selected · 1.2 GB", "3 selected · 999 bytes"] {
            #expect(width(summary) <= width(reference), "\(summary) would truncate")
        }
    }
}

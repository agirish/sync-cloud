import AppKit
import SwiftUI
import Testing
import Design
@testable import FileExplorer

/// The compare-pick bar must not grow with the filename: a long name would stretch it across the
/// window and over both panes' tab strips and breadcrumbs. The name has its own width ceiling, and
/// the instruction is composed around it so truncating the name can't truncate the words.
///
/// Measures the render, not the constant, for `PaneActionBarStabilityTests`' reason: a width
/// constant would only re-assert itself. That the bar takes layout space rather than floating over
/// the chrome is structural, in `mainContentView`.
@MainActor
@Suite(.serialized) struct ComparePickStripTests {

    private func strip(_ name: String) -> some View {
        // `.content`, not the bar: the shape-backed container renders empty offscreen and takes
        // its content with it, so a snapshot of the whole bar shows only the stroke.
        ComparePickStrip(fileName: name, onCancel: {}).content.padding(8)
    }

    private func fittingWidth(_ view: some View) -> CGFloat {
        let host = NSHostingView(rootView: AnyView(view))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.width
    }

    /// A long real filename, against a short one: the bar may grow by at most the name column.
    @Test(.machinePinned(.layoutMetrics)) func aLongFilenameCannotStretchTheBarPastItsNameColumn() {
        let short = fittingWidth(strip("a.pdf"))
        let real = fittingWidth(strip("Irrigation system check 10-10-2024 ( Clock C ) readvised new templet.3-18.pdf"))
        let absurd = fittingWidth(strip(String(repeating: "long-name-", count: 40) + ".pdf"))

        #expect(short > 200, "the fixture measured implausibly small — this check would be vacuous")
        #expect(real <= short + ComparePickStrip.nameWidth,
                "the reported filename grew the bar to \(real)pt against \(short)pt for a short one")
        #expect(absurd <= short + ComparePickStrip.nameWidth,
                "a pathological name grew the bar to \(absurd)pt — the name column has no ceiling")
        // And the ceiling is a ceiling, not a floor applied to everything: a short name is narrower.
        #expect(short < absurd, "every name renders at the same width — the name is not being drawn")
    }

    /// The instruction survives truncation, which a width ceiling alone doesn't buy: the words
    /// around the name are their own views, so a truncated name can't take "click another file"
    /// with it. Asserted on the composed sentence, since a SwiftUI `Text` can't be read back from a
    /// mounted view and the accessibility labels come back empty in tests.
    @Test func theInstructionIsNotInsideTheTruncatedRun() {
        let absurd = String(repeating: "long-name-", count: 40) + ".pdf"
        let described = ComparePickStrip(fileName: absurd, onCancel: {}).accessibilityDescription
        #expect(described.contains("Click another file"),
                "the instruction is missing from the bar's sentence: \(described)")
        #expect(described.contains("escape to cancel"), "the way out is not stated")
        #expect(described.contains(absurd),
                "the name arrived shortened — bounding it is the view's job, at the width it knows")
    }
}

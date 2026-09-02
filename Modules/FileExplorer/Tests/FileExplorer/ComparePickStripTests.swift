import AppKit
import SwiftUI
import Testing
import Design
@testable import FileExplorer

/// **The bar must not grow with the filename.** Reported from the running app: armed on
/// "Irrigation system check 10-10-2024 ( Clock C ) readvised new templet.3-18.pdf", the indicator
/// stretched the width of the window and drew over both panes' tab strips and breadcrumbs, with the
/// prompt, the tab titles and the crumbs superimposed and none of them readable.
///
/// Two things caused that and both are asserted here. The name had no width ceiling, so it pushed
/// everything after it out of the window; and the sentence had the name buried in the middle of it,
/// so truncating it would have truncated the instruction too. The name is bounded on its own now
/// and the words are composed around it.
///
/// Measuring the RENDER rather than the constant, for `PaneActionBarStabilityTests`' reason: a
/// width constant would only re-assert itself. The placement half — that the bar takes layout
/// space instead of floating over the chrome — is structural and lives in `mainContentView`.
@MainActor
@Suite(.serialized, .machinePinned(.pixelSampling)) struct ComparePickStripTests {

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

    /// The name that broke it, against a short one. The bar may grow by at most the name column.
    @Test func aLongFilenameCannotStretchTheBarPastItsNameColumn() {
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

    /// **The instruction survives the truncation**, which is the half a width ceiling alone does
    /// not buy. The words around the name are their own views, so a name long enough to truncate
    /// cannot take "click another file" with it — the first cut put the whole sentence in one
    /// `Text` with the name in the middle of it, where truncating the name truncates the
    /// instruction too.
    ///
    /// Asserted on the composed sentence rather than on the render: a SwiftUI `Text` cannot be read
    /// back off a mounted view, and a walk of the hosted view's accessibility labels came back
    /// empty — the test-blind channel this repo has hit before. The width half above IS measured
    /// on the render, so the two together cover it.
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

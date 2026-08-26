import AppKit
import SwiftUI
import Testing
@testable import Design

/// `InlineSpinner` replaces `ProgressView().controlSize(.small).scaleEffect(0.7)` at three row
/// sites, and the whole claim is that it is the same *size* drawn crisply rather than a smaller
/// spinner. Both halves of that need measuring: a footprint that drifts would shift every row the
/// spinner sits in, and it is the one thing a reviewer cannot check by reading the diff.
@Suite struct InlineSpinnerTests {

    @MainActor
    private func fitting<V: View>(_ view: V) -> CGSize {
        NSHostingView(rootView: view).fittingSize
    }

    /// **The old recipe and the new component must reserve exactly the same room.** Asserted
    /// against the recipe rather than against `16`, so this keeps meaning the right thing if AppKit
    /// ever resizes its controls — a literal would then be a second opinion rather than a check.
    ///
    /// This is the assertion that earned the suite: `scaleEffect` does not participate in layout,
    /// so the recipe reserves `.small`'s full box while drawing smaller, and the obvious
    /// `.controlSize(.mini)` swap measured 16 → 10. Three rows would have moved.
    @Test @MainActor func theFootprintMatchesTheRecipeItReplaces() {
        let old = fitting(ProgressView().controlSize(.small).scaleEffect(0.7))
        let new = fitting(InlineSpinner())
        #expect(old == new,
                "footprint moved \(old) → \(new); every row carrying this spinner shifts")
    }

    /// The *drawn* control is genuinely smaller than `.small` — that is the difference between
    /// drawing it small and resampling one drawn bigger. Measured without the frame, which exists
    /// only to hold the row's space open.
    @Test @MainActor func itIsDrawnSmallerThanTheSmallControlSize() {
        let small = fitting(ProgressView().controlSize(.small))
        let mini = fitting(ProgressView().controlSize(.mini))
        #expect(mini.width < small.width,
                "the mini spinner is \(mini.width) against .small's \(small.width) — no longer the smaller size")
        #expect(fitting(InlineSpinner()) == small,
                "the component should reserve exactly what .small does")
    }

    /// No `scaleEffect` anywhere in the component. The resample is the defect being fixed, so a
    /// later "just make it a bit smaller" that reaches for a scale would quietly reinstate it.
    @Test func theComponentDoesNotScaleItsWayToSize() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()                 // …/Modules/Design
            .appendingPathComponent("Sources/Design/InlineSpinner.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        #expect(text.contains("struct InlineSpinner"), "that is not the component's source")
        // Only the doc comment may name it — that is where the defect is explained.
        let code = text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("///") }
        #expect(!code.contains { $0.contains("scaleEffect") },
                "InlineSpinner resamples itself — the exact thing it replaced")
    }
}

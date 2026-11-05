import AppKit
import SwiftUI
import Testing
@testable import Design

/// `InlineSpinner` stands in for `ProgressView().controlSize(.small).scaleEffect(0.7)` in rows: the
/// same footprint, drawn crisply at a smaller size instead of resampled. Both halves are measured,
/// because a footprint that drifts shifts every row the spinner sits in, and reading the code
/// can't show it.
@Suite struct InlineSpinnerTests {

    @MainActor
    private func fitting<V: View>(_ view: V) -> CGSize {
        NSHostingView(rootView: view).fittingSize
    }

    /// The recipe and the component must reserve exactly the same room. Checked against the
    /// recipe, not a literal `16`, so it stays right if AppKit resizes its controls.
    ///
    /// `scaleEffect` takes no part in layout, so the recipe reserves `.small`'s full box while
    /// drawing smaller; a plain `.controlSize(.mini)` swap shrinks the footprint and moves rows.
    @Test @MainActor func theFootprintMatchesTheRecipeItReplaces() {
        let old = fitting(ProgressView().controlSize(.small).scaleEffect(0.7))
        let new = fitting(InlineSpinner())
        #expect(old == new,
                "footprint moved \(old) → \(new); every row carrying this spinner shifts")
    }

    /// The drawn control is smaller than `.small`, which is the difference between drawing it small
    /// and resampling one drawn bigger. Measured without the frame, which only holds the row's space
    /// open.
    @Test @MainActor func itIsDrawnSmallerThanTheSmallControlSize() {
        let small = fitting(ProgressView().controlSize(.small))
        let mini = fitting(ProgressView().controlSize(.mini))
        #expect(mini.width < small.width,
                "the mini spinner is \(mini.width) against .small's \(small.width) — no longer the smaller size")
        #expect(fitting(InlineSpinner()) == small,
                "the component should reserve exactly what .small does")
    }

    /// No `scaleEffect` anywhere in the component's code: a "make it a bit smaller" that reaches
    /// for a scale would bring the blurry resample back.
    @Test func theComponentDoesNotScaleItsWayToSize() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()                 // …/Modules/Design
            .appendingPathComponent("Sources/Design/InlineSpinner.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        #expect(text.contains("struct InlineSpinner"), "that is not the component's source")
        // Only the doc comment may name it, to explain why it isn't used.
        let code = text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("///") }
        #expect(!code.contains { $0.contains("scaleEffect") },
                "InlineSpinner resamples itself — the exact thing it replaced")
    }
}

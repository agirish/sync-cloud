import Testing
import Foundation
@testable import FileExplorer

/// **The results panel must declare no drop shadow, because its window has nowhere to put one.**
///
/// `CommandPalettePanelController.place()` sizes the panel window to exactly this list — the
/// field's width by the height `onHeight` reports — so there is no transparent margin for a shadow
/// to fall into. A `.shadow` here is therefore clipped to the window's **rectangle**, and what
/// survives is the part filling the gaps the card's **rounded** corners leave in that rectangle:
/// dark notches at the four corners, and nothing below the card where a shadow belongs.
///
/// That is not a prediction. It shipped in v4.2 and was measured on the running app against the
/// content immediately outside the panel — corners **14–26 luminance units darker**, strip below
/// the panel flat at 255. `NSWindow.hasShadow` does not rescue it either: flipping it to `true` on
/// the real code path moved the four deltas by less than a unit.
///
/// **A source scan, and it pins a spelling rather than the pixels** — deliberately, because the
/// pixel version cannot exist here. The card is a `groundedGlassCard`, and glass renders nothing
/// offscreen, so a render-and-sample test would pass vacuously on a blank bitmap. The alternative
/// to this scan is nothing at all standing in front of a regression whose whole character is that
/// it looks like a reasonable line of design intent. The failure message says what re-adding it
/// actually does, so whoever trips this reads the consequence rather than "a string moved".
@Suite struct GoToResultsPanelShadowTests {

    private func source() throws -> String {
        let url = URL(fileURLWithPath: #filePath)              // …/Tests/FileExplorer/<this>.swift
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FileExplorer/GoToResultsPanel.swift")
        let text = try #require(try? String(contentsOf: url, encoding: .utf8),
                                "cannot read GoToResultsPanel.swift — the check below would be vacuous")
        try #require(text.count > 500, "GoToResultsPanel.swift is implausibly short")
        return text
    }

    /// Comments stripped, because the reasoning above the `groundedGlassCard` call quotes the very
    /// modifier this forbids — a scan that read the explanation instead of the code would fail on a
    /// correct file, which is the fastest way to teach the next person to delete the test.
    private func codeOnly(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    @Test func theResultsPanelDeclaresNoShadow() throws {
        let code = codeOnly(try source())
        // Non-vacuity: the scan must still be looking at a real view body, or "no `.shadow(`" is
        // true of an empty string too.
        try #require(code.contains("groundedGlassCard"),
                     "the card's own edge treatment is gone — this scan is no longer reading the surface it guards")
        #expect(!code.contains(".shadow("),
                "GoToResultsPanel declares a shadow again. The panel window is sized to exactly this list, so the blur is clipped to the window RECTANGLE and all that renders is dark notches in the card's rounded corners — measured at 14–26 luminance units on v4.2, with no shadow below the card at all. NSWindow.hasShadow does not help. See the reasoning above `groundedGlassCard`.")
    }

    /// The scan can actually fail — the guard against a matcher that has quietly stopped matching.
    @Test func theShadowScanCanActuallyFail() throws {
        let mutated = codeOnly(try source())
            .replacingOccurrences(of: ".groundedGlassCard(level: glassLevel)",
                                  with: ".groundedGlassCard(level: glassLevel)\n        .shadow(color: .black.opacity(0.3), radius: 24, y: 6)")
        #expect(mutated.contains(".shadow("),
                "the matcher no longer sees a shadow that IS there, so the test above proves nothing")
    }
}

import Testing
import Foundation
@testable import FileExplorer

/// The results panel must declare no drop shadow, because its window has nowhere to put one.
///
/// `CommandPalettePanelController.place()` sizes the panel window to exactly this list (the field's
/// width by the height `onHeight` reports), so there is no transparent margin for a shadow to fall
/// into. A `.shadow` here is clipped to the window's rectangle, and what survives fills the gaps
/// the card's rounded corners leave in it: dark notches at the four corners (14–26 luminance units
/// darker than the content outside), and nothing below the card where a shadow belongs.
/// `NSWindow.hasShadow = true` doesn't rescue it either.
///
/// A source scan, pinning a spelling rather than the pixels, because the pixel version cannot exist
/// here: the card is a `groundedGlassCard`, and glass renders nothing offscreen, so a
/// render-and-sample test would pass vacuously on a blank bitmap. The failure message says what
/// re-adding the shadow does, so whoever trips this reads the consequence rather than "a string
/// moved".
@Suite struct GoToResultsPanelShadowTests {

    /// Comments stripped, because the reasoning above the `groundedGlassCard` call quotes the very
    /// modifier this forbids; a scan that read the explanation instead of the code would fail on a
    /// correct file.
    @Test func theResultsPanelDeclaresNoShadow() throws {
        let code = SourceText.codeOnly(try SourceText.fileExplorer("GoToResultsPanel.swift"))
        // Non-vacuity: the scan must still be looking at a real view body, or "no `.shadow(`" is
        // true of an empty string too.
        try #require(code.contains("groundedGlassCard"),
                     "the card's own edge treatment is gone — this scan is no longer reading the surface it guards")
        #expect(!code.contains(".shadow("),
                "GoToResultsPanel declares a shadow again. The panel window is sized to exactly this list, so the blur is clipped to the window RECTANGLE and all that renders is dark notches in the card's rounded corners — measured at 14–26 luminance units on v4.2, with no shadow below the card at all. NSWindow.hasShadow does not help. See the reasoning above `groundedGlassCard`.")
    }
}

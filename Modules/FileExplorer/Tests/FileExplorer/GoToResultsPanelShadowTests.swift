import Testing
import Foundation
@testable import FileExplorer

/// The results panel must declare no drop shadow: `CommandPalettePanelController.place()` sizes the
/// panel window to exactly this list, so a `.shadow` is clipped to the window's rectangle and shows
/// only as dark notches in the card's rounded corners. `NSWindow.hasShadow = true` doesn't help.
///
/// A source scan, because the card is a `groundedGlassCard` and glass renders nothing offscreen, so
/// a render-and-sample test would pass vacuously on a blank bitmap.
@Suite struct GoToResultsPanelShadowTests {

    /// Comments stripped: the reasoning above the `groundedGlassCard` call quotes the modifier this
    /// forbids.
    @Test func theResultsPanelDeclaresNoShadow() throws {
        let code = SourceText.codeOnly(try SourceText.fileExplorer("GoToResultsPanel.swift"))
        // Non-vacuity: "no `.shadow(`" is true of an empty string too.
        try #require(code.contains("groundedGlassCard"),
                     "the card's own edge treatment is gone — this scan is no longer reading the surface it guards")
        #expect(!code.contains(".shadow("),
                "GoToResultsPanel declares a shadow again. The panel window is sized to exactly this list, so the blur is clipped to the window RECTANGLE and all that renders is dark notches in the card's rounded corners — measured at 14–26 luminance units on v4.2, with no shadow below the card at all. NSWindow.hasShadow does not help. See the reasoning above `groundedGlassCard`.")
    }
}

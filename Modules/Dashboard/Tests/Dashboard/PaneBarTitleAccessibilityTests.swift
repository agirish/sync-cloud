import Testing
import Foundation
@testable import Dashboard

/// The word under a bar pill is hidden from VoiceOver, because the pill already carries the same
/// label. `accessibilityElement(children: .contain)` alone doesn't do that: it keeps children as
/// separate elements, so every titled item would be read twice ("Scan, button. Scan.").
///
/// A source scan, because without an assistive client AppKit builds no accessibility tree and any
/// assertion over it passes vacuously. It pins a spelling, not a behaviour: it can't tell that
/// `accessibilityHidden(true)` is on the word rather than elsewhere in the function.
@Suite struct PaneBarTitleAccessibilityTests {

    /// The scan. A renamed function can't make it vacuous: `functionBody` `#require`s the signature.
    @Test func theWordUnderAPillIsHiddenFromVoiceOver() throws {
        let body = try PaneBarInkChokePointTests.functionBody(
            "private func titledItem(_ item: PaneBarItem, controlSize: ControlSize,")

        // The word is drawn at all, or the rest is about nothing.
        #expect(body.contains("Text(title)"),
                "titledItem no longer draws the word, so this scan is vacuous and the titled ladder prices something that is not on screen")

        #expect(body.contains("accessibilityHidden(true)"),
                "the word under the pill is not hidden from VoiceOver, so every titled bar item is read twice — the pill's label, then the same word again")

        // `.contain` stays: it leaves the pill its own focusable element with button traits. It
        // just doesn't suppress the word.
        #expect(body.contains("accessibilityElement(children: .contain)"),
                "the container went with the fix — the pill needs to stay its own element, with its button traits")
    }
}

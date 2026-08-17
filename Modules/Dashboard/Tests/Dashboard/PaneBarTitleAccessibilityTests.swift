import Testing
import Foundation
@testable import Dashboard

/// The word under a bar pill must be **hidden from VoiceOver**, because the pill already carries the
/// same label.
///
/// ## Why this is a source scan and not a behavioural test
///
/// There is no accessibility tree to read in a unit test: without an assistive client attached,
/// AppKit builds no `NSAccessibility` hierarchy, so anything asking "what would VoiceOver say" comes
/// back empty and every assertion over it passes vacuously. That is recorded in
/// `docs/flaky-tests.md` and it has already cost this repo a set of caption tests that answered
/// nothing. A scan is the honest instrument here, and its limits are real: **it pins a spelling, not
/// a behaviour.** It cannot tell that `accessibilityHidden(true)` is attached to the word rather
/// than to something else in the same function, only that the modifier is present in it.
///
/// ## What it caught
///
/// `titledItem` carried a comment saying the word repeats the pill's label "so reading both would
/// say everything twice" — and then applied `accessibilityElement(children: .contain)`, which makes
/// the item a *container* and **keeps** its children as separate elements. Contain is not combine
/// and it is not hidden: VoiceOver read every titled bar item twice ("Scan, button. Scan.") for as
/// long as the comment said it did not. A comment describing an intent the code does not implement
/// is worse than no comment, because it stops the next reader looking.
@Suite struct PaneBarTitleAccessibilityTests {

    /// The scan, with a positive control so a renamed function cannot make it vacuous — the control
    /// is `functionBody` itself, which `#require`s the signature and fails loudly when it is gone.
    @Test func theWordUnderAPillIsHiddenFromVoiceOver() throws {
        let body = try PaneBarInkChokePointTests.functionBody(
            "private func titledItem(_ item: PaneBarItem, controlSize: ControlSize,")

        // Present at all: if the word stopped being drawn, the rest of this test would be about
        // nothing, and the ladder's titled rungs would be measuring a word that is not there.
        #expect(body.contains("Text(title)"),
                "titledItem no longer draws the word, so this scan is vacuous and the titled ladder prices something that is not on screen")

        #expect(body.contains("accessibilityHidden(true)"),
                "the word under the pill is not hidden from VoiceOver, so every titled bar item is read twice — the pill's label, then the same word again")

        // `.contain` is kept deliberately: it leaves the pill its own focusable element with its
        // button traits. What must NOT come back is relying on it to suppress the word, which is
        // what the old comment claimed it did.
        #expect(body.contains("accessibilityElement(children: .contain)"),
                "the container went with the fix — the pill needs to stay its own element, with its button traits")
    }
}

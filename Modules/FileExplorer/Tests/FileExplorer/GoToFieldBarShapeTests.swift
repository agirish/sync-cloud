import Testing
import Foundation
@testable import FileExplorer

/// The toolbar item's content must have one root view across both states.
///
/// If `GoToFieldBar.body` returned the pill from one branch of a `switch` and the field from the
/// other, with nothing above them, the item's content type would change when the field closed and
/// SwiftUI would tear the hosted view down without rebuilding it: after Escape
/// `NSToolbar.items[2].view` goes nil, the item still counts as visible, the row draws nothing
/// where the control was, and a window resize doesn't bring it back. A container around the
/// conditional keeps the view alive.
///
/// This is a source scan, and it pins a spelling rather than the behaviour: a `ToolbarItem` cannot
/// be mounted from a test, and `NSToolbarItem.view` is only observable in a real window. The
/// alternative is nothing standing in front of a regression that costs the user the control
/// entirely. The message names the symptom so whoever trips it knows what they are looking at.
@Suite struct GoToFieldBarShapeTests {

    private func source() throws -> String {
        let url = URL(fileURLWithPath: #filePath)              // …/Tests/FileExplorer/<this>.swift
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FileExplorer/GoToFieldBar.swift")
        let text = try #require(try? String(contentsOf: url, encoding: .utf8),
                                "cannot read GoToFieldBar.swift — the check below would be vacuous")
        try #require(text.count > 500, "GoToFieldBar.swift is implausibly short")
        return text
    }

    @Test func theItemsContentHasOneRootViewInBothStates() throws {
        let text = try source()
        let body = try #require(text.range(of: "public var body: some View {"))
        // Comments stripped first: the explanation of this rule sits inside `body` and is long
        // enough to push the code out of any fixed window, and a scan that reads the comment and
        // not the code passes on a broken file.
        let head = text[body.upperBound...].prefix(2000)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        // The first view constructed in `body` must be a container, not the `switch` itself.
        let switchIndex = try #require(head.range(of: "switch mode"))
        let containerIndex = try #require(head.range(of: "HStack"),
                                          "`body` no longer opens with a container — if it returns the pill from one branch and the field from the other, the toolbar item's view goes NIL when the field closes and the control disappears from the row")
        #expect(containerIndex.lowerBound < switchIndex.lowerBound,
                "the state switch is the ROOT of the toolbar item's content again — closing the field will leave NSToolbarItem.view nil and the control will vanish from the toolbar")
    }

    /// The caret claim waits between attempts. A bare `DispatchQueue.main.async` retry is not a
    /// retry, because blocks queued during a main-queue drain run in that drain: every attempt is
    /// spent before the field is in a window, it logs `claimFocus GAVE UP — never mounted`, and ⌘K
    /// opens a field with no caret.
    ///
    /// A source scan again, for the same reason as above: `makeFirstResponder` on a toolbar-hosted
    /// field cannot be reached from a test host. The panel's own pacing is asserted behaviourally
    /// (`theAnchorKeepsLookingAcrossRunloopTurnsRatherThanSpendingEveryRetryAtOnce` in
    /// `CommandPalettePanelTests`), so the rule is pinned once for real and once by spelling.
    @Test func theCaretClaimRetriesOnADelayRatherThanInTheSameRunloopTurn() throws {
        let text = try source()
        let claim = try #require(text.range(of: "private func claimFocus("))
        let body = String(text[claim.upperBound...].prefix(900))
        #expect(!body.contains("DispatchQueue.main.async {"),
                "the caret claim retries with a bare `async` — every attempt runs in one runloop turn, before the field is mounted, and \u{2318}K opens a field with no caret")
        #expect(body.contains("DispatchQueue.main.asyncAfter("),
                "the caret claim no longer waits between attempts")
    }
}

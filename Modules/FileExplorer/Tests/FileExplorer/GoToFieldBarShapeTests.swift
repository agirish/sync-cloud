import Testing
import Foundation
@testable import FileExplorer

/// **The toolbar item's content must have ONE root view across both states.**
///
/// This guards a defect that no green suite could see and that reported itself as the control
/// simply not being there. `GoToFieldBar.body` returned the pill from one branch of a `switch` and
/// the field from the other, with nothing above them — so the item's content type changed when the
/// field closed, and SwiftUI tore the hosted view down without rebuilding it. Measured in the
/// running app: after Escape, `NSToolbar.items[2].view` was **nil**, the item still counted as
/// visible, the row drew nothing where the control had been, and a window resize did not bring it
/// back. Wrapping the conditional in a container fixed it — same probe, `view` back at 137.5×34.
///
/// **This is a source scan, and it pins a spelling rather than the behaviour** — a `ToolbarItem`
/// cannot be mounted from a test, and `NSToolbarItem.view` is only observable in a real window. It
/// is here because the alternative is nothing at all standing in front of a regression that costs
/// the user the control entirely. The message names the symptom so whoever trips it knows what they
/// are looking at rather than just that a string moved.
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
        // Comments stripped first: the explanation of this very rule sits inside `body` and is
        // long enough to push the code out of any fixed window — a scan that reads the comment and
        // not the code is a scan that passes on a broken file.
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

    /// **The caret claim waits between attempts.** Same defect as the panel's anchor, on the other
    /// half of the same open: a bare `DispatchQueue.main.async` retry is not a retry, because
    /// blocks queued during a main-queue drain run in that drain — measured in the running app on
    /// 2026-08-19, all three attempts were spent before the field was in a window and it logged
    /// `claimFocus GAVE UP — never mounted`. ⌘K opened a field with no caret.
    ///
    /// A source scan again, and for the same reason as above: `makeFirstResponder` on a toolbar-
    /// hosted field cannot be reached from a test host. The panel's own pacing IS asserted
    /// behaviourally — `theAnchorKeepsLookingAcrossRunloopTurnsRatherThanSpendingEveryRetryAtOnce`
    /// in `CommandPalettePanelTests` — so the rule is pinned once for real and once by spelling.
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

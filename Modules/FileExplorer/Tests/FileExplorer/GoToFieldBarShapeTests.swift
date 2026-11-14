import Testing
import Foundation
@testable import FileExplorer

/// The toolbar item's content must have one root view across both states. If `GoToFieldBar.body`
/// returned the pill from one `switch` branch and the field from the other, the content type would
/// change when the field closed and SwiftUI would tear the hosted view down without rebuilding it:
/// `NSToolbarItem.view` goes nil and the control vanishes, even across a window resize. A container
/// around the conditional keeps the view alive.
///
/// A source scan pinning a spelling: a `ToolbarItem` cannot be mounted from a test, and
/// `NSToolbarItem.view` is only observable in a real window.
@Suite struct GoToFieldBarShapeTests {

    private func source() throws -> String { try SourceText.fileExplorer("GoToFieldBar.swift") }

    @Test func theItemsContentHasOneRootViewInBothStates() throws {
        // Comments stripped first: a scan that read the long explanation inside `body` rather than
        // the code would pass on a broken file.
        let head = try SourceText.body(of: "public var body: some View {", in: try source())
        let switchIndex = try #require(head.range(of: "switch mode"))
        let containerIndex = try #require(head.range(of: "HStack"),
                                          "`body` no longer opens with a container — if it returns the pill from one branch and the field from the other, the toolbar item's view goes NIL when the field closes and the control disappears from the row")
        #expect(containerIndex.lowerBound < switchIndex.lowerBound,
                "the state switch is the ROOT of the toolbar item's content again — closing the field will leave NSToolbarItem.view nil and the control will vanish from the toolbar")
    }

    /// The caret claim waits between attempts. A bare `DispatchQueue.main.async` retry is not a
    /// retry: blocks queued during a main-queue drain run in that drain, so every attempt is spent
    /// before the field is in a window and ⌘K opens a field with no caret.
    ///
    /// A source scan: `makeFirstResponder` on a toolbar-hosted field cannot be reached from a test
    /// host. The panel's own pacing is asserted behaviourally
    /// (`theAnchorKeepsLookingAcrossRunloopTurnsRatherThanSpendingEveryRetryAtOnce`).
    @Test func theCaretClaimRetriesOnADelayRatherThanInTheSameRunloopTurn() throws {
        let body = try SourceText.body(of: "private func claimFocus(", in: try source())
        #expect(!body.contains("DispatchQueue.main.async {"),
                "the caret claim retries with a bare `async` — every attempt runs in one runloop turn, before the field is mounted, and \u{2318}K opens a field with no caret")
        #expect(body.contains("DispatchQueue.main.asyncAfter("),
                "the caret claim no longer waits between attempts")
    }
}

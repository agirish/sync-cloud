import Testing
import Foundation
import Sync
@testable import FileExplorer

/// What Space previews when it arrives at the Differences table.
///
/// `CurrentSelectionTests` pins the rule's arithmetic; these pin the *composition* — which surface
/// this handler asks about, and how it reads its own selection. The reported bug was never in the
/// arithmetic, so arithmetic tests alone would have passed against the broken app. A mounted
/// key-window test is not available (the test host cannot make a window key), which makes this
/// seam the closest thing to an end-to-end assertion.
@Suite struct DifferencesSpaceQuickLookTests {

    private func diff(_ name: String, action: FileDifference.SyncAction = .copyToRight) -> FileDifference {
        FileDifference(
            relativePath: name,
            leftItemPath: "/left/\(name)",
            rightItemPath: "/right/\(name)",
            type: .missingOnRight,
            action: action,
            description: "test")
    }

    private func target(lastInteracted: SelectionSurface?,
                        left: Set<String> = [],
                        right: Set<String> = [],
                        rows: [FileDifference] = [],
                        selection: Set<FileDifference.ID> = []) -> String? {
        DifferencesQuery.spaceQuickLookTarget(
            lastInteracted: lastInteracted, leftSelection: left, rightSelection: right,
            rows: rows, selection: selection)
    }

    /// THE BUG, at the seam that actually receives the key event: a pane selection and a
    /// Differences selection both exist, the user last clicked in a pane, and Space must preview
    /// the pane's file even though this handler belongs to the table.
    @Test func previewsThePaneFileWhenThePaneWasTouchedLast() {
        let row = diff("a.txt")
        #expect(target(lastInteracted: .pane,
                       left: ["/left/chosen.txt"],
                       rows: [row], selection: [row.id]) == "/left/chosen.txt")
    }

    /// The mirror, and the case that must not regress: working in the table previews its own row.
    @Test func previewsItsOwnRowWhenTheTableWasTouchedLast() {
        let row = diff("a.txt")
        #expect(target(lastInteracted: .differences,
                       left: ["/left/chosen.txt"],
                       rows: [row], selection: [row.id]) == "/left/a.txt")
    }

    /// `reviewSourcePath` follows the action, so a copy-to-left row previews the RIGHT side. Pins
    /// that this handler previews the source, not blindly the left path.
    @Test func previewsTheSourceSideForACopyToLeftRow() {
        let row = diff("a.txt", action: .copyToLeft)
        #expect(target(lastInteracted: .differences, rows: [row], selection: [row.id]) == "/right/a.txt")
    }

    /// SwiftUI's `Table` does not prune its selection binding when rows vanish (measured), so a
    /// difference that syncs away leaves a stale id behind. That must not preview a row the user
    /// can no longer see — it falls through to the pane.
    @Test func aStaleSelectedIdFallsThroughToThePane() {
        let vanished = diff("gone.txt")
        #expect(target(lastInteracted: .differences,
                       left: ["/left/still-here.txt"],
                       rows: [], selection: [vanished.id]) == "/left/still-here.txt")
    }

    /// ...and with nothing left to fall through to, it previews nothing, which the caller turns
    /// into `.ignored` so Space stays available.
    @Test func aStaleSelectedIdWithNoPaneSelectionPreviewsNothing() {
        let vanished = diff("gone.txt")
        #expect(target(lastInteracted: .differences, rows: [], selection: [vanished.id]) == nil)
    }

    /// The topmost row of a multi-row selection wins — `rows` is already the filtered+sorted table,
    /// so this is the row the user sees first, not an arbitrary `Set` element.
    @Test func aMultiRowSelectionPreviewsTheTopmostVisibleRow() {
        let first = diff("a.txt"), second = diff("b.txt"), third = diff("c.txt")
        #expect(target(lastInteracted: .differences,
                       rows: [first, second, third],
                       selection: [third.id, second.id]) == "/left/b.txt")
    }

    /// Nothing selected anywhere.
    @Test func nothingSelectedPreviewsNothing() {
        #expect(target(lastInteracted: nil) == nil)
        #expect(target(lastInteracted: .pane) == nil)
        #expect(target(lastInteracted: .differences) == nil)
    }

    /// The right pane is honoured here — unlike the Tidy rail, this table only ever renders in
    /// Compare (`.differences` maps to `.compare`), so there is no hidden pane to suppress.
    @Test func theRightPaneCountsBecauseThisTableIsCompareOnly() {
        #expect(target(lastInteracted: .pane, right: ["/right/chosen.txt"]) == "/right/chosen.txt")
    }
}

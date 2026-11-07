import Testing
import Foundation
import Sync
@testable import FileExplorer

/// What Space previews when it arrives at the Differences table.
///
/// `CurrentSelectionTests` pins the rule's arithmetic; these pin the composition: which surface
/// this handler asks about, and how it reads its own selection. The test host can't make a window
/// key, so this seam is the closest thing to an end-to-end check.
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

    /// Both a pane and a Differences selection exist and the user last clicked in the pane: Space
    /// previews the pane's file, even though this handler belongs to the table.
    @Test func previewsThePaneFileWhenThePaneWasTouchedLast() {
        let row = diff("a.txt")
        #expect(target(lastInteracted: .pane,
                       left: ["/left/chosen.txt"],
                       rows: [row], selection: [row.id]) == "/left/chosen.txt")
    }

    /// The mirror: working in the table previews its own row.
    @Test func previewsItsOwnRowWhenTheTableWasTouchedLast() {
        let row = diff("a.txt")
        #expect(target(lastInteracted: .differences,
                       left: ["/left/chosen.txt"],
                       rows: [row], selection: [row.id]) == "/left/a.txt")
    }

    /// `reviewSourcePath` follows the action, so a copy-to-left row previews the right side: the
    /// source, not always the left path.
    @Test func previewsTheSourceSideForACopyToLeftRow() {
        let row = diff("a.txt", action: .copyToLeft)
        #expect(target(lastInteracted: .differences, rows: [row], selection: [row.id]) == "/right/a.txt")
    }

    /// SwiftUI's `Table` does not prune its selection binding when rows vanish, so a difference
    /// that syncs away leaves a stale id. That must not preview a row the user can no longer see;
    /// it falls through to the pane.
    @Test func aStaleSelectedIdFallsThroughToThePane() {
        let vanished = diff("gone.txt")
        #expect(target(lastInteracted: .differences,
                       left: ["/left/still-here.txt"],
                       rows: [], selection: [vanished.id]) == "/left/still-here.txt")
    }

    /// With nothing to fall through to, it previews nothing, which the caller turns into
    /// `.ignored` so Space stays available.
    @Test func aStaleSelectedIdWithNoPaneSelectionPreviewsNothing() {
        let vanished = diff("gone.txt")
        #expect(target(lastInteracted: .differences, rows: [], selection: [vanished.id]) == nil)
    }

    /// The topmost row of a multi-row selection wins: `rows` is the filtered, sorted table, so
    /// this is the row the user sees first, not an arbitrary `Set` element.
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

    /// The right pane counts here: unlike the single-source rail, this table renders only in
    /// Compare (`.differences` maps to `.compare`), so there is no hidden pane to suppress.
    @Test func theRightPaneCountsBecauseThisTableIsCompareOnly() {
        #expect(target(lastInteracted: .pane, right: ["/right/chosen.txt"]) == "/right/chosen.txt")
    }
}

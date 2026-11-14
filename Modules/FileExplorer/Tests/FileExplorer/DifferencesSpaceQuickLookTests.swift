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

    struct Case: Sendable, CustomTestStringConvertible {
        let testDescription: String
        var lastInteracted: SelectionSurface?
        var left: Set<String> = []
        var right: Set<String> = []
        /// The table's rows, top to bottom, by name.
        var rows: [String] = []
        var action: FileDifference.SyncAction = .copyToRight
        /// Selected rows by name; a name not in `rows` is a stale id for a row that synced away.
        var selected: [String] = []
        let expected: String?
    }

    static let cases: [Case] = [
        // Both a pane and a Differences selection exist and the user last clicked in the pane:
        // Space previews the pane's file, even though this handler belongs to the table.
        Case(testDescription: "the pane was touched last", lastInteracted: .pane,
             left: ["/left/chosen.txt"], rows: ["a.txt"], selected: ["a.txt"],
             expected: "/left/chosen.txt"),
        // The mirror: working in the table previews its own row.
        Case(testDescription: "the table was touched last", lastInteracted: .differences,
             left: ["/left/chosen.txt"], rows: ["a.txt"], selected: ["a.txt"],
             expected: "/left/a.txt"),
        // `reviewSourcePath` follows the action, so a copy-to-left row previews the right side:
        // the source, not always the left path.
        Case(testDescription: "a copy-to-left row", lastInteracted: .differences,
             rows: ["a.txt"], action: .copyToLeft, selected: ["a.txt"], expected: "/right/a.txt"),
        // SwiftUI's `Table` does not prune its selection binding when rows vanish, so a difference
        // that syncs away leaves a stale id. That must not preview a row the user can no longer
        // see; it falls through to the pane.
        Case(testDescription: "a stale id falls through to the pane", lastInteracted: .differences,
             left: ["/left/still-here.txt"], selected: ["gone.txt"],
             expected: "/left/still-here.txt"),
        // With nothing to fall through to, it previews nothing, which the caller turns into
        // `.ignored` so Space stays available.
        Case(testDescription: "a stale id and no pane selection", lastInteracted: .differences,
             selected: ["gone.txt"], expected: nil),
        // The topmost row of a multi-row selection wins: `rows` is the filtered, sorted table, so
        // this is the row the user sees first, not an arbitrary `Set` element.
        Case(testDescription: "a multi-row selection", lastInteracted: .differences,
             rows: ["a.txt", "b.txt", "c.txt"], selected: ["c.txt", "b.txt"],
             expected: "/left/b.txt"),
        // Nothing selected anywhere.
        Case(testDescription: "nothing selected, no surface", lastInteracted: nil, expected: nil),
        Case(testDescription: "nothing selected, pane", lastInteracted: .pane, expected: nil),
        Case(testDescription: "nothing selected, table", lastInteracted: .differences, expected: nil),
        // The right pane counts here: unlike the single-source rail, this table renders only in
        // Compare (`.differences` maps to `.compare`), so there is no hidden pane to suppress.
        Case(testDescription: "the right pane counts", lastInteracted: .pane,
             right: ["/right/chosen.txt"], expected: "/right/chosen.txt"),
    ]

    @Test(arguments: cases)
    func spaceTarget(_ c: Case) {
        let rows = c.rows.map { name in
            FileDifference(relativePath: name, leftItemPath: "/left/\(name)",
                           rightItemPath: "/right/\(name)", type: .missingOnRight,
                           action: c.action, description: "test")
        }
        // A selected name with no row gets an id no row has: the stale id.
        let selection = Set(c.selected.map { name in rows.first { $0.relativePath == name }?.id ?? UUID() })
        #expect(DifferencesQuery.spaceQuickLookTarget(
            lastInteracted: c.lastInteracted, leftSelection: c.left, rightSelection: c.right,
            rows: rows, selection: selection) == c.expected)
    }
}

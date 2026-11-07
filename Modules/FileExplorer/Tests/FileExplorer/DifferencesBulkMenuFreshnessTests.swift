import Testing
import Foundation
@testable import FileExplorer

/// A menu item may not carry the rows it was built from. The bulk context menu's buttons resolve
/// their rows from ids when they fire: an open NSMenu outlives the table state, so a scan landing
/// or a row's action flipping behind it would leave the click acting on the old table.
/// `DifferencesView` applies the same rule at `focusedSceneValue` and in `runCopyOrMove`.
///
/// `DifferencesShortcutRulesTests` covers the rules; this pins that the view calls them at fire
/// time. A source scan: it proves the action bodies name `ids` and not the snapshot bindings. That
/// `bulkTransfer` resolves live rows is
/// `transferItemsReturnsTheCurrentRowNotTheOneTheCallerRemembers`' job.
@Suite struct DifferencesBulkMenuFreshnessTests {

    private static func viewSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)          // …/Tests/FileExplorer/<this>.swift
            .deletingLastPathComponent()                    // …/Tests/FileExplorer
            .deletingLastPathComponent()                    // …/Tests
            .deletingLastPathComponent()                    // …/FileExplorer
            .appendingPathComponent("Sources/FileExplorer/DifferencesView.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The body of `bulkMenu`, from its signature to the start of the next `private func`.
    private static func bulkMenuBody() throws -> String {
        let source = try viewSource()
        let start = try #require(source.range(of: "private func bulkMenu("),
                                 "bulkMenu was renamed — this scan is measuring nothing")
        let rest = source[start.upperBound...]
        let end = rest.range(of: "\n    private func ") ?? rest.range(of: "\n}")
        return String(rest[..<(end?.lowerBound ?? rest.endIndex)])
    }

    /// Every `Button { … } label:` action body inside `bulkMenu`.
    private static func actionBodies(in body: String) -> [String] {
        var out: [String] = []
        var cursor = body.startIndex
        while let open = body.range(of: "Button {", range: cursor..<body.endIndex) {
            guard let close = body.range(of: "} label: {", range: open.upperBound..<body.endIndex)
            else { break }
            out.append(String(body[open.upperBound..<close.lowerBound]))
            cursor = close.upperBound
        }
        return out
    }

    @Test func everyBulkMenuActionResolvesItsRowsFromIds() throws {
        let body = try Self.bulkMenuBody()
        let actions = Self.actionBodies(in: body)
        // Copy-to-right, copy-to-left, Ignore, Clear selection.
        #expect(actions.count == 4,
                "the menu's shape changed — re-read this scan before trusting it: \(actions.count) actions")

        // "Clear selection" touches no rows at all; the other three each act on the selection.
        let rowActions = actions.filter { !$0.contains("selection.removeAll()") }
        #expect(rowActions.count == 3)
        for action in rowActions {
            #expect(action.contains("ids"),
                    "a bulk action does not name the ids it should resolve: \(action)")
        }
    }

    /// The snapshot may be counted in a label but never acted on. Checked inside the action bodies,
    /// not the whole function, because the labels legitimately mention it.
    @Test func noBulkMenuActionActsOnTheBuildTimeSnapshot() throws {
        let body = try Self.bulkMenuBody()
        // The premise: the snapshot bindings exist and the labels use them, or the absence below
        // passes on a function that no longer has them.
        #expect(body.contains("let toRight = DifferencesShortcutRules.transferItems(rows: selected,"),
                "the snapshot bindings are gone — this absence is no longer measuring anything")
        #expect(body.contains("\\(toRight.count)"), "the label stopped counting the snapshot")

        for action in Self.actionBodies(in: body) {
            for frozen in ["toRight", "toLeft", "selected"] {
                #expect(!action.contains(frozen),
                        "a bulk menu action acts on \(frozen), captured when the menu was built")
            }
        }
    }

    // MARK: - The single-row menu's one WRITE

    /// Most of the per-row menu takes the captured row: Get Info, Reveal and Copy Path name a side
    /// of the row the user pointed at. The ignore toggle differs: it writes `ignoredPaths`, keyed on
    /// the row's paths, and an NSMenu outlives the table state it was built from.
    @Test func theSingleRowIgnoreToggleResolvesItsRowWhenItFires() throws {
        let source = try Self.viewSource()
        let start = try #require(source.range(of: "private func singleRowMenu("),
                                 "singleRowMenu was renamed — this scan is measuring nothing")
        let rest = source[start.upperBound...]
        let end = rest.range(of: "\n    /// ") ?? rest.range(of: "\n    private func ")
        let body = String(rest[..<(end?.lowerBound ?? rest.endIndex)])

        #expect(body.contains("DifferencesShortcutRules.rows(displayRows.sorted, matching: [id])"),
                "the ignore toggle still writes from the row captured at menu-build")
        #expect(body.contains("toggledIgnoredPaths(\n                for: live,"),
                "the toggle does not use the resolved row")
    }

    /// The read-only items deliberately take the captured row: resolving them would make Reveal do
    /// nothing for a row that left the filtered list, which is worse than revealing what the user
    /// pointed at.
    @Test func theInspectionItemsStillTakeTheClickedRow() throws {
        let source = try Self.viewSource()
        #expect(source.contains("inspectionMenuItems(for: difference)"),
                "the inspection items were converted too — they should name the row that was clicked")
    }
}

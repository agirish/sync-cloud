import Testing
import Foundation
@testable import FileExplorer

/// **A menu item may not carry the rows it was built from.**
///
/// `DifferencesView` already states this rule twice — at `focusedSceneValue` ("No rows captured
/// here", because a focused value is not re-armed while a menu is open) and in `runCopyOrMove`,
/// which re-reads the move modifier at invocation rather than at menu build. The bulk context
/// menu's ITEMS were the half still frozen: `bulkMenu` captured filtered `FileDifference` values
/// and its Buttons acted on them, so anything landing behind an open NSMenu — a scan completing, a
/// row's action flipping — left the click operating on the table as it had been.
///
/// The rules themselves are covered behaviourally in `DifferencesShortcutRulesTests`. What that
/// cannot see is whether the VIEW calls them at fire time, which is the whole regression, so it is
/// pinned here on the structure of the action closures.
///
/// **A source scan, and honest about its reach**: it proves the action bodies name `ids` and do
/// not name the snapshot bindings. It cannot prove `bulkTransfer` resolves against live rows —
/// that is `transferItemsReturnsTheCurrentRowNotTheOneTheCallerRemembers`' job, one file over.
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

    /// The snapshot may be COUNTED in a label and must never be ACTED on. Stated as an absence
    /// inside the action bodies specifically, rather than over the whole function, because the
    /// labels legitimately mention it.
    @Test func noBulkMenuActionActsOnTheBuildTimeSnapshot() throws {
        let body = try Self.bulkMenuBody()
        // The premise: the snapshot bindings still exist and the labels still use them. Without
        // this the absence below passes on a function that simply stopped having them.
        #expect(body.contains("let toRight = selected.filter"),
                "the snapshot bindings are gone — this absence is no longer measuring anything")
        #expect(body.contains("\\(toRight.count)"), "the label stopped counting the snapshot")

        for action in Self.actionBodies(in: body) {
            for frozen in ["toRight", "toLeft", "selected"] {
                #expect(!action.contains(frozen),
                        "a bulk menu action acts on \(frozen), captured when the menu was built")
            }
        }
    }
}

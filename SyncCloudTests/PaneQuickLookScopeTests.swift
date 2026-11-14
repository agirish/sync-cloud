import Testing
import Foundation
@testable import SyncCloud

/// Where Space → Quick Look may listen: on the file list only. The pane column holds the pane
/// search `TextField`, so a handler on the column would eat every space typed into the search and
/// open Quick Look over whatever the pane had selected, and the panel would then take key focus.
///
/// Checked in source: `.onKeyPress` can't be fired, and the failure is which subtree a modifier is
/// attached to. Column checks read all of `MacApp/` (`macAppSources`).
@Suite struct PaneQuickLookScopeTests {
    // MARK: The premise

    /// The premise of the scan: the search field is inside the pane column. If it moves out, this
    /// fails, so the rule can't quietly go stale.
    @Test func testTheSearchFieldReallyIsInsideThePaneColumn() throws {
        let content = try macAppSources()
        let column = try #require(content.range(of: "func paneColumn(isLeft: Bool)"),
                                  "the pane column is gone — this scan would be vacuous")
        let list = try #require(content.range(of: "treeView(pane)", range: column.upperBound..<content.endIndex),
                                "paneColumn no longer builds the file list")
        let field = try #require(content.range(of: "searchText: paneSearchState(isLeft: isLeft)",
                                               range: column.upperBound..<content.endIndex),
                                 "the pane header is no longer given a search field")
        #expect(field.lowerBound < list.lowerBound,
                "the search field is not in the header above the list any more — re-derive the scope rule")
    }

    // MARK: The scope

    /// No key handler in the split layout: `ContentView+SplitLayout.swift` lays out whole pane
    /// columns and nothing smaller, so any Space handler in it swallows the search field's spaces.
    @Test func testTheSplitLayoutListensForNoKeysAtAll() throws {
        let split = try macAppFile("ContentView+SplitLayout.swift")
        #expect(!split.contains(".onKeyPress(.space)"),
                "a Space handler on a pane column eats spaces typed into that pane's search field")
        // Not just Space: every subject here is a whole column, so any key handler reaches the
        // field.
        #expect(!split.contains(".onKeyPress("),
                "a key handler on a pane column reaches that pane's search field")
        #expect(!split.contains("toggleQuickLook"),
                "the split layout is presenting Quick Look again — the handler belongs on the list")
    }

    /// The one handler is on the file list, not the column holding the header. Checked by
    /// indentation as well as order: "after `treeView(pane)`" is also true of a modifier on the
    /// enclosing `VStack`, which reads right at a glance.
    @Test func testTheHandlerIsAttachedToTheFileList() throws {
        let content = try macAppSources()
        let column = try #require(content.range(of: "func paneColumn(isLeft: Bool)"),
                                  "the pane column is gone — this scan would be vacuous")
        // Generous: `paneColumn` opens with a long `PaneHeader(…)` call, and a window short of the
        // list would fail like the regression. The checks anchor on the list line.
        let body = String(content[column.upperBound...].prefix(20_000))
        // Inside `paneInfoHost`, which draws Info over the whole chain, so one level deeper.
        let host = try #require(body.range(of: "            paneInfoHost(isLeft: isLeft) {\n"),
                                "the pane's list is not inside the Info host — Info would sit inside the list's chain")
        let list = try #require(body.range(of: "                treeView(pane)\n", range: host.upperBound..<body.endIndex),
                                "paneColumn no longer builds the list at the expected nesting")
        let after = String(body[list.upperBound...])
        // The list's own modifiers are indented one level deeper than the `treeView(pane)` line.
        #expect(after.contains("                    .onKeyPress(.space) { paneQuickLook() }"),
                "Space → Quick Look is not a modifier on the file list")
        // It is the first thing after the card, so it can't drift onto something wider. Measured
        // in code lines, so comments in between don't count.
        let codeLines = after
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        let spaceLine = try #require(codeLines.firstIndex { $0.contains(".onKeyPress(.space)") },
                                     "the Space handler is gone from the list's modifiers")
        let between = codeLines[..<spaceLine].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        // Exactly one modifier, the card, stands between list and handler; the card line is
        // matched by its head only.
        #expect(between.count == 1
                    && between[0].hasPrefix("                    .paneCardIfNeeded("),
                """
                the Space handler is no longer the first thing after the card — it is now preceded \
                by \(between.count) modifier line(s): \(between). Anything inserted here is a \
                modifier the handler has drifted past, which is how it ends up scoped to something \
                wider than the list.
                """)
        #expect(content.components(separatedBy: ".onKeyPress(.space) { paneQuickLook() }").count == 2,
                "there should be exactly one pane Quick Look handler")
    }

    // MARK: What it previews

    /// The rail and Browse show one pane, so a selection left in the hidden right pane from Compare
    /// must not hijack the preview. The one handler reads this from the layout; read wrong, the
    /// preview silently shows the wrong file.
    @Test func testTheTargetIsResolvedFromTheLayout() throws {
        let body = try memberBody("func paneQuickLook() -> KeyPress.Result {", inFile: "ContentView+PaneSearch.swift")
        #expect(body.contains("CurrentSelection.primaryPanePath"),
                "the target is no longer resolved by the shared resolver")
        #expect(body.contains("singleSource: layoutMode == .singleSource"),
                "a one-pane workspace can preview the hidden right pane's stale selection")
        #expect(body.contains("toggleQuickLook"))
        // The target's own `else`, not the suspension guard's `.ignored` above it.
        #expect(body.contains("singleSource: layoutMode == .singleSource ) else { return .ignored }"),
                "with nothing selected this must decline the key, not swallow it")
    }
}

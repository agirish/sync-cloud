import Testing
import Foundation
@testable import SyncCloud

/// Where Space → Quick Look is allowed to listen.
///
/// **The defect this exists for.** The handler used to hang off the whole pane column — on
/// `panesSplit` in Compare, on `paneColumn(isLeft: true)` in the rail and in Browse. Its own comment
/// explained why that was safe: `onKeyPress` "only fires while key focus is inside this subtree (the
/// pane Lists) … so text fields elsewhere get Space normally." That was true when a pane column was
/// a header of buttons over a list.
///
/// Pane search then put a `TextField` inside that subtree and "elsewhere" quietly stopped covering
/// it. Every Space typed into a pane's search field was intercepted: the space never reached the
/// query, and the Quick Look panel opened over the app on whatever the pane had selected — the hit
/// the walk had just revealed ("a random match"), or a row from before the search ("not even a
/// match"). The panel takes key focus, so typing then stopped altogether.
///
/// None of that is reachable from a unit test: `ContentView` needs a live `FileSyncManager` and a
/// render pass, `.onKeyPress` cannot be fired, and the failure is *which subtree a modifier is
/// attached to*, which leaves nothing in the AppKit tree to find. So it is checked at the source
/// level, the same way `BrowseWorkspaceCallSiteTests` and `ToolbarPaletteBarCallSiteTests` check
/// theirs — with the guards that scan needs: every check names its file and fails if it is missing
/// or implausibly short, `testTheScanCanActuallyFail` proves the reader is looking at real text, and
/// the premise the whole scan rests on (that the search field really is inside the pane column) is
/// asserted rather than assumed.
@Suite struct PaneQuickLookScopeTests {

    static func source(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)          // …/SyncCloudTests/<this>.swift
            .deletingLastPathComponent()                   // …/SyncCloudTests
            .deletingLastPathComponent()                   // repo root
            .appendingPathComponent("MacApp/\(name)")
        let text = try #require(try? String(contentsOf: url, encoding: .utf8),
                                "cannot read \(name) — every check below would be vacuous")
        #expect(text.count > 500, "\(name) is implausibly short")
        return text
    }

    /// The positive control. Everything below asserts a presence or an absence in one of three
    /// files; a reader that silently returned the wrong text would make every ABSENCE check pass.
    @Test func testTheScanCanActuallyFail() throws {
        #expect(try Self.source("ContentView.swift").contains("func paneColumn(isLeft: Bool)"),
                "this is not ContentView")
        #expect(try Self.source("ContentView+SplitLayout.swift").contains("var panesSplit: some View"),
                "this is not the split layout")
        #expect(try Self.source("ContentView+PaneSearch.swift").contains("func paneQuickLook()"),
                "this is not the pane-search file")
        #expect(try !Self.source("ContentView.swift").contains("a string that is definitely not in ContentView"))
    }

    // MARK: The premise

    /// **The reason the scan below is the right scan.** If the search field ever moves out of the
    /// pane column, none of this matters any more — and someone reading these tests should find that
    /// out from a failure here rather than by reasoning about a rule that has quietly gone stale.
    @Test func testTheSearchFieldReallyIsInsideThePaneColumn() throws {
        let content = try Self.source("ContentView.swift")
        let column = try #require(content.range(of: "func paneColumn(isLeft: Bool)"))
        let list = try #require(content.range(of: "treeView(pane)", range: column.upperBound..<content.endIndex),
                                "paneColumn no longer builds the file list")
        let field = try #require(content.range(of: "searchText: paneSearchState(isLeft: isLeft)",
                                               range: column.upperBound..<content.endIndex),
                                 "the pane header is no longer given a search field")
        #expect(field.lowerBound < list.lowerBound,
                "the search field is not in the header above the list any more — re-derive the scope rule")
    }

    // MARK: The scope

    /// The three old sites are gone. This is the assertion that actually fails if someone puts one
    /// back: `ContentView+SplitLayout.swift` lays out whole pane COLUMNS and nothing smaller, so any
    /// Space handler in it necessarily swallows the search field's spaces.
    @Test func testTheSplitLayoutListensForNoKeysAtAll() throws {
        let split = try Self.source("ContentView+SplitLayout.swift")
        #expect(!split.contains(".onKeyPress(.space)"),
                "a Space handler on a pane column eats spaces typed into that pane's search field")
        // Not just Space: this file's every subject is a whole column, so any key handler here has
        // the same reach over the field.
        #expect(!split.contains(".onKeyPress("),
                "a key handler on a pane column reaches that pane's search field")
        #expect(!split.contains("toggleQuickLook"),
                "the split layout is presenting Quick Look again — the handler belongs on the list")
    }

    /// …and the one replacement is on the file list, not on the column that contains the header.
    ///
    /// Checked by indentation as well as by order, because "after `treeView(pane)`" is also true of
    /// a modifier on the enclosing `VStack` — which is the exact mistake being guarded against, and
    /// the one that reads correctly at a glance.
    @Test func testTheHandlerIsAttachedToTheFileList() throws {
        let content = try Self.source("ContentView.swift")
        let column = try #require(content.range(of: "func paneColumn(isLeft: Bool)"))
        // Generous, because `paneColumn` opens with a long `PaneHeader(…)` call: a window that
        // stops short of the list turns every check below into a `#require` failure that reads like
        // the regression rather than like a mis-sized window.
        let body = String(content[column.upperBound...].prefix(20_000))
        let list = try #require(body.range(of: "            treeView(pane)\n"),
                                "paneColumn no longer builds the list at the expected nesting")
        let after = String(body[list.upperBound...])
        // The list's own modifiers are indented one level deeper than the `treeView(pane)` line.
        #expect(after.contains("                .onKeyPress(.space) { paneQuickLook() }"),
                "Space → Quick Look is not a modifier on the file list")
        // And it is the FIRST thing after the card, so it cannot have drifted past the overlay onto
        // something wider without this failing.
        let handler = try #require(after.range(of: ".onKeyPress(.space)"))
        #expect(after.distance(from: after.startIndex, to: handler.lowerBound) < 300,
                "the Space handler has drifted away from the list it is supposed to be scoped to")
        #expect(content.components(separatedBy: ".onKeyPress(.space) { paneQuickLook() }").count == 2,
                "there should be exactly one pane Quick Look handler")
    }

    // MARK: What it previews

    /// The rail and Browse show one pane, and a selection left in the hidden right pane from an
    /// earlier Compare session must not hijack the preview. That used to be a hand-passed
    /// `singleSource: true` at two call sites; with one handler it has to be read from the layout,
    /// and reading it wrong is silent — the preview simply shows the wrong file.
    @Test func testTheTargetIsResolvedFromTheLayout() throws {
        let search = try Self.source("ContentView+PaneSearch.swift")
        let start = try #require(search.range(of: "func paneQuickLook()"))
        let body = String(search[start.upperBound...].prefix(500))
        #expect(body.contains("CurrentSelection.primaryPanePath"),
                "the target is no longer resolved by the shared resolver")
        #expect(body.contains("singleSource: layoutMode == .singleSource"),
                "a one-pane workspace can preview the hidden right pane's stale selection")
        #expect(body.contains("toggleQuickLook"))
        #expect(body.contains("return .ignored"),
                "with nothing selected this must decline the key, not swallow it")
    }
}

import Testing
import Foundation
@testable import SyncCloud

/// Every entry point that opens the Quick Look panel declares whose preview it is.
///
/// `CurrentSelection.previewFollow` decides what an open panel does when the pane selection moves,
/// and its answer turns entirely on one Bool: is this the PANES' preview? Get that wrong at a call
/// site and the failure is silent and split between two opposite symptoms — a pane preview that
/// goes stale exactly as it did before (`followsPane` omitted), or a Differences/lens preview that
/// gets yanked or closed by a click in a pane that has nothing to do with it (`followsPane: true`
/// where it does not belong).
///
/// Neither is reachable from a unit test: `ContentView` needs a live `FileSyncManager` and a render
/// pass, and `.onChange` cannot be fired. So the call sites are checked at the source level, with
/// the guards a scan needs — the file is named and length-checked, `testTheScanCanActuallyFail`
/// proves the reader is looking at real text, and the count is asserted so a NEW entry point cannot
/// be added without deciding this question.
@Suite struct QuickLookOriginTests {

    static func source(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("MacApp/\(name)")
        let text = try #require(try? String(contentsOf: url, encoding: .utf8),
                                "cannot read \(name) — every check below would be vacuous")
        #expect(text.count > 500, "\(name) is implausibly short")
        return text
    }

    /// Every call to `toggleQuickLook(` across the app, as written.
    static func callSites() throws -> [String] {
        var sites: [String] = []
        for file in ["ContentView.swift", "ContentView+SplitLayout.swift", "ContentView+PaneSearch.swift"] {
            for line in try source(file).components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // The definition and the doc comment are not call sites.
                guard trimmed.contains("toggleQuickLook("),
                      !trimmed.hasPrefix("//"), !trimmed.hasPrefix("///"),
                      !trimmed.contains("func toggleQuickLook") else { continue }
                sites.append(trimmed)
            }
        }
        return sites
    }

    @Test func testTheScanCanActuallyFail() throws {
        #expect(try Self.source("ContentView.swift").contains("func toggleQuickLook("),
                "this is not ContentView, or the presenter has been renamed")
        #expect(try !Self.source("ContentView.swift").contains("a string that is definitely not in ContentView"))
    }

    /// The scan finds call sites at all. Without this every per-site check below is a loop over an
    /// empty array — the classic way a source scan passes with the bug present.
    @Test func testTheScanFindsTheCallSites() throws {
        let sites = try Self.callSites()
        #expect(sites.count >= 4, "found only \(sites.count) Quick Look call sites — the reader is broken")
        #expect(sites.contains { $0.contains("followsPane: true") },
                "no site claims a pane preview — Space and the row menu both should")
        #expect(sites.contains { !$0.contains("followsPane") },
                "every site claims a pane preview — the Differences and lens previews should not")
    }

    /// **The panes' entry points, named individually.** Space in the comparison panes, Space on the
    /// single-source rail, and the pane row menu. Each opens a preview OF THE PANE SELECTION, so
    /// each must be the kind that follows it.
    @Test func testEveryPaneEntryPointFollowsTheSelection() throws {
        // Space, in the one handler every pane surface shares — see `PaneQuickLookScopeTests` for
        // why it is a single function scoped to the file list rather than three column-wide copies.
        let search = try Self.source("ContentView+PaneSearch.swift")
        let handler = try #require(search.range(of: "func paneQuickLook()"),
                                   "the pane Space handler is gone or has moved out of this file")
        let body = String(search[handler.upperBound...].prefix(400))
        #expect(body.contains("toggleQuickLook(URL(fileURLWithPath: targetPath), followsPane: true)"),
                "Space opens a pane preview that will not follow the selection")
        let content = try Self.source("ContentView.swift")
        let treeView = try #require(content.range(of: "FileTreeView("),
                                    "the pane is no longer built here")
        let call = String(content[treeView.upperBound...].prefix(4_000))
        #expect(call.contains("onQuickLook: { toggleQuickLook($0, followsPane: true) }"),
                "the pane's row menu is not routed to the host's panel — it presents its own, which nothing can keep current")
    }

    /// …and the entry points that are NOT the panes'. Both surfaces can hold a selection at once, so
    /// a pane click must not move or close a preview one of these put up.
    @Test func testTheOtherSurfacesDoNotClaimThePaneSelection() throws {
        let content = try Self.source("ContentView.swift")
        for marker in ["DifferencesView(", "onQuickLook: { toggleQuickLook($0) }"] {
            #expect(content.contains(marker), "\(marker) is gone — this check has stopped covering it")
        }
        // The Differences table's preview, on the line that constructs the view.
        let differences = try #require(content.range(of: "DifferencesView("))
        let line = String(content[differences.lowerBound...].prefix(600))
        #expect(line.contains("onQuickLook: { toggleQuickLook($0) }"),
                "the Differences preview now follows the PANE selection — a pane click would move it")
        #expect(!line.contains("followsPane: true"))
    }

    /// The origin has to be cleared when the panel closes by hand: `.quickLookPreview` nils its
    /// binding without going through `toggleQuickLook`, so a stale `true` would be inherited by the
    /// next preview whatever opened it.
    @Test func testTheOriginIsClearedWhenThePanelIsDismissed() throws {
        let content = try Self.source("ContentView.swift")
        #expect(content.contains(".onChange(of: quickLookURL) { _, url in if url == nil { quickLookFollowsPane = false } }"),
                "dismissing the panel leaves the origin flag set")
        #expect(content.contains(".onChange(of: paneQuickLookTarget)"),
                "nothing observes the pane selection — the panel cannot follow anything")
        #expect(content.contains("CurrentSelection.previewFollow("),
                "the follow decision is no longer made by the shared rule")
    }
}

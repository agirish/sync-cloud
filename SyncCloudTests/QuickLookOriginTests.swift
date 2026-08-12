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

    /// One named file, length-checked — for the checks that assert something about *that* file.
    static func source(_ name: String) throws -> String {
        let text = try readable(name)
        #expect(text.count > 500, "\(name) is implausibly short")
        return text
    }

    /// Any file in `MacApp/`, without the length guard.
    ///
    /// The sweep below reads every Swift file in the directory, and a plausible-length assertion
    /// per file is a tripwire on the wrong thing: adding a twenty-line enum to `MacApp/` would fail
    /// this suite with "implausibly short" rather than anything about Quick Look. The non-vacuity
    /// the sweep actually needs is on its RESULT — that it found call sites at all — which
    /// `testTheScanFindsTheCallSites` asserts, and on the named file `testTheScanCanActuallyFail`
    /// reads through `source(_:)`.
    static func readable(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("MacApp/\(name)")
        return try #require(try? String(contentsOf: url, encoding: .utf8),
                            "cannot read \(name) — every check below would be vacuous")
    }

    /// Every call to `toggleQuickLook(` across the app, as written.
    ///
    /// **Swept over the whole of `MacApp/`, not a named three.** The doc above promises "a NEW
    /// entry point cannot be added without deciding this question", and a fixed file list cannot
    /// keep that promise: a fifth call in a fourth file is exactly the new entry point it is
    /// about, and it was invisible here.
    static func callSites() throws -> [String] {
        var sites: [String] = []
        for file in try Self.macAppSwiftFiles() {
            for line in try readable(file).components(separatedBy: "\n") {
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

    /// Every Swift file in `MacApp/`, by name, so the sweep above cannot silently narrow.
    static func macAppSwiftFiles() throws -> [String] {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MacApp")
        let urls = try #require(try? FileManager.default.contentsOfDirectory(at: dir,
                                                                            includingPropertiesForKeys: nil),
                                "cannot list MacApp/ — every check below would be vacuous")
        let names = urls.filter { $0.pathExtension == "swift" }.map { $0.lastPathComponent }
        try #require(names.count > 10, "MacApp/ listed \(names.count) files — the reader is broken")
        return names.sorted()
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
        // **Exact, not a floor.** `>= 4` over a fixed three-file list was the weaker of two
        // promises this suite makes: a fifth site passed it in silence, which is the one event the
        // suite exists for. Raising this number is the deliberate act of having decided what the
        // new entry point does about `followsPane`.
        #expect(sites.count == 4,
                """
                \(sites.count) Quick Look call sites, expected 4 — if you added one, decide whether \
                it owns the pane preview (`followsPane:`) and then update this count:
                \(sites.joined(separator: "\n"))
                """)
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

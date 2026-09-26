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
        // `#require`, not `#expect`: a file that exists but is truncated hands a short string on,
        // after which every `contains` here answers false and every `!contains` answers true. One
        // quiet issue standing in front of a page of green is the wrong signal — stop instead.
        try #require(text.count > 500, "\(name) is implausibly short — the scans below would be near-vacuous")
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

    /// Every call to `toggleQuickLook(` across the app — each as `toggleQuickLook(<its whole
    /// argument list>)`, whitespace-normalised (``normalizedCode(_:)``).
    ///
    /// **Swept over the whole of `MacApp/`, not a named three.** The doc above promises "a NEW
    /// entry point cannot be added without deciding this question", and a fixed file list cannot
    /// keep that promise: a fifth call in a fourth file is exactly the new entry point it is
    /// about, and it was invisible here.
    ///
    /// **A call, not a line** (2026-09-26). A site was the LINE holding `toggleQuickLook(`, so a
    /// call broken after its URL put `followsPane:` on a line this never read — and two calls on
    /// one line counted once. ``argumentLists(of:in:)`` reads each call to its own closing paren,
    /// skips comments and strings, and does not count the definition.
    static func callSites() throws -> [String] {
        var sites: [String] = []
        for file in try Self.macAppSwiftFiles() {
            for list in argumentLists(of: "toggleQuickLook(", in: sourceCodeOnly(try readable(file))) {
                sites.append("toggleQuickLook(\(normalizedCode(list)))")
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
        // 6 since TE33: the Edit rail's row menu, which is not the pane's preview — see
        // `testTheOtherSurfacesDoNotClaimThePaneSelection`.
        #expect(sites.count == 6,
                """
                \(sites.count) Quick Look call sites, expected 6 — if you added one, decide whether \
                it owns the pane preview (`followsPane:`) and then update this count:
                \(sites.joined(separator: "\n"))
                """)
        #expect(sites.contains { $0.contains(normalizedCode("followsPane: true")) },
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
        // The handler's own body. It was a character window — widened once already when
        // `paneQuickLook` gained its suspension guard, because a window tighter than the body it
        // reads fails for the wrong reason. A body cannot outgrow its own closing brace.
        let body = try CallArguments(of: "toggleQuickLook(", in: try declarationBody(of: "func paneQuickLook()", in: search))
        #expect(body.unlabeled == [normalizedCode("URL(fileURLWithPath: targetPath)")] && body.passes("followsPane", "true"),
                "Space opens a pane preview that will not follow the selection")
        let content = try Self.source("ContentView.swift")
        // **The whole argument list, not a character budget.** A `prefix(4_000)` window read this
        // call until v4.4 added parameters ahead of `onQuickLook:` — the argument moved past the
        // end of the window, and the suite failed claiming the row menu was no longer routed to the
        // host's panel, which was never true. That is the SECOND time this scan has failed for a
        // reason that has nothing to do with Quick Look (see the note on `paneQuickLook` above): a
        // window measured in characters has to be re-tuned every time an unrelated argument is
        // added, and it accuses whoever touches the call next rather than whoever wrote the number.
        // `argumentList` is the answer to that — now the shared, lexer-backed one, which does not
        // take a `)` inside a string for the call's end — and stops at the call's closing paren.
        let call = try CallArguments(of: "FileTreeView(", in: sourceCodeOnly(content))
        #expect(call.passes("onQuickLook", "{ toggleQuickLook($0, followsPane: true) }"),
                "the pane's row menu is not routed to the host's panel — it presents its own, which nothing can keep current")

        // **The fifth site: File ▸ Quick Look.** The menu item is the row menu's verb reached from
        // the menu bar instead of a right-click, so it previews the same thing — the pane
        // selection — and must follow it for the same reason. Named here rather than left to the
        // count above, which says only that a site exists.
        let shortcuts = try Self.source("ShortcutCommands.swift")
        // **To the member's own closing brace, not a 2,000-character window.** That window is the
        // defect the note above names, and it bit exactly as described: TE30 added one resolver
        // argument to an unrelated verb (File ▸ Open in Edit) and pushed `followsPane: true` to
        // character 2,060, turning a Quick Look test red over a change that did not touch Quick
        // Look. A member cannot outgrow its own closing brace — now found by matching braces.
        let resolver = CodeText(try declarationBody(of: "var shortcutPaneRowVerbs", in: shortcuts))
        #expect(resolver.contains("return PaneRowVerbs("),
                "the slice is not the resolver's body — the check below would be vacuous")
        #expect(resolver.contains("followsPane: true"),
                "File ▸ Quick Look opens a preview that will not follow the pane selection it is about")
    }

    /// …and the entry points that are NOT the panes'. Both surfaces can hold a selection at once, so
    /// a pane click must not move or close a preview one of these put up.
    @Test func testTheOtherSurfacesDoNotClaimThePaneSelection() throws {
        let content = try Self.source("ContentView.swift")
        for marker in ["DifferencesView(", "onQuickLook: { toggleQuickLook($0) }"] {
            #expect(CodeText(content).contains(marker), "\(marker) is gone — this check has stopped covering it")
        }
        // The Differences table's preview, on the call that constructs the view — its own
        // argument list, where it was the next 600 characters.
        let differences = try CallArguments(of: "DifferencesView(", in: sourceCodeOnly(content))
        #expect(differences.passes("onQuickLook", "{ toggleQuickLook($0) }"),
                "the Differences preview now follows the PANE selection — a pane click would move it")
        #expect(!differences.arguments.contains { $0.value.contains(normalizedCode("followsPane: true")) })

        // **The Edit rail's row menu (TE33).** A rail row is not the pane's selection: the rail is
        // drawn only while the pane is folded away, and the row right-clicked need not be the file
        // the folded pane has selected. So if the pane is expanded while that preview is still up,
        // a pane click must not retarget or close it.
        #expect(try EditorRailRowMenuWiringTests.railRowActions()
                    .passes("quickLook", "{ path in toggleQuickLook(URL(fileURLWithPath: path), followsPane: false) }"),
                "the Edit rail's Quick Look now follows the PANE selection — a pane click would move it")
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

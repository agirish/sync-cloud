import Testing
import Foundation
@testable import SyncCloud

/// Every entry point that opens the Quick Look panel declares whose preview it is.
/// `CurrentSelection.previewFollow` decides what an open panel does when the pane selection moves,
/// and turns on one Bool: is this the panes' preview? Wrong at a call site, a pane preview goes
/// stale (`followsPane` omitted), or a Differences or lens preview is moved or closed by an
/// unrelated pane click (`followsPane: true` where it doesn't belong).
///
/// `ContentView` needs a live `FileSyncManager` and a render pass, so the call sites are checked
/// in source: `testTheScanCanActuallyFail` proves the reader sees real text, and the exact count
/// means a new entry point can't be added without deciding this.
@Suite struct QuickLookOriginTests {

    /// One named file, length-checked — for the checks that assert something about *that* file.
    static func source(_ name: String) throws -> String {
        let text = try readable(name)
        // `#require`, not `#expect`: a truncated file would make every `contains` false and every
        // `!contains` true, so stop instead of reporting a page of green.
        try #require(text.count > 500, "\(name) is implausibly short — the scans below would be near-vacuous")
        return text
    }

    /// Any file in `MacApp/`, without the length guard, so a short new file there doesn't fail
    /// this suite. The sweep's non-vacuity is checked on its result instead, by
    /// `testTheScanFindsTheCallSites`.
    static func readable(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("MacApp/\(name)")
        return try #require(try? String(contentsOf: url, encoding: .utf8),
                            "cannot read \(name) — every check below would be vacuous")
    }

    /// Every call to `toggleQuickLook(` across the app, each as `toggleQuickLook(<its whole
    /// argument list>)`, whitespace-normalised (``normalizedCode(_:)``). Swept over all of
    /// `MacApp/`, since a fixed file list would miss a call in a new file. Read per call, not per
    /// line: ``argumentLists(of:in:)`` reads to the closing paren, skips comments and strings, and
    /// doesn't count the definition.
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

    /// The scan finds call sites at all, or every per-site check below loops over nothing.
    @Test func testTheScanFindsTheCallSites() throws {
        let sites = try Self.callSites()
        // Exact, not a floor: raising it means you decided what the new site does about
        // `followsPane`. One of the six is the Edit rail's row menu, which isn't the pane's preview
        // (see `testTheOtherSurfacesDoNotClaimThePaneSelection`).
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

    /// The panes' entry points, named one by one: Space in the panes, the pane row menu, and
    /// File ▸ Quick Look. Each previews the pane selection, so each must follow it.
    @Test func testEveryPaneEntryPointFollowsTheSelection() throws {
        // Space, in the one handler every pane surface shares (`PaneQuickLookScopeTests` says why
        // it is one function).
        let search = try Self.source("ContentView+PaneSearch.swift")
        // The handler's own body, not a character window, which would fail for the wrong reason
        // whenever the body grew.
        let body = try CallArguments(of: "toggleQuickLook(", in: try declarationBody(of: "func paneQuickLook()", in: search))
        #expect(body.unlabeled == [normalizedCode("URL(fileURLWithPath: targetPath)")] && body.passes("followsPane", "true"),
                "Space opens a pane preview that will not follow the selection")
        let content = try Self.source("ContentView.swift")
        // The whole argument list, not a character window, which an unrelated new argument would
        // push `onQuickLook:` out of. The lexer-backed reader doesn't take a `)` in a string for
        // the call's end.
        let call = try CallArguments(of: "FileTreeView(", in: sourceCodeOnly(content))
        #expect(call.passes("onQuickLook", "{ toggleQuickLook($0, followsPane: true) }"),
                "the pane's row menu is not routed to the host's panel — it presents its own, which nothing can keep current")

        // File ▸ Quick Look is the row menu's verb from the menu bar, so it previews the pane
        // selection and must follow it. Named here; the count above only says a site exists.
        let shortcuts = try Self.source("ShortcutCommands.swift")
        // To the member's own closing brace, found by matching braces, so an argument added to an
        // unrelated verb can't push `followsPane: true` out of view.
        let resolver = CodeText(try declarationBody(of: "var shortcutPaneRowVerbs", in: shortcuts))
        #expect(resolver.contains("return PaneRowVerbs("),
                "the slice is not the resolver's body — the check below would be vacuous")
        #expect(resolver.contains("followsPane: true"),
                "File ▸ Quick Look opens a preview that will not follow the pane selection it is about")
    }

    /// The entry points that are not the panes'. Both surfaces can hold a selection at once, so a
    /// pane click must not move or close a preview one of these put up.
    @Test func testTheOtherSurfacesDoNotClaimThePaneSelection() throws {
        let content = try Self.source("ContentView.swift")
        for marker in ["DifferencesView(", "onQuickLook: { toggleQuickLook($0) }"] {
            #expect(CodeText(content).contains(marker), "\(marker) is gone — this check has stopped covering it")
        }
        // The Differences table's preview, read from the argument list of the call that builds it.
        let differences = try CallArguments(of: "DifferencesView(", in: sourceCodeOnly(content))
        #expect(differences.passes("onQuickLook", "{ toggleQuickLook($0) }"),
                "the Differences preview now follows the PANE selection — a pane click would move it")
        #expect(!differences.arguments.contains { $0.value.contains(normalizedCode("followsPane: true")) })

        // The Edit rail's row menu. A rail row isn't the pane's selection: the rail shows only while
        // the pane is folded, and the row need not be the pane's selected file. So once the pane is
        // expanded, a pane click must not retarget or close that preview.
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

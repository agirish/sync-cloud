import Testing
import Foundation
import FileExplorer
@testable import SyncCloud

/// The toolbar actually mounts the ⌘K pill, and mounts it wired to the palette.
///
/// `CommandPaletteBar` renders and measures beautifully in `CommandPaletteBarTests`, and
/// `WorkspaceBarMetrics.styles` resolves a ladder that `WorkspaceBarMetricsTests` pins from both
/// sides — and **every one of those stays green if the toolbar never draws the control**, or draws
/// it with a hard-coded rung, or hangs a different action off it. `mainToolbar` is a
/// `ToolbarContent` builder: it cannot be instantiated and asked what it contains, and the button
/// underneath is not an `NSControl` a test could click.
///
/// So this is a source-level scan, with the two habits that keep one honest: it **names the file it
/// reads and fails if that file cannot be found**, and every check asserts a string whose absence is
/// exactly the regression being guarded — not merely that some related word appears.
@Suite struct ToolbarPaletteBarCallSiteTests {

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

    @Test func theToolbarDrawsThePillAndOpensThePaletteWithIt() throws {
        let toolbar = try Self.source("ContentView+Toolbar.swift")
        #expect(toolbar.contains("CommandPaletteBar("),
                "the toolbar no longer draws the ⌘K pill — the render tests are measuring a view nothing shows")
        #expect(toolbar.contains("toggleCommandPalette()"),
                "the pill is wired to something other than the palette")
        // The chord comes from `AppChord`, not a literal: the pill's key and the menu item's key
        // equivalent must be one registration, or the toolbar can advertise a chord that does
        // nothing — the exact drift `AppChord` was created to end.
        #expect(toolbar.contains("chord: AppChord.commandPalette.display"),
                "the pill's key is a hand-written string again — it can now disagree with the menu item")
        #expect(!toolbar.contains("chord: \"⌘K\""))
    }

    @Test func thePillTakesTheResolvedRungRatherThanAFixedOne() throws {
        let toolbar = try Self.source("ContentView+Toolbar.swift")
        // A hard-coded `.full` is the failure with no symptom until the window is narrow, and then
        // the symptom is the whole toolbar behind macOS's overflow chevron.
        #expect(toolbar.contains("style: toolbarStyles.search"),
                "the pill is drawing a fixed rung — the width ladder no longer reaches it")
        #expect(toolbar.contains("let style = toolbarStyles.workspace"),
                "the workspace bar is no longer reading the same resolved value the pill does")
    }

    @Test func bothRungsAreResolvedInOnePlaceFromTheWindowsWidth() throws {
        let content = try Self.source("ContentView.swift")
        // One `onGeometryChange`, one value. Two thresholds resolved separately is how each control
        // concludes it fits a width the other is also spending.
        #expect(content.contains("onGeometryChange(for: ToolbarBarStyles.self)"),
                "the toolbar's two controls are sizing themselves from separate decisions again")
        #expect(content.contains("WorkspaceBarMetrics.styles("))
        // And the pill's own measurements are fed in — a `styles` call that passed zero widths
        // would compile, resolve, and reserve nothing for the control on the row.
        #expect(content.contains("searchLabelWidth: CommandPaletteBarMetrics.labelWidth("))
        #expect(content.contains("searchKeycapWidth: CommandPaletteBarMetrics.keycapWidth("))
        #expect(!content.contains("searchLabelWidth: 0"))
    }
}

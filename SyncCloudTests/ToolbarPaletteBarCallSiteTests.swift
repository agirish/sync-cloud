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
        // `#require`, not `#expect`: a file that exists but is truncated hands a short string on,
        // after which every `contains` here answers false and every `!contains` answers true. One
        // quiet issue standing in front of a page of green is the wrong signal — stop instead.
        try #require(text.count > 500, "\(name) is implausibly short — the scans below would be near-vacuous")
        return text
    }

    @Test func theToolbarDrawsThePillAndOpensThePaletteWithIt() throws {
        let toolbar = try Self.source("ContentView+Toolbar.swift")
        // `GoToFieldBar` as of §7: the pill and the field it becomes are one control, and the
        // toolbar draws that one. It still renders `CommandPaletteBar` for its closed state — the
        // pill's own suite measures a view the toolbar reaches through this.
        #expect(toolbar.contains("GoToFieldBar("),
                "the toolbar no longer draws the Go-to control — the render tests are measuring a view nothing shows")
        #expect(toolbar.contains("toggleCommandPalette()"),
                "the control is wired to something other than the palette")
        // The field's keys reach the list, and through the controller rather than by reading rows
        // in the view: ↑ ↓ and ↩ arrive from the field editor, and a toolbar that drew the field
        // without wiring them would type beautifully and go nowhere.
        #expect(toolbar.contains("palettePanel.move(by:"), "↑ / ↓ from the field reach nothing")
        #expect(toolbar.contains("palettePanel.runSelection()"), "↩ from the field runs nothing")
        #expect(toolbar.contains("palettePanel.dismiss()"), "esc from the field closes nothing")
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
        #expect(toolbar.contains("mode: goToFieldMode"),
                "the control is drawing a fixed rung — the width ladder no longer reaches it")
        // And the mode itself comes off the resolved pair, never from a constant width.
        #expect(toolbar.contains("toolbarStyles.field"))
        #expect(toolbar.contains(".closed(toolbarStyles.search)"))
        #expect(toolbar.contains("let style = toolbarStyles.workspace"),
                "the workspace bar is no longer reading the same resolved value the pill does")
    }

    @Test func bothRungsAreResolvedInOnePlaceFromTheWindowsWidth() throws {
        let content = try Self.source("ContentView.swift")
        // One `onGeometryChange`, one value. Two thresholds resolved separately is how each control
        // concludes it fits a width the other is also spending.
        #expect(content.contains("onGeometryChange(for: ToolbarBarStyleSet.self)"),
                "the toolbar's controls are sizing themselves from separate decisions again")
        // `styleSet`, not `styles`: BOTH answers — closed and open — come out of one call at one
        // width. Resolving the open one anywhere else is how the field ends up sized for a window
        // the toolbar no longer has.
        #expect(content.contains("WorkspaceBarMetrics.styleSet("))
        // The open field's key is `esc` and is measured from the string the field draws.
        #expect(content.contains("fieldKeycapWidth: CommandPaletteBarMetrics.keycapWidth("))
        #expect(content.contains("symbol: GoToFieldMetrics.closeKeycap"))
        // And the pill's own measurements are fed in — a `styles` call that passed zero widths
        // would compile, resolve, and reserve nothing for the control on the row.
        #expect(content.contains("searchLabelWidth: CommandPaletteBarMetrics.labelWidth("))
        #expect(content.contains("searchKeycapWidth: CommandPaletteBarMetrics.keycapWidth("))
        #expect(!content.contains("searchLabelWidth: 0"))
    }

    /// **The destination picker owns the window, and every way to leave it must know that.**
    ///
    /// `a1c96082` suspended ⌘K by nilling a focused value, which reached the menu item alone; the
    /// pill and the armed-on-launch path called `toggleCommandPalette()` directly and walked past
    /// it, so clicking the pill mid-pick raised the palette and ↩ on a workspace row switched
    /// workspace under the pending pick. The workspace bar had the same hole with no ⌘K involved.
    ///
    /// Each guard is asserted where it lives. Every one of them could be deleted with all 1,129 +
    /// 392 tests green before this test existed — which is the shape the commit that added them
    /// condemned in `a1c96082`, one layer down and in its own diff.
    @Test func everyWayIntoTheAppIsSuspendedWhileADestinationPickIsPending() throws {
        let host = try Self.source("CommandPaletteHost.swift")
        let toggle = try #require(host.range(of: "func toggleCommandPalette()"),
                                  "toggleCommandPalette is gone — this scan would be vacuous")
        let body = String(host[toggle.upperBound...].prefix(1200))
        #expect(body.contains("pendingDestination == nil"),
                "toggleCommandPalette no longer refuses while a destination pick is pending — the pill and the armed-on-launch path raise the palette over it, and ↩ switches workspace mid-pick")

        let toolbar = try Self.source("ContentView+Toolbar.swift")
        #expect(toolbar.components(separatedBy: "disabled(pendingDestination != nil)").count - 1 >= 2,
                "the toolbar no longer dims both the ⌘K pill and the workspace bar during a pick — a control that silently does nothing, or one that switches workspace under the picker")

        let content = try Self.source("ContentView.swift")
        #expect(content.contains("palettePanel.dismiss()"),
                "presentDestination no longer lowers the palette, so the picker can be raised under a window that holds key and take neither a keystroke nor a click")
        #expect(content.contains("paletteOnLaunchArmed, pendingDestination == nil"),
                "the armed-on-launch flag is consumed before the guard can refuse it — the one shot for that session is burned with only a log line to say so")
    }
}

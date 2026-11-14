import Testing
import Foundation
import FileExplorer
@testable import SyncCloud

/// The toolbar actually mounts the ⌘K pill, and mounts it wired to the palette.
///
/// `CommandPaletteBarTests` and `WorkspaceBarMetricsTests` all stay green if the toolbar never
/// draws the control, draws it with a hard-coded rung, or hangs a different action off it.
/// `mainToolbar` is a `ToolbarContent` builder that cannot be instantiated and inspected, so this
/// is a source scan: it names the file it reads and fails if it cannot be found, and each check
/// asserts a string whose absence is exactly the regression guarded.
@Suite struct ToolbarPaletteBarCallSiteTests {

    @Test func theToolbarDrawsThePillAndOpensThePaletteWithIt() throws {
        let toolbar = try macAppFile("ContentView+Toolbar.swift")
        // The pill and the field it becomes are one control, `GoToFieldBar`, which still renders
        // `CommandPaletteBar` closed. The toolbar draws it through `GoToFieldHost`, the field bound
        // to the query object.
        #expect(toolbar.contains("GoToFieldHost("),
                "the toolbar no longer draws the Go-to control — the render tests are measuring a view nothing shows")
        let host = try macAppFile("CommandPaletteHost.swift")
        #expect(host.contains("GoToFieldBar(mode: mode, query: $query.text"),
                "`GoToFieldHost` no longer draws the Go-to control bound to the query it observes")
        // Every keystroke reaches the list, from the host, which is what observes the query.
        #expect(host.contains(".onChange(of: query.text) { _, typed in onQuery(typed) }"),
                "the field’s keystrokes are no longer forwarded to the list")
        #expect(toolbar.contains("onQuery: { palettePanel.setQuery($0) }"),
                "the field’s keystrokes are forwarded to something other than the palette")
        #expect(toolbar.contains("toggleCommandPalette()"),
                "the control is wired to something other than the palette")
        // The field's keys reach the list through the controller: ↑ ↓ and ↩ arrive from the field
        // editor, and a field drawn without them would type but go nowhere.
        #expect(toolbar.contains("palettePanel.move(by:"), "↑ / ↓ from the field reach nothing")
        #expect(toolbar.contains("palettePanel.runSelection()"), "↩ from the field runs nothing")
        #expect(toolbar.contains("palettePanel.dismiss()"), "esc from the field closes nothing")
        // The chord comes from `AppChord`, not a literal: the pill's key and the menu item's key
        // equivalent must be one registration, or the toolbar can advertise a chord that does
        // nothing.
        #expect(toolbar.contains("chord: AppChord.commandPalette.display"),
                "the pill's key is a hand-written string again — it can now disagree with the menu item")
        #expect(!toolbar.contains("chord: \"⌘K\""))
    }

    /// A keystroke in the field redraws the field, not the window. The query is an object
    /// `ContentView` holds without observing, and only `GoToFieldHost` reads it; a read in the
    /// window's body would re-run the whole body on every key. A source check, because
    /// `ContentView` cannot be mounted in a test; it pins the two things that bring the redraw back.
    @Test func theWindowDoesNotObserveTheGoToQuery() throws {
        let content = try macAppFile("ContentView.swift")
        #expect(content.contains("@State var goToQuery = GoToQuery()"),
                "the query is held some other way — check `ContentView` does not observe it")
        // Every file `ContentView`'s body is assembled from, not just the one that declares it.
        let parts = try FileManager.default.contentsOfDirectory(atPath: macAppDirectory().path)
            .filter { $0.hasPrefix("ContentView") && $0.hasSuffix(".swift") }
        #expect(parts.count > 5, "found \(parts.count) ContentView files — this check is aimed wrong")
        for part in parts {
            let source = try macAppFile(part)
            #expect(!source.contains("@StateObject var goToQuery") && !source.contains("@ObservedObject var goToQuery"),
                    "`\(part)` observes the query, so every keystroke redraws the window")
            #expect(!source.contains("goToQuery.text") && !source.contains("of: goToQuery"),
                    "`\(part)` reads the query, which makes the window's body depend on every keystroke")
        }
        // An `@Observable` class is tracked by any body that merely reads it; only an
        // `ObservableObject` held in `@State` keeps the window out of it.
        let host = try macAppFile("CommandPaletteHost.swift")
        #expect(host.contains("final class GoToQuery: ObservableObject"))
        #expect(!host.contains("@Observable\nfinal class GoToQuery") && !host.contains("@Observable final class GoToQuery"))
    }

    @Test func thePillTakesTheResolvedRungRatherThanAFixedOne() throws {
        let toolbar = try macAppFile("ContentView+Toolbar.swift")
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
        let content = try macAppFile("ContentView.swift")
        // One `onGeometryChange`, one value. Two thresholds resolved separately would let each
        // control conclude it fits a width the other is also spending.
        #expect(content.contains("onGeometryChange(for: ToolbarBarStyleSet.self)"),
                "the toolbar's controls are sizing themselves from separate decisions again")
        // `styleSet`, not `styles`: both answers, closed and open, come out of one call at one
        // width, or the open field could be sized for a window the toolbar no longer has.
        #expect(content.contains("WorkspaceBarMetrics.styleSet("))
        // The open field's key is `esc` and is measured from the string the field draws.
        #expect(content.contains("fieldKeycapWidth: CommandPaletteBarMetrics.keycapWidth("))
        #expect(content.contains("symbol: GoToFieldMetrics.closeKeycap"))
        // And the pill's own measurements are fed in: a call that passed zero widths would
        // compile, resolve, and reserve nothing for the control on the row.
        #expect(content.contains("searchLabelWidth: CommandPaletteBarMetrics.labelWidth("))
        #expect(content.contains("searchKeycapWidth: CommandPaletteBarMetrics.keycapWidth("))
        #expect(!content.contains("searchLabelWidth: 0"))
    }

    /// The destination picker owns the window, and every way to leave it must know that.
    ///
    /// Suspending only the menu item is not enough: the pill and the armed-on-launch path call
    /// `toggleCommandPalette()` directly, so a click mid-pick would raise the palette and ↩ on a
    /// workspace row would switch workspace under the pending pick. The workspace bar needs the
    /// same guard. Each guard is asserted where it lives, since no other test notices one removed.
    @Test func everyWayIntoTheAppIsSuspendedWhileADestinationPickIsPending() throws {
        let host = try macAppFile("CommandPaletteHost.swift")
        let toggle = try #require(host.range(of: "func toggleCommandPalette()"),
                                  "toggleCommandPalette is gone — this scan would be vacuous")
        let body = String(host[toggle.upperBound...].prefix(1200))
        #expect(body.contains("pendingDestination == nil"),
                "toggleCommandPalette no longer refuses while a destination pick is pending — the pill and the armed-on-launch path raise the palette over it, and ↩ switches workspace mid-pick")

        let toolbar = try macAppFile("ContentView+Toolbar.swift")
        #expect(toolbar.components(separatedBy: "disabled(pendingDestination != nil)").count - 1 >= 2,
                "the toolbar no longer dims both the ⌘K pill and the workspace bar during a pick — a control that silently does nothing, or one that switches workspace under the picker")

        let content = try macAppFile("ContentView.swift")
        #expect(content.contains("palettePanel.dismiss()"),
                "presentDestination no longer lowers the palette, so the picker can be raised under a window that holds key and take neither a keystroke nor a click")
        #expect(content.contains("paletteOnLaunchArmed, pendingDestination == nil"),
                "the armed-on-launch flag is consumed before the guard can refuse it — the one shot for that session is burned with only a log line to say so")
    }
}

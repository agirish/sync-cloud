import AppKit
import SwiftUI
import Testing
import Foundation
import Sync
@testable import SyncCloud

/// The app-side half of Browse tabs: where the strip is mounted, what the ⌃⇥ item says, and the
/// three-state Tab Bar switch.
///
/// `ContentView` is a `View` with `@State` and cannot be instantiated here, so the rules that
/// matter are extracted as values (`TabBarSwitch.resolve`, `PaneFocusSwitch.menuTitle`) and pinned
/// twice: the rule directly, and the call site by a source scan — because a rule nothing calls is
/// one revert away from being decoration, and this repo has shipped exactly that.
@MainActor
@Suite struct PaneTabWiringTests {

    private static func source(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // SyncCloudTests
            .deletingLastPathComponent()      // repo root
            .appendingPathComponent("MacApp/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The positive control. Every scan below asserts a presence in one of two files; a reader that
    /// silently returned the wrong text would make them all pass.
    @Test func theScanCanActuallyFail() throws {
        #expect(try Self.source("ContentView.swift").contains("func paneColumn(isLeft: Bool)"),
                "this is not ContentView")
        #expect(try Self.source("ShortcutCommands.swift").contains("struct TabBarSwitch"),
                "this is not the shortcuts file")
        #expect(try !Self.source("ContentView.swift").contains("a string that is definitely not in ContentView"))
    }

    // MARK: Where the strip is mounted

    /// **A sibling above the header, never a wrapper around it.**
    ///
    /// `PaneQuickLookScopeTests` fails if the pane column's `VStack` is re-nested — but it fails
    /// with a message about Quick Look's scope, which is a long way from "someone wrapped the tab
    /// strip around the pane". This says it directly, and it is the one structural fact the whole
    /// feature rests on: one insertion point serves Browse, both Compare panes and the rail.
    @Test func theStripIsMountedAboveTheHeaderInTheSamePaneColumn() throws {
        let content = try Self.source("ContentView.swift")
        let column = try #require(content.range(of: "func paneColumn(isLeft: Bool)"),
                                  "the pane column is gone — this scan would be vacuous")
        let body = String(content[column.upperBound...].prefix(20_000))
        let strip = try #require(body.range(of: "PaneTabStrip("),
                                 "the pane column does not build a tab strip")
        let header = try #require(body.range(of: "PaneHeader("),
                                  "the pane column does not build its header")
        let list = try #require(body.range(of: "            treeView(pane)\n"),
                                "the pane column no longer builds the list at the expected nesting")
        #expect(strip.lowerBound < header.lowerBound, "the strip is not above the pane header")
        #expect(header.lowerBound < list.lowerBound, "the header is no longer above the list")
        // Mounted at the same nesting as the header — a wrapper would indent the header deeper.
        #expect(body.contains("                PaneTabStrip("),
                "the strip is not a sibling inside the column's VStack")
    }

    /// One call site, so Compare's two panes and the Organize/Storage rail get the strip for free.
    /// A second would be the plumbing this design exists to avoid.
    @Test func thereIsExactlyOnePlaceThatBuildsAStrip() throws {
        let content = try Self.source("ContentView.swift")
        #expect(content.components(separatedBy: "PaneTabStrip(").count - 1 == 1,
                "more than one place builds a tab strip — they will drift")
    }

    // MARK: The Tab Bar switch

    @Test func aSecondTabForcesTheTabBarSwitchOnAndFreezesIt() {
        let forced = TabBarSwitch.resolve(hasSecondTab: true, preference: false) { _ in }
        #expect(forced.isOn, "the switch reads OFF while a tab bar is on screen")
        #expect(forced.isForced, "the switch could hide a strip whose tabs would be unreachable")
    }

    @Test func atOneTabTheSwitchIsThePreferenceAndIsLive() {
        let off = TabBarSwitch.resolve(hasSecondTab: false, preference: false) { _ in }
        #expect(!off.isOn)
        #expect(!off.isForced)

        let on = TabBarSwitch.resolve(hasSecondTab: false, preference: true) { _ in }
        #expect(on.isOn)
        #expect(!on.isForced)
    }

    @Test func theSwitchWritesThroughToThePreference() {
        var written: Bool?
        TabBarSwitch.resolve(hasSecondTab: false, preference: false) { written = $0 }.set(true)
        #expect(written == true)
    }

    /// The call-site half: the resolver is what the focused value actually publishes.
    @Test func theTabBarSwitchIsResolvedThroughTheRule() throws {
        let commands = try Self.source("ShortcutCommands.swift")
        let resolver = try #require(commands.range(of: "var shortcutTabBar: TabBarSwitch {"),
                                    "the focused value no longer publishes a TabBarSwitch")
        let body = String(commands[resolver.upperBound...].prefix(400))
        #expect(body.contains("TabBarSwitch.resolve("),
                "shortcutTabBar builds the switch by hand — the tested rule is unused")
    }

    /// …and the item disables on it, which is the half a value cannot state.
    @Test func theTabBarItemDisablesWhileTheSwitchIsForced() throws {
        let commands = try Self.source("ShortcutCommands.swift")
        let item = try #require(commands.range(of: "struct ToggleTabBarCommand: View {"),
                                "the Tab Bar menu item is gone")
        let body = String(commands[item.upperBound...].prefix(700))
        #expect(body.contains("isForced == true"),
                "the Tab Bar item stays clickable while a second tab is open")
    }

    // MARK: ⌃⇥ says which of its two jobs it will do

    @Test func theFocusItemNamesTheOtherPaneInCompare() {
        #expect(PaneFocusSwitch.menuTitle(for: PaneFocusSwitch(targetName: "Dropbox", run: {}))
                == "Focus Dropbox")
    }

    /// In Browse the same chord cycles tabs, and the menu is the only place that says so at rest.
    @Test func theFocusItemReadsNextTabInBrowse() {
        #expect(PaneFocusSwitch.menuTitle(for: .nextTab(run: {})) == "Next Tab")
    }

    @Test func theDisabledFocusItemNamesNoPane() {
        #expect(PaneFocusSwitch.menuTitle(for: nil) == "Focus Other Pane")
    }

    /// The Browse branch is real, not just expressible: ⌃⇥ resolves to a tab cycle there, and only
    /// when the pane has a second tab to cycle to.
    @Test func browseResolvesTheChordToATabCycle() throws {
        let search = try Self.source("ContentView+PaneSearch.swift")
        let action = try #require(search.range(of: "var switchPaneFocusAction: PaneFocusSwitch? {"),
                                  "the ⌃⇥ resolver is gone")
        let body = String(search[action.upperBound...].prefix(700))
        #expect(body.contains(".nextTab"), "⌃⇥ never cycles tabs — the Browse branch is missing")
        #expect(body.contains("paneTabs(isLeft: true).count > 1"),
                "⌃⇥ offers a tab cycle with only one tab to cycle")
    }

    // MARK: The row menu's entry point

    /// The discovery route. ⌘T opens the folder you are already in, so this is the only entry
    /// point that produces a second tab somewhere else — and it is gated on the delegate's own
    /// capability, like the two menu items beside it.
    @Test func theRowMenuOffersOpenInNewTabForFoldersOnly() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Modules/FileExplorer/Sources/FileExplorer/FileTreeView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let menu = try #require(source.range(of: "if singleNode.isDirectory {"),
                                "the row menu's folder branch is gone")
        let body = String(source[menu.upperBound...].prefix(1_200))
        #expect(body.contains("delegate.canOpenInNewTab"),
                "Open in New Tab is offered by hosts that have no strip to open a tab in")
        #expect(body.contains("handleOpenInNewTab(singleNode)"),
                "Open in New Tab is not wired to the delegate")
    }
}

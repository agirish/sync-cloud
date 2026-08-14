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

    /// One member's body: from its declaration to the first line that is a closing brace at
    /// member indentation.
    ///
    /// **Not a fixed character window.** A window is what `QuickLookOriginTests` uses, and this
    /// change is what showed the cost: one more argument on an unrelated call site pushed the line
    /// it looks for out of range, and a *tab* handler failed a *Quick Look* test. Slicing to the
    /// member's own end cannot go stale as the member grows, and a member that outgrows its own
    /// closing brace is not a thing.
    private static func memberBody(_ declaration: String, in source: String) throws -> String {
        let start = try #require(source.range(of: declaration),
                                 "\(declaration) is gone — this scan would be vacuous")
        let rest = source[start.upperBound...]
        let end = try #require(rest.range(of: "\n    }\n"),
                               "\(declaration) never closes at member indentation")
        return String(rest[..<end.lowerBound])
    }

    /// One TYPE's body — to its closing brace at column zero.
    ///
    /// Separate from `memberBody` because the two close at different indentations, and using the
    /// member form on a type silently returns the first member instead: `CloseTabCommand`'s slice
    /// stopped at its static helper and the scan below reported the item as still disabled. A
    /// scan that reads the wrong region is worse than no scan, so the two are named apart.
    private static func typeBody(_ declaration: String, in source: String) throws -> String {
        let start = try #require(source.range(of: declaration),
                                 "\(declaration) is gone — this scan would be vacuous")
        let rest = source[start.upperBound...]
        let end = try #require(rest.range(of: "\n}\n"), "\(declaration) never closes at column zero")
        return String(rest[..<end.lowerBound])
    }

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

        // Both slicers, against a member and a type whose contents are known — a helper that
        // returned the wrong region would make every scan below pass on the wrong text, which is
        // exactly what `typeBody` was added for.
        let commands = try Self.source("ShortcutCommands.swift")
        #expect(try Self.typeBody("struct CloseTabCommand: View {", in: commands).contains("keyboardShortcut"),
                "the type slice does not reach the item's body")
        #expect(try Self.memberBody("static func run(_ close: (() -> Void)?", in: commands)
                    .contains("closeWindow()"),
                "the member slice does not reach the rule's body")
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

    /// **Drawn only when there is something to draw.** At one tab the strip must occupy no space
    /// at all — an empty 34pt row above every pane is what an install that never opens a second tab
    /// would otherwise get, and the whole "unchanged unless you use it" claim rests on this `if`.
    @Test func theStripIsGatedOnHavingTabsOrTheSwitch() throws {
        let content = try Self.source("ContentView.swift")
        let column = try #require(content.range(of: "func paneColumn(isLeft: Bool)"))
        let body = String(content[column.upperBound...].prefix(20_000))
        let gate = try #require(body.range(of: "if paneShowsTabStrip(isLeft: isLeft) {"),
                                "the strip is built unconditionally — one tab now costs a 34pt row")
        let strip = try #require(body.range(of: "PaneTabStrip("))
        #expect(gate.lowerBound < strip.lowerBound, "the gate does not guard the strip")

        let rule = try Self.memberBody("func paneShowsTabStrip(isLeft: Bool) -> Bool",
                                       in: Self.source("ContentView+PaneTabs.swift"))
        #expect(rule.contains("showsStrip"), "the gate no longer asks the tab list")
        #expect(rule.contains("tabBarVisible"), "View ▸ Tab Bar no longer shows the strip")
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
        let body = try Self.memberBody("var shortcutTabBar: TabBarSwitch {", in: commands)
        #expect(body.contains("TabBarSwitch.resolve("),
                "shortcutTabBar builds the switch by hand — the tested rule is unused")
    }

    /// …and the item disables on it, which is the half a value cannot state.
    @Test func theTabBarItemDisablesWhileTheSwitchIsForced() throws {
        let commands = try Self.source("ShortcutCommands.swift")
        let body = try Self.typeBody("struct ToggleTabBarCommand: View {", in: commands)
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
        let body = try Self.memberBody("var switchPaneFocusAction: PaneFocusSwitch? {", in: search)
        #expect(body.contains(".nextTab"), "⌃⇥ never cycles tabs — the Browse branch is missing")
        #expect(body.contains("paneTabs(isLeft: true).count > 1"),
                "⌃⇥ offers a tab cycle with only one tab to cycle")
    }

    // MARK: What the chips say

    private func list(_ paths: [String], selected: Int, providers: [String] = []) -> PaneTabList {
        let tabs = paths.enumerated().map { index, path in
            PaneTab(providerId: index < providers.count ? providers[index] : "iCloud", relativePath: path)
        }
        return PaneTabList(tabs: tabs, selectedIndex: selected)
    }

    private let iCloud = PaneTabChips.Source(displayName: "iCloud Drive",
                                             markImageName: "icloud", root: "~/Documents")

    /// **The active chip reads the LIVE pane; every other chip reads its own parked snapshot.**
    /// The active entry in the list is stale by construction, so a strip drawn entirely from the
    /// list is correct when you arrive and wrong one click later.
    @Test func theActiveChipFollowsThePaneAndTheParkedOnesDoNot() {
        let items = PaneTabChips.items(list(["Finance", "Photos"], selected: 0),
                                       liveProviderId: "Dropbox",
                                       livePath: "Finance/US/2024",
                                       source: { _ in self.iCloud })
        #expect(items[0].title == "2024", "the active chip is naming its parked snapshot, not the pane")
        #expect(items[0].isActive)
        #expect(items[1].title == "Photos", "a parked chip moved with the pane")
        #expect(!items[1].isActive)
    }

    /// A tab at a source root has no folder to name.
    @Test func aChipAtTheRootWearsItsSourcesName() {
        let items = PaneTabChips.items(list(["", "Photos"], selected: 0),
                                       liveProviderId: "iCloud", livePath: "",
                                       source: { _ in self.iCloud })
        #expect(items[0].title == "iCloud Drive")
    }

    /// A source removed mid-session: the chip still says which source it meant rather than going
    /// blank, and wears the folder mark `ProviderLogo` draws for a source with no brand.
    @Test func aChipWhoseSourceIsGoneStillNamesIt() {
        let items = PaneTabChips.items(list(["", "Photos"], selected: 0, providers: ["iCloud", "Dropbox"]),
                                       liveProviderId: "iCloud", livePath: "",
                                       source: { _ in nil })
        #expect(items[0].title == "iCloud")
        #expect(items[0].markImageName == "folder.fill")
    }

    /// **The tooltip's path is expanded.** A source's stored root may carry a tilde; the chip's
    /// help tag is the strip's answer to "which Documents is this?", and `~/Documents/Finance`
    /// answers it worse than the real path does.
    @Test func theChipsPathIsExpanded() {
        let items = PaneTabChips.items(list(["Finance"], selected: 0),
                                       liveProviderId: "iCloud", livePath: "Finance",
                                       source: { _ in self.iCloud })
        #expect(!items[0].fullPath.hasPrefix("~"), "the chip's path still carries a tilde")
        #expect(items[0].fullPath.hasSuffix("/Documents/Finance"))
    }

    // MARK: Whether a switch changes the source

    @Test func aTabOnTheSameSourceWritesNoProviderId() {
        #expect(PaneTabProviderSwitch.decide(arrived: "iCloud", current: "iCloud",
                                             isAvailable: { _ in true }) == .keep)
    }

    @Test func aTabOnAnotherAvailableSourceIsAdopted() {
        #expect(PaneTabProviderSwitch.decide(arrived: "Dropbox", current: "iCloud",
                                             isAvailable: { _ in true }) == .adopt("Dropbox"))
    }

    /// The invisible one: a tab whose source has been removed must not have its folder rendered
    /// under whatever source the pane happens to be showing.
    @Test func aTabOnASourceThatIsGoneIsRefusedRatherThanReinterpreted() {
        #expect(PaneTabProviderSwitch.decide(arrived: "Dropbox", current: "iCloud",
                                             isAvailable: { _ in false }) == .unavailable("Dropbox"))
    }

    /// The call site: adopting is what arms the suppression counter, and without that the provider
    /// `onChange` runs `resetNavigation()` over the navigation the switch just restored.
    @Test func adoptingASourceArmsTheSuppressionCounter() throws {
        let body = try Self.memberBody("private func tabAction(isLeft: Bool",
                                       in: Self.source("ContentView+PaneTabs.swift"))
        let adopt = try #require(body.range(of: "case .adopt(let id):"),
                                 "the provider decision is no longer handled by case")
        #expect(String(body[adopt.upperBound...]).contains("pendingTabProviderChanges += 1"),
                "adopting a source does not suppress the navigation reset")
    }

    /// …and every arrival reloads. `applyTab` deliberately does not ring `refreshSubject` — it
    /// cannot, because the provider id is written after it returns — so the pane would keep showing
    /// the previous tab's tree if this were dropped.
    @Test func everyArrivalDrivesOneReload() throws {
        let body = try Self.memberBody("private func tabAction(isLeft: Bool",
                                       in: Self.source("ContentView+PaneTabs.swift"))
        #expect(body.contains("refreshForTabSwitch()"),
                "a tab switch never reloads — the pane keeps the previous tab's tree")
        // The other half of the same rule, one layer down: `applyTab` must NOT ring the refresh
        // itself, or it fires before the provider id is written and loads the new tab's path under
        // the old tab's root.
        let sync = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Modules/Sync/Sources/Sync/FileSyncManager+PaneTabs.swift"),
                              encoding: .utf8)
        let apply = try Self.memberBody("public func applyTab(_ tab: PaneTab, isLeft: Bool)", in: sync)
        #expect(!apply.contains("syncPathsFromHistory()") && !apply.contains("refreshSubject"),
                "applyTab rings the refresh itself — it runs before the provider id is written")
    }

    // MARK: ⌘W, which replaced File ▸ Close

    /// **⌘W must still close a window that has no tabs.** This item takes the standard Close
    /// group's place, and the app has three auxiliary `Window` scenes — Keyboard Shortcuts,
    /// Activity Log, Sync History — none of which publishes a focused value. Disabled on `nil`,
    /// which is how every other item in that file spells "not available", left ⌘W dead in all
    /// three.
    @Test func closeFallsBackToTheWindowWhenNoTabIsPublished() {
        var closedWindow = false
        CloseTabCommand.run(nil) { closedWindow = true }
        #expect(closedWindow, "⌘W does nothing on a window that publishes no tab to close")
    }

    @Test func closeTakesTheTabWhenThereIsOne() {
        var closedTab = false
        var closedWindow = false
        CloseTabCommand.run({ closedTab = true }) { closedWindow = true }
        #expect(closedTab)
        #expect(!closedWindow, "⌘W closed the window as well as the tab")
    }

    /// The item itself must not be disabled, or the fallback above can never run.
    @Test func theCloseItemIsNeverDisabled() throws {
        let body = try Self.typeBody("struct CloseTabCommand: View {",
                                     in: Self.source("ShortcutCommands.swift"))
        #expect(!body.contains(".disabled("),
                "⌘W is disabled when no tab is published — it is also this app's only Close")
        #expect(body.contains("Self.run(close)"), "the item does not go through the tested rule")
    }

    // MARK: The launch restore

    /// **The restore must NOT arm the suppression counter.** It runs inside the provider
    /// bootstrap, where the id's `onChange` bails on `isBootstrappingProviders` without
    /// decrementing — so an armed counter strands at one and silently swallows the user's next
    /// real source switch, leaving that switch's navigation un-reset. `tabAction` arms it because
    /// it runs later, when the handler is live; these two must not be made to look alike.
    @Test func theLaunchRestoreDoesNotArmTheSuppressionCounter() throws {
        let body = try Self.memberBody("func restoreBrowseTabs()",
                                       in: Self.source("ContentView+PaneTabs.swift"))
        #expect(body.contains("leftProviderId = active.providerId"),
                "the restore no longer applies its tab's source — this check is vacuous")
        #expect(!body.contains("pendingTabProviderChanges"),
                "the launch restore arms a counter the bootstrap guard will never decrement")
    }

    /// The swap moves the lists as well as the panes, so what is saved has to move with them.
    @Test func swappingThePanesSavesTheStrip() throws {
        let body = try Self.memberBody("func swapPanesAction()", in: Self.source("ContentView.swift"))
        #expect(body.contains("saveBrowseTabs(isLeft: true)"),
                "a swap leaves the saved strip describing the pane that just left")
    }

    // MARK: The seam

    /// The seam's ⇄ / 🔗 capsule is drawn on top of the strip, and it lands on the left pane's ＋.
    @Test func theStripGivesUpTheEdgeTheSeamControlsSitOn() {
        #expect(PaneTabSeam.inset(isCompare: true, isLeft: true, leading: false) == PaneTabSeam.reserve,
                "the left pane's ＋ stays under the seam controls")
        #expect(PaneTabSeam.inset(isCompare: true, isLeft: false, leading: true) == PaneTabSeam.reserve,
                "the right pane's first chip stays under the seam controls")
    }

    /// …and only that edge. The other three would be track given up for nothing.
    @Test func noOtherEdgeGivesUpTrack() {
        #expect(PaneTabSeam.inset(isCompare: true, isLeft: true, leading: true) == 0)
        #expect(PaneTabSeam.inset(isCompare: true, isLeft: false, leading: false) == 0)
    }

    /// Browse and the Organize/Storage rail have no seam — one pane, nothing straddling anything.
    @Test func aSinglePaneWorkspaceKeepsItsWholeStrip() {
        for isLeft in [true, false] {
            for leading in [true, false] {
                #expect(PaneTabSeam.inset(isCompare: false, isLeft: isLeft, leading: leading) == 0,
                        "a single-pane workspace lost strip track to a seam it does not have")
            }
        }
    }

    /// The call-site half: the pane column asks the rule rather than spelling a number.
    @Test func thePaneColumnReservesTheSeamThroughTheRule() throws {
        let tabs = try Self.source("ContentView+PaneTabs.swift")
        let body = try Self.memberBody("func seamInset(isLeft: Bool, leading: Bool)", in: tabs)
        #expect(body.contains("PaneTabSeam.inset("), "the seam reserve is spelled by hand")
        let content = try Self.source("ContentView.swift")
        #expect(content.contains("leadingInset: seamInset(isLeft: isLeft, leading: true)"),
                "the strip is not given the seam reserve")
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

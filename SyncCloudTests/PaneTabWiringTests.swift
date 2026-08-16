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

    /// Source with its comment lines removed.
    ///
    /// **Every negative assertion below must go through this.** A scan for the ABSENCE of something
    /// is answered by any comment that mentions it — this file has now tripped over its own prose
    /// twice: a doc comment naming `FileTreeView(` broke a Quick Look scan, and a comment
    /// explaining why the header menu registers no `keyboardShortcut` made the check for one pass.
    /// `ShortcutCommandsTests` carries the same helper for the same reason.
    private static func codeOnly(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private static func fileExplorer(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Modules/FileExplorer/Sources/FileExplorer/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
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

    /// …and the call site **acts on it**, which for most of this feature's life it did not.
    ///
    /// The branch only logged, under a comment claiming the pane "stayed on its current source".
    /// That is true of the source and false of the folder: the verb has already applied the tab, so
    /// the pane is sitting on the removed source's folder path under the LIVE source's root — a
    /// path that usually exists nowhere, which shows as an empty pane. `discardTab` drops the tab
    /// and lands the pane on one that works; see `PaneTabSwitchingTests` for both of its cases.
    @Test func aTabOnASourceThatIsGoneIsDiscardedAndNotJustLogged() throws {
        let body = try Self.memberBody("private func tabAction(isLeft: Bool",
                                       in: Self.source("ContentView+PaneTabs.swift"))
        let branch = try #require(body.range(of: "case .unavailable"),
                                  "the removed-source case is no longer handled")
        let rest = String(body[branch.upperBound...])
        // `discardDeadTabs`, not `discardTab`: the fallback is a neighbour and neighbours die
        // together, so a single discard landed the pane straight onto the next dead tab.
        #expect(rest.contains("syncManager.discardDeadTabs("),
                "a tab on a removed source is only warned about — the pane is left on a path under the wrong root")
        // And the pane's search field follows the tab it lands on, like every other arrival.
        #expect(rest.contains("paneSearchState(isLeft: isLeft).wrappedValue"),
                "the discarded tab's search query is left in the field of the tab that replaced it")
    }

    /// **Every question about whether a PANE may be pointed at a source asks `enabledProviders`,
    /// and it asks it through one predicate.**
    ///
    /// Three of them asked `availableProviders` instead — the *discovered* list, which keeps a
    /// source the user has switched off in Settings. `refreshAction` and `refreshForTabSwitch`
    /// resolve their pair out of `enabledProviders` and return without loading anything when either
    /// is missing, so a pane on a disabled source is a pane nothing will ever walk.
    ///
    /// The launch path was the sharp end, and it is the one this scan is really about. Open a tab
    /// on a source, switch that source off, quit, relaunch: `applyProviderSelection` resolves the
    /// pane's id against the enabled list, then `restoreBrowseTabs` writes the disabled one back
    /// over it, and the bootstrap's `refreshAction()` bails. Both panes up, empty, no scan and
    /// nothing said — and nothing re-resolves, because `enabledProviders` never changed and its
    /// `onChange` never fires.
    ///
    /// Scanned as an ABSENCE across the whole file rather than as three presences, because the
    /// failure is a list being asked for somewhere new: a per-site check passes the moment a fourth
    /// site is added. The one legitimate reading is asserted by name below, so this cannot pass by
    /// the file having lost the ability to name a source at all.
    @Test func everyPaneProviderQuestionAsksTheEnabledList() throws {
        let code = Self.codeOnly(try Self.source("ContentView+PaneTabs.swift"))
        #expect(code.contains("settings.enabledProviders.contains { $0.id == id }"),
                "paneCanShowSource no longer reads the enabled list")
        for site in ["isAvailable: paneCanShowSource", "isKnownProvider: paneCanShowSource",
                     "paneCanShowSource(active.providerId)"] {
            #expect(code.contains(site), "\(site) no longer routes through the one predicate")
        }
        // The chip's NAME and mark are the one thing the discovered list is right for: a source
        // switched off still has a display name, and a chip reading "Dropbox" for the moment before
        // the tab is discarded beats one reading its raw id.
        let uses = code.components(separatedBy: "availableProviders").count - 1
        #expect(uses == 1,
                "\(uses) uses of availableProviders — a pane may be pointed at a source no refresh will walk")
        let items = try Self.memberBody("func paneTabItems(isLeft: Bool",
                                        in: Self.source("ContentView+PaneTabs.swift"))
        #expect(items.contains("settings.availableProviders"),
                "the one legitimate use has moved — this scan is now counting something else")
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

    /// …and an arrival that DOES move the pane reloads exactly once, from the host.
    ///
    /// The "which arrivals" half is `theScanIsGatedOnTheSameRuleTheInvalidationUses` above — a
    /// switch inside one source at one scope reloads nothing. What is pinned here is the half that
    /// has not changed: `applyTab` must not ring `refreshSubject` itself, because it runs *before*
    /// the provider id is written and would load the new tab's path under the old tab's root.
    @Test func theReloadIsDrivenByTheHostAndNotByApplyTab() throws {
        let body = try Self.memberBody("private func tabAction(isLeft: Bool",
                                       in: Self.source("ContentView+PaneTabs.swift"))
        #expect(body.contains("refreshForTabSwitch(movedPane: isLeft)"),
                "a tab switch never reloads — a source change would keep the previous tab's tree")
        let sync = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Modules/Sync/Sources/Sync/FileSyncManager+PaneTabs.swift"),
                              encoding: .utf8)
        // Sliced on the prefix, not the whole signature: this scan broke once already when the
        // parameter list grew, reporting "applyTab is gone" for a member that was right there.
        let apply = try Self.memberBody("public func applyTab(_ tab: PaneTab, isLeft: Bool", in: sync)
        let applyCode = Self.codeOnly(apply)
        #expect(!applyCode.contains("syncPathsFromHistory()") && !applyCode.contains("refreshSubject"),
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
        #expect(!Self.codeOnly(body).contains(".disabled("),
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
        let body = try Self.memberBody("func restoreBrowseTabs(isLeft: Bool)",
                                       in: Self.source("ContentView+PaneTabs.swift"))
        #expect(body.contains("leftProviderId = active.providerId"),
                "the restore no longer applies its tab's source — this check is vacuous")
        // Both sides, since the restore now runs for both panes: a right pane that adopted no
        // source would silently reopen every tab under whichever provider the pane happened to
        // be on, showing the right folder path under the wrong root.
        #expect(body.contains("rightProviderId = active.providerId"),
                "the right pane's restore does not apply its tab's source")
        #expect(!Self.codeOnly(body).contains("pendingTabProviderChanges"),
                "the launch restore arms a counter the bootstrap guard will never decrement")
    }

    /// **Both panes are restored, and the right one is easy to drop.** The launch sequence called
    /// this once for years; a later edit that re-collapses it to the left leaves Compare's right
    /// pane seeding one tab again, which is the state this whole feature exists to end.
    @Test func bothPanesAreRestoredAtLaunch() throws {
        let source = Self.codeOnly(try Self.source("ContentView.swift"))
        #expect(source.contains("restoreBrowseTabs(isLeft: true)"))
        #expect(source.contains("restoreBrowseTabs(isLeft: false)"),
                "the right pane's strip is never restored, so it seeds one tab every launch")
    }

    /// The swap moves the lists as well as the panes, so what is saved has to move with them.
    ///
    /// **Both sides, and that is the half a reader would leave out.** A swap is the one move that
    /// changes both strips at once. Saving only the left leaves the right's stored strip naming the
    /// pane that is no longer there, and the next launch restores two halves of a swap that never
    /// happened — one side from before it, one from after. Nothing on screen says so until a
    /// relaunch, which is why it is pinned here rather than left to the manual pass.
    @Test func swappingThePanesSavesBothStrips() throws {
        let body = try Self.memberBody("func swapPanesAction()", in: Self.source("ContentView.swift"))
        #expect(body.contains("saveBrowseTabs(isLeft: true)"),
                "a swap leaves the saved strip describing the pane that just left")
        #expect(body.contains("saveBrowseTabs(isLeft: false)"),
                "a swap saves only the left strip, so a relaunch restores half a swap")
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

    /// **The strip slides in** (roadmap Fig. 10). ⌘T opens the folder you are already in, so both
    /// chips say the same thing and nothing else on screen changes — the strip's arrival is the
    /// only feedback there is, and an abrupt one reads as a glitch rather than a result.
    @Test func theStripArrivesWithAnAnimation() throws {
        let content = try Self.source("ContentView.swift")
        let column = try #require(content.range(of: "func paneColumn(isLeft: Bool)"))
        let body = String(content[column.upperBound...].prefix(20_000))
        #expect(body.contains(".transition(.move(edge: .top)"),
                "the strip appears with no transition — nothing marks the arrival ⌘T is fed back by")
        // Keyed on PRESENCE, not on the tab count: opening a third tab while the strip is already
        // up must not animate the header and the list under it.
        #expect(body.contains("value: paneShowsTabStrip(isLeft: isLeft)"),
                "the strip's animation is keyed on something other than its own presence")
    }

    /// Pinning is wired, and it saves — a pin that did not survive a quit would be a worse
    /// promise than no pin at all.
    @Test func pinningIsWiredAndPersisted() throws {
        let content = try Self.source("ContentView.swift")
        #expect(content.contains("onSetPinned: { id, pinned in setTabPinned(pinned, id: id, isLeft: isLeft) }"),
                "the strip's pin action is wired to nothing")
        let body = try Self.memberBody("func setTabPinned(_ pinned: Bool, id: UUID, isLeft: Bool)",
                                       in: Self.source("ContentView+PaneTabs.swift"))
        #expect(body.contains("syncManager.setTabPinned("), "pinning does not reach the manager")
        #expect(body.contains("saveBrowseTabs(isLeft: isLeft)"), "a pin does not survive a quit")
        // Pinning moves no pane, so it must not pay for a reload.
        #expect(!Self.codeOnly(body).contains("refreshForTabSwitch"),
                "pinning reloads the tree for nothing")
    }

    /// **The File menu, read off the running app rather than out of the source.**
    ///
    /// The test host IS the app, so `NSApp.mainMenu` is the menu AppKit built from the `.commands`
    /// declarations — which makes this the one check that sees what the group replacements actually
    /// produced. Two of them are invisible to a source scan and both would ship silently:
    /// `CommandGroup(replacing: .saveItem)` failing to remove AppKit's own Close (two items
    /// registering ⌘W, one of them dead), and the tab items landing in the wrong group and so in
    /// the wrong place — the roadmap's Fig. 9 puts Close Tab beside New Tab, not below Delete.
    @Test func theFileMenuIsInTheRoadmapsOrder() throws {
        let file = try #require(NSApp.mainMenu?.items.first { $0.title == "File" }?.submenu,
                                "the app has no File menu — this check would be vacuous")
        let titles = file.items.map(\.title).filter { !$0.isEmpty }
        #expect(titles.prefix(4) == ["New Folder…", "New Tab", "Close Tab", "Reopen Closed Tab"],
                "the File menu opens with \(titles.prefix(4)) — Fig. 9 puts the tab items with New Folder")

        // AppKit's own Close is gone, and exactly one item claims ⌘W. Two would leave one of them
        // dead, and which one AppKit picks is not something this app decides.
        #expect(!titles.contains("Close"), "the standard File ▸ Close is still there beside Close Tab")
        // **Close All (⌥⌘W) goes with it, deliberately.** It came from the same group, and this app
        // is one window plus three utilities — while ⌥ chords are the one kind that fire through
        // the ⌥-hold reveal, so putting it back by hand would break an invariant `AppChordTests`
        // guards for the whole app. Pinned so the loss reads as a decision rather than an oversight.
        #expect(!titles.contains("Close All"),
                "Close All is back — it registers an ⌥ chord, which fires through the ⌥-hold reveal")
        let closers = file.items.filter { $0.keyEquivalent == "w" }
        #expect(closers.count == 1, "\(closers.count) items register ⌘W")
        #expect(closers.first?.title == "Close Tab")

        // Reopen Closed Tab has no chord on purpose: ⇧⌘T is the Tab Bar, and an ⌥ chord is the one
        // kind that can fire through the ⌥-hold reveal.
        let reopen = try #require(file.items.first { $0.title == "Reopen Closed Tab" })
        #expect(reopen.keyEquivalent.isEmpty, "Reopen Closed Tab has acquired a chord")
    }

    /// The View menu's Tab Bar switch, same source: a checkmark item, above the other switches.
    @Test func theViewMenuCarriesTheTabBarSwitch() throws {
        let view = try #require(NSApp.mainMenu?.items.first { $0.title == "View" }?.submenu,
                                "the app has no View menu")
        let titles = view.items.map(\.title).filter { !$0.isEmpty }
        let tabBar = try #require(titles.firstIndex(of: "Tab Bar"), "View ▸ Tab Bar is gone")
        let hidden = try #require(titles.firstIndex(of: "Hidden Files"))
        #expect(tabBar < hidden, "Tab Bar sits below the other switches")
        #expect(view.items.first { $0.title == "Tab Bar" }?.keyEquivalent == "t")
        // A noun with a tick, never a Show/Hide pair.
        #expect(!titles.contains { $0.hasPrefix("Show Tab") || $0.hasPrefix("Hide Tab") },
                "the tab bar switch became a Show/Hide pair")
    }

    // MARK: The right-click routes

    /// **The pane's own background menu offers New Tab.** It is the only right-click route that
    /// works at ONE tab — the row menu needs a folder under the pointer and the strip's menu needs
    /// a strip, and neither exists in the state every install starts in.
    @Test func thePaneBackgroundMenuOffersANewTab() throws {
        let shared = try Self.memberBody("static func tabActions(at path: String, delegate: FileActionDelegate)",
                                         in: Self.fileExplorer("FileTreeView.swift"))
        #expect(shared.contains("delegate.canOpenInNewTab"), "the item is offered by hosts with no strip")
        #expect(shared.contains("handleNewTab(at: path)"), "New Tab is wired to nothing")
        #expect(shared.contains("delegate.canCloseTab"),
                "Close Tab is offered at one tab, where it would close the window instead")

        // …and both view modes' background menus actually build it.
        for file in ["FileTreeView.swift", "PaneColumnsView.swift"] {
            #expect(try Self.fileExplorer(file).contains("SharedFileMenuItems.tabActions("),
                    "\(file)'s empty-area menu has no tab items")
        }
    }

    /// **Right-clicking the header card offers a new tab.** It is the surface a Mac user reaches
    /// for to act on a pane, and it was the one place with no tab route at all — the row menu needs
    /// a folder under the pointer, the strip's menu needs a strip, and the pane's background menu
    /// needs empty space below the rows, which a full column does not have.
    ///
    /// The bar itself is untouched: no glyph, no `PaneBarItem`, nothing in the customize sheet.
    @Test func theHeaderCardsMenuOffersANewTab() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Modules/Dashboard/Sources/Dashboard/DashboardViews.swift")
        let header = try String(contentsOf: url, encoding: .utf8)
        let menu = try Self.memberBody("private func barContextMenu() -> some View {", in: header)
        #expect(menu.contains("Button(\"New Tab\")"), "the header card's menu has no New Tab")
        #expect(menu.contains("Button(\"Close Tab\")"), "the header card's menu has no Close Tab")
        #expect(menu.contains("Customize Pane Bar…"), "the menu lost what it already carried")
        // No chord badges: the pair is registered once in the menu bar, and a `.keyboardShortcut`
        // here would register a second pair — one per pane.
        #expect(!Self.codeOnly(menu).contains("keyboardShortcut"),
                "the header menu registers its own chords, so ⌘T is claimed twice")

        // …and the call site withholds Close Tab at one tab rather than offering to close the window.
        let content = try Self.source("ContentView.swift")
        #expect(content.contains("onCloseTab: syncManager.paneTabs(isLeft: isLeft).count > 1"),
                "the header menu offers Close Tab at one tab, where it would close the window")
    }

    /// Discovery beats tidiness: the row menu's tab item sits above Quick Look, not at the bottom
    /// of the folder branch (roadmap Fig. 11).
    @Test func openInNewTabSitsAheadOfQuickLook() throws {
        let code = try Self.fileExplorer("FileTreeView.swift")
        let tab = try #require(code.range(of: "Label(\"Open in New Tab\""),
                               "the row menu no longer offers Open in New Tab")
        let quickLook = try #require(code.range(of: "Label(\"Quick Look\""))
        #expect(tab.lowerBound < quickLook.lowerBound,
                "Open in New Tab sank below Quick Look — it is the whole discovery story for tabs")
    }

    // MARK: The row menu's entry point

    /// The discovery route. ⌘T opens the folder you are already in, so this is the only entry
    /// point that produces a second tab somewhere else — gated on the delegate's own capability
    /// like the two items beside it, and on the row being a FOLDER, because a tab is a location.
    @Test func theRowMenuOffersOpenInNewTabForFoldersOnly() throws {
        let code = try Self.fileExplorer("FileTreeView.swift")
        let item = try #require(code.range(of: "Label(\"Open in New Tab\""),
                                "the row menu no longer offers Open in New Tab")
        // The gate is the two lines above the label, not a block further up: the item moved out of
        // the folder branch to sit ahead of Quick Look, so it carries its own `isDirectory` test.
        let lead = String(code[..<item.lowerBound].suffix(300))
        #expect(lead.contains("singleNode.isDirectory"), "a FILE can be opened as a tab")
        #expect(lead.contains("delegate.canOpenInNewTab"),
                "Open in New Tab is offered by hosts that have no strip to open a tab in")
        let after = String(code[item.upperBound...].prefix(200))
        #expect(after.contains("handleOpenInNewTab(singleNode)") || lead.contains("handleOpenInNewTab(singleNode)"),
                "Open in New Tab is not wired to the delegate")
    }

    // MARK: Compare — both panes wear the strip

    /// The term that makes Compare readable: **a second tab on either pane draws the strip on
    /// both.** Without it the pane that grew the tab has its header pushed 34pt down and every row
    /// after it names a different folder on the left than on the right.
    @Test func inCompareOnePanesSecondTabDrawsBothStrips() {
        #expect(PaneTabStripVisibility.shows(own: false, sibling: true, isCompare: true, switchIsOn: false),
                "the sibling grew a second tab and this pane drew nothing — the two rows are now offset")
        #expect(PaneTabStripVisibility.shows(own: true, sibling: false, isCompare: true, switchIsOn: false),
                "the pane with the tabs does not draw its own strip")
    }

    /// …and the other direction, which is the one that costs a 34pt row if it goes wrong. Browse and
    /// the single-source rail have no sibling on screen, so the sibling's list must not reach them —
    /// the right pane's list exists in both, it is simply not shown.
    @Test func outsideCompareTheSiblingsTabsDrawNothing() {
        #expect(!PaneTabStripVisibility.shows(own: false, sibling: true, isCompare: false, switchIsOn: false),
                "Browse drew a strip because the hidden right pane has two tabs")
        #expect(!PaneTabStripVisibility.shows(own: false, sibling: false, isCompare: true, switchIsOn: false),
                "a strip is drawn with one tab on each side and the switch off")
        #expect(PaneTabStripVisibility.shows(own: false, sibling: false, isCompare: false, switchIsOn: true),
                "View ▸ Tab Bar no longer shows the strip")
    }

    /// The call-site half: the rule is fed the SIBLING's list and the layout, not just this pane's.
    /// Reading `paneTabs(isLeft: isLeft)` twice would pass every rule test above and still ship the
    /// offset rows.
    @Test func theStripGateAsksBothPanes() throws {
        let rule = try Self.memberBody("func paneShowsTabStrip(isLeft: Bool) -> Bool",
                                       in: Self.source("ContentView+PaneTabs.swift"))
        #expect(rule.contains("PaneTabStripVisibility.shows("),
                "the gate is built by hand — the tested rule is unused")
        #expect(rule.contains("paneTabs(isLeft: !isLeft)"),
                "the gate never asks the sibling pane, so Compare's two rows can sit at different heights")
        #expect(rule.contains("layoutMode == .compare"),
                "the gate does not restrict the sibling term to Compare")
        #expect(rule.contains("tabBarVisible"), "View ▸ Tab Bar no longer shows the strip")
    }

    // MARK: Compare — a linked pane opens the tab too

    /// The mirror lands on the deepest folder the sibling genuinely has. A tab naming a folder that
    /// pane does not carry is a chip that cannot be navigated to, and the two sides are being
    /// compared precisely because they differ.
    @Test func aMirroredTabIsPrunedToWhatTheSiblingHas() {
        let has: Set<String> = ["Photos", "Photos/2024"]
        #expect(PaneTabMirror.landing(for: "Photos/2024") { has.contains($0) } == "Photos/2024",
                "a folder the sibling has in full was still pruned")
        #expect(PaneTabMirror.landing(for: "Photos/2024/June") { has.contains($0) } == "Photos/2024",
                "the mirror did not stop at the deepest shared folder")
        #expect(PaneTabMirror.landing(for: "Taxes/2024") { has.contains($0) } == "",
                "a folder the sibling shares nothing of did not fall back to its root")
        #expect(PaneTabMirror.landing(for: "") { _ in true } == "",
                "the root mirrored as something other than the root")
    }

    /// A folder missing halfway down must not be walked past — pruning stops, it does not skip.
    ///
    /// **The fixture is the whole test.** The obvious one — a sibling holding `Photos` and
    /// `Photos/2024/June` — cannot tell the two apart, because skipping `2024` next asks about
    /// `Photos/June`, which is not there either, and a `continue` in place of the `break` returned
    /// the same answer. This sibling *does* have `Photos/June`, so a skipping walk assembles a
    /// path out of two folders that are not parent and child.
    @Test func theMirrorStopsAtTheFirstMissingFolder() {
        let has: Set<String> = ["Photos", "Photos/June"]
        #expect(PaneTabMirror.landing(for: "Photos/2024/June") { has.contains($0) } == "Photos",
                "the walk skipped a missing folder and landed on a path with a hole in it")
    }

    /// Both entry points mirror, and both go through the one predicate.
    @Test func bothWaysOfOpeningATabMirrorOntoTheLinkedPane() throws {
        let code = Self.codeOnly(try Self.source("ContentView+PaneTabs.swift"))
        let here = try Self.memberBody("func openNewTabHere(isLeft: Bool)", in: code)
        #expect(here.contains("guard tabsOpenOnBothPanes else { return }"),
                "⌘T and the ＋ do not open a tab on the linked pane")
        #expect(here.contains("openTabHere(isLeft: !isLeft"),
                "the mirrored ⌘T does not target the other pane")

        let openThere = try Self.memberBody("func openInNewTab(absolutePath: String, isLeft: Bool)", in: code)
        #expect(openThere.contains("mirrorOpenInNewTab(relative, from: isLeft)"),
                "Open in New Tab does not mirror onto the linked pane")

        let mirror = try Self.memberBody("private func mirrorOpenInNewTab(", in: code)
        #expect(mirror.contains("guard tabsOpenOnBothPanes else { return }"),
                "the mirror runs unlinked, or in Browse, where there is no sibling")
        #expect(mirror.contains("PaneTabMirror.landing("),
                "the mirror copies the path outright instead of pruning it")
        #expect(mirror.contains("expandingTildeInPath"),
                "the sibling's root is compared unexpanded, so every mirror prunes to its root")
    }

    // MARK: What the launch sequence may not overwrite

    /// **The save has to refuse during the provider bootstrap.**
    ///
    /// The launch sequence points the pane at its stored folder and *then* reads the stored strip.
    /// That first move fires the persistence `onChange`, and the pane at that instant still holds
    /// the freshly-initialised one-tab list — so a save landing in between overwrites the user's
    /// whole strip with a single tab, and the restore reads back what it just destroyed. Whether
    /// the window opens at all comes down to when SwiftUI runs a view update across the `await`
    /// between the two steps, which is not a thing to leave to timing.
    @Test func theStripIsNotSavedWhileTheProvidersAreStillBootstrapping() throws {
        let rule = try Self.memberBody("func saveBrowseTabs(isLeft: Bool)",
                                       in: Self.source("ContentView+PaneTabs.swift"))
        #expect(rule.contains("!isBootstrappingProviders"),
                "a save during launch can overwrite the stored strip before the restore reads it")
        // **And it must not refuse the right pane.** `guard isLeft` sat here until the right strip
        // was persisted, and putting it back is a one-word change that kills right-pane persistence
        // outright while every store test stays green — they call the store directly and never
        // reach this. Negative, so it goes through `codeOnly`.
        #expect(!Self.codeOnly(rule).contains("guard isLeft"),
                "the save refuses the right pane again, so its strip is never written")
    }

    /// **One body serves both panes, so every side-dependent call inside it has to thread `isLeft`.**
    ///
    /// A single hardcoded side here is the worst failure this feature can have and the quietest: the
    /// app compiles, the package suite is green (it calls `PaneTabsStore` directly and never reaches
    /// these call sites), and nothing is visibly wrong until a relaunch. A save pinned to `true`
    /// makes every right-pane move overwrite the LEFT pane's stored strip — the user loses the tabs
    /// they were actually using. A `setPaneTabs`/`applyTab` pinned to `true` installs the right
    /// pane's restored tabs onto the left pane at launch.
    ///
    /// Pinned both ways round: the threading is asserted positively, and the literals are asserted
    /// absent — either alone can be satisfied while the other is broken.
    @Test func theSaveAndRestoreThreadTheirSideRatherThanHardcodingIt() throws {
        let source = try Self.source("ContentView+PaneTabs.swift")
        let save = Self.codeOnly(try Self.memberBody("func saveBrowseTabs(isLeft: Bool)", in: source))
        let restore = Self.codeOnly(try Self.memberBody("func restoreBrowseTabs(isLeft: Bool)",
                                                        in: source))

        #expect(save.contains("PaneTabsStore.save(") && save.contains("isLeft: isLeft"),
                "the save does not pass its own side to the store")
        #expect(restore.contains("PaneTabsStore.load(isLeft: isLeft)"),
                "the restore reads a fixed pane's stored strip")
        #expect(restore.contains("setPaneTabs(restored, isLeft: isLeft)"),
                "the restored strip is installed on a fixed pane")
        #expect(restore.contains("applyTab(active, isLeft: isLeft"),
                "the restored tab is applied to a fixed pane")

        for (name, body) in [("saveBrowseTabs", save), ("restoreBrowseTabs", restore)] {
            #expect(!body.contains("isLeft: true") && !body.contains("isLeft: false"),
                    "\(name) hardcodes a side, so one pane acts on the other's state")
        }
    }

    /// **The source is part of where a tab is**, and it is the half that moves without either path
    /// moving: switching source at the root leaves the history default, the column stack empty and
    /// the relative path `""`, so neither path `onChange` fires. Left unwatched, the stored entry
    /// keeps naming the old source — and because the restore writes the tab's provider over
    /// `selectedLeftProviderId`, the next launch actively undoes the switch.
    @Test func theSavedStripFollowsTheSourceAndNotOnlyThePath() throws {
        let source = try Self.source("ContentView+PaneTabs.swift")
        let modifier = try Self.typeBody("struct BrowseTabPersistence: ViewModifier {", in: source)
        #expect(modifier.contains("onChange(of: leftProviderId)"),
                "a source switch at the root is never saved, so the next launch reopens the old one")
        #expect(modifier.contains("onChange(of: syncManager.leftRelativePath)"),
                "the scope is no longer watched")
        #expect(modifier.contains("onChange(of: syncManager.leftBrowsePath)"),
                "the column stack is no longer watched")

        // **The same three for the right pane**, which is persisted too. Watching only the left
        // would leave the right pane's strip written by the tab verbs but never by navigation — so
        // it would come back at the folder its tabs were opened at rather than where they were
        // left, which is the exact bug this rule was written for on the left.
        #expect(modifier.contains("onChange(of: rightProviderId)"),
                "a right-pane source switch at the root is never saved")
        #expect(modifier.contains("onChange(of: syncManager.rightRelativePath)"),
                "the right pane's scope is not watched")
        #expect(modifier.contains("onChange(of: syncManager.rightBrowsePath)"),
                "the right pane's column stack is not watched")

        // …and the call site actually feeds it. A modifier watching a value nobody passes is the
        // shape this repo has shipped before.
        let callSite = try Self.source("ContentView.swift")
        #expect(callSite.contains("leftProviderId: leftProviderId"),
                "BrowseTabPersistence is built without the source it watches")
        #expect(callSite.contains("rightProviderId: rightProviderId"),
                "BrowseTabPersistence is built without the right pane's source")
        // **And its callback saves the side that moved.** The modifier reports which pane changed;
        // a call site that ignores that and saves a fixed side puts every right-pane move into the
        // left pane's stored strip. Six correct `onChange`s above cannot save you from one wrong
        // closure here, which is why the wiring is checked as well as the watching.
        #expect(Self.codeOnly(callSite).contains("saveBrowseTabs(isLeft: $0)"),
                "the persistence callback ignores which pane moved and saves a fixed side")
    }

    // MARK: The scan a tab switch does not run

    /// **A tab switch inside one source at one scope reloads nothing and rescans nothing.**
    ///
    /// The trees walk one root at one focus and the differences are about one pair of focused
    /// folders, so a switch that changes neither leaves both correct. Refreshing is the Refresh
    /// button's job — and drilling through columns, which moves the same column stack a tab
    /// carries, has never rescanned either.
    ///
    /// The two halves must ask **one** rule: the manager decides from it whether to drop the trees
    /// and the comparison, the host decides from it whether to run the scan. Two copies would let a
    /// switch invalidate without reloading, leaving a pane with no tree and no scan until the user
    /// pressed Refresh — strictly worse than the rescan this removes.
    @Test func theScanIsGatedOnTheSameRuleTheInvalidationUses() throws {
        let host = try Self.memberBody("private func tabAction(isLeft: Bool, _ verb: () -> PaneTab?)",
                                       in: Self.source("ContentView+PaneTabs.swift"))
        #expect(host.contains("PaneTabArrival.needsReload("),
                "the host rescans on every tab switch, or decides with its own copy of the rule")
        let gate = try #require(host.range(of: "PaneTabArrival.needsReload("))
        let refresh = try #require(host.range(of: "refreshForTabSwitch(movedPane:"),
                                   "the reload is gone entirely — a source switch would never load")
        #expect(gate.lowerBound < refresh.lowerBound, "the gate does not guard the reload")

        // Captured BEFORE the verb runs, because the verb moves the pane — read afterwards, the
        // "from" focus IS the arriving tab's focus and the rule says "no reload" for every switch,
        // including the source changes that genuinely need one.
        //
        // **Asserted as an ORDER, not as a presence.** Checking only that the line exists passed
        // with the read moved below `verb()` — the mutation this test is for.
        let read = try #require(host.range(of: "let fromFocus = isLeft ? syncManager.leftRelativePath"),
                                "the pane's focus before the switch is never captured")
        let verb = try #require(host.range(of: "verb() else {"), "the verb call is gone")
        #expect(read.upperBound < verb.lowerBound,
                "the focus is read after the pane has already moved, so the rule always says no")
    }

    /// **The prune must also fire when a pane finishes loading**, not only when its tree changes.
    ///
    /// `pruneBrowsePath` refuses while a tree is loading, because progressive loading publishes a
    /// shallow root-children-only tree first and pruning against that cuts a valid stack to its
    /// first component. But the deep tree is published *before* `await applyFilters()` and the flag
    /// is cleared *after* it, so the update carrying the final tree can arrive while the flag is
    /// still up — the republish handler skips, and the tree does not change again to re-fire it. A
    /// folder deleted externally would keep its dead stack, which is the whole thing the prune is
    /// for. The falling edge closes it without depending on which side of an `await` a SwiftUI
    /// update lands on.
    @Test func theStackIsAlsoPrunedWhenAPaneFinishesLoading() throws {
        let body = try Self.typeBody("struct ColumnStackPruning: ViewModifier {",
                                     in: Self.source("ContentView+PaneTabs.swift"))
        for flag in ["isLoadingLeftTree", "isLoadingRightTree"] {
            let handler = try #require(body.range(of: "onChange(of: syncManager.\(flag))"),
                                       "nothing prunes \(flag)'s pane when it settles")
            // **Sliced to this handler's own closure, not a fixed window.** A `prefix(200)` here
            // reached into the NEXT handler and found its guard, so deleting this one's passed —
            // the mutation that made the point.
            let rest = body[handler.upperBound...]
            let end = rest.range(of: "\n            .onChange") ?? rest.range(of: "\n    }")
            let own = String(rest[..<(end?.lowerBound ?? rest.endIndex)])
            #expect(own.contains("guard !isLoading else { return }"),
                    "the \(flag) handler prunes on the RISING edge too, against a tree still loading")
            #expect(own.contains("prune(isLeft:"), "the \(flag) handler does not prune")
        }
        // The republish trigger is still there — the falling edge is an addition, not a swap.
        #expect(body.contains("onChange(of: syncManager.leftPaneTree)"),
                "a republish no longer prunes, so a deleted folder keeps its stack until a reload")
        #expect(body.contains("onChange(of: syncManager.rightPaneTree)"))
        // And the modifier is actually installed.
        #expect(try Self.source("ContentView.swift").contains("ColumnStackPruning("),
                "the pruning modifier is defined and never applied")
    }

    // MARK: Log coverage

    /// **Every verb that changes the strip writes a line**, because he audits `~/sync-cloud.log`
    /// and the app's house style logs far smaller things than these ("User toggled hidden files",
    /// "User changed sort option").
    ///
    /// Named one by one rather than scanned as a family: a blanket "every func in this file logs"
    /// passes the moment a verb is renamed out of the pattern, which is the blind spot this repo
    /// has hit before. The positive control is `theScanCanActuallyFail` above plus the deliberate
    /// omission asserted underneath.
    @Test func everyVerbThatChangesTheStripIsLogged() throws {
        let source = try Self.source("ContentView+PaneTabs.swift")
        let verbs = [
            "private func openTabHere(isLeft: Bool, mirrored: Bool = false)",
            "func openInNewTab(absolutePath: String, isLeft: Bool)",
            "private func mirrorOpenInNewTab(",
            "func selectTab(id: UUID, isLeft: Bool)",
            "func cycleTab(forward: Bool, isLeft: Bool)",
            "func closeTab(id: UUID, isLeft: Bool)",
            "func closeOtherTabs(keeping id: UUID, isLeft: Bool)",
            "func duplicateTab(id: UUID, isLeft: Bool)",
            "func setTabPinned(_ pinned: Bool, id: UUID, isLeft: Bool)",
            "func moveTab(id: UUID, to index: Int, isLeft: Bool)",
            "func reopenClosedTab(isLeft: Bool)",
            "func copyTabPath(id: UUID, isLeft: Bool)",
        ]
        for verb in verbs {
            let body = try Self.memberBody(verb, in: source)
            #expect(body.contains("Logger.shared."),
                    "“\(verb)” changes the strip and writes nothing to the log")
        }
    }

    /// The two that are deliberately quieter, and the two that are deliberately louder — a level
    /// this file picked on purpose is worth pinning, because "make it consistent" would otherwise
    /// flatten them on the next pass.
    @Test func cyclingIsQuietAndClosingIsNot() throws {
        let source = try Self.source("ContentView+PaneTabs.swift")
        for quiet in ["func selectTab(id: UUID, isLeft: Bool)",
                      "func cycleTab(forward: Bool, isLeft: Bool)",
                      "func moveTab(id: UUID, to index: Int, isLeft: Bool)"] {
            let body = try Self.memberBody(quiet, in: source)
            #expect(body.contains("Logger.shared.debug"),
                    "“\(quiet)” logs at info — holding ⌃⇥ then buries the lines worth reading")
        }
        for loud in ["func closeTab(id: UUID, isLeft: Bool)",
                     "func closeOtherTabs(keeping id: UUID, isLeft: Bool)"] {
            let body = try Self.memberBody(loud, in: source)
            #expect(body.contains("Logger.shared.info"),
                    "“\(loud)” throws tabs away at debug level")
        }
    }

    /// **A mirrored ⌘T must not log the same sentence as the one that caused it.** Both panes open
    /// a tab at their own folder, so without a distinct line the log shows one keystroke firing
    /// twice in the same second — which reads as a bug in the very log used to rule bugs out.
    @Test func theMirroredNewTabSaysItIsTheMirror() throws {
        let body = try Self.memberBody("private func openTabHere(isLeft: Bool, mirrored: Bool = false)",
                                       in: Self.source("ContentView+PaneTabs.swift"))
        #expect(body.contains("mirrored"), "the log line cannot tell a mirrored ⌘T from a real one")
        #expect(body.contains("Linked panes:"),
                "the mirrored line does not say the link is why it happened")
        #expect(try Self.memberBody("func openNewTabHere(isLeft: Bool)",
                                    in: Self.source("ContentView+PaneTabs.swift"))
                    .contains("mirrored: true"),
                "the mirror is opened without marking itself as one")
    }

    /// Reopen logs from *inside* the verb, so a press with an empty stack — the item is always
    /// enabled, so that press is a real thing a user does — writes no line claiming a tab came back.
    @Test func reopenOnlyClaimsATabWhenOneComesBack() throws {
        let body = try Self.memberBody("func reopenClosedTab(isLeft: Bool)",
                                       in: Self.source("ContentView+PaneTabs.swift"))
        let guardIndex = try #require(body.range(of: "else { return nil }"),
                                      "reopen no longer distinguishes an empty stack")
        let log = try #require(body.range(of: "Logger.shared.info"))
        #expect(guardIndex.upperBound < log.lowerBound,
                "reopen logs before it knows whether anything came back")
    }

    /// **One setting, every way of walking into a folder.** The mirror predicate is the same
    /// expression `applyColumnNavigation` uses; two copies would let a link mean one thing for a
    /// drill and another for a tab, and nothing on screen would say which.
    @Test func theMirrorObeysTheSameLinkTestAsAMirroredDrill() throws {
        let predicate = "layoutMode == .compare\n            && (PaneLinkPreference.isLinked || NSEvent.modifierFlags.contains(.option))"
        #expect(try Self.source("ContentView+PaneTabs.swift").contains(predicate),
                "the tab mirror invented its own link test")
        #expect(try Self.source("ContentView.swift").contains(predicate),
                "the mirrored drill's link test moved — the two have drifted apart")
    }
}

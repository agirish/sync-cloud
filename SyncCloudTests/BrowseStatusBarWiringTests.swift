import AppKit
import Testing
import Design
import Foundation
@testable import SyncCloud

/// Browse's status bar where it meets the app: the View menu item, the preference's default, and
/// the one structural promise the bar makes, that it appears on Browse and nowhere else.
@MainActor
@Suite struct BrowseStatusBarWiringTests {

    // MARK: The menu

    /// A noun with a tick, beside the other view switches, and no chord. ⌘/ is Finder's Show Status
    /// Bar, and the two free alternatives both carry ⌥, which fires through the ⌥-hold reveal
    /// (`AppChordTests`). A chord added here later has to argue with this test.
    @Test func theViewMenuCarriesTheStatusBarSwitch() throws {
        let view = try appMenu("View")
        let titles = view.items.map(\.title).filter { !$0.isEmpty }
        let status = try #require(titles.firstIndex(of: "Status Bar"), "View ▸ Status Bar is gone")
        let tabBar = try #require(titles.firstIndex(of: "Tab Bar"))
        #expect(tabBar + 1 == status,
                "the switches read \(titles[tabBar...status]) — Status Bar belongs under Tab Bar")
        #expect(view.items.first { $0.title == "Status Bar" }?.keyEquivalent.isEmpty == true,
                "Status Bar has acquired a chord")
        #expect(!titles.contains { $0.hasPrefix("Show Status") || $0.hasPrefix("Hide Status") },
                "the status bar switch became a Show/Hide pair")
        // Edit's format bar is the next bar down: the same noun-with-a-tick, no chord, and greyed
        // here (the test host shows no document), as Text's items are.
        let format = try #require(titles.firstIndex(of: "Format Bar"), "View ▸ Format Bar is gone")
        #expect(status + 1 == format, "the switches read \(titles[tabBar...format]) — Format Bar belongs under Status Bar")
        let formatItem = try #require(view.items.first { $0.title == "Format Bar" })
        #expect(formatItem.keyEquivalent.isEmpty, "Format Bar has acquired a chord")
        #expect(!formatItem.isEnabled, "View ▸ Format Bar is live with no document open")
        #expect(view.items.filter { $0.title == "Format Bar" }.count == 1)
    }

    /// The View menu's builder is at its ten children, which is why the two chrome switches are
    /// grouped in `PaneChromeCommands`. A `ViewBuilder` silently takes only the first ten, so an
    /// eleventh added loose would drop an item off the menu with nothing failing.
    @Test func theViewMenusBuilderStaysWithinItsTenChildren() throws {
        let group = try declarationBody(of: "CommandGroup(after: .sidebar) {", in: macAppFile("SyncCloudApp.swift"))
        let children = group.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        #expect(children.count <= 10,
                "the View group lists \(children.count) children: \(children) — a ViewBuilder takes ten")
        #expect(children.contains("PaneChromeCommands()"),
                "the tab bar / status bar pair is no longer one child")
    }

    // MARK: Browse only

    /// The bar is built in `browseLayout`, not in `paneColumn`. `paneColumn` is the one pane that
    /// Browse, both Compare panes and the Organize/Storage rail are built from, so a bar there would
    /// appear on four surfaces, and Compare's two panes want two answers that one strip can't give.
    /// The scan reads structure because asking a rendered Compare needs the whole window.
    @Test func theBarIsBuiltForBrowseAndNotInTheSharedPaneColumn() throws {
        let layout = try macAppFile("ContentView+SplitLayout.swift")
        let browse = try declarationBody(of: "func browseLayout(geo: GeometryProxy) -> some View {", in: layout)
        #expect(browse.contains("browseStatusBar"), "browseLayout no longer builds the status bar")
        #expect(browse.contains("if statusBarVisible"),
                "the bar is drawn unconditionally — View ▸ Status Bar cannot hide it")

        // Exactly one construction in the whole app, so moving the call can't satisfy it: a second
        // `BrowseStatusBar(` anywhere in MacApp is a second surface drawing it.
        let built = try QuickLookOriginTests.macAppSwiftFiles().reduce(into: [String: Int]()) { counts, name in
            let hits = try macAppCode(name).components(separatedBy: "BrowseStatusBar(").count - 1
            if hits > 0 { counts[name] = hits }
        }
        #expect(built == ["ContentView+SplitLayout.swift": 1],
                "the status bar is constructed in \(built) — it belongs to browseLayout alone")

        // And it is not reached from the shared pane builder by another name.
        let column = try declarationBody(of: "func paneColumn(isLeft: Bool) -> some View {",
                                         in: macAppFile("ContentView.swift"))
        #expect(!column.contains("browseStatusBar") && !column.contains("StatusBar"),
                "paneColumn draws a status bar — it is shared with Compare and the lens rail")
    }

    /// The menu item is live on Browse and disabled everywhere else, following the folder
    /// sidebar's rule: a ticked switch on Compare would describe a strip that surface does not draw.
    @Test func theSwitchIsLiveOnBrowseAndNowhereElse() throws {
        let body = try declarationBody(of: "var shortcutStatusBar: Binding<Bool>? {", in: macAppFile("ShortcutCommands.swift"))
        #expect(body.contains("selectedWorkspace == .browse"),
                "the switch no longer gates on the one workspace that draws the bar")
    }

    // MARK: The preference

    /// On by default, unlike the tab bar beside it: the bar states facts the window has nowhere
    /// else to put, where a tab bar restates a folder name the header already shows. The key is its
    /// own: reusing `browseTabBarVisible` would tie two switches together.
    @Test func theStatusBarPreferenceDefaultsOnAndKeepsItsOwnKey() throws {
        let source = try macAppFile("ContentView.swift")
        #expect(source.contains(#"@AppStorage(BrowseWindowSettings.statusBarVisibleKey) var statusBarVisible: Bool = BrowseWindowSettings.statusBarVisibleDefault"#)
                && BrowseWindowSettings.statusBarVisibleKey == "browseStatusBarVisible" && BrowseWindowSettings.statusBarVisibleDefault,
                "the status bar preference is gone, renamed, or no longer defaults on")
        #expect(source.contains(#"@AppStorage(BrowseWindowSettings.tabBarVisibleKey) var tabBarVisible: Bool = BrowseWindowSettings.tabBarVisibleDefault"#)
                && BrowseWindowSettings.tabBarVisibleKey == "browseTabBarVisible" && !BrowseWindowSettings.tabBarVisibleDefault,
                "the tab bar preference moved — the two switches may now share a key")
    }
}

import AppKit
import Testing
import Foundation
@testable import SyncCloud

/// Browse's status bar where it meets the app (roadmap RD6): the View menu item, the preference's
/// default, and the one structural promise the bar makes — that it appears on Browse and nowhere
/// else.
@MainActor
@Suite struct BrowseStatusBarWiringTests {

    // MARK: The menu

    /// A noun with a tick, beside the other view switches, and **no chord**.
    ///
    /// The absence is the part worth pinning: ⌘/ is Finder's Show Status Bar and the two free
    /// alternatives both carry ⌥ — the one kind of chord that fires through the ⌥-hold reveal,
    /// which `AppChordTests` holds the whole app to. A chord arriving here later should have to
    /// argue with this test rather than slip in.
    @Test func theViewMenuCarriesTheStatusBarSwitch() throws {
        let view = try #require(NSApp.mainMenu?.items.first { $0.title == "View" }?.submenu,
                                "the app has no View menu")
        let titles = view.items.map(\.title).filter { !$0.isEmpty }
        let status = try #require(titles.firstIndex(of: "Status Bar"), "View ▸ Status Bar is gone")
        let tabBar = try #require(titles.firstIndex(of: "Tab Bar"))
        #expect(tabBar + 1 == status,
                "the switches read \(titles[tabBar...status]) — Status Bar belongs under Tab Bar")
        #expect(view.items.first { $0.title == "Status Bar" }?.keyEquivalent.isEmpty == true,
                "Status Bar has acquired a chord")
        #expect(!titles.contains { $0.hasPrefix("Show Status") || $0.hasPrefix("Hide Status") },
                "the status bar switch became a Show/Hide pair")
    }

    /// **The View menu's builder is at its ten children**, which is why the two chrome switches are
    /// grouped. A `ViewBuilder` silently takes only the first ten, so an eleventh added loose would
    /// drop an item off the menu with nothing failing — which is exactly what the grouping in
    /// `PaneChromeCommands` exists to prevent, and exactly what a later edit would undo.
    @Test func theViewMenusBuilderStaysWithinItsTenChildren() throws {
        let group = try Self.slice(from: "CommandGroup(after: .sidebar) {", to: "\n            }\n",
                                   in: try Self.source("SyncCloudApp.swift"))
        let children = group.split(separator: "\n")
            .map { $0.prefix { $0 != "/" }.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        #expect(children.count <= 10,
                "the View group lists \(children.count) children: \(children) — a ViewBuilder takes ten")
        #expect(children.contains("PaneChromeCommands()"),
                "the tab bar / status bar pair is no longer one child")
    }

    // MARK: Browse only

    /// **The bar is built in `browseLayout` and not in `paneColumn`** — which is the whole of the
    /// v4.2 deferral being answered rather than dodged.
    ///
    /// `paneColumn` is the ONE pane that Browse, both Compare panes and the Organize/Storage rail
    /// are all built from. A bar added there would appear on four surfaces, and Compare is the
    /// surface the deferral is about: two panes want two answers and one strip can give one. The
    /// scan reads structure rather than behaviour because there is no way to ask a rendered Compare
    /// "is there a status bar under you" without standing up the whole window.
    @Test func theBarIsBuiltForBrowseAndNotInTheSharedPaneColumn() throws {
        let layout = try Self.source("ContentView+SplitLayout.swift")
        let browse = try Self.slice(from: "func browseLayout(geo: GeometryProxy) -> some View {",
                                    to: "\n    }\n", in: layout)
        #expect(browse.contains("browseStatusBar"), "browseLayout no longer builds the status bar")
        #expect(browse.contains("if statusBarVisible"),
                "the bar is drawn unconditionally — View ▸ Status Bar cannot hide it")

        // **Exactly one construction in the whole app**, which is the check that cannot be
        // satisfied by moving the call somewhere else: a second `BrowseStatusBar(` anywhere in
        // MacApp is a second surface drawing it, whatever the enclosing function is called.
        let built = try Self.appSources().reduce(into: [String: Int]()) { counts, entry in
            let hits = entry.value.components(separatedBy: "BrowseStatusBar(").count - 1
            if hits > 0 { counts[entry.key] = hits }
        }
        #expect(built == ["ContentView+SplitLayout.swift": 1],
                "the status bar is constructed in \(built) — it belongs to browseLayout alone")

        // And it is not reached from the shared pane builder by another name.
        let column = try Self.slice(from: "func paneColumn(isLeft: Bool) -> some View {",
                                    to: "\n    }\n", in: try Self.source("ContentView.swift"))
        #expect(!column.contains("browseStatusBar") && !column.contains("StatusBar"),
                "paneColumn draws a status bar — it is shared with Compare and the lens rail")
    }

    /// The menu item is live on Browse and disabled everywhere else, following the folder
    /// sidebar's rule: a ticked switch on Compare would describe a strip that surface does not draw.
    @Test func theSwitchIsLiveOnBrowseAndNowhereElse() throws {
        let body = try Self.slice(from: "var shortcutStatusBar: Binding<Bool>? {", to: "\n    }\n",
                                  in: try Self.source("ShortcutCommands.swift"))
        #expect(body.contains("selectedWorkspace == .browse"),
                "the switch no longer gates on the one workspace that draws the bar")
    }

    // MARK: The preference

    /// **On by default**, unlike the tab bar beside it — the bar states facts the window has
    /// nowhere else to put, where a tab bar restates a folder name the header already shows. And
    /// the key is its own: reusing `browseTabBarVisible` would tie two switches together.
    @Test func theStatusBarPreferenceDefaultsOnAndKeepsItsOwnKey() throws {
        let source = try Self.source("ContentView.swift")
        #expect(source.contains(#"@AppStorage("browseStatusBarVisible") var statusBarVisible: Bool = true"#),
                "the status bar preference is gone, renamed, or no longer defaults on")
        #expect(source.contains(#"@AppStorage("browseTabBarVisible") var tabBarVisible: Bool = false"#),
                "the tab bar preference moved — the two switches may now share a key")
    }

    // MARK: Helpers

    private static func source(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // SyncCloudTests
            .deletingLastPathComponent()      // repo root
            .appendingPathComponent("MacApp/\(name)")
        let text = try String(contentsOf: url, encoding: .utf8)
        try #require(text.count > 500, "\(name) read as \(text.count) characters — truncated?")
        return text
    }

    /// Every Swift file under `MacApp`, by file name. The scan derives its subject from the tree
    /// rather than from a list, so a status bar built in a file added later is still caught.
    private static func appSources() throws -> [String: String] {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MacApp")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".swift") }
        try #require(names.count > 20, "found \(names.count) app sources — this scan would be thin")
        return try names.reduce(into: [:]) { out, name in
            out[name] = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
        }
    }

    /// The text between a declaration and its closing brace. A scan that reads the wrong region is
    /// worse than no scan, so both ends are required rather than defaulted.
    private static func slice(from opening: String, to closing: String, in source: String) throws -> String {
        let start = try #require(source.range(of: opening),
                                 "\(opening) is gone — this scan would be vacuous")
        let rest = source[start.upperBound...]
        let end = try #require(rest.range(of: closing), "\(opening) never closes")
        return String(rest[..<end.lowerBound])
    }
}

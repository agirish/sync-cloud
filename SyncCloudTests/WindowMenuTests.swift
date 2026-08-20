import Testing
import AppKit

/// **The Window and Help menus, read off the running app rather than out of the source.**
///
/// The test host IS the app, so `NSApp.mainMenu` is what AppKit actually built. That matters more
/// here than anywhere else in the menu bar, because the defect this suite pins was **invisible to a
/// source scan**: SwiftUI creates a Window-menu opener for every `Window` scene automatically, and
/// nothing in `MacApp/` writes those items down. Help carried a hand-written second copy of all
/// three auxiliary windows under a comment asserting the Activity Log "otherwise has no menu
/// entry", and every one of them was listed twice, in two menus, under two different names.
@MainActor
@Suite struct WindowMenuTests {

    static func menu(_ title: String) throws -> NSMenu {
        try #require(NSApp.mainMenu?.items.first { $0.title == title }?.submenu,
                     "the app has no \(title) menu — this check would be vacuous")
    }

    static func titles(_ menu: NSMenu) -> [String] {
        menu.items.filter { !$0.isSeparatorItem }.map(\.title)
    }

    /// Each auxiliary window is reachable, and reachable **once**.
    @Test(arguments: ["Activity Log", "Sync History", "Keyboard Shortcuts"])
    func eachAuxiliaryWindowAppearsExactlyOnceInTheWholeMenuBar(window: String) throws {
        let everywhere = try (NSApp.mainMenu?.items ?? []).flatMap { top -> [String] in
            guard let sub = top.submenu else { return [] }
            return Self.titles(sub)
        }
        #expect(everywhere.filter { $0 == window }.count == 1,
                "\(window) appears \(everywhere.filter { $0 == window }.count) times across the menu bar")
        #expect(Self.titles(try Self.menu("Window")).contains(window),
                "\(window) is not in the Window menu, which is where a Mac user looks for a window")
    }

    /// **The main window keeps its own opener**, and this is the assertion that stops the obvious
    /// fix from shipping. Suppressing the automatic entries of all three auxiliary scenes with
    /// `.commandsRemoved()` takes the main window's "SyncCloud" opener with them — measured twice,
    /// reproducibly — which would leave no menu route back after closing it. Only Activity Log's is
    /// suppressed, and only because its item carries ⌘L, which an automatic entry cannot.
    @Test func theMainWindowKeepsItsOpener() throws {
        #expect(Self.titles(try Self.menu("Window")).contains("SyncCloud"),
                "the Window menu lost the main window's own entry — closing it would strand the user")
    }

    /// ⌘L survives the move. It is a registered `AppChord` and a documented row in the ⌘/
    /// reference; an automatic Window-menu entry carries no key equivalent, which is the whole
    /// reason one item is still supplied by hand.
    @Test func activityLogKeepsItsChord() throws {
        let item = try #require(try Self.menu("Window").items.first { $0.title == "Activity Log" })
        #expect(item.keyEquivalent == "l")
        #expect(item.keyEquivalentModifierMask == .command)
    }

    /// Help keeps what is genuinely help, and nothing that is a window.
    @Test func helpCarriesNoWindowsAndNoSecondAbout() throws {
        let help = Self.titles(try Self.menu("Help"))
        #expect(!help.contains("About SyncCloud"),
                "Help still has an About — the application menu's own is supplied by AppKit and was never replaced, so this is the second one")
        for window in ["Activity Log", "Sync History", "Keyboard Shortcuts",
                       "Open Activity Log", "Open Sync History"] {
            #expect(!help.contains(window), "Help still carries \(window)")
        }
        #expect(help.contains("SyncCloud Help"), "Help lost its own front door")
        #expect(help.contains("Reveal Log File in Finder"),
                "the log reveal is a Finder action, not a window — it belongs here")
    }

    /// About is in the application menu, where AppKit puts it — the half of the duplication that
    /// was always correct.
    @Test func aboutIsInTheApplicationMenu() throws {
        #expect(Self.titles(try Self.menu("SyncCloud")).contains("About SyncCloud"))
    }
}

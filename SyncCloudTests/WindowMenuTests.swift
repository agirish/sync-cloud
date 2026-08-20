@testable import SyncCloud
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

/// Organize's two menu-bar homes: its sections under View, its row verbs under File.
///
/// Read off the running app for the same reason the Window menu is — a `Menu` inside a
/// `CommandGroup` is a submenu AppKit builds, and whether it landed where it was declared is not
/// something the source can answer.
@MainActor
@Suite struct OrganizeMenuTests {

    static func menu(_ title: String) throws -> NSMenu {
        try #require(NSApp.mainMenu?.items.first { $0.title == title }?.submenu,
                     "no \(title) menu — this check would be vacuous")
    }

    /// The five sections are a submenu of View, next to the workspaces.
    @Test func viewCarriesTheSectionsAsASubmenu() throws {
        let view = try Self.menu("View")
        let organize = try #require(view.items.first { $0.title == "Organize" && $0.hasSubmenu }?.submenu,
                                    "View has no Organize submenu — \(view.items.map(\.title))")
        let sections = organize.items.map(\.title)
        #expect(sections == ["To File", "Duplicates", "Renames", "Restructure", "Rules"],
                "the Organize submenu reads \(sections)")
    }

    /// **The workspace item and the submenu are different things with the same word.** View already
    /// had "Organize ⌘3", which selects the workspace; the submenu chooses a section inside it. The
    /// tell them apart, and the reason this is not a collision worth renaming: one has a chord and
    /// no submenu, the other has a submenu and no chord.
    @Test func theOrganizeWorkspaceItemIsStillThereAndDistinct() throws {
        let organizeItems = try Self.menu("View").items.filter { $0.title == "Organize" }
        #expect(organizeItems.count == 2, "expected the workspace item and the submenu, got \(organizeItems.count)")
        #expect(organizeItems.contains { $0.keyEquivalent == "3" && !$0.hasSubmenu },
                "the ⌘3 workspace item is gone")
        #expect(organizeItems.contains { $0.hasSubmenu && $0.keyEquivalent.isEmpty },
                "the sections submenu is gone, or acquired a chord")
    }

    /// The four verbs are in File, and none of them registers a key equivalent — every free chord
    /// is spent, and a verb that is usually unavailable is the wrong place to spend the next one.
    @Test func fileCarriesTheFourVerbsWithoutChords() throws {
        let titles = try Self.menu("File").items.map(\.title)
        for verb in ["Organize This Folder…", "Find Duplicates of This", "Fix Name…",
                     "Always Allow This Name"] {
            #expect(titles.contains(verb), "File is missing \(verb)")
        }
        let verbItems = try Self.menu("File").items.filter {
            ["Organize This Folder…", "Find Duplicates of This", "Fix Name…",
             "Always Allow This Name"].contains($0.title)
        }
        #expect(verbItems.allSatisfy { $0.keyEquivalent.isEmpty },
                "an Organize verb claimed a chord")
    }
}

/// Which of Organize's four verbs a selection offers.
@Suite struct OrganizeVerbAvailabilityTests {

    static func resolve(count: Int = 1, isDirectory: Bool = true,
                        isRisky: Bool = false) -> OrganizeVerbAvailability.Answer {
        OrganizeVerbAvailability.resolve(selectionCount: count, isDirectory: isDirectory, isRisky: isRisky)
    }

    @Test func oneFolderOffersOrganiseAndDuplicates() {
        let a = Self.resolve()
        #expect(a.organizeFolder && a.findDuplicates)
        #expect(!a.fixName && !a.keepName, "a name that is not risky has nothing to fix")
    }

    /// **Files are not organized.** The lens answers "where does this live", which is a question
    /// about a folder's contents — but duplicates are a question about any node.
    @Test func oneFileOffersDuplicatesButNotOrganise() {
        let a = Self.resolve(isDirectory: false)
        #expect(!a.organizeFolder)
        #expect(a.findDuplicates)
    }

    @Test func aRiskyNameUnlocksBothNameVerbs() {
        let a = Self.resolve(isRisky: true)
        #expect(a.fixName && a.keepName)
    }

    /// The discriminating case: a right-click has one row under the pointer by construction, a menu
    /// item does not, so every verb must refuse a multiple selection rather than take the first.
    @Test(arguments: [0, 2, 7])
    func onlyASingleSelectionOffersAnything(count: Int) {
        #expect(Self.resolve(count: count, isRisky: true)
                == OrganizeVerbAvailability.Answer(organizeFolder: false, findDuplicates: false,
                                                   fixName: false, keepName: false),
                "a selection of \(count) offered a verb")
    }
}

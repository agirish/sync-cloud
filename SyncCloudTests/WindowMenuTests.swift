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

/// The Organize menu — its sections, then its verbs.
///
/// Read off the running app rather than the source: whether a `CommandMenu` landed as its own
/// top-level menu, and in what order, is not a question the declaration can answer.
@MainActor
@Suite struct OrganizeMenuTests {

    static func menu(_ title: String) throws -> NSMenu {
        try #require(NSApp.mainMenu?.items.first { $0.title == title }?.submenu,
                     "no \(title) menu — this check would be vacuous")
    }

    static func titles(_ menu: NSMenu) -> [String] {
        menu.items.filter { !$0.isSeparatorItem }.map(\.title)
    }

    @Test func organizeIsItsOwnMenuOpeningWithTheFiveSections() throws {
        let organize = Self.titles(try Self.menu("Organize"))
        #expect(organize.prefix(5) == ["To File", "Duplicates", "Renames", "Restructure", "Rules"],
                "the Organize menu opens with \(organize.prefix(5))")
    }

    @Test func theFourVerbsFollowTheSections() throws {
        let organize = Self.titles(try Self.menu("Organize"))
        #expect(organize.suffix(4) == ["Organize This Folder…", "Find Duplicates of This",
                                       "Fix Name…", "Always Allow This Name"],
                "the Organize menu ends with \(organize.suffix(4))")
    }

    /// **The word appears once per menu, and that is the whole point of the arrangement.**
    ///
    /// The first cut put the sections in a `Menu("Organize")` inside View, four rows below the ⌘3
    /// workspace item — one menu, one word, two meanings, and a test asserting they were "distinct"
    /// rather than fixing it. View now carries only the workspace item, exactly as it carries
    /// "Compare ⌘2" beside a separate Compare menu.
    @Test func viewCarriesTheWorkspaceItemAndNothingElseCalledOrganize() throws {
        let organizeItems = try Self.menu("View").items.filter { $0.title == "Organize" }
        #expect(organizeItems.count == 1,
                "View has \(organizeItems.count) items called Organize — it should have only the workspace")
        #expect(organizeItems.first?.keyEquivalent == "3")
        #expect(organizeItems.first?.hasSubmenu == false, "the workspace item grew a submenu again")
    }

    /// The verbs left File when they gained a menu; File must not keep a stale copy.
    @Test func fileNoLongerCarriesTheVerbs() throws {
        let file = Self.titles(try Self.menu("File"))
        for verb in ["Organize This Folder…", "Find Duplicates of This", "Fix Name…",
                     "Always Allow This Name"] {
            #expect(!file.contains(verb), "File still carries \(verb)")
        }
    }

    /// No verb or section takes a chord — every free one is spent, and ⌘3 already reaches the
    /// workspace these all live inside.
    @Test func theOrganizeMenuRegistersNoChords() throws {
        #expect(try Self.menu("Organize").items.allSatisfy { $0.keyEquivalent.isEmpty },
                "something in the Organize menu claimed a chord")
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

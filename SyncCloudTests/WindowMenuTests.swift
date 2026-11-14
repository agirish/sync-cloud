@testable import SyncCloud
import Design
import Sync
import Testing
import AppKit

/// The Window and Help menus, read off the running app rather than out of the source.
///
/// The test host is the app, so `NSApp.mainMenu` is what AppKit actually built. A source scan
/// cannot see these items: SwiftUI creates a Window-menu opener for every `Window` scene, and
/// nothing in `MacApp/` writes them down, so a hand-written copy in Help would list each window
/// twice under two names.
@MainActor
@Suite struct WindowMenuTests {

    /// Each auxiliary window is reachable, and reachable once.
    @Test(arguments: ["Activity", "Keyboard Shortcuts"])
    func eachAuxiliaryWindowAppearsExactlyOnceInTheWholeMenuBar(window: String) throws {
        let everywhere = try (NSApp.mainMenu?.items ?? []).flatMap { top -> [String] in
            guard let sub = top.submenu else { return [] }
            return menuTitles(sub)
        }
        #expect(everywhere.filter { $0 == window }.count == 1,
                "\(window) appears \(everywhere.filter { $0 == window }.count) times across the menu bar")
        #expect(menuTitles(try appMenu("Window")).contains(window),
                "\(window) is not in the Window menu, which is where a Mac user looks for a window")
    }

    /// Sync History is a part of Activity's Events, not a tab or a window: no menu item names it.
    @Test func noMenuItemOpensSyncHistory() throws {
        let everywhere = (NSApp.mainMenu?.items ?? []).flatMap { top -> [String] in
            guard let sub = top.submenu else { return [] }
            return menuTitles(sub)
        }
        #expect(!everywhere.contains("Sync History"), "a menu item still opens a Sync History tab that no longer exists")
    }

    /// The main window keeps its own opener. **Never** suppress more scenes' automatic entries with
    /// `.commandsRemoved()`: doing it for the auxiliary scenes takes the main window's "SyncCloud"
    /// opener too, leaving no menu route back after closing it. Only Keyboard Shortcuts' is
    /// suppressed, for ⌘/; Activity's ⌘L goes on its automatic entry instead (`ActivityMenuKey`).
    @Test func theMainWindowKeepsItsOpener() throws {
        #expect(menuTitles(try appMenu("Window")).contains("SyncCloud"),
                "the Window menu lost the main window's own entry — closing it would strand the user")
    }

    /// Activity carries ⌘L, a registered `AppChord` and a documented row in the ⌘/ reference. Its
    /// entry is SwiftUI's automatic one, which a scene's own `.keyboardShortcut` does not reach, so
    /// `ActivityMenuKey` puts ⌘L on it. No item for the retired Activity Log window remains.
    @Test func activityKeepsTheLogsChord() throws {
        let window = try appMenu("Window")
        let item = try #require(window.items.first { $0.title == "Activity" })
        #expect(item.keyEquivalent == "l")
        #expect(item.keyEquivalentModifierMask == .command)
        #expect(!menuTitles(window).contains("Activity Log"), "the retired Activity Log window still has an item")
    }

    /// Every chord the app declares is actually on a menu item; only the built menu knows, and a
    /// command `View` with no call site leaves a documented key answering nothing. Presence, not
    /// enabled state: most are `@FocusedValue` items, correctly grey with no window focused.
    @Test func everyDeclaredChordIsOnAMenuItem() throws {
        var registered: Set<String> = []
        func walk(_ menu: NSMenu) {
            for item in menu.items {
                if !item.keyEquivalent.isEmpty {
                    registered.insert(Self.chordKey(item.keyEquivalent,
                                                    item.keyEquivalentModifierMask))
                }
                if let sub = item.submenu { walk(sub) }
            }
        }
        walk(try #require(NSApp.mainMenu, "the app built no menu bar — this check would be vacuous"))
        #expect(registered.count > 20,
                "only \(registered.count) chords found in the menu bar — the walk lost its way")

        // ⌘. is the progress capsule's stop, not a menu item (`AppChord.controlOnly`); its key is
        // proved through a real window by `ProgressCapsuleCancelKeyTests` instead.
        let controlOnly = Set(AppChord.controlOnly.map { Self.chordKey($0) })
        #expect(controlOnly.count == AppChord.controlOnly.count)
        // And the other way: no menu item may claim it, or the menu answers ⌘. before the dialog.
        #expect(registered.isDisjoint(with: controlOnly),
                "a menu item claims ⌘., which belongs to the progress capsule's stop")
        let missing = AppChord.registry
            .filter { !registered.contains(Self.chordKey($0)) && !controlOnly.contains(Self.chordKey($0)) }
            .map(\.display)
        #expect(missing.isEmpty, """
                \(missing.count) declared chord(s) are on no menu item: \(missing.joined(separator: ", ")).
                A chord in `AppChord.registry` has a row in the ⌘/ reference, so one that nothing \
                registers is a key the app documents and does not answer.
                """)
    }

    /// A chord as a comparable string. `AppChord` carries SwiftUI's `KeyEquivalent` and AppKit's
    /// items carry a `String` plus an `NSEvent.ModifierFlags`, so the two are folded to one
    /// spelling rather than compared across the frameworks' own types.
    static func chordKey(_ key: String, _ modifiers: NSEvent.ModifierFlags) -> String {
        var out = ""
        if modifiers.contains(.control) { out += "^" }
        if modifiers.contains(.option) { out += "~" }
        if modifiers.contains(.shift) { out += "$" }
        if modifiers.contains(.command) { out += "@" }
        return out + key.lowercased()
    }

    static func chordKey(_ chord: AppChord) -> String {
        chordKey(chord.appKitKeyEquivalent, chord.appKitModifierMask)
    }

    /// View ▸ Sidebar carries ⌃⌘S, and nothing else does; where the column cannot be drawn the item
    /// is disabled rather than deleted. Read off the built menu, so an item that lost its key
    /// equivalent fails.
    @Test func theSidebarSwitchIsInTheViewMenu() throws {
        let chorded = try menuItems(claiming: "s", modifiers: [.control, .command]).map(\.title)
        #expect(chorded == ["Sidebar"],
                "⌃⌘S is registered by \(chorded) — it belongs to View ▸ Sidebar and to nothing else")
    }

    /// Help keeps what is genuinely help, and nothing that is a window.
    @Test func helpCarriesNoWindowsAndNoSecondAbout() throws {
        let help = menuTitles(try appMenu("Help"))
        #expect(!help.contains("About SyncCloud"),
                "Help still has an About — the application menu's own is supplied by AppKit and was never replaced, so this is the second one")
        for window in ["Activity", "Activity Log", "Sync History", "Keyboard Shortcuts",
                       "Open Activity Log", "Open Sync History"] {
            #expect(!help.contains(window), "Help still carries \(window)")
        }
        #expect(help.contains("SyncCloud Help"), "Help lost its own front door")
        #expect(help.contains("Reveal Log File in Finder"),
                "the log reveal is a Finder action, not a window — it belongs here")
    }

    /// About is in the application menu, where AppKit puts it, and only there.
    @Test func aboutIsInTheApplicationMenu() throws {
        #expect(menuTitles(try appMenu("SyncCloud")).contains("About SyncCloud"))
    }
}

/// The Organize menu: its sections, then its verbs. Read off the running app, since whether a
/// `CommandMenu` landed as its own top-level menu, and in what order, the declaration cannot say.
@MainActor
@Suite struct OrganizeMenuTests {

    @Test func organizeIsItsOwnMenuOpeningWithTheFiveSections() throws {
        let organize = menuTitles(try appMenu("Organize"))
        #expect(organize.prefix(5) == ["To File", "Duplicates", "Renames", "Restructure", "Rules"],
                "the Organize menu opens with \(organize.prefix(5))")
    }

    /// The order is the argument: the folder verbs with File with Claude after them, then the two
    /// that open a Restructure surface, then the ledger undo, which is about a landing that already
    /// happened, not a thing to do with a selection.
    @Test func theVerbsFollowTheSections() throws {
        let organize = menuTitles(try appMenu("Organize"))
        #expect(organize.suffix(8) == ["Organize This Folder…", "Find Duplicates of This", "File with Claude",
                                       "Fix Name", "Always Allow This Name",
                                       "Plan This Folder’s Shape…", "Set Up Like Its Siblings",
                                       "Undo This Reorganization…"],
                "the Organize menu ends with \(organize.suffix(8))")
    }

    /// The word appears once per menu: View carries only the ⌘3 workspace item, as it carries
    /// "Compare ⌘2" beside a separate Compare menu. A sections submenu there would give one word two
    /// meanings in one menu.
    @Test func viewCarriesTheWorkspaceItemAndNothingElseCalledOrganize() throws {
        let organizeItems = try appMenu("View").items.filter { $0.title == "Organize" }
        #expect(organizeItems.count == 1,
                "View has \(organizeItems.count) items called Organize — it should have only the workspace")
        #expect(organizeItems.first?.keyEquivalent == "3")
        #expect(organizeItems.first?.hasSubmenu == false, "the workspace item grew a submenu again")
    }

    /// The verbs left File when they gained a menu; File must not keep a stale copy.
    @Test func fileNoLongerCarriesTheVerbs() throws {
        let file = menuTitles(try appMenu("File"))
        for verb in ["Organize This Folder…", "Find Duplicates of This", "Fix Name",
                     "Always Allow This Name"] {
            #expect(!file.contains(verb), "File still carries \(verb)")
        }
    }

    /// No verb or section takes a chord: every free one is spent, and ⌘3 already reaches the
    /// workspace these all live inside.
    @Test func theOrganizeMenuRegistersNoChords() throws {
        #expect(try appMenu("Organize").items.allSatisfy { $0.keyEquivalent.isEmpty },
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

    /// Files are not organized: the lens answers "where does this live", a question about a
    /// folder's contents. Duplicates are a question about any node.
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

/// The Edit menu's file verbs, and the one property that must not be "tidied".
@MainActor
@Suite struct EditMenuTests {

    static func item(_ title: String) throws -> NSMenuItem {
        try #require(try appMenu("Edit").items.first { $0.title == title }, "Edit has no \(title)")
    }

    @Test(arguments: [("Select All", "a"), ("Cut", "x"), ("Copy", "c"), ("Paste", "v")])
    func eachFileVerbIsPresentWithItsChord(spec: (title: String, key: String)) throws {
        let item = try Self.item(spec.title)
        #expect(item.keyEquivalent == spec.key)
        #expect(item.keyEquivalentModifierMask == .command)
    }

    /// None of the four may be disabled. `.disabled()` on a SwiftUI menu item is static per render
    /// and cannot know where the caret is, so disabling Copy with no files selected would also grey
    /// it while someone types in the ⌘K field. The items stay live and `TextEditingChord.route`
    /// picks the meaning at fire time. The test host has no selection and no caret, the very state
    /// that tempts disabling them.
    @Test(arguments: ["Select All", "Cut", "Copy", "Paste"])
    func theEditItemsAreNeverDisabled(title: String) throws {
        #expect(try Self.item(title).isEnabled,
                "\(title) is disabled — that kills the chord in every text field too")
    }

    /// Exactly one item claims each of the four chords. Two would leave one dead and AppKit picks.
    @Test func noChordIsClaimedTwiceInEdit() throws {
        let chords = try appMenu("Edit").items
            .filter { !$0.keyEquivalent.isEmpty && $0.keyEquivalentModifierMask == .command }
            .map(\.keyEquivalent)
        for key in ["a", "x", "c", "v"] {
            #expect(chords.filter { $0 == key }.count == 1,
                    "⌘\(key.uppercased()) is claimed \(chords.filter { $0 == key }.count) times in Edit")
        }
    }
}

/// Which section the Organize menu ticks.
@Suite struct OrganizeTickTests {

    /// In Organize, the stored section is the one showing.
    @Test func inOrganizeTheStoredSectionIsTicked() {
        #expect(OrganizeLensSwitch.tick(workspace: .filing, stored: .duplicates) == .duplicates)
        #expect(OrganizeLensSwitch.tick(workspace: .filing, stored: nil) == nil,
                "the overview is not a section and ticks nothing")
    }

    /// Outside Organize nothing is ticked, because nothing is showing. The stored key survives
    /// leaving, so ⌘3 returns you where you were, but ticking it from Browse would claim a section
    /// is on screen while the window shows a file tree.
    @Test(arguments: [Workspace.browse, .compare, .editor])
    func outsideOrganizeNothingIsTicked(workspace: Workspace) {
        #expect(OrganizeLensSwitch.tick(workspace: workspace, stored: .duplicates) == nil,
                "\(workspace) ticked a section it is not showing")
    }
}

/// Whether ⌘A means the pane.
@Suite struct SelectAllScopeTests {

    /// The ordinary case, and the one a fresh window is in.
    @Test(arguments: [SelectionSurface.pane, nil])
    func thePaneOrNothingMeansThePane(surface: SelectionSurface?) {
        #expect(SelectAllScope.appliesToPane(surface: surface))
    }

    /// A differences selection withholds it. ⌘A is an app-wide menu equivalent, so otherwise it
    /// would select the whole pane in a Compare window whose selection lives in the Differences
    /// table, re-aiming ⌘⌫ and the transfer verbs at rows the user was not looking at. The table has
    /// no select-all of its own, so nothing is lost.
    @Test func aDifferencesSelectionWithholdsIt() {
        #expect(!SelectAllScope.appliesToPane(surface: .differences))
    }
}

/// ⌘X, ⌘C, ⌘V and ⌘A while Edit's file pane is folded.
@Suite struct EditorFoldedPaneKeysTests {

    /// Folded in Edit, and only there. An open pane shows the selection the keys act on, and every
    /// other workspace's pane is on screen whenever it has the keys.
    @Test func onlyEditsFoldedPaneRefuses() {
        #expect(EditorFoldedPaneKeys.refuses(workspace: .editor, paneFolded: true))
        #expect(!EditorFoldedPaneKeys.refuses(workspace: .editor, paneFolded: false))
        for workspace in Workspace.allCases where workspace != .editor {
            #expect(!EditorFoldedPaneKeys.refuses(workspace: workspace, paneFolded: true), "\(workspace)")
        }
    }

    /// All three clipboard verbs answer, so each is heard to refuse. A `nil` half would make the key
    /// silent: the item stays live (`theEditItemsAreNeverDisabled`) and does nothing.
    @Test func everyClipboardVerbAnswers() {
        let refused = EditorFoldedPaneKeys.clipboard
        #expect(refused.cut != nil && refused.copy != nil && refused.paste != nil)
    }

    /// The rule is asked before the pane is read, by both values the four items publish from.
    @Test func bothPublishedValuesAskTheRuleFirst() throws {
        let commands = try macAppFile("ShortcutCommands.swift")
        let ask = "if EditorFoldedPaneKeys.refuses(workspace: selectedWorkspace, paneFolded: editorPaneIsFolded) {"
        for (declaration, answer) in [("var shortcutSelectAll: (() -> Void)? {", "return EditorFoldedPaneKeys.refusal"),
                                      ("var shortcutClipboard: ClipboardActions {", "return EditorFoldedPaneKeys.clipboard")] {
            let body = CodeText(try declarationBody(of: declaration, in: commands))
            let rule = try #require(body.range(of: ask + " " + answer), "\(declaration) never asks the rule")
            let pane = try #require(body.range(of: "shortcutTargetIsLeft"))
            #expect(rule.lowerBound < pane.lowerBound, "\(declaration) reads the pane before asking")
        }
    }
}

/// What the pane row menu's verbs offer, now that they are also menu items.
@Suite struct PaneRowVerbAvailabilityTests {

    static func resolve(count: Int = 1, isDirectory: Bool = true,
                        canOpenInNewTab: Bool = true,
                        isComparing: Bool = true,
                        opensInEdit: Bool = false) -> PaneRowVerbAvailability.Answer {
        PaneRowVerbAvailability.resolve(selectionCount: count, isDirectory: isDirectory,
                                        canOpenInNewTab: canOpenInNewTab, isComparing: isComparing,
                                        opensInEdit: opensInEdit)
    }

    /// File ▸ Open in Edit: one row, a file, and a file the editor opens, each term asserted by
    /// removing it alone. A multi-selection would hand over whichever node came first.
    @Test func openInEditNeedsASingleTextFile() {
        #expect(Self.resolve(count: 1, isDirectory: false, opensInEdit: true).openInEditor)
        #expect(!Self.resolve(count: 1, isDirectory: true, opensInEdit: true).openInEditor,
                "a folder offered the editor")
        #expect(!Self.resolve(count: 2, isDirectory: false, opensInEdit: true).openInEditor,
                "a multi-selection offered the editor")
        #expect(!Self.resolve(count: 1, isDirectory: false, opensInEdit: false).openInEditor,
                "a file the editor does not open was offered to it")
    }

    @Test func oneFolderOffersEverything() {
        let a = Self.resolve()
        #expect(a.openInNewTab && a.singleNodeVerbs && a.chooseDestination && a.ignore)
    }

    // MARK: File ▸ Download (roadmap RD2) — decided by `CloudDownloadOffer`, tested in FileExplorer

    /// A file has no tab to open, but keeps Quick Look, Reveal and Rename.
    @Test func aFileOffersTheSingleNodeVerbsButNoTab() {
        let a = Self.resolve(isDirectory: false)
        #expect(!a.openInNewTab)
        #expect(a.singleNodeVerbs)
    }

    /// The pane decides whether tabs are available at all, as the row menu does.
    @Test func aPaneThatCannotOpenTabsWithholdsIt() {
        #expect(!Self.resolve(canOpenInNewTab: false).openInNewTab)
    }

    /// A batch still picks a destination. Copy to… and Move to… work on many; the picker and
    /// `FileOperations` both prune nested nodes, so a folder and its child cannot both travel.
    @Test(arguments: [2, 9])
    func aBatchKeepsTheDestinationPickerAndLosesTheSingleNodeVerbs(count: Int) {
        let a = Self.resolve(count: count)
        #expect(a.chooseDestination && a.ignore)
        #expect(!a.singleNodeVerbs && !a.openInNewTab,
                "Quick Look, Reveal and Rename have no referent for \(count) rows")
    }

    /// Ignoring is a statement about a comparison, so a pane with no comparison has nothing to say.
    @Test func withoutAComparisonThereIsNothingToIgnore() {
        #expect(!Self.resolve(isComparing: false).ignore)
        #expect(Self.resolve(isComparing: false).chooseDestination,
                "a destination pick is not about comparing and must survive")
    }

    /// The call-site half: `shortcutPaneRowVerbs` answers `isCloudOnly` from the badge cache, a
    /// memo of what the drawn row already found, and never with an `lstat` of its own, which on a
    /// wedged provider would stall every `ContentView` body pass. The offer itself,
    /// `CloudDownloadOffer.forActiveSelection`, takes the folders' one read off the main thread, so
    /// its body is scanned too.
    @Test func theMenuItemReadsTheBadgeCacheAndNeverStats() throws {
        let body = try declarationBody(of: "var shortcutPaneRowVerbs: PaneRowVerbs",
                                       in: try macAppFile("ShortcutCommands.swift"))
        #expect(body.contains("CloudDownloadOffer.forActiveSelection("),
                "File ▸ Download stopped asking for the active selection's offer")
        #expect(!body.contains("MaterializationStatus."),
                "File ▸ Download stats the filesystem on every body pass")
        #expect(body.contains("CloudDownloadRequest.request(offer"),
                "File ▸ Download stopped sharing the row verb's body")

        let offer = try declarationBody(
            of: "public static func forActiveSelection(",
            in: try repoFile("Modules/FileExplorer/Sources/FileExplorer/CloudDownloadOffer.swift"))
        #expect(offer.contains("CloudOnlyBadgeCache.cached("),
                "File ▸ Download no longer reads the badge's memo")
        #expect(!offer.contains("MaterializationStatus."),
                "File ▸ Download stats the filesystem on every body pass")
        #expect(offer.contains("forSelection("),
                "File ▸ Download stopped asking the row menu's own question")
        #expect(offer.contains("BoundedCloudRead.shared.run"),
                "File ▸ Download reads a folder's domain on the main thread again")
    }

    @Test func anEmptySelectionOffersNothing() {
        let a = Self.resolve(count: 0)
        #expect(a == PaneRowVerbAvailability.Answer(openInNewTab: false, singleNodeVerbs: false,
                                                    openInEditor: false,
                                                    chooseDestination: false, ignore: false))
    }
}

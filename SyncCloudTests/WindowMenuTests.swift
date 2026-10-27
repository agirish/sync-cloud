@testable import SyncCloud
import Design
import Sync
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

    /// Each auxiliary window is reachable, and reachable **once**. Sync History is Activity's
    /// History tab now (TE232), and keeps its item under the name people know.
    @Test(arguments: ["Activity", "Sync History", "Keyboard Shortcuts"])
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
    /// reproducibly — which would leave no menu route back after closing it. Only Keyboard Shortcuts'
    /// is suppressed, for its ⌘/; suppressing Activity's too (for ⌘L) took the opener with it, again,
    /// measured 2026-10-27 — so ⌘L is put on Activity's automatic entry instead (`ActivityMenuKey`).
    @Test func theMainWindowKeepsItsOpener() throws {
        #expect(Self.titles(try Self.menu("Window")).contains("SyncCloud"),
                "the Window menu lost the main window's own entry — closing it would strand the user")
    }

    /// ⌘L survives the move to one Activity window (TE232). It is a registered `AppChord` and a
    /// documented row in the ⌘/ reference. Activity's entry is SwiftUI's automatic one, which carries
    /// no key equivalent — a scene's own `.keyboardShortcut` does not reach it (measured 2026-10-27)
    /// — so `ActivityMenuKey` puts ⌘L on it. The Activity Log's old item is gone.
    @Test func activityKeepsTheLogsChord() throws {
        let window = try Self.menu("Window")
        let item = try #require(window.items.first { $0.title == "Activity" })
        #expect(item.keyEquivalent == "l")
        #expect(item.keyEquivalentModifierMask == .command)
        #expect(!Self.titles(window).contains("Activity Log"), "the retired Activity Log window still has an item")
    }

    /// **Every chord the app declares is actually on a menu item.**
    ///
    /// The guard that was missing, and the regression it catches shipped inside the very commit
    /// this suite was written for. `cd87b08e` took the auxiliary windows out of the Help menu —
    /// correctly — and `ShortcutsWindowCommand` was the only thing in the app registering ⌘/. It
    /// was not put anywhere else, so from that commit the app's own keyboard-shortcut chord opened
    /// nothing: a `View` with no call site, and a documented row in the ⌘/ reference pointing at a
    /// key that did nothing.
    ///
    /// Nothing could see it. `AppChordTests` reads the registry, `ShortcutsReferenceTests` compares
    /// the registry against the reference table, and neither knows whether anything *registers* the
    /// chord — the same blindness that let a menu carry two copies of one window. Only the built
    /// menu knows, and the test host is the app, so it can be asked.
    ///
    /// Presence, not enabled state: most of these are `@FocusedValue` items that are correctly grey
    /// with no window focused. An item that is not there at all is the failure.
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

        // ⌘. is the progress capsule's stop, not a menu item — see `AppChord.controlOnly`, whose
        // key is proved through a real window by `ProgressCapsuleCancelKeyTests` instead.
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
        var out = ""
        if chord.modifiers.contains(.control) { out += "^" }
        if chord.modifiers.contains(.option) { out += "~" }
        if chord.modifiers.contains(.shift) { out += "$" }
        if chord.modifiers.contains(.command) { out += "@" }
        return out + String(chord.key.character).lowercased()
    }

    /// **View ▸ Sidebar is in the bar, and it carries ⌃⌘S** — the column is on for v4.4 (item #13),
    /// and where it cannot be drawn (collapsed panes) the item is disabled rather than deleted.
    ///
    /// **This test has now asserted both directions, and the swap each way is the point.** A menu
    /// item is built from a `Commands` declaration whether or not anything answers it, so while the
    /// column was held it would have been possible to leave the tick, the chord and a greyed row
    /// exactly where they were — ⌃⌘S doing nothing, in the place a Mac user reaches for a sidebar.
    /// This is what said no then, and it is what says the item is really registered now: neither
    /// direction is visible in review, because both compile and both read correctly.
    ///
    /// Both halves, because either alone can go missing: an item titled "Sidebar" that lost its key
    /// equivalent passes a title check and leaves Finder's chord dead.
    @Test func theSidebarSwitchIsInTheViewMenu() throws {
        var titles: [String] = []
        var chorded: [String] = []
        func walk(_ menu: NSMenu) {
            for item in menu.items {
                titles.append(item.title)
                if item.keyEquivalent.lowercased() == "s",
                   item.keyEquivalentModifierMask == [.control, .command] {
                    chorded.append(item.title)
                }
                if let sub = item.submenu { walk(sub) }
            }
        }
        walk(try #require(NSApp.mainMenu, "the app built no menu bar — this check would be vacuous"))
        // The walk can see a switch that IS there, or every check below is a check on an empty list.
        #expect(titles.contains("Tab Bar"), "the walk cannot see View ▸ Tab Bar — it is not reading the bar")

        #expect(titles.contains("Sidebar"),
                "no menu item is titled Sidebar — the column has a chord and a toolbar button with no menu home")
        #expect(chorded == ["Sidebar"],
                "⌃⌘S is registered by \(chorded) — it belongs to View ▸ Sidebar and to nothing else")
    }

    /// Help keeps what is genuinely help, and nothing that is a window.
    @Test func helpCarriesNoWindowsAndNoSecondAbout() throws {
        let help = Self.titles(try Self.menu("Help"))
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

    /// Six verbs since §11's two deferred ones landed (proposal O10). The order is the argument:
    /// the four folder verbs, then the two that open a Restructure surface, then the ledger undo
    /// — which is about a landing that already happened, not a thing to do with a selection.
    @Test func theVerbsFollowTheSections() throws {
        let organize = Self.titles(try Self.menu("Organize"))
        #expect(organize.suffix(7) == ["Organize This Folder…", "Find Duplicates of This",
                                       "Fix Name", "Always Allow This Name",
                                       "Plan This Folder’s Shape…", "Set Up Like Its Siblings",
                                       "Undo This Reorganization…"],
                "the Organize menu ends with \(organize.suffix(7))")
    }

    /// §11's one hard constraint on the new verb: it must never sit beside ⌘Z's Undo. Edit is
    /// where that mistake would live, so Edit is asserted clean of it.
    @Test func editNeverCarriesTheReorganisationUndo() throws {
        let edit = Self.titles(try Self.menu("Edit"))
        #expect(!edit.contains("Undo This Reorganization…"),
                "the ledger undo sat down beside ⌘Z — exactly the confusion §11 forbids")
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
        for verb in ["Organize This Folder…", "Find Duplicates of This", "Fix Name",
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

/// The Edit menu's file verbs, and the one property that must not be "tidied".
@MainActor
@Suite struct EditMenuTests {

    static func edit() throws -> NSMenu {
        try #require(NSApp.mainMenu?.items.first { $0.title == "Edit" }?.submenu,
                     "no Edit menu — this check would be vacuous")
    }

    static func item(_ title: String) throws -> NSMenuItem {
        try #require(try Self.edit().items.first { $0.title == title }, "Edit has no \(title)")
    }

    @Test(arguments: [("Select All", "a"), ("Cut", "x"), ("Copy", "c"), ("Paste", "v")])
    func eachFileVerbIsPresentWithItsChord(spec: (title: String, key: String)) throws {
        let item = try Self.item(spec.title)
        #expect(item.keyEquivalent == spec.key)
        #expect(item.keyEquivalentModifierMask == .command)
    }

    /// **None of the four may be disabled, and this is the guard on that.**
    ///
    /// A menu item cannot know where the caret is when it renders, so disabling Copy when no files
    /// are selected would grey it out while somebody is typing in the ⌘K field — and `.disabled()`
    /// on a SwiftUI menu item is static per render, not a validator that could ask. The items stay
    /// live and `TextEditingChord.route` picks the meaning at fire time.
    ///
    /// The test host has no selection and no caret, which is precisely the state that would tempt
    /// someone to disable them.
    @Test(arguments: ["Select All", "Cut", "Copy", "Paste"])
    func theEditItemsAreNeverDisabled(title: String) throws {
        #expect(try Self.item(title).isEnabled,
                "\(title) is disabled — that kills the chord in every text field too")
    }

    /// Exactly one item claims each of the four chords. Two would leave one dead and AppKit picks.
    @Test func noChordIsClaimedTwiceInEdit() throws {
        let chords = try Self.edit().items
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

    /// **Outside Organize nothing is ticked**, because nothing is showing. The stored key survives
    /// leaving — that is what makes ⌘3 return you where you were — so ticking it from Browse would
    /// be the menu claiming a section is on screen while the window shows a file tree.
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

    /// **A differences selection withholds it.** ⌘A is registered app-wide as a menu equivalent, so
    /// without this it fires in a Compare window whose selection lives in the Differences table and
    /// selects the whole pane instead — re-aiming ⌘⌫ and the transfer verbs at rows the user was not
    /// looking at. The table has no select-all of its own, so nothing that worked stops working.
    @Test func aDifferencesSelectionWithholdsIt() {
        #expect(!SelectAllScope.appliesToPane(surface: .differences))
    }
}

/// ⌘X, ⌘C, ⌘V and ⌘A while Edit's file pane is folded (TE153, decision BR).
@Suite struct EditorFoldedPaneKeysTests {

    /// **Folded in Edit, and only there.** An open pane shows the selection the keys act on, and
    /// every other workspace's pane is on screen whenever it has the keys.
    @Test func onlyEditsFoldedPaneRefuses() {
        #expect(EditorFoldedPaneKeys.refuses(workspace: .editor, paneFolded: true))
        #expect(!EditorFoldedPaneKeys.refuses(workspace: .editor, paneFolded: false))
        for workspace in Workspace.allCases where workspace != .editor {
            #expect(!EditorFoldedPaneKeys.refuses(workspace: workspace, paneFolded: true), "\(workspace)")
        }
    }

    /// **All three clipboard verbs answer, so each one is heard to refuse.** A `nil` half would
    /// make the key silent — the item stays live (`theEditItemsAreNeverDisabled`) and does nothing.
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

    /// **File ▸ Open in Edit: one row, a file, and a file the editor opens.**
    ///
    /// Each term is asserted by removing it and nothing else, because all three have been the
    /// wrong answer somewhere in this family: a folder is the case the row menu's own gate exists
    /// for, a multi-selection would hand over whichever node happened to be first, and a `.pdf`
    /// would open a document the editor then refuses.
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

    /// The pane decides whether tabs are available at all — the row menu asks the same question.
    @Test func aPaneThatCannotOpenTabsWithholdsIt() {
        #expect(!Self.resolve(canOpenInNewTab: false).openInNewTab)
    }

    /// **A batch still picks a destination.** Copy to… and Move to… work on many; the picker and
    /// `FileOperations` both prune nested nodes, so a folder and its child cannot both travel.
    @Test(arguments: [2, 9])
    func aBatchKeepsTheDestinationPickerAndLosesTheSingleNodeVerbs(count: Int) {
        let a = Self.resolve(count: count)
        #expect(a.chooseDestination && a.ignore)
        #expect(!a.singleNodeVerbs && !a.openInNewTab,
                "Quick Look, Reveal and Rename have no referent for \(count) rows")
    }

    /// **Ignoring is a statement about a comparison**, so Browse and Storage have nothing to say.
    @Test func withoutAComparisonThereIsNothingToIgnore() {
        #expect(!Self.resolve(isComparing: false).ignore)
        #expect(Self.resolve(isComparing: false).chooseDestination,
                "a destination pick is not about comparing and must survive")
    }

    /// The call-site half: `shortcutPaneRowVerbs` answers `isCloudOnly` from the badge cache — a
    /// memo of what the drawn row already found — and never with an `lstat` of its own, which on a
    /// wedged provider would stall every `ContentView` body pass. Both halves, because the memo
    /// read is one edit away from being "fixed" into the stat the row menu is allowed to make.
    @Test func theMenuItemReadsTheBadgeCacheAndNeverStats() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MacApp/ShortcutCommands.swift")
        let source = sourceCodeOnly(try String(contentsOf: url, encoding: .utf8))
        let start = try #require(source.range(of: "var shortcutPaneRowVerbs: PaneRowVerbs {"),
                                 "shortcutPaneRowVerbs is gone — this scan would be vacuous")
        let rest = source[start.upperBound...]
        let end = try #require(rest.range(of: "\n    }\n"))
        let body = String(rest[..<end.lowerBound])
        #expect(body.contains("CloudOnlyBadgeCache.cached("),
                "File ▸ Download no longer reads the badge's memo")
        #expect(!body.contains("MaterializationStatus."),
                "File ▸ Download stats the filesystem on every body pass")
        #expect(body.contains("CloudDownloadOffer.forSelection("),
                "File ▸ Download stopped asking the row menu's own question")
        #expect(body.contains("CloudDownloadRequest.request(offer"),
                "File ▸ Download stopped sharing the row verb's body")
    }

    @Test func anEmptySelectionOffersNothing() {
        let a = Self.resolve(count: 0)
        #expect(a == PaneRowVerbAvailability.Answer(openInNewTab: false, singleNodeVerbs: false,
                                                    openInEditor: false,
                                                    chooseDestination: false, ignore: false))
    }
}

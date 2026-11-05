@testable import SyncCloud
import Dashboard
import Design
import Testing
import Foundation

/// The sidebar's refresh triggers, read off `ContentView`'s source, since `ContentView` can't be
/// instantiated in a test. `refreshFolderSidebarRows` returns early unless the column is on screen,
/// so switching the sidebar on and arriving at Browse must themselves be triggers; without them the
/// column shows whatever it last resolved, and an empty or stale list reads as "my pins are gone".
/// The scan reads one named file, strips comments so prose can't satisfy it, and requires a known
/// trigger so a scan that finds nothing fails.
@Suite struct FolderSidebarWiringTests {

    static func contentViewSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MacApp/ContentView.swift")
        let raw = try #require(try? String(contentsOf: url, encoding: .utf8),
                               "cannot read ContentView.swift — this scan would be vacuous")
        try #require(raw.count > 5000, "ContentView.swift is implausibly short — the scan is vacuous")
        // Comments stripped at `//`, so a trigger named in prose cannot stand in for one that runs.
        return raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let comment = line.range(of: "//") else { return line }
                return line[..<comment.lowerBound]
            }
            .joined(separator: "\n")
    }

    /// Each trigger with the call it must make, matched as one string: `.onChange(of:
    /// selectedWorkspace)` exists for other reasons too, so finding it proves nothing unless the
    /// refresh is inside it.
    @Test(arguments: ["browseSidebarVisible", "selectedWorkspace", "leftProviderId",
                      "browseSidebarRecentsMode"])
    func everyTriggerTheGuardMakesNecessaryIsWired(value: String) throws {
        let source = try Self.contentViewSource()
        let declaration = ".onChange(of: \(value)) { _, _ in refreshFolderSidebarRows() }"
        #expect(source.contains(declaration),
                "\(value) does not refresh the sidebar — with the on-screen guard in place, the column keeps whatever rows it last resolved")
    }

    /// The scan reads something: a trigger that is definitely there must be found, or the checks
    /// above pass over an empty string.
    @Test func theScanCanSeeAKnownTrigger() throws {
        #expect(try Self.contentViewSource().contains("refreshFolderSidebarRows()"))
    }

    /// The guard is the one rule, not a hand-rolled copy: the layout's `if` and the refresh's guard
    /// must ask the same question, or the column draws rows nobody refreshed.
    @Test func bothSitesAskTheOneRule() throws {
        let source = try Self.contentViewSource()
        #expect(!source.contains("selectedWorkspace == .browse, browseSidebarVisible"),
                "the guard was re-spelled in ContentView instead of going through FolderSidebarModel")

        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MacApp/ContentView+SplitLayout.swift")
        let layout = try #require(try? String(contentsOf: url, encoding: .utf8))
        #expect(layout.contains("if folderSidebarIsShowing"),
                "browseLayout draws the sidebar on its own condition rather than the shared rule")
    }
}

/// The sidebar's chord in the registry and its row in the ⌘/ reference, which decide whether ⌃⌘S
/// is discoverable. The menu bar is asserted in `WindowMenuTests.theSidebarSwitchIsInTheViewMenu`.
/// The chord, the menu item and the row travel together: one without the others documents a
/// keystroke that does nothing, or ships one nobody can find.
@Suite struct TheSidebarHasItsChordAndItsRow {

    @Test func theChordIsInTheRegistry() {
        #expect(AppChord.registry.contains { $0.display == "⌃⌘S" },
                "⌃⌘S is not in the registry — the ⌘/ panel is generated from it, so the sidebar's chord would be undocumented")
    }

    /// Exactly one row names it, by chord: two rows for one switch is how a panel starts disagreeing
    /// with itself.
    @Test func exactlyOneShortcutsReferenceRowDescribesTheSidebar() {
        let rows = ShortcutsReference.groups.flatMap(\.items)
        #expect(rows.count > 10, "the reference is implausibly short — this scan would be near-vacuous")
        let chorded = rows.filter { $0.keys.replacingOccurrences(of: " ", with: "").contains("⌃⌘S") }
        #expect(chorded.count == 1, "\(chorded.count) rows list ⌃⌘S: \(chorded.map(\.action))")
        #expect(chorded.first?.action.lowercased().contains("sidebar") == true,
                "the ⌃⌘S row does not say what it toggles: “\(chorded.first?.action ?? "")”")
    }

    /// The row names no workspace. Every workspace has a sidebar, so any qualifier could only go
    /// stale when the set changes, with nothing to catch it. Asserted, so re-adding one has to be
    /// deliberate.
    @Test func theRowDoesNotEnumerateWorkspaces() {
        let rows = ShortcutsReference.groups.flatMap(\.items)
        let row = rows.first { $0.keys.replacingOccurrences(of: " ", with: "").contains("⌃⌘S") }
        let action = row?.action ?? ""
        for workspace in Workspace.allCases.map(\.title) {
            #expect(!action.localizedCaseInsensitiveContains(workspace),
                    "the ⌃⌘S row names \(workspace) — every workspace has a sidebar, so the qualifier can only go stale: “\(action)”")
        }
        #expect(action.localizedCaseInsensitiveContains("sidebar"),
                "the row no longer says what it toggles: “\(action)”")
    }
}

/// Every input to the visibility gate has a refresh trigger. `refreshFolderSidebarRows` returns
/// early while the column is off screen, since it `stat`s every provider root, so anything firing
/// while it is hidden is dropped and nothing re-runs it when the column comes back. Each way of
/// becoming visible must itself be a trigger, or the column shows a list resolved before it hid.
@Suite struct SidebarRefreshTriggerTests {

    static func appSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MacApp/ContentView.swift")
        let raw = try #require(try? String(contentsOf: url, encoding: .utf8),
                               "cannot read ContentView.swift — this scan would be vacuous")
        try #require(raw.count > 3000, "the file is implausibly short — the scan is vacuous")
        return raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let comment = line.range(of: "//") else { return line }
                return line[..<comment.lowerBound]
            }
            .joined(separator: "\n")
    }

    @Test func theScanCanSeeTheRefreshAtAll() throws {
        #expect(try Self.appSource().contains("refreshFolderSidebarRows()"))
    }

    /// The state values `folderSidebarIsShowing` reads, each named as a trigger (Expand's hold in
    /// Edit among them). Named rather than counted: a wrong set of the right size would pass a count.
    @Test func eachGateInputIsAlsoATrigger() throws {
        let code = try Self.appSource()
        for input in ["browseSidebarVisible", "editorSidebarVisible", "selectedWorkspace", "panesHiddenForCurrentTab",
                      "folderSidebarHeldByExpand"] {
            #expect(code.contains(".onChange(of: \(input)) { _, _ in refreshFolderSidebarRows() }"),
                    "\(input) decides whether the sidebar is showing but does not refresh it — anything that changed while it was hidden stays dropped")
        }
    }

    /// The row builder is handed the dragged order. `FolderSidebarModel.rows` applies it
    /// (`FavoriteOrderReachesTheRowsTests`), but the parameter defaults to empty, so dropping this
    /// argument draws an order nobody chose with the builder's own suite still green.
    @Test func theRefreshHandsTheBuilderTheDraggedOrder() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MacApp/ContentView+FolderSidebar.swift")
        let code = try #require(try? String(contentsOf: url, encoding: .utf8))
        #expect(code.contains("favoriteOrder: FolderJumpStore.shared.favoriteOrder"),
                "the sidebar is built without the user's dragged order — every Favorites drag persists and draws nothing")
    }

    /// The gate really reads those inputs, so the list above can't fall behind the rule it protects.
    @Test func theGateReadsExactlyThoseFour() throws {
        let sidebar = try #require(try? String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("MacApp/ContentView+FolderSidebar.swift"), encoding: .utf8))
        #expect(sidebar.contains("workspaceSupportsSidebar: selectedWorkspace.supportsFolderSidebar"))
        #expect(sidebar.contains("panesCollapsed: panesHiddenForCurrentTab"))
        #expect(sidebar.contains("preference: folderSidebarPreference(for: selectedWorkspace) && !folderSidebarHeldByExpand"))
        // Edit reads its own switch, off until shown; the rest share one.
        #expect(sidebar.contains("workspace == .editor ? editorSidebarVisible : browseSidebarVisible"))
        #expect(sidebar.contains("outlivesCollapse: selectedWorkspace.folderSidebarOutlivesPaneCollapse"))
    }
}

/// The pane's "Add to Favorites" is a three-part seam, and two parts compile without the third.
/// `FileTreeView` draws the item, `PaneActionDelegate` answers `canFavoriteFolder` /
/// `isFolderFavorite` and forwards the tap, and `ContentView` supplies the closure that writes to
/// `FolderJumpStore`. The closure is defaulted on the delegate, so dropping the line that passes it
/// leaves an item that draws, enables and does nothing, with every other test green. Scanned,
/// because `ContentView` can't be instantiated in a test.
@Suite struct PaneFavoriteWiringTests {

    @Test func contentViewSuppliesTheFavoriteClosureToEveryPaneDelegate() throws {
        let code = try FolderSidebarWiringTests.contentViewSource()
        #expect(code.contains("onToggleFolderFavorite: { node in toggleFavorite(forPaneFolder: node, isLeft: pane.isLeft) }"),
                "the pane delegate is built without its favorite closure — the menu item draws and does nothing")
    }

    /// The handler it names exists, so the check above can't be satisfied by a stale spelling.
    @Test func theHandlerTheClosureNamesIsDefined() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MacApp/ContentView+FolderSidebar.swift")
        let code = try #require(try? String(contentsOf: url, encoding: .utf8))
        #expect(code.contains("func toggleFavorite(forPaneFolder node: FileNode, isLeft: Bool)"))
    }

    /// One rule, asked once. The menu's label comes from `PaneActionDelegate.favoritePlace` and the
    /// tap must resolve the root and relative path the same way; a second derivation could offer
    /// "Remove from Favorites" for a folder the tap then adds. Scanned for the call, not the parts.
    @Test func theHandlerGoesThroughTheOneRuleRatherThanDerivingItAgain() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MacApp/ContentView+FolderSidebar.swift")
        let raw = try #require(try? String(contentsOf: url, encoding: .utf8))
        let code = raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let comment = line.range(of: "//") else { return line }
                return line[..<comment.lowerBound]
            }
            .joined(separator: "\n")
        let body = try #require(code.range(of: "func toggleFavorite(forPaneFolder"))
            .upperBound
        let handler = String(code[body...].prefix(900))
        #expect(handler.contains("PaneActionDelegate.favoritePlace("),
                "the handler derives the pane root itself instead of asking the rule the menu asked")
        #expect(!handler.contains("PathBoundary.relativize("),
                "the containment rule is spelled a second time here — it belongs to favoritePlace alone")
    }

    /// Every write to the Favorites places goes through the salvaging funnel, as a property of the
    /// file, not of the verbs in it today. `SidebarFavoritePlaces.places(from:)` answers the standard
    /// three for an unreadable value as for an untouched one, so encoding that straight back over the
    /// key would destroy a value this build couldn't read. One named file, comments stripped, with a
    /// required anchor so a scan that matches nothing fails.
    @Test func everyFavoritePlacesWriteGoesThroughTheFunnel() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MacApp/ContentView+FolderSidebar.swift")
        let raw = try #require(try? String(contentsOf: url, encoding: .utf8),
                               "cannot read ContentView+FolderSidebar.swift — this scan would be vacuous")
        let source = raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let comment = line.range(of: "//") else { return line }
                return line[..<comment.lowerBound]
            }
            .joined(separator: "\n")

        try #require(source.contains("func writeFolderSidebarFavoritePlaces("),
                     "the funnel is gone, so this scan is asserting nothing")
        try #require(source.contains("SidebarFavoritePlaces.isUnreadable("),
                     "the funnel no longer salvages, which is the whole point of routing through it")

        // The funnel itself holds the one legitimate assignment; anything beyond it is a verb
        // writing the key directly.
        let writes = source.components(separatedBy: "browseSidebarFavoritePlacesRaw =").count - 1
        #expect(writes == 1,
                "\(writes) assignments to browseSidebarFavoritePlacesRaw — every write but the funnel's own can overwrite bytes this build could not read")
    }
}

/// Which pane a sidebar open asks about, read off the three handlers' bodies. All three route
/// through `isLeft`, which the context menu can point at the non-target pane, so consulting the
/// target's state (`folderSidebarRoot`, `folderSidebarProviderId`) would answer for the wrong pane
/// exactly when `side` matters. One named file, comments stripped, each check scoped to its member
/// so a spelling elsewhere can't answer for it, and anchored so a renamed member fails.
@Suite struct FolderSidebarOpenTargetingTests {

    static func sidebarSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MacApp/ContentView+FolderSidebar.swift")
        let raw = try #require(try? String(contentsOf: url, encoding: .utf8),
                               "cannot read ContentView+FolderSidebar.swift — this scan would be vacuous")
        try #require(raw.count > 5000, "the file is implausibly short — the scan is vacuous")
        // Comments stripped, as this file's other scans do: the doc comments quote these spellings,
        // so an unstripped scan would find the prose with the code reverted.
        return raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let comment = line.range(of: "//") else { return line }
                return line[..<comment.lowerBound]
            }
            .joined(separator: "\n")
    }

    /// One member's body: from its declaration to the next member declaration at the extension's
    /// indentation. Structural, not a character budget, which an unrelated edit could truncate.
    /// Member indentation only (4–5 spaces), so a local `var` in the body doesn't end the slice, and
    /// deeper-indented signature continuation lines can't match.
    static func body(of declaration: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> String {
        let code = try sidebarSource()
        let start = try #require(code.range(of: declaration),
                                 "\(declaration) is gone — this scan is aimed at nothing",
                                 sourceLocation: sourceLocation)
        let rest = String(code[start.upperBound...])
        let end = rest.range(of: #"\n {4,5}(private )?(func|var) "#, options: .regularExpression)
        return end.map { String(rest[..<$0.lowerBound]) } ?? rest
    }

    /// `openFolderSidebarRow` asks the pane it is opening on: the source-switch guard compares the
    /// row's root with the `isLeft` pane's provider path, not `folderSidebarRoot`, which describes
    /// the target and would switch the wrong pane's source from the context menu.
    @Test func theRowOpenDerivesItsGuardFromTheOpeningPane() throws {
        let body = try Self.body(of: "func openFolderSidebarRow(")
        try #require(body.contains("syncManager.focusOn(relativePath: row.relativePath, isLeft: isLeft)"),
                     "the open no longer focuses — this slice is not the member it claims to be")
        #expect(body.contains("settings.rootPath(for: isLeft ? leftProviderId : rightProviderId)"),
                "the guard no longer derives the pane root from the pane being opened on")
        #expect(!body.contains("FolderJumpStore.key(forRoot: folderSidebarRoot)"),
                "the guard asks the TARGET's root — it answers for the wrong pane exactly when `side` points the other way")
    }

    /// `openFolderSidebarShortcutInsideItsOwner` resolves its owner by id. `.inside` carries the id
    /// `owningSource` resolved so two same-named sources can't make this pick the wrong one and
    /// strip against the wrong root.
    @Test func theInsideOpenResolvesItsOwnerById() throws {
        let body = try Self.body(of: "func openFolderSidebarShortcutInsideItsOwner(")
        try #require(body.contains("folderSidebarProviders.first(where:"),
                     "the owner lookup is gone — this slice is not the member it claims to be")
        #expect(body.contains("$0.id == ownerId"),
                "the owner is not resolved by id — two same-named sources and this picks whichever came first")
        #expect(!body.contains("displayName == owner"),
                "the owner is resolved by display name, the collision this section's qualifiers exist for")
    }

    /// It compares against the pane being opened on, matching the provider write beside it, rather
    /// than reading the target pane's provider while setting the `isLeft` pane's. Pinned on which
    /// pane's provider is read, not on the operator around it.
    @Test func theInsideOpenComparesTheOpeningPanesProvider() throws {
        let body = try Self.body(of: "func openFolderSidebarShortcutInsideItsOwner(")
        #expect(body.contains("provider.id == (isLeft ? leftProviderId : rightProviderId)"),
                "the switch decision reads some other pane's provider than the one it sets")
        #expect(!body.contains("folderSidebarProviderId"),
                "the switch decision reads the TARGET pane's provider while setting the `isLeft` pane's")
    }

    /// `promoteFolderSidebarShortcut` decides "minted" by membership taken before the call. Taken
    /// after, it can't tell "just added" from "already existed": a disabled source's row draws as
    /// not added, and the inline Remove would delete a source the user configured long ago.
    @Test func thePromotionTakesMembershipBeforeItAdds() throws {
        let body = try Self.body(of: "func promoteFolderSidebarShortcut(")
        let before = try #require(body.range(of: "let knownBefore"),
                                  "the before-the-call membership set is gone — wasAdded can no longer tell added from existed")
        let add = try #require(body.range(of: "settings.addFolderSource(path:"),
                               "the promotion no longer adds — this slice is not the member it claims to be")
        #expect(before.lowerBound < add.lowerBound,
                "membership is taken AFTER addFolderSource — at that point the id is always known and wasAdded is always false")
        #expect(body.contains("let wasAdded = !knownBefore.contains(id)"),
                "wasAdded is not derived from the before-the-call set")
        #expect(!body.contains("let wasAdded = settings.folderSources.contains"),
                "wasAdded is read off the after-the-fact list, which cannot tell added from existed")
    }

    /// A promotion that reached an existing source re-enables it. A "not added yet" row over an
    /// existing source can only be a disabled one (enabled sources draw as `.configured`), and a pane
    /// on a disabled provider is a state the pane header's own menu can't reach.
    @Test func thePromotionReEnablesADisabledExistingSource() throws {
        let body = try Self.body(of: "func promoteFolderSidebarShortcut(")
        #expect(body.contains("if !wasAdded && !settings.isEnabled(id)"),
                "the not-minted path no longer checks for the disabled source it can only be")
        #expect(body.contains("settings.setEnabled(true, for: id)"),
                "the disabled source is not switched back on — the click said “use this folder”")
    }
}

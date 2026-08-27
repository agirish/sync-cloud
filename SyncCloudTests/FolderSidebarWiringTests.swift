@testable import SyncCloud
import Dashboard
import Design
import Testing
import Foundation

/// **The sidebar's refresh triggers, read off `ContentView`'s source.**
///
/// `ContentView` is a `View` with `@State` and cannot be instantiated in a test, so its `onChange`
/// wiring is invisible to every other kind of check — and this particular wiring is the half of a
/// fix that is easy to leave out. `refreshFolderSidebarRows` guards on the column being on screen,
/// because it `stat`s a provider root and its other triggers fire on every workspace. That guard
/// makes two new triggers *necessary*: switching the sidebar on, and arriving at Browse, both land
/// on whatever was last resolved. Without them a person switching the column on reads an empty or
/// stale list as "my pins are gone".
///
/// A source scan is a weak instrument and this one is scoped and proved accordingly: it reads one
/// named file, strips comments so a mention in prose cannot satisfy it, and requires a known
/// trigger to be present so a scan that finds nothing fails loudly rather than passing.
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

    /// Each trigger, and the call it has to make. Written as pairs rather than as two substring
    /// searches: `.onChange(of: selectedWorkspace)` exists for other reasons too, so finding the
    /// line proves nothing unless the refresh is inside it.
    @Test(arguments: ["browseSidebarVisible", "selectedWorkspace", "leftProviderId"])
    func everyTriggerTheGuardMakesNecessaryIsWired(value: String) throws {
        let source = try Self.contentViewSource()
        let declaration = ".onChange(of: \(value)) { _, _ in refreshFolderSidebarRows() }"
        #expect(source.contains(declaration),
                "\(value) does not refresh the sidebar — with the on-screen guard in place, the column keeps whatever rows it last resolved")
    }

    /// The scan is reading something: a trigger that is definitely there must be found, or the
    /// three checks above pass over an empty string.
    @Test func theScanCanSeeAKnownTrigger() throws {
        #expect(try Self.contentViewSource().contains("refreshFolderSidebarRows()"))
    }

    /// And the guard itself is the one rule, not a hand-rolled copy — the layout's `if` and the
    /// refresh's guard must ask the same question or the column draws rows nobody refreshed.
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

/// **The other two surfaces: the chord registry and the ⌘/ reference.**
///
/// The menu bar itself is asserted in `WindowMenuTests.theSidebarSwitchIsInTheViewMenu`, which
/// walks the running app's bar — one walker, in the suite that owns it. What is left here is the
/// pair that decides whether ⌃⌘S is *discoverable*: the registry is what the ⌘/ panel is generated
/// from, and the panel is where a person goes to find out what the app can do.
///
/// **This suite was `TheSidebarHasNoChordAndNoRow` and asserted every one of these absences.** It
/// is inverted rather than deleted, because the claim worth pinning is the same in both directions:
/// the chord, the item and the row travel together, and a release that has one without the others
/// either documents a keystroke that does nothing or ships one nobody can find.
@Suite struct TheSidebarHasItsChordAndItsRow {

    @Test func theChordIsInTheRegistry() {
        #expect(AppChord.registry.contains { $0.display == "⌃⌘S" },
                "⌃⌘S is not in the registry — the ⌘/ panel is generated from it, so the sidebar's chord would be undocumented")
    }

    /// Exactly one row names it, by chord. More than one would be the drift
    /// `theShortcutsReferenceDescribesNoSidebar` used to catch from the other side: two rows for one
    /// switch is how a panel starts disagreeing with itself.
    @Test func exactlyOneShortcutsReferenceRowDescribesTheSidebar() {
        let rows = ShortcutsReference.groups.flatMap(\.items)
        #expect(rows.count > 10, "the reference is implausibly short — this scan would be near-vacuous")
        let chorded = rows.filter { $0.keys.replacingOccurrences(of: " ", with: "").contains("⌃⌘S") }
        #expect(chorded.count == 1, "\(chorded.count) rows list ⌃⌘S: \(chorded.map(\.action))")
        #expect(chorded.first?.action.lowercased().contains("sidebar") == true,
                "the ⌃⌘S row does not say what it toggles: “\(chorded.first?.action ?? "")”")
    }

    /// **And it names no workspace**, which is the point rather than an omission.
    ///
    /// This row has been wrong twice. It read "Browse only" while that was true and went stale when
    /// Organize and Storage got a sidebar; it then read "not in Compare" and went stale the same
    /// day when Compare did. Every shipping workspace has one now, so a qualifier is not merely
    /// unnecessary — any qualifier is a thing that must be re-edited whenever the set changes, with
    /// nothing to make it fail when it is not.
    ///
    /// Asserted as "names no workspace", so re-adding one has to be deliberate.
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

/// **Every input to the visibility gate has a refresh trigger**, which is a rule this codebase has
/// now broken twice.
///
/// `refreshFolderSidebarRows` returns early wherever the column is not on screen — correct, since
/// it `stat`s every provider root and its triggers fire on every workspace. The consequence is that
/// anything firing while the column is hidden is DROPPED, and nothing re-runs it when the column
/// comes back. So each way of becoming visible must itself be a trigger.
///
/// It was written that way for the first two (`browseSidebarVisible`, `selectedWorkspace`), with a
/// comment saying "the guard and these two are one change". Then `panesCollapsed` joined the gate
/// and its trigger did not, so expanding the panes showed a list resolved before the collapse —
/// which reads as "my pins are gone", exactly what that comment predicted.
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

    /// The three state values `FolderSidebarModel.isShowing` reads, each named as a trigger.
    ///
    /// Named individually rather than counted: a count says the right NUMBER of triggers exists,
    /// which is what a wrong one would also say.
    @Test func eachGateInputIsAlsoATrigger() throws {
        let code = try Self.appSource()
        for input in ["browseSidebarVisible", "selectedWorkspace", "panesHiddenForCurrentTab"] {
            #expect(code.contains(".onChange(of: \(input)) { _, _ in refreshFolderSidebarRows() }"),
                    "\(input) decides whether the sidebar is showing but does not refresh it — anything that changed while it was hidden stays dropped")
        }
    }

    /// **The row builder is handed the dragged sequence.** `FolderSidebarModel.rows` applies it —
    /// `FavoriteOrderReachesTheRowsTests` proves that — but the parameter is defaulted to empty, so
    /// dropping this one argument puts the section straight back to drawing an order nobody chose,
    /// with the builder's own suite still green.
    @Test func theRefreshHandsTheBuilderTheDraggedOrder() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MacApp/ContentView+FolderSidebar.swift")
        let code = try #require(try? String(contentsOf: url, encoding: .utf8))
        #expect(code.contains("favoriteOrder: FolderJumpStore.shared.favoriteOrder"),
                "the sidebar is built without the user's dragged order — every Favorites drag persists and draws nothing")
    }

    /// And the gate really does read all three, so the list above cannot quietly fall behind the
    /// rule it is protecting.
    @Test func theGateReadsExactlyThoseThree() throws {
        let sidebar = try #require(try? String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("MacApp/ContentView+FolderSidebar.swift"), encoding: .utf8))
        #expect(sidebar.contains("workspaceSupportsSidebar: selectedWorkspace.supportsFolderSidebar"))
        #expect(sidebar.contains("panesCollapsed: panesHiddenForCurrentTab"))
        #expect(sidebar.contains("preference: browseSidebarVisible"))
    }
}

/// **The pane's "Add to Favorites" is a three-part seam, and two of the three compile without the
/// third.**
///
/// `FileTreeView` draws the item, `PaneActionDelegate` answers `canFavoriteFolder` /
/// `isFolderFavorite` and forwards the tap, and `ContentView` supplies the closure that actually
/// writes to `FolderJumpStore`. That closure is **defaulted** on the delegate — it has to be, or
/// every existing delegate test would have to name a route it is not testing — which means deleting
/// the one line in `ContentView` that passes it leaves a menu item that draws, enables, says "Add
/// to Favorites", and does nothing at all. Nothing fails to compile and no test goes red: the
/// delegate's own suite asserts the path RULE, and the rule is still right.
///
/// Source-scanned for the reason the suite above is: `ContentView` cannot be instantiated in a
/// test, so its construction of `PaneActionDelegate` is invisible to every other instrument.
@Suite struct PaneFavoriteWiringTests {

    @Test func contentViewSuppliesTheFavoriteClosureToEveryPaneDelegate() throws {
        let code = try FolderSidebarWiringTests.contentViewSource()
        #expect(code.contains("onToggleFolderFavorite: { node in toggleFavorite(forPaneFolder: node, isLeft: pane.isLeft) }"),
                "the pane delegate is built without its favorite closure — the menu item draws and does nothing")
    }

    /// And the handler it names exists, so the check above cannot be satisfied by a stale spelling.
    @Test func theHandlerTheClosureNamesIsDefined() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MacApp/ContentView+FolderSidebar.swift")
        let code = try #require(try? String(contentsOf: url, encoding: .utf8))
        #expect(code.contains("func toggleFavorite(forPaneFolder node: FileNode, isLeft: Bool)"))
    }

    /// **One rule, asked once.** The menu's label comes from `PaneActionDelegate.favoritePlace` and
    /// the tap has to resolve the root and the relative path the same way — a second derivation is
    /// how the label comes to offer "Remove from Favorites" for a folder the tap then adds. The
    /// handler is scanned for the call rather than for the ingredients.
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

    /// **Every write to the Favorites places goes through the salvaging funnel**, and this is what
    /// makes that a property of the file rather than of the three verbs that happen to be in it
    /// today.
    ///
    /// `SidebarFavoritePlaces.places(from:)` answers the standard three for an unreadable value as
    /// well as an untouched one. Encoding that answer straight back over the key is what turns a
    /// value this build could not read into a value nobody can — and the verb that does it is
    /// whichever one the user reaches for first, so no single call site looks wrong. A fourth verb
    /// added later would be written the same way this scan exists to catch.
    ///
    /// Scoped and proved like the scan above: one named file, comments stripped, and a required
    /// anchor so a scan that matches nothing fails rather than passes.
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

/// **Which pane a sidebar open ASKS ABOUT, read off the three handlers' own bodies.**
///
/// All three route through `isLeft`, which the context menu can point at the non-target pane — and
/// each of them had, or nearly had, a spelling that consulted the TARGET's state instead
/// (`folderSidebarRoot`, `folderSidebarProviderId`), which answers for the wrong pane exactly when
/// `side` is doing its job. `ContentView` cannot be instantiated in a test, so the derivations are
/// pinned the way this file pins wiring: one named file, comments stripped, each check scoped to
/// the member it is about — a spelling adopted elsewhere in the file must not answer for the
/// handler that lost it — and premise-anchored so a renamed member fails loudly.
@Suite struct FolderSidebarOpenTargetingTests {

    static func sidebarSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MacApp/ContentView+FolderSidebar.swift")
        let raw = try #require(try? String(contentsOf: url, encoding: .utf8),
                               "cannot read ContentView+FolderSidebar.swift — this scan would be vacuous")
        try #require(raw.count > 5000, "the file is implausibly short — the scan is vacuous")
        // Comments stripped, as this file's other scans do — these fixes are QUOTED in the doc
        // comments that explain them, so an unstripped scan would find the prose with the code
        // reverted.
        return raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let comment = line.range(of: "//") else { return line }
                return line[..<comment.lowerBound]
            }
            .joined(separator: "\n")
    }

    /// One member's body: from its declaration to the next member declaration at the extension's
    /// own indentation. Structural, not a character budget — a budget is the window that
    /// truncated under an unrelated edit and failed a test about something else entirely.
    /// Member indentation only (4–5 spaces), so a LOCAL `var` inside the body does not end the
    /// slice early; continuation lines of a multi-line signature are indented deeper and cannot
    /// match either.
    static func body(of declaration: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> String {
        let code = try sidebarSource()
        let start = try #require(code.range(of: declaration),
                                 "\(declaration) is gone — this scan is aimed at nothing",
                                 sourceLocation: sourceLocation)
        let rest = String(code[start.upperBound...])
        let end = rest.range(of: #"\n {4,5}(private )?(func|var) "#, options: .regularExpression)
        return end.map { String(rest[..<$0.lowerBound]) } ?? rest
    }

    /// **`openFolderSidebarRow` asks the pane it is opening on.** The source-switch guard compares
    /// the row's root against the `isLeft` pane's provider path — not `folderSidebarRoot`, which
    /// always describes the target and so switched the wrong pane's source from the context menu.
    @Test func theRowOpenDerivesItsGuardFromTheOpeningPane() throws {
        let body = try Self.body(of: "func openFolderSidebarRow(")
        try #require(body.contains("syncManager.focusOn(relativePath: row.relativePath, isLeft: isLeft)"),
                     "the open no longer focuses — this slice is not the member it claims to be")
        #expect(body.contains("settings.rootPath(for: isLeft ? leftProviderId : rightProviderId)"),
                "the guard no longer derives the pane root from the pane being opened on")
        #expect(!body.contains("FolderJumpStore.key(forRoot: folderSidebarRoot)"),
                "the guard asks the TARGET's root — it answers for the wrong pane exactly when `side` points the other way")
    }

    /// **`openFolderSidebarShortcutInsideItsOwner` resolves its owner by ID.** `.inside` carries
    /// the id `owningSource` resolved precisely so two same-named sources cannot make this pick
    /// the wrong one and count-strip against the wrong root.
    @Test func theInsideOpenResolvesItsOwnerById() throws {
        let body = try Self.body(of: "func openFolderSidebarShortcutInsideItsOwner(")
        try #require(body.contains("folderSidebarProviders.first(where:"),
                     "the owner lookup is gone — this slice is not the member it claims to be")
        #expect(body.contains("$0.id == ownerId"),
                "the owner is not resolved by id — two same-named sources and this picks whichever came first")
        #expect(!body.contains("displayName == owner"),
                "the owner is resolved by display name, the collision this section's qualifiers exist for")
    }

    /// And it compares against the pane being opened on, matching the `setFolderSidebarProvider`
    /// call beside it — comparing the target pane's provider while setting the `isLeft` pane's was
    /// the missed half of the same fix.
    @Test func theInsideOpenComparesTheOpeningPanesProvider() throws {
        let body = try Self.body(of: "func openFolderSidebarShortcutInsideItsOwner(")
        #expect(body.contains("provider.id != (isLeft ? leftProviderId : rightProviderId)"),
                "the switch decision reads some other pane's provider than the one it sets")
        #expect(!body.contains("provider.id != folderSidebarProviderId"),
                "the switch decision reads the TARGET pane's provider while setting the `isLeft` pane's")
    }

    /// **`promoteFolderSidebarShortcut` decides "minted" by membership taken BEFORE the call.**
    /// Taken after, it cannot tell "just added" from "already existed": a disabled source's row
    /// draws as not-added, the after-the-fact test answered true, and the inline Remove would have
    /// deleted a source the user configured long ago.
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

    /// **A promotion that reached an existing source re-enables it.** A "not added yet" row over a
    /// pre-existing source can only mean a DISABLED one — enabled sources draw as `.configured` —
    /// and pointing the pane at a disabled provider lands in a state the pane header's own menu
    /// cannot reach.
    @Test func thePromotionReEnablesADisabledExistingSource() throws {
        let body = try Self.body(of: "func promoteFolderSidebarShortcut(")
        #expect(body.contains("if !wasAdded && !settings.isEnabled(id)"),
                "the not-minted path no longer checks for the disabled source it can only be")
        #expect(body.contains("settings.setEnabled(true, for: id)"),
                "the disabled source is not switched back on — the click said “use this folder”")
    }
}

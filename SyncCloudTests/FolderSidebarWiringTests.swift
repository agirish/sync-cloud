@testable import SyncCloud
import Dashboard
import Design
import Testing
import Foundation

/// The sidebar's refresh triggers, read off `ContentView`'s source (it can't be instantiated in a
/// test). `refreshFolderSidebarRows` returns early unless the column is on screen, so each way of
/// showing it must be a trigger, or a stale list reads as "my pins are gone". Comments are stripped
/// so prose can't satisfy the scan.
@Suite struct FolderSidebarWiringTests {
    /// Every input `folderSidebarIsShowing` reads triggers the refresh, matched with its call as one
    /// string: `.onChange(of: selectedWorkspace)` exists for other reasons too, so finding it alone
    /// proves nothing.
    @Test(arguments: ["browseSidebarVisible", "selectedWorkspace", "leftProviderId",
                      "browseSidebarRecentsMode", "editorSidebarVisible", "panesHiddenForCurrentTab",
                      "folderSidebarHeldByExpand"])
    func everyTriggerTheGuardMakesNecessaryIsWired(value: String) throws {
        let source = try macAppCode("ContentView.swift")
        let declaration = ".onChange(of: \(value)) { _, _ in refreshFolderSidebarRows() }"
        #expect(source.contains(declaration),
                "\(value) does not refresh the sidebar — with the on-screen guard in place, the column keeps whatever rows it last resolved")
    }

    /// The guard is the one rule, not a hand-rolled copy: the layout's `if` and the refresh's guard
    /// must ask the same question, or the column draws rows nobody refreshed.
    @Test func bothSitesAskTheOneRule() throws {
        let source = try macAppCode("ContentView.swift")
        #expect(!source.contains("selectedWorkspace == .browse, browseSidebarVisible"),
                "the guard was re-spelled in ContentView instead of going through FolderSidebarModel")

        #expect(try macAppFile("ContentView+SplitLayout.swift").contains("if folderSidebarIsShowing"),
                "browseLayout draws the sidebar on its own condition rather than the shared rule")
    }
}

/// The sidebar's chord in the registry and its row in the ⌘/ reference, which decide whether ⌃⌘S
/// is discoverable. The menu bar is asserted in `WindowMenuTests.theSidebarSwitchIsInTheViewMenu`.
/// The chord, the menu item and the row travel together: one without the others documents a
/// keystroke that does nothing, or ships one nobody can find.
@Suite struct TheSidebarHasItsChordAndItsRow {
    /// Exactly one row names it, by chord: two rows for one switch is how a panel starts disagreeing
    /// with itself.
    @Test func exactlyOneShortcutsReferenceRowDescribesTheSidebar() {
        let rows = ShortcutsReference.groups.flatMap(\.items)
        #expect(rows.count > 10, "the reference is implausibly short — this scan would be near-vacuous")
        let chorded = rows.filter { $0.keys.replacingOccurrences(of: " ", with: "").contains("⌃⌘S") }
        #expect(chorded.count == 1, "\(chorded.count) rows list ⌃⌘S: \(chorded.map(\.action))")
        let action = chorded.first?.action ?? ""
        #expect(action.lowercased().contains("sidebar"), "the ⌃⌘S row does not say what it toggles: “\(action)”")
        // It names no workspace: every workspace has a sidebar, so a qualifier could only go stale.
        for workspace in Workspace.allCases.map(\.title) {
            #expect(!action.localizedCaseInsensitiveContains(workspace),
                    "the ⌃⌘S row names \(workspace) — every workspace has a sidebar, so the qualifier can only go stale: “\(action)”")
        }
    }
}

/// Every input to the visibility gate has a refresh trigger. `refreshFolderSidebarRows` returns
/// early while the column is off screen, since it `stat`s every provider root, so anything firing
/// while it is hidden is dropped and nothing re-runs it when the column comes back. Each way of
/// becoming visible must itself be a trigger, or the column shows a list resolved before it hid.
@Suite struct SidebarRefreshTriggerTests {
    /// The row builder is handed the dragged order. `FolderSidebarModel.rows` applies it
    /// (`FavoriteOrderReachesTheRowsTests`), but the parameter defaults to empty, so dropping this
    /// argument draws an order nobody chose with the builder's own suite still green.
    @Test func theRefreshHandsTheBuilderTheDraggedOrder() throws {
        let code = try macAppFile("ContentView+FolderSidebar.swift")
        #expect(code.contains("favoriteOrder: FolderJumpStore.shared.favoriteOrder"),
                "the sidebar is built without the user's dragged order — every Favorites drag persists and draws nothing")
    }

    /// The gate really reads those inputs, so the list above can't fall behind the rule it protects.
    @Test func theGateReadsExactlyThoseFour() throws {
        let sidebar = try macAppFile("ContentView+FolderSidebar.swift")
        #expect(sidebar.contains("workspaceSupportsSidebar: selectedWorkspace.supportsFolderSidebar"))
        #expect(sidebar.contains("panesCollapsed: panesHiddenForCurrentTab"))
        #expect(sidebar.contains("preference: folderSidebarPreference(for: selectedWorkspace) && !folderSidebarHeldByExpand"))
        // Edit reads its own switch, off until shown; the rest share one.
        #expect(sidebar.contains("workspace == .editor ? editorSidebarVisible : browseSidebarVisible"))
        #expect(sidebar.contains("outlivesCollapse: selectedWorkspace.folderSidebarOutlivesPaneCollapse"))
    }
}

/// The pane's "Add to Favorites": `FileTreeView` draws it, `PaneActionDelegate` answers and
/// forwards the tap, and `ContentView` supplies the closure that writes to `FolderJumpStore`. That
/// closure is defaulted, so dropping it leaves an item that draws, enables and does nothing, with
/// every other test green.
@Suite struct PaneFavoriteWiringTests {
    @Test func contentViewSuppliesTheFavoriteClosureToEveryPaneDelegate() throws {
        let code = try macAppCode("ContentView.swift")
        #expect(code.contains("onToggleFolderFavorite: { node in toggleFavorite(forPaneFolder: node, isLeft: pane.isLeft) }"),
                "the pane delegate is built without its favorite closure — the menu item draws and does nothing")
    }

    /// One rule, asked once. The menu's label comes from `PaneActionDelegate.favoritePlace` and the
    /// tap must resolve the root and relative path the same way; a second derivation could offer
    /// "Remove from Favorites" for a folder the tap then adds. Scanned for the call, not the parts.
    @Test func theHandlerGoesThroughTheOneRuleRatherThanDerivingItAgain() throws {
        let handler = try declarationBody(of: "func toggleFavorite(forPaneFolder",
                                          in: macAppFile("ContentView+FolderSidebar.swift"))
        #expect(handler.contains("PaneActionDelegate.favoritePlace("),
                "the handler derives the pane root itself instead of asking the rule the menu asked")
        #expect(!handler.contains("PathBoundary.relativize("),
                "the containment rule is spelled a second time here — it belongs to favoritePlace alone")
    }

    /// Every write to the Favorites places goes through the salvaging funnel.
    /// `SidebarFavoritePlaces.places(from:)` answers the standard three for an unreadable value, so
    /// writing that straight back would destroy a value this build couldn't read.
    @Test func everyFavoritePlacesWriteGoesThroughTheFunnel() throws {
        let source = sourceCodeOnly(try macAppFile("ContentView+FolderSidebar.swift"))

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

/// Which pane a sidebar open asks about, read off the three handlers' bodies. All route through
/// `isLeft`, which the context menu can point at the non-target pane, so reading the target's state
/// (`folderSidebarRoot`, `folderSidebarProviderId`) would answer for the wrong pane. Each check is
/// scoped to its member and anchored, so a renamed member fails.
@Suite struct FolderSidebarOpenTargetingTests {
    /// `openFolderSidebarRow` asks the pane it is opening on: the source-switch guard compares the
    /// row's root with the `isLeft` pane's provider path, not `folderSidebarRoot`, which describes
    /// the target and would switch the wrong pane's source from the context menu.
    @Test func theRowOpenDerivesItsGuardFromTheOpeningPane() throws {
        let body = try declarationBody(of: "func openFolderSidebarRow(", in: macAppFile("ContentView+FolderSidebar.swift"))
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
        let body = try declarationBody(of: "func openFolderSidebarShortcutInsideItsOwner(", in: macAppFile("ContentView+FolderSidebar.swift"))
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
        let body = try declarationBody(of: "func openFolderSidebarShortcutInsideItsOwner(", in: macAppFile("ContentView+FolderSidebar.swift"))
        #expect(body.contains("provider.id == (isLeft ? leftProviderId : rightProviderId)"),
                "the switch decision reads some other pane's provider than the one it sets")
        #expect(!body.contains("folderSidebarProviderId"),
                "the switch decision reads the TARGET pane's provider while setting the `isLeft` pane's")
    }

    /// `promoteFolderSidebarShortcut` decides "minted" by membership taken before the call. Taken
    /// after, it can't tell "just added" from "already existed": a disabled source's row draws as
    /// not added, and the inline Remove would delete a source the user configured long ago.
    @Test func thePromotionTakesMembershipBeforeItAdds() throws {
        let body = try declarationBody(of: "func promoteFolderSidebarShortcut(", in: macAppFile("ContentView+FolderSidebar.swift"))
        let before = try #require(body.range(of: "let knownBefore"),
                                  "the before-the-call membership set is gone — wasAdded can no longer tell added from existed")
        let add = try #require(body.range(of: "settings.addFolderSource(path:"),
                               "the promotion no longer adds — this slice is not the member it claims to be")
        #expect(before.lowerBound < add.lowerBound,
                "membership is taken AFTER addFolderSource — at that point the id is always known and wasAdded is always false")
        #expect(body.contains("let wasAdded = !knownBefore.contains(id)"),
                "wasAdded is not derived from the before-the-call set")
    }

    /// A promotion that reached an existing source re-enables it. A "not added yet" row over an
    /// existing source can only be a disabled one (enabled sources draw as `.configured`), and a pane
    /// on a disabled provider is a state the pane header's own menu can't reach.
    @Test func thePromotionReEnablesADisabledExistingSource() throws {
        let body = try declarationBody(of: "func promoteFolderSidebarShortcut(", in: macAppFile("ContentView+FolderSidebar.swift"))
        #expect(body.contains("if !wasAdded && !settings.isEnabled(id)"),
                "the not-minted path no longer checks for the disabled source it can only be")
        #expect(body.contains("settings.setEnabled(true, for: id)"),
                "the disabled source is not switched back on — the click said “use this folder”")
    }
}

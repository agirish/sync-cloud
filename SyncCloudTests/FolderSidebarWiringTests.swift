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
}

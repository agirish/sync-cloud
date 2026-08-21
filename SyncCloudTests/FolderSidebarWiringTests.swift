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

/// **The hold's other two surfaces: the chord registry and the ⌘/ reference.**
///
/// The menu bar itself is asserted in `WindowMenuTests.theSidebarSwitchIsGoneFromEveryMenu`, which
/// walks the running app's bar — one walker, in the suite that owns it. What is left here is the
/// pair that would let ⌃⌘S be *documented* again even with no item registering it: the registry is
/// what the ⌘/ panel is generated from, and the panel is where a person goes to find out what the
/// app can do.
@Suite struct TheSidebarHasNoChordAndNoRow {

    @Test func theChordIsNotInTheRegistry() {
        #expect(!AppChord.registry.contains { $0.display == "⌃⌘S" },
                "⌃⌘S is back in the registry — every registry chord gets a ⌘/ row and a menu item, and the sidebar has neither")
    }

    /// No row names it, by chord or in prose. Written against the rows and not the source, for the
    /// reason `testNoRowAdvertisesDragAndDrop` gives: every other check on this panel pins its
    /// *shape*, so a row describing a feature the app does not have stays green in all of them.
    @Test func theShortcutsReferenceDescribesNoSidebar() {
        let rows = ShortcutsReference.groups.flatMap(\.items)
        #expect(rows.count > 10, "the reference is implausibly short — this scan would be near-vacuous")
        for item in rows {
            #expect(!item.keys.replacingOccurrences(of: " ", with: "").contains("⌃⌘S"),
                    "a row still lists ⌃⌘S: “\(item.action)”")
            let action = item.action.lowercased()
            #expect(!action.contains("sidebar"), "a row still describes a sidebar: “\(item.action)”")
            #expect(!action.contains("pinned and recent"), "a row still describes the held column: “\(item.action)”")
        }
    }
}

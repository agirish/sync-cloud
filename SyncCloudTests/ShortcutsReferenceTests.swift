import Testing
@testable import SyncCloud

/// Pins the shortcuts reference's shape: the three expected groups exist, every row has
/// both keys and an action, and no action is listed twice within a group. The CONTENT is a
/// hand-maintained mirror of the real bindings — update it alongside any shortcut change.
@Suite struct ShortcutsReferenceTests {

    @Test func testGroupsCoverTheExpectedAreas() {
        #expect(ShortcutsReference.groups.map(\.title) == ["General", "Panes", "Differences", "Guided review"])
    }

    @Test func testEveryItemHasKeysAndAction() {
        for group in ShortcutsReference.groups {
            #expect(!group.items.isEmpty)
            for item in group.items {
                #expect(!item.keys.isEmpty)
                #expect(!item.action.isEmpty)
            }
        }
    }

    @Test func testActionsAreUniqueWithinEachGroup() {
        for group in ShortcutsReference.groups {
            let actions = group.items.map(\.action)
            #expect(Set(actions).count == actions.count)
        }
    }

    /// Every chord the menu bar registers is listed in the reference.
    ///
    /// The shape tests above cannot notice a dropped row (see `testNoRowAdvertisesDragAndDrop`'s
    /// history for how that goes wrong in the other direction), so the chords themselves are
    /// pinned: each key string here must appear in some row. Hand-maintained alongside
    /// `ShortcutCommands.swift` — a chord added there without a row here fails this, which is
    /// the point.
    @Test func testEveryMenuChordHasAReferenceRow() {
        let allKeys = ShortcutsReference.groups.flatMap(\.items).map(\.keys)
        // The workspace range moves with the bar — Browse arriving at its head made every other
        // segment's digit shift by one. Derived rather than retyped, so this list cannot be the
        // thing that has to be remembered; `testTheWorkspaceRowCountsEveryWorkspace` below is what
        // pins the row's own text against the same count.
        let chords = ["⌘ 1 – ⌘ \(Workspace.allCases.count)",
                      "⌘ [ / ⌘ ]", "⌘ R", "⇧⌘ N", "⇧⌘ .", "⇧⌘ P", "⌘ ⌫", "⌃ ⇥",
                      "⇧⌘ R", "⇧⌘ V", "⌘ D", "⇧⌘ F", "⌘ I", "⌘ L", "⌘ F", "⌘ ,", "⌘ /", "⌘ K"]
        for chord in chords {
            #expect(allKeys.contains(chord), "no reference row lists “\(chord)”")
        }
    }

    /// ⌘1–⌘5 assumes every workspace fits behind a single digit. A sixth workspace still fits
    /// (⌘6); a tenth does not — this fails first, before someone ships a ⌘10 that cannot exist.
    @Test func testEveryWorkspaceIsReachableByASingleDigitChord() {
        #expect(Workspace.allCases.count <= 9)
    }

    /// ...and the reference's workspace row must count the same list: a sixth workspace would
    /// otherwise ship with a row still reading "⌘ 1 – ⌘ 3" and every shape test green.
    @Test func testTheWorkspaceRowCountsEveryWorkspace() {
        let expected = "⌘ 1 – ⌘ \(Workspace.allCases.count)"
        let keys = ShortcutsReference.groups.flatMap(\.items).map(\.keys)
        #expect(keys.contains(expected), "no row lists “\(expected)”")
    }

    /// No row may advertise dragging or dropping.
    ///
    /// Cross-pane drag & drop was removed in `4d55246`, but this reference kept listing
    /// "⇧ or ⌘ while dropping — Move instead of copy when dragging between panes" until
    /// `94f1776`'s follow-up, because every test above pins only the SHAPE: groups exist, rows
    /// are non-empty, actions are unique. A row can therefore describe a feature that no longer
    /// exists and stay green — which is exactly what happened, in a panel the user opens with ⌘/
    /// to find out what the app can do.
    ///
    /// If a future feature legitimately involves dragging (resizing a divider, say), narrow this
    /// to the cross-pane transfer wording rather than deleting it.
    @Test func testNoRowAdvertisesDragAndDrop() {
        for group in ShortcutsReference.groups {
            for item in group.items {
                let text = "\(item.keys) \(item.action)".lowercased()
                #expect(!text.contains("drag"), "\(group.title): “\(item.action)” mentions dragging")
                #expect(!text.contains("drop"), "\(group.title): “\(item.action)” mentions dropping")
            }
        }
    }
}

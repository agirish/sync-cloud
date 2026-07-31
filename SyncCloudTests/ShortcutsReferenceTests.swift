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

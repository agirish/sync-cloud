import Testing
@testable import SyncCloud

/// Pins the shortcuts reference's shape: the three expected groups exist, every row has
/// both keys and an action, and no action is listed twice within a group. The CONTENT is a
/// hand-maintained mirror of the real bindings — update it alongside any shortcut change.
@Suite struct ShortcutsReferenceTests {

    @Test func testGroupsCoverTheExpectedAreas() {
        #expect(ShortcutsReference.groups.map(\.title) == ["General", "Panes", "Guided review"])
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
}

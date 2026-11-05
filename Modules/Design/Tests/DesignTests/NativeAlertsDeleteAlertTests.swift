import AppKit
import Testing
@testable import Design

/// `NativeAlerts.confirmDelete`, the ⌘⌫ / row-menu confirmation, asked of the alert `deleteAlert`
/// builds, never of `confirmDelete`, whose `runModal()` would park this test's main thread on a
/// session nothing here can dismiss.
@Suite @MainActor struct NativeAlertsDeleteAlertTests {

    /// The body adds to the title instead of repeating it: it says the item can come back, and
    /// promises no ⌘Z (see `confirmDelete`).
    @Test func oneItemsAlertSaysItCanComeBack() throws {
        let alert = try #require(NativeAlerts.deleteAlert(for: ["Report.pdf"]))
        #expect(alert.messageText == "Move “Report.pdf” to the Trash?")
        #expect(alert.informativeText == "You can put it back from the Trash.")
        #expect(alert.buttons.map(\.title) == ["Move to Trash", "Cancel"])
        #expect(alert.buttons.first?.hasDestructiveAction == true)
        #expect(alert.buttons.first?.keyEquivalent == "\r", "Return no longer moves it to the Trash")
    }

    @Test func manyItemsAlertCountsThemAndSaysTheyCanComeBack() throws {
        let alert = try #require(NativeAlerts.deleteAlert(for: ["a", "b", "c"]))
        #expect(alert.messageText == "Move 3 items to the Trash?")
        #expect(alert.informativeText == "You can put them back from the Trash.")
        #expect(alert.buttons.map(\.title) == ["Move to Trash", "Cancel"])
    }

    /// A folder goes to the Trash with everything in it, including what a type filter hides, and
    /// the prompt says so.
    @Test func aFolderWithFilteredItemsSaysTheyGoToo() throws {
        let one = try #require(NativeAlerts.deleteAlert(for: ["photos"], hiddenByFilter: 3))
        #expect(one.informativeText == "Includes 3 items the filter is hiding. You can put it back from the Trash.")
        let single = try #require(NativeAlerts.deleteAlert(for: ["a", "b"], hiddenByFilter: 1))
        #expect(single.informativeText == "Includes 1 item the filter is hiding. You can put them back from the Trash.")
        let none = try #require(NativeAlerts.deleteAlert(for: ["photos"], hiddenByFilter: 0))
        #expect(none.informativeText == "You can put it back from the Trash.")
    }

    @Test func noItemsAsksNothing() {
        #expect(NativeAlerts.deleteAlert(for: []) == nil)
    }
}

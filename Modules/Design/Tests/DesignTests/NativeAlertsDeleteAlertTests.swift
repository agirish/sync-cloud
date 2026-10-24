import AppKit
import Testing
@testable import Design

/// `NativeAlerts.confirmDelete` — the ⌘⌫ / row-menu confirmation, asked of the alert
/// `deleteAlert` builds, never of `confirmDelete`, whose `runModal()` would park this test's main
/// thread on a session nothing here can dismiss.
@Suite @MainActor struct NativeAlertsDeleteAlertTests {

    /// **The body adds to the title.** It said "It goes to the Trash." under "Move “x” to the
    /// Trash?" — the title again. It says the item can come back, and promises no ⌘Z (see
    /// `confirmDelete`).
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

    @Test func noItemsAsksNothing() {
        #expect(NativeAlerts.deleteAlert(for: []) == nil)
    }
}

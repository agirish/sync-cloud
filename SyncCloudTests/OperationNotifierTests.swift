import Testing
@testable import SyncCloud
import Sync

/// Pins the background-notification gate and its title mapping — the UNUserNotificationCenter
/// call itself is untestable headless, so the decision logic stays in pure seams.
@Suite struct OperationNotifierTests {

    @Test func testNotifiesOnlyWhenEnabledAndInBackground() {
        #expect(OperationNotifier.shouldNotify(enabled: true, appIsActive: false))
        #expect(!OperationNotifier.shouldNotify(enabled: true, appIsActive: true))
        #expect(!OperationNotifier.shouldNotify(enabled: false, appIsActive: false))
        #expect(!OperationNotifier.shouldNotify(enabled: false, appIsActive: true))
    }

    @Test func testTitlesPerSeverity() {
        #expect(OperationNotifier.title(for: .success) == "Operation complete")
        #expect(OperationNotifier.title(for: .warning) == "Operation finished with warnings")
        #expect(OperationNotifier.title(for: .error) == "Operation failed")
    }
}

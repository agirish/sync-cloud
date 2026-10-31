import Testing
import Foundation
import UserNotifications
@testable import SyncCloud
import Sync

/// **One-way sync's notifications** (RD67, DC): their own opt-in, off until setup turns it on;
/// posted whichever app is in front, which General's background-completion ones are not; one
/// identifier per row, so a reminder replaces the row's earlier notification; and the row named,
/// so a click opens Now on it.
@MainActor
@Suite struct OneWaySyncNotifierTests {

    static let delivery = OneWaySyncNoticeDelivery(
        kind: .first, rowID: "limit:Legal", title: "Legal: 31 removals wait for you", body: "Everything else keeps syncing.")

    @Test func offUntilSetupTurnsItOn() {
        let test = TestDefaults()
        var posted: [UNNotificationRequest] = []
        OneWaySyncNotifier.post(Self.delivery, defaults: test.defaults, post: { posted.append($0) })
        #expect(posted.isEmpty)
        // General's switch is not this one.
        test.defaults.set(true, forKey: "notifyOnBackgroundCompletion")
        OneWaySyncNotifier.post(Self.delivery, defaults: test.defaults, post: { posted.append($0) })
        #expect(posted.isEmpty)

        test.defaults.set(true, forKey: OneWaySyncNoticeBoard.notifyKey)
        OneWaySyncNotifier.post(Self.delivery, defaults: test.defaults, post: { posted.append($0) })
        #expect(posted.count == 1)
    }

    @Test func theRequestNamesItsRowAndAReminderReplacesTheFirst() {
        let first = OneWaySyncNotifier.request(for: Self.delivery)
        #expect(first.content.title == "Legal: 31 removals wait for you")
        #expect(first.content.body == "Everything else keeps syncing.")
        #expect(first.content.userInfo[OneWaySyncNotifier.noticeKey] as? String == "limit:Legal")
        #expect(first.trigger == nil)
        var reminder = Self.delivery
        reminder.kind = .reminder
        #expect(OneWaySyncNotifier.request(for: reminder).identifier == first.identifier)
        var other = Self.delivery
        other.rowID = "limit:Finance"
        #expect(OneWaySyncNotifier.request(for: other).identifier != first.identifier)
    }

    /// With SyncCloud in front, one-way sync's show and General's stay as they were: not shown.
    @Test func onlyOneWaySyncShowsWithTheAppInFront() {
        let request = OneWaySyncNotifier.request(for: Self.delivery)
        #expect(OperationNotificationClicks.presentation(for: request.content.userInfo) == [.banner, .list, .sound])
        #expect(OperationNotificationClicks.presentation(for: [OperationNotifier.activityMessageKey: UUID().uuidString]) == [])
    }

    /// The delegate the app installs is the one that answers `willPresent`: without it, macOS
    /// shows nothing for the app in front.
    @Test func theInstalledDelegateAnswersWillPresent() {
        let delegate: UNUserNotificationCenterDelegate = OperationNotificationClicks.shared
        #expect(delegate.responds(to: #selector(UNUserNotificationCenterDelegate.userNotificationCenter(_:willPresent:withCompletionHandler:))))
    }
}

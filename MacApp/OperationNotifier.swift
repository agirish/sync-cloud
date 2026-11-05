import AppKit
import FileExplorer
import Events
import Settings
import Sync
import UserNotifications

/// Mirrors an operation banner as a system notification when it lands while SyncCloud is in the
/// background (a General setting, off by default), since the banner itself lives inside the window.
@MainActor
enum OperationNotifier {

    /// The gate, pure so it's testable without UNUserNotificationCenter: notify only when the user
    /// opted in and the app isn't frontmost (a visible banner is enough).
    nonisolated static func shouldNotify(enabled: Bool, appIsActive: Bool) -> Bool {
        enabled && !appIsActive
    }

    /// Notification title per outcome; the banner message itself becomes the body.
    nonisolated static func title(for severity: OperationBanner.Severity) -> String {
        switch severity {
        case .success: return "Operation complete"
        case .warning: return "Operation finished with warnings"
        case .error: return "Operation failed"
        }
    }

    /// `defaults`, `appIsActive` and `post` are injectable for tests only: the test host is the
    /// running app, so writing `.standard` would change the user's live settings, and
    /// `UNUserNotificationCenter` can't be observed headless.
    ///
    /// A message that ends a long run is titled with that run ("Merging “Photos”") rather than
    /// "Operation complete"; the body carries the detail line too; and the request names the
    /// message, so a click opens the Activity window on it (``activityMessageKey``,
    /// `SyncCloudAppDelegate`'s notification delegate).
    static func postIfEnabled(for banner: OperationBanner,
                              runTitle: String? = nil,
                              defaults: UserDefaults = .standard,
                              appIsActive: Bool = NSApp.isActive,
                              post: (UNNotificationRequest) -> Void = OperationNotifier.postToNotificationCenter) {
        let enabled = defaults.bool(forKey: GeneralSettings.notifyOnBackgroundCompletionKey)
        guard shouldNotify(enabled: enabled, appIsActive: appIsActive) else { return }

        let content = UNMutableNotificationContent()
        content.title = runTitle ?? title(for: banner.severity)
        content.body = [banner.message, banner.detail].compactMap { $0 }.joined(separator: "\n")
        content.sound = .default
        content.userInfo = [activityMessageKey: banner.id.uuidString]
        // Each banner is one completed outcome, so it gets its own notification. The per-publish
        // UUID gives every request a distinct identifier, so the system never coalesces two
        // different outcomes into one.
        post(UNNotificationRequest(identifier: banner.id.uuidString, content: content, trigger: nil))
    }

    /// The notification's user-info key for the message it reports: Recent's row id.
    nonisolated static let activityMessageKey = "activityMessage"

    /// The title of the run a message ends, when the last long run ended a moment ago (the window's
    /// rule for a run's ending, `ContentView.runOrigin(ending:)`). A run's message is set in the
    /// turn its progress clears.
    nonisolated static func runTitle(lastFinished: (title: String?, ended: Date)?, now: Date = Date()) -> String? {
        guard let lastFinished, now.timeIntervalSince(lastFinished.ended) < 2 else { return nil }
        return lastFinished.title
    }

    private static func postToNotificationCenter(_ request: UNNotificationRequest) {
        // The completion handler is the only signal. `add` fails silently when notification
        // permission was revoked, and this posts only while the app is in the background, so a
        // dropped notification is an outcome the user never sees: the in-window banner is gone by
        // the time they come back. The logger is resolved on the main actor first (`Logger.shared`
        // is MainActor-isolated), so the handler, which arrives on an arbitrary queue, touches only
        // its nonisolated API.
        let logger = Logger.shared
        UNUserNotificationCenter.current().add(request) { error in
            guard let error else { return }
            logger.error("Could not post the background-completion notification: \(error.localizedDescription)")
        }
    }
}

/// One-way sync's notifications: a Needs you row's first, then its reminder, and the one
/// information row that sends one. Its own opt-in, made at setup
/// (`OneWaySyncNoticeBoard.notifyKey`), apart from General's background-completion switch, and
/// shown with SyncCloud in front too (`OperationNotificationClicks.willPresent`): a sync that
/// stopped matters whichever app is in front.
@MainActor
enum OneWaySyncNotifier {

    /// The notification's user-info key for the row it reports.
    nonisolated static let noticeKey = "oneWaySyncNotice"

    /// `defaults` and `post` are injectable for the tests alone, as in ``OperationNotifier``.
    static func post(_ delivery: OneWaySyncNoticeDelivery, defaults: UserDefaults = .standard,
                     post: (UNNotificationRequest) -> Void = OneWaySyncNotifier.postToNotificationCenter) {
        guard defaults.bool(forKey: OneWaySyncNoticeBoard.notifyKey) else { return }
        post(request(for: delivery))
    }

    nonisolated static func request(for delivery: OneWaySyncNoticeDelivery) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = delivery.title
        content.body = delivery.body ?? ""
        content.sound = .default
        content.userInfo = [noticeKey: delivery.rowID]
        // One identifier per row: a reminder replaces the row's earlier notification in
        // Notification Center rather than stacking beside it.
        return UNNotificationRequest(identifier: "one-way-sync:" + delivery.rowID, content: content, trigger: nil)
    }

    private static func postToNotificationCenter(_ request: UNNotificationRequest) {
        let logger = Logger.shared
        UNUserNotificationCenter.current().add(request) { error in
            guard let error else { return }
            logger.error("Could not post a one-way sync notification: \(error.localizedDescription)")
        }
    }
}

/// A notification's click opens that message in the Activity window, on Now with the row picked
/// out; not the popover, which hangs from a main window that may be behind other apps.
final class OperationNotificationClicks: NSObject, UNUserNotificationCenterDelegate {
    static let shared = OperationNotificationClicks()

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        let notice = userInfo[OneWaySyncNotifier.noticeKey] as? String
        let id = (userInfo[OperationNotifier.activityMessageKey] as? String).flatMap(UUID.init(uuidString:))
        Task { @MainActor in
            NSApp.activate()
            if let notice {
                ActivityCenter.shared.openWindow(highlightingNotice: notice)
            } else {
                ActivityCenter.shared.openWindow(highlighting: id)
            }
            completionHandler()
        }
    }

    /// With SyncCloud in front, only one-way sync's notifications show; the others are posted
    /// only from the background, where this isn't asked.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler(Self.presentation(for: notification.request.content.userInfo))
    }

    nonisolated static func presentation(for userInfo: [AnyHashable: Any]) -> UNNotificationPresentationOptions {
        userInfo[OneWaySyncNotifier.noticeKey] is String ? [.banner, .list, .sound] : []
    }
}

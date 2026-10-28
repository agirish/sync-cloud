import AppKit
import FileExplorer
import Events
import Settings
import Sync
import UserNotifications

/// Mirrors an operation banner as a system notification when it lands while SyncCloud is in
/// the background (General setting, default off) — banners live inside the window, so a long
/// copy finishing behind another app was previously silent.
@MainActor
enum OperationNotifier {

    /// The gate, kept pure so it's testable without UNUserNotificationCenter: notify only
    /// when the user opted in AND the app isn't frontmost (a visible banner is enough).
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

    /// `defaults`, `appIsActive` and `post` are injectable for the tests alone — the test host IS
    /// the running app, so a test that wrote `.standard` would be writing the user's live General
    /// settings, and `UNUserNotificationCenter` cannot be observed headless. Production callers
    /// pass nothing and get exactly the previous behavior.
    ///
    /// **Run Room TE227:** a message that ends a long run is titled with that run — "Merging
    /// “Photos”" — rather than "Operation complete"; the body carries the detail line too; and the
    /// request names the message, so a click opens the Activity window on it (``activityMessageKey``,
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
        // Each banner is one completed outcome (success/warning/error — see the `.banner =`
        // call sites), so it should surface as its own notification. The per-publish UUID gives
        // every request a distinct identifier, so the system never coalesces two genuinely
        // different outcomes into one.
        post(UNNotificationRequest(identifier: banner.id.uuidString, content: content, trigger: nil))
    }

    /// The notification's user-info key for the message it reports — Recent's row id.
    nonisolated static let activityMessageKey = "activityMessage"

    /// The run a message ends, by name — the last long run, when it ended a moment ago: within the
    /// window's own rule for a run's ending (`ContentView.runOrigin(ending:)`). A run's message is
    /// set in the turn its progress clears.
    nonisolated static func runTitle(lastFinished: (title: String?, ended: Date)?, now: Date = Date()) -> String? {
        guard let lastFinished, now.timeIntervalSince(lastFinished.ended) < 2 else { return nil }
        return lastFinished.title
    }

    private static func postToNotificationCenter(_ request: UNNotificationRequest) {
        // The completion handler is the only signal this feature has. `add` fails silently when the
        // user has revoked notification permission in System Settings — and this feature exists
        // precisely for when the app is in the BACKGROUND, so a dropped notification is a dropped
        // outcome the user never sees: the in-window banner is gone by the time they come back.
        // Resolved on the main actor before the call (`Logger.shared` is MainActor-isolated) so the
        // handler, which arrives on an arbitrary queue, only touches the logger's nonisolated API.
        let logger = Logger.shared
        UNUserNotificationCenter.current().add(request) { error in
            guard let error else { return }
            logger.error("Could not post the background-completion notification: \(error.localizedDescription)")
        }
    }
}

/// **A notification's click opens that message in Activity** (Run Room TE227, R15): the window on
/// Now with the row picked out — not the popover, which hangs from a main window that may be behind
/// other apps.
final class OperationNotificationClicks: NSObject, UNUserNotificationCenterDelegate {
    static let shared = OperationNotificationClicks()

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = (response.notification.request.content.userInfo[OperationNotifier.activityMessageKey] as? String)
            .flatMap(UUID.init(uuidString:))
        Task { @MainActor in
            NSApp.activate()
            ActivityCenter.shared.openWindow(highlighting: id)
            completionHandler()
        }
    }
}

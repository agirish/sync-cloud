import AppKit
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

    static func postIfEnabled(for banner: OperationBanner) {
        let enabled = UserDefaults.standard.bool(forKey: GeneralSettings.notifyOnBackgroundCompletionKey)
        guard shouldNotify(enabled: enabled, appIsActive: NSApp.isActive) else { return }

        let content = UNMutableNotificationContent()
        content.title = title(for: banner.severity)
        content.body = banner.message
        content.sound = .default
        // Each banner is one completed outcome (success/warning/error — see the `.banner =`
        // call sites), so it should surface as its own notification. The per-publish UUID gives
        // every request a distinct identifier, so the system never coalesces two genuinely
        // different outcomes into one.
        let request = UNNotificationRequest(identifier: banner.id.uuidString, content: content, trigger: nil)
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

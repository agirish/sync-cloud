import AppKit
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
        // The banner id keeps a rapid banner replacement from stacking two notifications
        // for what the user perceives as one outcome.
        let request = UNNotificationRequest(identifier: banner.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

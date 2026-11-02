import AppKit
import Design
import Events
import ServiceManagement
import SwiftUI

/// The four General preferences the guided setup sheet offers under *More options*, and the two of
/// them that carry a state machine.
///
/// **Extracted so setup and Settings ▸ General are the same controls, not two spellings of them.**
/// Two of the four are more than a stored boolean: launch-at-login is an `SMAppService` round-trip
/// with an echo guard between the toggle and the service, and the notification toggle has to ask
/// macOS for permission on the way on and say so when it is refused. A second copy of either in
/// setup would be a second implementation of a state machine that took several attempts to get
/// right the first time.
///
/// The rows keep their `Toggle` titles exactly as they were, so
/// `SettingsSearchTests.everyControlLabelInTheTabSourcesIsIndexed` still finds them — and this file
/// sits directly in `Sources/Settings/`, because that scan reads one level of the directory and
/// nothing below it.

/// Launch at login, with the service round-trip and its approval hint. The state machine lives in
/// `LoginItemController.shared`, so this row and any other control (setup's row, an Ask Claude
/// card) drive one round-trip and show one value.
public struct LaunchAtLoginRow: View {
    @ObservedObject private var loginItem = LoginItemController.shared

    public init() {}

    public var body: some View {
    SettingsSection {
        Toggle("Launch SyncCloud at login", isOn: Binding(
            get: { loginItem.isOn },
            set: { loginItem.setFromUser($0) }))
            .help("Adds SyncCloud to your Mac’s Login Items, so it opens when you log in.")
    } caption: {
        if loginItem.needsApproval {
            HStack(spacing: 4) {
                Text("Approval needed — allow SyncCloud in Login Items settings.")
                Button("Open Login Items Settings") {
                    SMAppService.openSystemSettingsLoginItems()
                }
                .buttonStyle(.link)
                .controlSize(.small)
            }
        } else {
            Text("Automatically start SyncCloud when you log in to your Mac.")
        }
    }
        .task { loginItem.refresh() }
        // Approving the login item happens in System Settings, so this footer's hint goes stale
        // exactly while the tab is still open. Coming back to the app re-activates it.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItem.refresh()
        }
    }
}

/// Notify when background operations finish, with the permission request its "on" position needs.
public struct NotifyInBackgroundRow: View {
    @AppStorage(GeneralSettings.notifyOnBackgroundCompletionKey) private var notifyInBackground: Bool = false
    /// Whether the system has DENIED notification permission while the toggle is on — the one
    /// state where the feature looks enabled here but can never fire.
    @State private var notificationsDenied = false

    public init() {}

    public var body: some View {
    SettingsSection {
        Toggle("Notify when operations finish in the background", isOn: $notifyInBackground)
            .help("Posts a system notification when a copy, sync, or verify finishes while SyncCloud isn’t the active app. Turning it on asks macOS for permission.")
            .onChange(of: notifyInBackground) { _, enabled in
                if enabled {
                    BackgroundNotificationPermission.request { notificationsDenied = $0 }
                } else {
                    // The hint only matters while the feature is on.
                    notificationsDenied = false
                }
            }
    } caption: {
        if notifyInBackground && notificationsDenied {
            Text("Notifications are disabled in System Settings — allow SyncCloud under Notifications to see these alerts.")
                .foregroundStyle(.orange)
        } else {
            Text("Shows a system notification when a copy, sync, or verify finishes while SyncCloud isn’t the active app. Requires notification permission.")
        }
    }
        .task { readNotificationAuthorization() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            readNotificationAuthorization()
        }
    }

    /// Reflects the real notification authorization into the footer hint, while the feature is on.
    private func readNotificationAuthorization() {
        guard notifyInBackground else { return }
        BackgroundNotificationPermission.readDenied { notificationsDenied = $0 }
    }
}

/// The four rows together, for setup's *More options*.
///
/// **The notification toggle really does request permission here**, because it is the Settings row
/// — a copy that only wrote the key would leave a user who turned it on during setup waiting for
/// notifications that were never authorised.
public struct GeneralRows: View {
    @AppStorage(GeneralSettings.warnBeforeQuitKey) private var warnBeforeQuit: Bool = true
    @AppStorage(GeneralSettings.restoreLastFocusKey) private var restoreLastFocus: Bool = true

    /// No `SettingsManager`: all four of these are stored preferences, and two of them talk to the
    /// system rather than to the app. Taking a manager it never reads would say otherwise.
    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            NotifyInBackgroundRow()
            LaunchAtLoginRow()
            Toggle("Reopen panes where I left off", isOn: $restoreLastFocus)
                .help("Reopens each pane with the tabs and folders it had when you last quit. Off, every pane starts with one tab at its source’s opening folder.")
            Toggle("Warn before quitting during file operations", isOn: $warnBeforeQuit)
                .help("Asks before quitting while a copy, move, or delete is still running. Off, SyncCloud quits at once.")
        }
        .toggleStyle(.checkbox)
    }
}

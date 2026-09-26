import AppKit
import Design
import Events
import ServiceManagement
import SwiftUI
import UserNotifications

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

/// Launch at login, with the service round-trip and its approval hint.
public struct LaunchAtLoginRow: View {
    /// Mirrors `SMAppService.mainApp.status`. Deliberately not seeded in the initializer:
    /// the status getter is a synchronous XPC call, which must not run on the main thread —
    /// `.task` kicks off a detached read once the view is up (and app activation re-reads,
    /// since approval happens over in System Settings).
    @State private var launchAtLogin = false
    /// The login item is registered but awaits the user's consent in System Settings →
    /// Login Items; shown distinctly so a pending approval doesn't read as a broken toggle.
    @State private var loginItemNeedsApproval = false
    /// Tells a user's flip apart from the echo of a programmatic set, keeps the register /
    /// unregister calls serialised to one at a time, and decides what a finished round-trip
    /// owes the user — see `LoginItemEchoGuard`, where the whole state machine lives so it can
    /// be tested without an SMAppService round-trip.
    @State private var loginItemEcho = LoginItemEchoGuard()

    public init() {}

    public var body: some View {
    SettingsSection {
        Toggle("Launch SyncCloud at login", isOn: $launchAtLogin)
            .onChange(of: launchAtLogin) { _, enabled in
                guard loginItemEcho.shouldStartRoundTrip(for: enabled, at: .now) else {
                    // Echo of a programmatic set, or a gesture the in-flight call will
                    // carry in its `settle`. Logged because the second case is the one
                    // shape of this guard the user can FEEL — the switch moves and
                    // nothing happens — and with no line here a guard stuck shut was
                    // invisible in the log by construction.
                    Logger.shared.debug("Launch-at-login: no round-trip started for \(enabled) (echo, or one already in flight)")
                    return
                }
                updateLoginItem(enabled)
            }
    } caption: {
        if loginItemNeedsApproval {
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
        .task { readLoginItemState() }
        // Approving the login item happens in System Settings, so this footer's hint goes stale
        // exactly while the tab is still open. Coming back to the app re-activates it.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            readLoginItemState()
        }
    }

    /// Reflects the real service state into the toggle and approval hint. A pending
    /// approval counts as "on": the item *is* registered, just not yet consented to.
    ///
    /// Dated against the echo guard: this runs on `.task` and on EVERY app re-activation, so
    /// without the epoch check a cmd-tab away and back mid-gesture published a service state
    /// that predated the user's flip, moving the toggle out from under the running round-trip.
    /// That call then settled against the "moved" toggle and drove the service back, losing a
    /// registration that had succeeded.
    private func readLoginItemState() {
        Task {
            let epoch = loginItemEcho.epoch
            let status = await Self.readStatusOffMain()
            guard loginItemEcho.mayPublishStatus(readAt: epoch, at: .now) else { return }
            applyLoginItemState(status)
        }
    }

    /// Publishes just the approval hint, leaving the toggle where the user put it. Used when a
    /// failing round-trip's status re-read is the freshest thing we know but the toggle has
    /// already moved on — `applyLoginItemState` would overwrite that move.
    private func applyApprovalHint(_ status: SMAppService.Status) {
        loginItemNeedsApproval = (status == .requiresApproval)
    }

    /// Publishes a freshly read service status to the view state. Marking the value applied in
    /// the same main-actor turn as the toggle keeps `onChange` from treating the programmatic
    /// set as a user gesture (initial read, failure revert).
    ///
    /// `adoptedStatus` rather than `markApplied`: this write TAKES the toggle, so any round-trip
    /// whose claim had already expired must stop speaking for it — see `adoptedStatus`.
    private func applyLoginItemState(_ status: SMAppService.Status) {
        launchAtLogin = (status == .enabled || status == .requiresApproval)
        loginItemNeedsApproval = (status == .requiresApproval)
        loginItemEcho.adoptedStatus(launchAtLogin)
    }

    /// Registers/unregisters the login item, reverting the toggle to the real service state on
    /// failure so the UI never claims a state the system rejected.
    private func updateLoginItem(_ enabled: Bool) {
        // Synchronously, before the `Task` is even scheduled: two `onChange` turns must not
        // both pass `shouldStartRoundTrip` and start a call apiece.
        let token = loginItemEcho.beginRoundTrip(at: .now)
        Task {
            do {
                let needsApproval = try await Self.applyLoginItemOffMain(enabled)
                // A superseded settle (nil) owns nothing, so it publishes nothing: this hint was
                // sampled off-main and lands an actor hop later, and whatever superseded the call
                // — a fresher status read, a later gesture — knows better than it does.
                guard let followUp = loginItemEcho.settle(
                    token: token, applied: enabled, toggle: launchAtLogin, succeeded: true) else { return }
                loginItemNeedsApproval = needsApproval
                if needsApproval {
                    Logger.shared.info("Login item registered; awaiting user approval in Login Items settings")
                }
                perform(followUp, status: nil)
            } catch {
                // Logged before the ownership test: the call really did fail, and that is worth
                // a line whether or not this round-trip still speaks for the toggle.
                Logger.shared.error("Failed to \(enabled ? "register" : "unregister") launch-at-login item: \(error.localizedDescription)")
                let status = await Self.readStatusOffMain()
                guard let followUp = loginItemEcho.settle(
                    token: token, applied: enabled, toggle: launchAtLogin, succeeded: false) else { return }
                perform(followUp, status: status)
            }
        }
    }

    /// Carries out what `LoginItemEchoGuard.settle` decided. `status` is the freshly re-read
    /// service status, available only on the failure path.
    private func perform(_ followUp: LoginItemFollowUp, status: SMAppService.Status?) {
        switch followUp {
        case .settled:
            break
        case .adoptServiceState:
            if let status { applyLoginItemState(status) }
        case .reapply(let value, let refreshApprovalHint):
            if refreshApprovalHint, let status { applyApprovalHint(status) }
            updateLoginItem(value)
        }
    }

    /// Reads `SMAppService.mainApp.status` detached: the getter is a synchronous XPC call
    /// that must not run on the main thread (the same hazard that defers the initial read
    /// out of view init).
    private static func readStatusOffMain() async -> SMAppService.Status {
        await Task.detached(priority: .userInitiated) {
            SMAppService.mainApp.status
        }.value
    }

    /// Runs the status check plus register/unregister round-trip detached — all three are
    /// synchronous XPC calls. Returns whether the item now awaits approval in Login Items.
    private static func applyLoginItemOffMain(_ enabled: Bool) async throws -> Bool {
        try await Task.detached(priority: .userInitiated) {
            let status = SMAppService.mainApp.status
            if enabled {
                if status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if status == .enabled || status == .requiresApproval {
                // Unregistering a pending-approval item withdraws it from Login Items.
                try SMAppService.mainApp.unregister()
            }
            return SMAppService.mainApp.status == .requiresApproval
        }.value
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
            .onChange(of: notifyInBackground) { _, enabled in
                if enabled {
                    // Capture the result: a denied request used to vanish, leaving the
                    // toggle on and the user waiting for notifications that never come.
                    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                        Task { @MainActor in notificationsDenied = !granted }
                    }
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
            Text("Shows a system notification when a copy, sync, or verify finishes while SyncCloud isn't the active app. Requires notification permission.")
        }
    }
        .task { readNotificationAuthorization() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            readNotificationAuthorization()
        }
    }

    /// Reflects the real notification authorization into the footer hint. Only `denied` shows
    /// the warning: `notDetermined` means the request prompt is still ahead, and provisional/
    /// authorized both deliver.
    private func readNotificationAuthorization() {
        guard notifyInBackground else { return }
        UNUserNotificationCenter.current().getNotificationSettings { notificationSettings in
            let denied = notificationSettings.authorizationStatus == .denied
            Task { @MainActor in notificationsDenied = denied }
        }
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
            Toggle("Warn before quitting during file operations", isOn: $warnBeforeQuit)
        }
        .toggleStyle(.checkbox)
    }
}

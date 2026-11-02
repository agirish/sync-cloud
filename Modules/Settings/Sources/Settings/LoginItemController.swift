import AppKit
import Events
import ServiceManagement

/// Launch at login, owned once for the app: the switch's value, the approval hint, and the
/// `SMAppService` round-trip with its echo guard (TE290 step 0a).
///
/// **Moved out of `LaunchAtLoginRow` so every control drives one state machine.** The row used to
/// hold all of this in `@State`, so setup's row and Settings' row each ran their own guard against
/// the one service, and anything that is not that view (an Ask Claude card, TE290) could only write
/// the switch by mounting a second copy. The logic is the row's, line for line; what changed is
/// where it lives and that a user's flip arrives as `setFromUser` rather than through `onChange`.
///
/// **A programmatic set still reaches the guard the way `onChange` did.** SwiftUI delivered the
/// row's `onChange` for its own writes too, after `adoptedStatus` had run in the same turn, and the
/// guard dismissed them as echoes (with a debug line). `publish` keeps that order: write, adopt,
/// then hand the change to the same handler, so the guard and the log see exactly what they saw.
@MainActor
public final class LoginItemController: ObservableObject {

    /// The app's one controller. Rows and cards observe this, so they show one value.
    public static let shared = LoginItemController()

    /// Mirrors `SMAppService.mainApp.status`; a pending approval counts as on. Not seeded at init:
    /// the status getter is a synchronous XPC call, which must not run on the main thread —
    /// `refresh()` reads it detached.
    @Published public private(set) var isOn = false

    /// The login item is registered but awaits the user's consent in System Settings → Login
    /// Items; shown distinctly so a pending approval doesn't read as a broken switch.
    @Published public private(set) var needsApproval = false

    /// See `LoginItemEchoGuard`, where the state machine lives so it can be tested without a
    /// service round-trip.
    private var echo = LoginItemEchoGuard()

    /// The service calls, a seam so a test can stand in for `SMAppService`.
    let service: LoginItemService

    /// The last round-trip started, kept so a test can await it instead of polling — a polled
    /// wait on the main actor times out when other suites hold it. Nil until one starts, which is
    /// also how a test sees that a status read started none.
    private(set) var lastRoundTrip: Task<Void, Never>?

    init(service: LoginItemService = .live) {
        self.service = service
    }

    /// A user's flip of the switch: the row's `onChange`, now called directly.
    public func setFromUser(_ enabled: Bool) {
        guard enabled != isOn else { return }
        isOn = enabled
        handleChange(to: enabled)
    }

    /// Reflects the real service state into the switch and the approval hint.
    ///
    /// Dated against the echo guard: this runs when a row appears and on EVERY app re-activation,
    /// so without the epoch check a cmd-tab away and back mid-gesture published a service state
    /// that predated the user's flip, moving the switch out from under the running round-trip.
    /// That call then settled against the "moved" switch and drove the service back, losing a
    /// registration that had succeeded.
    /// - Returns: The read, so a caller can await it.
    @discardableResult
    public func refresh() -> Task<Void, Never> {
        Task {
            let epoch = echo.epoch
            let status = await readStatusOffMain()
            guard echo.mayPublishStatus(readAt: epoch, at: .now) else { return }
            applyState(status)
        }
    }

    /// What the row's `onChange` did with every change of the switch, user's or programmatic.
    private func handleChange(to enabled: Bool) {
        guard echo.shouldStartRoundTrip(for: enabled, at: .now) else {
            // Echo of a programmatic set, or a gesture the in-flight call will carry in its
            // `settle`. Logged because the second case is the one shape of this guard the user
            // can FEEL — the switch moves and nothing happens — and with no line here a guard
            // stuck shut was invisible in the log by construction.
            Logger.shared.debug("Launch-at-login: no round-trip started for \(enabled) (echo, or one already in flight)")
            return
        }
        updateLoginItem(enabled)
    }

    /// A programmatic write: set, let the guard adopt it in the same turn, then deliver the change
    /// as `onChange` would have — only when the value actually moved.
    private func publish(_ value: Bool) {
        let old = isOn
        isOn = value
        echo.adoptedStatus(value)
        if old != value { handleChange(to: value) }
    }

    /// Publishes just the approval hint, leaving the switch where the user put it. Used when a
    /// failing round-trip's status re-read is the freshest thing known but the switch has already
    /// moved on — `applyState` would overwrite that move.
    private func applyApprovalHint(_ status: SMAppService.Status) {
        needsApproval = (status == .requiresApproval)
    }

    /// Publishes a freshly read service status. `adoptedStatus` rather than `markApplied`: this
    /// write TAKES the switch, so any round-trip whose claim had already expired must stop
    /// speaking for it — see `adoptedStatus`.
    private func applyState(_ status: SMAppService.Status) {
        needsApproval = (status == .requiresApproval)
        publish(status == .enabled || status == .requiresApproval)
    }

    /// Registers or unregisters the login item, reverting the switch to the real service state on
    /// failure so no control claims a state the system rejected.
    private func updateLoginItem(_ enabled: Bool) {
        // Synchronously, before the `Task` is even scheduled: two changes must not both pass
        // `shouldStartRoundTrip` and start a call apiece.
        let token = echo.beginRoundTrip(at: .now)
        lastRoundTrip = Task {
            do {
                let awaitsApproval = try await applyOffMain(enabled)
                // A superseded settle (nil) owns nothing, so it publishes nothing: this hint was
                // sampled off-main and lands an actor hop later, and whatever superseded the call
                // — a fresher status read, a later gesture — knows better than it does.
                guard let followUp = echo.settle(
                    token: token, applied: enabled, toggle: isOn, succeeded: true) else { return }
                needsApproval = awaitsApproval
                if awaitsApproval {
                    Logger.shared.info("Login item registered; awaiting user approval in Login Items settings")
                }
                perform(followUp, status: nil)
            } catch {
                // Logged before the ownership test: the call really did fail, and that is worth a
                // line whether or not this round-trip still speaks for the switch.
                Logger.shared.error("Failed to \(enabled ? "register" : "unregister") launch-at-login item: \(error.localizedDescription)")
                let status = await readStatusOffMain()
                guard let followUp = echo.settle(
                    token: token, applied: enabled, toggle: isOn, succeeded: false) else { return }
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
            if let status { applyState(status) }
        case .reapply(let value, let refreshApprovalHint):
            if refreshApprovalHint, let status { applyApprovalHint(status) }
            updateLoginItem(value)
        }
    }

    /// Reads the status detached: the getter is a synchronous XPC call.
    private func readStatusOffMain() async -> SMAppService.Status {
        let service = service
        return await Task.detached(priority: .userInitiated) { service.status() }.value
    }

    /// Runs the status check plus register/unregister round-trip detached — all three are
    /// synchronous XPC calls. Returns whether the item now awaits approval in Login Items.
    private func applyOffMain(_ enabled: Bool) async throws -> Bool {
        let service = service
        return try await Task.detached(priority: .userInitiated) {
            let status = service.status()
            if enabled {
                if status != .enabled {
                    try service.register()
                }
            } else if status == .enabled || status == .requiresApproval {
                // Unregistering a pending-approval item withdraws it from Login Items.
                try service.unregister()
            }
            return service.status() == .requiresApproval
        }.value
    }
}

/// The three `SMAppService.mainApp` calls the controller makes, so a test can stand in for them.
struct LoginItemService: Sendable {
    var status: @Sendable () -> SMAppService.Status
    var register: @Sendable () throws -> Void
    var unregister: @Sendable () throws -> Void

    static let live = LoginItemService(
        status: { SMAppService.mainApp.status },
        register: { try SMAppService.mainApp.register() },
        unregister: { try SMAppService.mainApp.unregister() })
}

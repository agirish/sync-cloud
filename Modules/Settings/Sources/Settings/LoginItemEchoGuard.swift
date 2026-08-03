/// The launch-at-login toggle's echo/reconcile state machine, extracted from
/// `GeneralSettingsTab` so it can be tested without an `SMAppService` round-trip.
///
/// Two jobs, and they are the same job seen from either end of an asynchronous register /
/// unregister call:
///
/// - The switch binds to local `@State`, so a PROGRAMMATIC write (the initial status read, a
///   failure revert) flows out through the same `onChange` a user's flip does. Comparing
///   against `lastApplied` swallows those echoes — the same idiom `AutomationToggleEchoGuard`
///   uses.
/// - The call is a round-trip, so the user can flip the switch again while it is in flight.
///   Such a flip does not start a call of its own; `settle` compares the toggle's position
///   against what the finished call pushed and hands the difference back as a follow-up.
///
/// **The invariant: at most one round-trip is in flight, and no status read may overwrite the
/// toggle while one is.** Both halves are enforced by explicit state — `isRoundTripInFlight`
/// and `roundTripEvents` — rather than inferred from `lastApplied`, which is what the previous
/// version tried and could not do:
///
/// - Serialisation used to rest on the marker being stale mid-flight, so a flip back to the
///   in-flight value would compare equal and be suppressed. That holds for ONE mid-flight
///   flip, not two. From toggle off / service off, ON → OFF → ON suppresses the OFF (it
///   matches the stale `false`) but NOT the second ON, which differs from it — so `onChange`
///   started a second round-trip alongside the first. If the first then failed and the second
///   succeeded, the first's re-read saw a service that was still off, adopted it, snapped the
///   toggle OFF, and the second settled against a toggle that had "moved" — unregistering the
///   login item its own call had just registered. Internally consistent, and the opposite of
///   what the user asked for.
/// - A background status read (`.task`, and every app re-activation) publishes the service's
///   state into the toggle. Landing that mid-flight moved the toggle out from under a running
///   call, which then settled against the "moved" toggle and drove the service back — losing a
///   registration that had SUCCEEDED. `StatusReadEpoch` dates a read against the guard's
///   round-trip state, so a read that is stale, or that overlaps a call, is dropped rather
///   than published.
///
/// The marker still deliberately does NOT move in `shouldStartRoundTrip` — it names the value
/// last pushed at the service, and mid-flight nothing new has been pushed.
struct LoginItemEchoGuard {
    /// The last toggle value known to match the value last pushed at the service. `nil` until
    /// the first status read lands, so the very first move of the switch always counts.
    private var lastApplied: Bool?

    /// Whether a register/unregister round-trip is running right now. This — not the stale
    /// marker — is what serialises the calls.
    private var isRoundTripInFlight = false

    /// Bumped every time a round-trip starts and every time one settles, so a status read that
    /// began before either can tell it is now out of date. Only ever compared for equality.
    private var roundTripEvents = 0

    /// Dates a background status read against the guard's round-trip state. Captured when the
    /// read starts, handed back to `mayPublishStatus(readAt:)` before it publishes.
    struct StatusReadEpoch: Equatable {
        fileprivate let events: Int
    }

    /// The epoch to capture at the start of a status read.
    var epoch: StatusReadEpoch { StatusReadEpoch(events: roundTripEvents) }

    /// Whether the toggle's move to `value` should start a round-trip **now**.
    ///
    /// False for the echo of a programmatic set, and false while a call is already in flight —
    /// in that second case the move is a real gesture, but the in-flight call's `settle` is
    /// what carries it, so starting one here would double up.
    func shouldStartRoundTrip(for value: Bool) -> Bool {
        !isRoundTripInFlight && value != lastApplied
    }

    /// Whether a status read that began at `epoch` may still be published to the toggle.
    ///
    /// No, if a call is in flight — that call owns the toggle until it settles. No, if any
    /// round-trip has started or settled since the read began — the status in hand predates it,
    /// and publishing it would walk the toggle backwards.
    func mayPublishStatus(readAt epoch: StatusReadEpoch) -> Bool {
        !isRoundTripInFlight && epoch == self.epoch
    }

    /// A programmatic write put the toggle at `value` — mark it so its `onChange` is swallowed.
    mutating func markApplied(_ value: Bool) {
        lastApplied = value
    }

    /// A round-trip is starting. Must be called synchronously with the decision to start one —
    /// if it waited for the call's `Task` to be scheduled, two gestures could both pass
    /// `shouldStartRoundTrip` before either marked itself in flight.
    mutating func beginRoundTrip() {
        isRoundTripInFlight = true
        roundTripEvents += 1
    }

    /// A round-trip that tried to apply `enabled` has returned; `toggle` is where the switch
    /// sits now, and `succeeded` says whether the service took the value.
    ///
    /// **The marker moves to `enabled` first, on BOTH paths.** With it left stale — which is
    /// what the failure path did before this type existed — the next echo reads as a gesture.
    mutating func settle(applied enabled: Bool, toggle: Bool, succeeded: Bool) -> LoginItemFollowUp {
        isRoundTripInFlight = false
        roundTripEvents += 1
        lastApplied = enabled
        guard toggle != enabled else {
            // Nothing moved. A success has already published the truth; a failure has not, so
            // the service's real state is what the toggle should show.
            return succeeded ? .settled : .adoptServiceState
        }
        // The toggle moved while the call was in flight. Keep the user's position and drive the
        // service toward it, rather than overwriting a gesture with the service's state.
        return .reapply(toggle, refreshApprovalHint: !succeeded)
    }
}

/// What `updateLoginItem` must do once its round-trip has returned.
enum LoginItemFollowUp: Equatable {
    /// The call succeeded and the toggle never moved — it already shows the truth.
    case settled
    /// The call failed and the toggle never moved — publish the service's real state, so the UI
    /// never claims a state the system rejected.
    case adoptServiceState
    /// The toggle moved while the call was in flight; drive the service to this position.
    /// `refreshApprovalHint` is set when a freshly re-read status is in hand (the failure path):
    /// the hint can be published without disturbing the toggle the user just moved.
    case reapply(Bool, refreshApprovalHint: Bool)
}

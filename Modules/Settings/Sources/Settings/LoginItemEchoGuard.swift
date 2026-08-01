/// The launch-at-login toggle's echo/reconcile state machine, extracted from
/// `GeneralSettingsTab` so it can be tested without an `SMAppService` round-trip.
///
/// Two jobs, and they are the same job seen from either end of an asynchronous register /
/// unregister call:
///
/// - The switch binds to local `@State`, so a PROGRAMMATIC write (the initial status read, a
///   failure revert) flows out through the same `onChange` a user's flip does. `isGesture`
///   swallows those echoes — the same `lastApplied` idiom `AutomationToggleEchoGuard` uses.
/// - The call is a round-trip, so the user can flip the switch again while it is in flight.
///   That flip's `onChange` compares against the stale marker and is SUPPRESSED, which means
///   nobody is left to act on it — so `settle` hands it back as a follow-up when the call
///   returns.
///
/// The marker deliberately does NOT move in `isGesture`. Moving it there would let a mid-flight
/// flip start a second concurrent round-trip for one gesture; leaving it stale until `settle`
/// is what serialises them — at most one call in flight, and the toggle's latest position
/// applied when it lands.
struct LoginItemEchoGuard {
    /// The last toggle value known to match the value last pushed at the service. `nil` until
    /// the first status read lands, so the very first move of the switch always counts.
    private var lastApplied: Bool?

    /// The toggle moved to `value`. Returns whether that is a genuine user gesture to send to
    /// the service (false when it is the echo of a programmatic set).
    ///
    /// Non-`mutating` on purpose, and that is load-bearing rather than tidiness: see the note on
    /// `settle` about why the marker must not move here.
    func isGesture(_ value: Bool) -> Bool {
        value != lastApplied
    }

    /// A programmatic write put the toggle at `value` — mark it so its `onChange` is swallowed.
    mutating func markApplied(_ value: Bool) {
        lastApplied = value
    }

    /// A round-trip that tried to apply `enabled` has returned; `toggle` is where the switch
    /// sits now, and `succeeded` says whether the service took the value.
    ///
    /// **The marker moves to `enabled` first, on BOTH paths.** That ordering is what makes the
    /// premise "the mid-flight flip was suppressed, so this follow-up is the only one acting on
    /// it" true more than once. With the marker left stale — which is what the failure path did
    /// before this type existed — the *next* mid-flight flip is not suppressed, so `onChange`
    /// starts a round-trip AND this follow-up starts one: two concurrent `SMAppService` calls
    /// for a single gesture, fanning out again on every subsequent failure.
    mutating func settle(applied enabled: Bool, toggle: Bool, succeeded: Bool) -> LoginItemFollowUp {
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

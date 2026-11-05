import Foundation

/// The launch-at-login toggle's echo/reconcile state machine, kept apart from
/// `LoginItemController` so it can be tested without an `SMAppService` round-trip. Two jobs, one
/// seen from either end of an asynchronous register/unregister call:
///
/// - A programmatic write (a status read, a failure revert) reaches the same change handler as a
///   user's flip. Comparing against `lastApplied` swallows those echoes, as
///   `AutomationToggleEchoGuard` does.
/// - The user can flip again while a call is in flight. That flip starts no call of its own;
///   `settle` compares the toggle with what the call pushed and returns the difference as a
///   follow-up.
///
/// **The invariant: at most one round-trip holds a live claim, and no status read may overwrite
/// the toggle while one does.** Both halves are explicit state (`inFlight`, `roundTripEvents`),
/// not inferred from `lastApplied`, which can't serialise two mid-flight flips: a second
/// round-trip would race the first and could unregister what it just registered.
///
/// The claim expires after `roundTripGoesStaleAfter`, because the guarded XPC call can't be
/// cancelled or timed out, only stopped waiting on. Once superseded (by a later gesture's
/// round-trip, or a published status read via `adoptedStatus`) a late settle is ignored by token.
/// Expiry and supersession must agree on who owns the toggle. `StatusReadEpoch` drops a
/// background status read that is stale or overlaps a call, which would otherwise move the toggle
/// under the call and make it drive the service back.
///
/// The marker does not move in `shouldStartRoundTrip`: it names the value last pushed at the
/// service, and mid-flight nothing new has been pushed.
struct LoginItemEchoGuard {
    /// The last toggle value known to match the value last pushed at the service. `nil` until
    /// the first status read lands, so the very first move of the switch always counts.
    private var lastApplied: Bool?

    /// The round-trip running right now, if any. This, not the marker, serialises the calls.
    private var inFlight: RoundTrip?

    /// Bumped every time a round-trip starts and every time one settles, so a status read that
    /// began before either can tell it is now out of date. Only ever compared for equality.
    private var roundTripEvents = 0

    /// A started round-trip: which one it is, and when it started.
    private struct RoundTrip {
        let token: RoundTripToken
        let startedAt: ContinuousClock.Instant
    }

    /// Names one round-trip, so a settle can be matched against the call actually in flight: a
    /// superseded call must not clear its successor's claim on the way out. The filing lens's
    /// re-ask guard follows the same ownership rule.
    struct RoundTripToken: Equatable {
        fileprivate let value: Int
    }

    /// How long an unfinished round-trip keeps its exclusive claim on the toggle.
    ///
    /// **Without a bound this guard could latch shut.** The claim is cleared in `settle`, after an
    /// XPC call into `smd` that a wedge can hold for ever (`Task.value` doesn't resume on
    /// cancellation): every later flip would be swallowed, every status read dropped, and nothing
    /// logged. 15 seconds is far longer than a healthy call (sub-second, a few seconds for a slow
    /// `smd`), so an impatient double-flip is still suppressed, and short enough that trying again
    /// gets a response. The deadline is the guard's, not a timeout on the await, because the call
    /// can't be cancelled; only the claim has to recover, and that is a pure, testable decision.
    ///
    /// **Measured on `ContinuousClock`, never `Date`.** A wall-clock step backwards would keep the
    /// claim live for the step's length; a step forwards would expire a healthy call at once.
    /// Continuous, not suspending, because time asleep is still time the call hasn't answered.
    static let roundTripGoesStaleAfter: Duration = .seconds(15)

    /// Dates a background status read against the guard's round-trip state. Captured when the
    /// read starts, handed back to `mayPublishStatus(readAt:)` before it publishes.
    struct StatusReadEpoch: Equatable {
        fileprivate let events: Int
    }

    /// The epoch to capture at the start of a status read.
    var epoch: StatusReadEpoch { StatusReadEpoch(events: roundTripEvents) }

    /// Whether the toggle's move to `value` should start a round-trip **now**.
    ///
    /// False for the echo of a programmatic set, and false while a live call is in flight, whose
    /// `settle` carries the gesture. A stale call (see `roundTripGoesStaleAfter`) no longer blocks.
    func shouldStartRoundTrip(for value: Bool, at now: ContinuousClock.Instant) -> Bool {
        value != lastApplied && !hasLiveRoundTrip(at: now)
    }

    /// Whether a status read that began at `epoch` may still be published to the toggle.
    ///
    /// No while a live call is in flight, since it owns the toggle until it settles. No if any
    /// round-trip started or settled since the read began, since the status predates it. A stale
    /// call owns nothing, so a read goes through: with the call wedged, it is the only way left to
    /// put the toggle back in step with the service.
    func mayPublishStatus(readAt epoch: StatusReadEpoch, at now: ContinuousClock.Instant) -> Bool {
        epoch == self.epoch && !hasLiveRoundTrip(at: now)
    }

    /// Whether a round-trip is in flight AND still within its claim window.
    private func hasLiveRoundTrip(at now: ContinuousClock.Instant) -> Bool {
        guard let inFlight else { return false }
        return inFlight.startedAt.duration(to: now) < Self.roundTripGoesStaleAfter
    }

    /// A freshly read service status was just published into the toggle: mark it applied so its
    /// change is swallowed as an echo, and supersede any round-trip on the books.
    ///
    /// **The only way to mark a value applied outside a settle**; never add a marker-only setter.
    /// `mayPublishStatus` lets a read through once a claim has expired, but `settle` checks the
    /// token alone, so the expired call must lose its token here. Otherwise its settle would read
    /// the published value as a mid-flight flip and drive the service back, undoing a successful
    /// registration. Bumping the counter dates every read still in the air, which would otherwise
    /// walk the switch backwards.
    mutating func adoptedStatus(_ value: Bool) {
        lastApplied = value
        inFlight = nil
        roundTripEvents += 1
    }

    /// A round-trip is starting. **Call it synchronously with the decision to start one**, or two
    /// gestures could both pass `shouldStartRoundTrip` before either is marked in flight. Hand the
    /// returned token to `settle`, so a superseded call can't clear its successor's claim.
    mutating func beginRoundTrip(at now: ContinuousClock.Instant) -> RoundTripToken {
        roundTripEvents += 1
        let token = RoundTripToken(value: roundTripEvents)
        inFlight = RoundTrip(token: token, startedAt: now)
        return token
    }

    /// A round-trip that tried to apply `enabled` has returned; `toggle` is where the switch
    /// sits now, and `succeeded` says whether the service took the value.
    ///
    /// The marker moves to `enabled` first, on both paths; left stale, the next echo would read as
    /// a gesture.
    ///
    /// A superseded call returns `nil` and does nothing: a wedged call returning late would
    /// otherwise clear the live call's claim and drive the service from a stale toggle position.
    /// `nil`, not `.settled`, because `.settled` tells the caller to publish the call's approval
    /// hint, and a superseded call's hint is older than what is on screen.
    mutating func settle(
        token: RoundTripToken,
        applied enabled: Bool,
        toggle: Bool,
        succeeded: Bool
    ) -> LoginItemFollowUp? {
        guard inFlight?.token == token else { return nil }
        inFlight = nil
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

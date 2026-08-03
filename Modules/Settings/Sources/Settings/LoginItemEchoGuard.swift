import Foundation

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
/// **The invariant: at most one round-trip holds a live claim, and no status read may overwrite
/// the toggle while one does.** Both halves are enforced by explicit state — `inFlight` and
/// `roundTripEvents` — rather than inferred from `lastApplied`, which is what the previous
/// version tried and could not do.
///
/// "Live claim" rather than "in flight", because the claim EXPIRES: a round-trip that has not
/// returned within `roundTripGoesStaleAfter` stops blocking, and its late settle is ignored by
/// token. Stating it as "at most one in flight" would be a promise this type cannot keep — the
/// call it is guarding is an XPC round-trip it can neither cancel nor time out, only stop waiting
/// on. See `roundTripGoesStaleAfter` for what that unbounded version cost.
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

    /// The round-trip running right now, if any. This — not the stale marker — is what
    /// serialises the calls.
    private var inFlight: RoundTrip?

    /// Bumped every time a round-trip starts and every time one settles, so a status read that
    /// began before either can tell it is now out of date. Only ever compared for equality.
    private var roundTripEvents = 0

    /// A started round-trip: which one it is, and when it started.
    private struct RoundTrip {
        let token: RoundTripToken
        let startedAt: Date
    }

    /// Names one round-trip, so a settle can be matched against the call that is actually in
    /// flight. Needed because a round-trip can now be SUPERSEDED (see `roundTripGoesStaleAfter`)
    /// and a superseded call must not clear its successor's claim on the way out — the same
    /// ownership rule the filing lens's re-ask guard needs, for the same reason.
    struct RoundTripToken: Equatable {
        fileprivate let value: Int
    }

    /// How long an unfinished round-trip keeps its exclusive claim on the toggle.
    ///
    /// **Without a bound this guard could latch shut permanently.** The in-flight flag used to
    /// be cleared only in `settle`, which the call site reaches only after its `await` returns —
    /// and that await is an XPC call into `smd`, the very hazard the SettingsView helpers run off
    /// the main thread to survive. `Task.value` does not resume early on cancellation, so a wedged
    /// `smd` left the flag set for the life of the view: every later flip was swallowed (the
    /// switch MOVED and nothing happened), every status read was dropped so the toggle could not
    /// self-correct either, and nothing was logged because nothing had failed. That is strictly
    /// worse than the double-fire this type was written to fix, which at least left the user a way
    /// out.
    ///
    /// 15 seconds is far longer than a live round-trip takes (sub-second normally, a few seconds
    /// for a slow `smd`), so an impatient double-flip during a healthy call is still suppressed
    /// rather than doubled up; and it is short enough that a user who sees nothing happen and
    /// tries again gets a response. The deadline lives HERE rather than as a timeout around the
    /// await deliberately: the call cannot be cancelled (a blocked synchronous XPC call ignores
    /// cancellation), so there is nothing to abandon — what has to recover is this guard's claim,
    /// which is a pure decision and can therefore be tested without any concurrency plumbing.
    static let roundTripGoesStaleAfter: TimeInterval = 15

    /// Dates a background status read against the guard's round-trip state. Captured when the
    /// read starts, handed back to `mayPublishStatus(readAt:)` before it publishes.
    struct StatusReadEpoch: Equatable {
        fileprivate let events: Int
    }

    /// The epoch to capture at the start of a status read.
    var epoch: StatusReadEpoch { StatusReadEpoch(events: roundTripEvents) }

    /// Whether the toggle's move to `value` should start a round-trip **now**.
    ///
    /// False for the echo of a programmatic set, and false while a LIVE call is already in
    /// flight — in that second case the move is a real gesture, but the in-flight call's `settle`
    /// is what carries it, so starting one here would double up. A call that has gone stale
    /// (see `roundTripGoesStaleAfter`) has lost its claim and no longer blocks.
    func shouldStartRoundTrip(for value: Bool, at now: Date) -> Bool {
        value != lastApplied && !hasLiveRoundTrip(at: now)
    }

    /// Whether a status read that began at `epoch` may still be published to the toggle.
    ///
    /// No, if a live call is in flight — that call owns the toggle until it settles. No, if any
    /// round-trip has started or settled since the read began — the status in hand predates it,
    /// and publishing it would walk the toggle backwards. Once the in-flight call has gone stale
    /// it owns nothing, so a read is allowed through: with the call wedged, an activation read is
    /// the only thing left that can put the toggle back in step with the service.
    func mayPublishStatus(readAt epoch: StatusReadEpoch, at now: Date) -> Bool {
        epoch == self.epoch && !hasLiveRoundTrip(at: now)
    }

    /// Whether a round-trip is in flight AND still within its claim window.
    private func hasLiveRoundTrip(at now: Date) -> Bool {
        guard let inFlight else { return false }
        return now.timeIntervalSince(inFlight.startedAt) < Self.roundTripGoesStaleAfter
    }

    /// A programmatic write put the toggle at `value` — mark it so its `onChange` is swallowed.
    mutating func markApplied(_ value: Bool) {
        lastApplied = value
    }

    /// A round-trip is starting. Must be called synchronously with the decision to start one —
    /// if it waited for the call's `Task` to be scheduled, two gestures could both pass
    /// `shouldStartRoundTrip` before either marked itself in flight.
    ///
    /// Returns the token that names it; hand it back to `settle` so a superseded call cannot
    /// clear its successor's claim.
    mutating func beginRoundTrip(at now: Date) -> RoundTripToken {
        roundTripEvents += 1
        let token = RoundTripToken(value: roundTripEvents)
        inFlight = RoundTrip(token: token, startedAt: now)
        return token
    }

    /// A round-trip that tried to apply `enabled` has returned; `toggle` is where the switch
    /// sits now, and `succeeded` says whether the service took the value.
    ///
    /// **The marker moves to `enabled` first, on BOTH paths.** With it left stale — which is
    /// what the failure path did before this type existed — the next echo reads as a gesture.
    ///
    /// **A superseded call settles into nothing.** Once a round-trip has gone stale a later
    /// gesture can start its own, and the wedged one may still return afterwards. Letting that
    /// late settle run would clear the live call's claim, move the marker to a value nobody is
    /// pushing any more, and drive the service from a decision made against a toggle position two
    /// gestures old. It owns nothing, so it does nothing.
    mutating func settle(
        token: RoundTripToken,
        applied enabled: Bool,
        toggle: Bool,
        succeeded: Bool
    ) -> LoginItemFollowUp {
        guard inFlight?.token == token else { return .settled }
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

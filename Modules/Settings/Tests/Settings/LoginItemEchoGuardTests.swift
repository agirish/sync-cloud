import Testing
import Foundation
@testable import Settings

/// Pins `LoginItemEchoGuard` — the launch-at-login toggle's echo/reconcile state machine.
///
/// This code was untestable until it was extracted: it lived inside a `View` method wrapped
/// around an `SMAppService` XPC round-trip, so the only way to exercise the failure path was to
/// make registration fail on a real Mac. Reverting the whole failure-path hunk left the suite
/// 113/113 green, which is how a double-fire shipped in it.
@Suite struct LoginItemEchoGuardTests {

    /// A pinned instant for the direct-guard tests. The guard's decisions are now dated (a
    /// round-trip's claim expires — see `roundTripGoesStaleAfter`), and a test that read the real
    /// clock would be judging itself against wall time it does not control.
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    // MARK: - The echo guard

    @Test func theFirstMoveOfTheSwitchIsAlwaysAGesture() {
        // `lastApplied` starts nil: the status read that seeds it is deferred out of view init
        // (the getter is a synchronous XPC call), so the user can reach the switch first.
        let guardState = LoginItemEchoGuard()

        #expect(guardState.shouldStartRoundTrip(for: true, at: t0))
        #expect(guardState.shouldStartRoundTrip(for: false, at: t0))
    }

    @Test func aProgrammaticSetIsSwallowed() {
        var guardState = LoginItemEchoGuard()
        guardState.markApplied(true)

        #expect(!guardState.shouldStartRoundTrip(for: true, at: t0), "the initial read's own write must not register as a flip")
        #expect(guardState.shouldStartRoundTrip(for: false, at: t0), "but moving away from it is a real gesture")
    }

    // MARK: - Settling a finished round-trip

    @Test func aSuccessWithAStillSwitchIsDone() {
        var guardState = LoginItemEchoGuard()

        let token = guardState.beginRoundTrip(at: t0)

        #expect(guardState.settle(token: token, applied: true, toggle: true, succeeded: true)
                == .settled)
    }

    @Test func aFailureWithAStillSwitchAdoptsTheServiceState() {
        // Nothing was overwritten, so the UI must stop claiming a state the system rejected.
        var guardState = LoginItemEchoGuard()

        let token = guardState.beginRoundTrip(at: t0)

        #expect(guardState.settle(token: token, applied: true, toggle: true, succeeded: false)
                == .adoptServiceState)
    }

    @Test func aSuccessReappliesAMidFlightFlip() {
        // The flip's own onChange was suppressed while the call was in flight, so this follow-up
        // is the only thing left to act on it.
        var guardState = LoginItemEchoGuard()

        let token = guardState.beginRoundTrip(at: t0)

        #expect(guardState.settle(token: token, applied: true, toggle: false, succeeded: true)
                == .reapply(false, refreshApprovalHint: false))
    }

    @Test func aFailureReappliesAMidFlightFlipAndRefreshesTheHint() {
        // The failure path has a freshly re-read status in hand; the approval hint can be
        // published from it without overwriting the toggle the user just moved.
        var guardState = LoginItemEchoGuard()

        let token = guardState.beginRoundTrip(at: t0)

        #expect(guardState.settle(token: token, applied: true, toggle: false, succeeded: false)
                == .reapply(false, refreshApprovalHint: true))
    }

    /// Both paths mark the value applied — the property the failure path was missing.
    @Test(arguments: [true, false])
    func settlingMarksTheValueApplied(_ succeeded: Bool) {
        var guardState = LoginItemEchoGuard()
        let token = guardState.beginRoundTrip(at: t0)
        _ = guardState.settle(token: token, applied: true, toggle: true, succeeded: succeeded)

        #expect(!guardState.shouldStartRoundTrip(for: true, at: t0),
                "settle must record what it pushed, or the next echo reads as a gesture")
        #expect(guardState.shouldStartRoundTrip(for: false, at: t0))
    }

    // MARK: - The whole loop, with the service modelled

    /// A driver for the whole loop — `Toggle`'s `onChange`, the round-trip, `settle`, `perform`,
    /// and the activation status read — with the login item itself modelled, so a trace can be
    /// judged on what the USER ends up with rather than only on the guard's return values.
    ///
    /// It holds **any number of calls in flight at once** and lets the test complete them in
    /// whatever order and with whatever outcome it chooses. That is the point of the rebuild:
    /// the driver this replaces had a single `inFlight: Bool?` slot, so two concurrent
    /// round-trips — the defect — were literally unrepresentable and the harness could not fail
    /// on them.
    private final class Driver {
        /// A started round-trip. `value` is what it is pushing at the service.
        struct Call: Equatable {
            let id: Int
            let value: Bool
        }

        var guardState = LoginItemEchoGuard()
        /// The clock the guard is judged against. Pinned rather than real: the staleness window
        /// is 15s, and a test that waited it out in real time would be 15s of dead suite.
        var now = Date(timeIntervalSince1970: 1_000_000)
        /// Token of each started call, by id, so a completion settles as ITS OWN round-trip.
        private var tokens: [Int: LoginItemEchoGuard.RoundTripToken] = [:]
        /// Where the switch sits — the view's `launchAtLogin`.
        var toggle: Bool
        /// Whether the modelled login item is registered right now.
        private(set) var serviceRegistered: Bool
        /// Every round-trip ever started, in order.
        private(set) var calls: [Call] = []
        /// Every value the service actually TOOK, in order: one entry per successful
        /// register/unregister. This is the user-visible side effect.
        private(set) var serviceHistory: [Bool] = []
        /// Calls started but not yet completed.
        private(set) var inFlight: [Call] = []
        /// The high-water mark of `inFlight.count` — the invariant under test.
        private(set) var peakConcurrency = 0

        init(startingRegistered: Bool) {
            serviceRegistered = startingRegistered
            toggle = startingRegistered
            guardState.markApplied(startingRegistered)
        }

        /// The user flips the switch — the `Toggle`'s `onChange` handler.
        func flip(to value: Bool) {
            toggle = value
            guard guardState.shouldStartRoundTrip(for: value, at: now) else { return }
            start(value)
        }

        /// `updateLoginItem` — begin a round-trip.
        private func start(_ value: Bool) {
            let call = Call(id: calls.count, value: value)
            tokens[call.id] = guardState.beginRoundTrip(at: now)
            calls.append(call)
            inFlight.append(call)
            peakConcurrency = max(peakConcurrency, inFlight.count)
        }

        /// A specific in-flight call returns — `updateLoginItem`'s do/catch plus `perform`.
        /// The test picks both the call and its outcome, so completion ORDER is a test variable.
        func complete(_ id: Int, succeeded: Bool) {
            guard let index = inFlight.firstIndex(where: { $0.id == id }) else {
                Issue.record("no call \(id) in flight")
                return
            }
            let call = inFlight.remove(at: index)
            if succeeded {
                serviceRegistered = call.value
                serviceHistory.append(call.value)
            }
            // The failure path re-reads the service before it settles; the success path has no
            // status in hand (it publishes the approval flag the round-trip returned instead).
            let status: Bool? = succeeded ? nil : serviceRegistered
            let token = tokens[call.id] ?? guardState.beginRoundTrip(at: now)
            switch guardState.settle(
                token: token, applied: call.value, toggle: toggle, succeeded: succeeded) {
            case .settled:
                break
            case .adoptServiceState:
                if let status { adopt(status) }
            case .reapply(let value, _):
                start(value)
            }
        }

        /// The user changed the login item over in System Settings → Login Items, where this
        /// app is not watching. Only an activation read can discover it.
        func serviceChangedExternally(to registered: Bool) {
            serviceRegistered = registered
        }

        /// `applyLoginItemState` — publish a service status into the toggle.
        private func adopt(_ registered: Bool) {
            toggle = registered
            guardState.markApplied(registered)
        }

        /// `readLoginItemState`'s task begins — the app was activated, or `.task` ran. Returns
        /// the status the detached getter saw, dated by the epoch captured alongside it.
        /// Split from the landing so a test can slide a whole round-trip in between.
        func beginActivationRead() -> (status: Bool, epoch: LoginItemEchoGuard.StatusReadEpoch) {
            (serviceRegistered, guardState.epoch)
        }

        /// That read returns and publishes — if the guard still lets it.
        func landActivationRead(_ read: (status: Bool, epoch: LoginItemEchoGuard.StatusReadEpoch)) {
            guard guardState.mayPublishStatus(readAt: read.epoch, at: now) else { return }
            adopt(read.status)
        }

        /// The common case: the read begins and lands with nothing in between.
        func activate() {
            landActivationRead(beginActivationRead())
        }
    }

    // MARK: - A wedged round-trip must not latch the guard shut forever

    /// The guard's claim is bounded, so an `smd` that never answers cannot kill the toggle.
    ///
    /// `settle` is the only thing that clears the claim, and the call site reaches it only after
    /// its XPC `await` returns. A wedged `smd` therefore used to leave the guard shut for the life
    /// of the view: every later flip swallowed (the switch MOVES and nothing happens), every
    /// activation read dropped so the toggle could not self-correct either. That is worse than the
    /// double-fire this type exists to fix — that one at least left a way out.
    @MainActor
    @Test func aWedgedRoundTripStopsBlockingOnceItsClaimGoesStale() {
        let driver = Driver(startingRegistered: false)

        driver.flip(to: true)                     // call 0 — wedges, never completes
        #expect(driver.calls.count == 1)

        // Inside the window the claim is live, so the ON -> OFF -> ON trace must still not double
        // up. (The OFF is swallowed as an echo: it puts the toggle back where the service already
        // is. The second ON differs from the marker, so the CLAIM is what refuses it.)
        driver.now += LoginItemEchoGuard.roundTripGoesStaleAfter / 2
        driver.flip(to: false)
        driver.flip(to: true)
        #expect(driver.calls.count == 1, "a live round-trip still carries mid-flight gestures")

        // Past the window the wedged call has lost its claim, so the user gets a response.
        driver.now += LoginItemEchoGuard.roundTripGoesStaleAfter
        driver.flip(to: false)
        driver.flip(to: true)
        #expect(driver.calls.count == 2, "a stale round-trip must not swallow later gestures")

        driver.complete(1, succeeded: true)
        #expect(driver.serviceHistory == [true], "the user's position reached the service")
        #expect(driver.toggle == driver.serviceRegistered)
    }

    /// An activation read is the only thing that can re-sync the toggle while a call is wedged,
    /// so it is allowed through once the claim goes stale — and refused while it is still live.
    @MainActor
    @Test func anActivationReadIsAllowedThroughOnceTheClaimGoesStale() {
        let driver = Driver(startingRegistered: false)
        driver.flip(to: true)                     // call 0 — wedges
        driver.serviceChangedExternally(to: false)

        driver.activate()
        #expect(driver.toggle, "a LIVE round-trip still owns the toggle")

        driver.now += LoginItemEchoGuard.roundTripGoesStaleAfter
        driver.activate()
        #expect(!driver.toggle, "a stale claim must not keep the toggle out of step forever")
    }

    /// The superseded call settles into nothing. Once the wedged call has lost its claim and a
    /// later gesture has started its own round-trip, the wedged one may still return — and must
    /// not clear the live call's claim, move the marker, or drive the service from a decision
    /// made against a toggle position two gestures old.
    @MainActor
    @Test func aSupersededRoundTripSettlesIntoNothing() {
        let driver = Driver(startingRegistered: false)
        driver.flip(to: true)                     // call 0 — wedges
        driver.now += LoginItemEchoGuard.roundTripGoesStaleAfter
        driver.flip(to: false)
        driver.flip(to: true)                     // call 1 — supersedes it
        #expect(driver.calls.count == 2)

        driver.complete(0, succeeded: true)       // the wedged one finally returns

        #expect(driver.calls.count == 2, "a superseded settle must not start a follow-up")
        // Call 1 must still own the claim: a fresh gesture is still carried by it, not doubled.
        driver.flip(to: false)
        driver.flip(to: true)
        #expect(driver.calls.count == 2, "the superseded settle must not free call 1's claim")

        driver.complete(1, succeeded: true)
        #expect(driver.toggle == driver.serviceRegistered)
    }

    // MARK: - The defect: on -> off -> on starts a SECOND concurrent round-trip

    /// The review's trace. Flipping ON, OFF, ON while the first call is still in flight: the
    /// OFF is suppressed because it matches the stale marker, but the second ON does NOT match
    /// it, so `onChange` starts a round-trip on top of the one already running.
    ///
    /// One call in flight is what every reconciliation decision downstream assumes.
    @Test func theOnOffOnTraceStartsAtMostOneRoundTrip() {
        let driver = Driver(startingRegistered: false)

        driver.flip(to: true)   // user turns it on; call 1 is in flight
        driver.flip(to: false)  // ...changes their mind...
        driver.flip(to: true)   // ...and changes it back, all before call 1 returns

        #expect(driver.peakConcurrency == 1,
                "a second round-trip must not start while one is in flight")
        #expect(driver.calls.map(\.value) == [true],
                "the mid-flight flips are reconciled when call 1 settles, not sent on their own")
    }

    /// The harmful composition: call 1 FAILS and call 2 SUCCEEDS, call 1 settling first.
    ///
    /// Call 1's catch re-reads the service — which is still off, because only call 2 registered
    /// it — and adopts that, snapping the toggle OFF. Call 2 then settles against a toggle that
    /// has "moved", so it reapplies `false` and UNREGISTERS the login item its own round-trip
    /// had just successfully registered. The user asked to launch at login; nothing tells them
    /// otherwise; and the item is gone.
    @Test func aFailedCallNeverUndoesARegistrationThatSucceeded() {
        let driver = Driver(startingRegistered: false)

        driver.flip(to: true)
        driver.flip(to: false)
        driver.flip(to: true)

        // Complete every call this trace chose to start, oldest first — the ordering that
        // lets a stale re-read overwrite a fresh success. Only the first one fails.
        var completed = 0
        while let call = driver.inFlight.first {
            driver.complete(call.id, succeeded: completed > 0)
            completed += 1
        }

        #expect(driver.calls.map(\.value) == [true],
                "the only thing the user asked the service for was ON")
        #expect(!driver.serviceHistory.contains(false),
                "the service must never be driven OFF: the user never asked for that")
        #expect(driver.toggle == driver.serviceRegistered,
                "the toggle must agree with the service it ends up with")
    }

    /// The same trace when the round-trip SUCCEEDS: the user's flip must survive intact — one
    /// call, item registered, switch on.
    @Test func theOnOffOnTraceEndsRegisteredWhenTheRoundTripSucceeds() {
        let driver = Driver(startingRegistered: false)

        driver.flip(to: true)
        driver.flip(to: false)
        driver.flip(to: true)

        var completed = 0
        while let call = driver.inFlight.first {
            driver.complete(call.id, succeeded: true)
            completed += 1
        }

        #expect(completed == 1, "one gesture's worth of round-trips, not two")
        #expect(driver.serviceRegistered, "the user's last gesture was ON")
        #expect(driver.toggle, "and the switch must show it")
        #expect(driver.serviceHistory == [true], "registered once, never churned")
    }

    // MARK: - A background status read must not overwrite a gesture in flight

    /// The user flips ON, then cmd-tabs away and back while the round-trip is still running.
    /// `didBecomeActive` re-reads the service — which has not been registered YET — and
    /// publishes it, snapping the toggle back OFF. The round-trip then succeeds, sees a toggle
    /// that "moved", and unregisters the registration that had just succeeded.
    @Test func anActivationReadDuringAnInFlightGestureCannotUndoIt() {
        let driver = Driver(startingRegistered: false)

        driver.flip(to: true)
        driver.activate()               // cmd-tab away and back, mid-flight
        driver.complete(0, succeeded: true)

        #expect(driver.serviceRegistered, "the registration succeeded; nothing may undo it")
        #expect(driver.toggle, "and the switch must still show the user's flip")
        #expect(driver.calls.map(\.value) == [true], "no compensating round-trip")
    }

    /// The narrower window: the read begins while the guard is idle, but a whole gesture
    /// completes before its detached status getter returns. The status in hand is now stale and
    /// publishing it walks the toggle backwards.
    @Test func anActivationReadOvertakenByAGestureIsDiscarded() {
        let driver = Driver(startingRegistered: false)

        let stale = driver.beginActivationRead()    // reads "not registered"
        driver.flip(to: true)
        driver.complete(0, succeeded: true)         // ...and the gesture lands first
        driver.landActivationRead(stale)

        #expect(driver.serviceRegistered)
        #expect(driver.toggle, "a status read older than the gesture must not walk the switch back")
    }

    /// The read is how the toggle gets seeded and how an approval granted over in System
    /// Settings reaches the UI, so an idle read must still publish.
    @Test func anActivationReadWhileIdleStillPublishes() {
        let driver = Driver(startingRegistered: false)

        // Go through a whole round-trip first, so "idle" means the guard RELEASED the toggle
        // rather than never having held it.
        driver.flip(to: true)
        driver.complete(0, succeeded: true)
        #expect(driver.inFlight.isEmpty)

        // The user then removed SyncCloud over in Login Items settings, where the app is not
        // watching. The toggle still says on; only this read can correct it.
        driver.serviceChangedExternally(to: false)
        driver.activate()

        #expect(!driver.toggle, "an idle read is how that discovery reaches the switch")
        #expect(!driver.guardState.shouldStartRoundTrip(for: false, at: t0), "the read's own write is an echo, not a flip")
    }

    // MARK: - One gesture, one round-trip

    /// A mid-flight flip is carried by `settle`, not by a second concurrent call, and it costs
    /// exactly one extra round-trip however the first one ends.
    @Test(arguments: [true, false])
    func aMidFlightFlipCostsExactlyOneExtraRoundTrip(_ succeeded: Bool) {
        let driver = Driver(startingRegistered: false)

        driver.flip(to: true)
        driver.flip(to: false)          // suppressed; carried by settle instead
        #expect(driver.peakConcurrency == 1)
        driver.complete(0, succeeded: succeeded)

        #expect(driver.calls.map(\.value) == [true, false])
        #expect(driver.peakConcurrency == 1)
    }

    /// Repeated failures must not fan out: each settle starts at most one follow-up.
    @Test func repeatedFailuresNeverFanOutIntoConcurrentRoundTrips() {
        let driver = Driver(startingRegistered: false)

        driver.flip(to: true)
        driver.flip(to: false)
        driver.complete(0, succeeded: false)
        #expect(driver.calls.map(\.value) == [true, false], "the suppressed flip is re-applied, once")

        driver.flip(to: true)
        driver.complete(1, succeeded: false)

        #expect(driver.calls.map(\.value) == [true, false, true],
                "one gesture per round-trip; a second failure must not fan out")
        #expect(driver.peakConcurrency == 1)
    }

    /// Serialising the calls means holding an in-flight flag, and a flag that is set and never
    /// cleared silently swallows everything that follows. Once a round-trip has settled the
    /// guard must be IDLE again, so the user's next flip — minutes later, the ordinary case —
    /// still reaches the service.
    @Test func aFlipAfterAPreviousRoundTripSettledStartsANewOne() {
        let driver = Driver(startingRegistered: false)

        driver.flip(to: true)
        driver.complete(0, succeeded: true)

        driver.flip(to: false)              // much later; nothing is in flight
        #expect(driver.calls.map(\.value) == [true, false],
                "the in-flight flag must not outlive the round-trip that set it")
        driver.complete(1, succeeded: true)

        #expect(!driver.serviceRegistered)
        #expect(!driver.toggle)
        #expect(driver.peakConcurrency == 1)
    }

    /// A settled toggle stops the loop rather than ping-ponging: the common case is one flip,
    /// one round-trip, done.
    @Test func anUndisturbedFlipIsASingleRoundTrip() {
        let driver = Driver(startingRegistered: false)

        driver.flip(to: true)
        driver.complete(0, succeeded: true)

        #expect(driver.calls.map(\.value) == [true])
        #expect(driver.peakConcurrency == 1)
        #expect(!driver.guardState.shouldStartRoundTrip(for: true, at: t0))
    }
}

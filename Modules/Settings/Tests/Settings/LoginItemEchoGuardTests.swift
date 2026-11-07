import Testing
import Foundation
@testable import Settings

/// Pins `LoginItemEchoGuard`, the launch-at-login toggle's echo/reconcile state machine, kept out
/// of the view so its failure path can be tested without making registration fail on a real Mac.
@Suite struct LoginItemEchoGuardTests {

    /// A pinned instant for the direct-guard tests. The guard's decisions are dated (a claim
    /// expires after `roundTripGoesStaleAfter`), so reading the clock per decision would judge the
    /// test by time it doesn't control. Sampled once from the guard's monotonic clock.
    private let t0 = ContinuousClock.now

    // MARK: - The echo guard

    @Test func theFirstMoveOfTheSwitchIsAlwaysAGesture() {
        // `lastApplied` starts nil: the seeding status read is deferred out of view init (the
        // getter is a synchronous XPC call), so the user can reach the switch first.
        let guardState = LoginItemEchoGuard()

        #expect(guardState.shouldStartRoundTrip(for: true, at: t0))
        #expect(guardState.shouldStartRoundTrip(for: false, at: t0))
    }

    @Test func aProgrammaticSetIsSwallowed() {
        var guardState = LoginItemEchoGuard()
        guardState.adoptedStatus(true)

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

    /// Both paths mark the value applied, so the next echo isn't read as a gesture.
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

    /// A driver for the whole loop (`Toggle`'s `onChange`, the round-trip, `settle`, `perform`
    /// and the activation status read) with the login item modelled, so a trace is judged on what
    /// the user ends up with, not only on the guard's return values.
    ///
    /// It holds any number of calls in flight and lets the test complete them in any order with
    /// any outcome, so two concurrent round-trips are representable and can fail a test.
    private final class Driver {
        /// A started round-trip. `value` is what it is pushing at the service.
        struct Call: Equatable {
            let id: Int
            let value: Bool
        }

        var guardState = LoginItemEchoGuard()
        /// The clock the guard is judged against, advanced by hand so no test waits out the
        /// staleness window in real time.
        var now = ContinuousClock.now
        /// Token of each started call, by id, so a completion settles as its own round-trip.
        private var tokens: [Int: LoginItemEchoGuard.RoundTripToken] = [:]
        /// Where the switch sits: the view's `launchAtLogin`.
        var toggle: Bool
        /// The view's `loginItemNeedsApproval`, the footer hint. The settle call site writes it
        /// from a flag sampled off-main, so a settle that owns nothing must not write it.
        private(set) var needsApproval = false
        /// Whether the modelled login item is registered right now.
        private(set) var serviceRegistered: Bool
        /// Every round-trip ever started, in order.
        private(set) var calls: [Call] = []
        /// Every value the service actually took, in order: one entry per successful
        /// register/unregister. This is the user-visible side effect.
        private(set) var serviceHistory: [Bool] = []
        /// Calls started but not yet completed.
        private(set) var inFlight: [Call] = []
        /// The high-water mark of `inFlight.count`: the invariant under test.
        private(set) var peakConcurrency = 0

        init(startingRegistered: Bool) {
            serviceRegistered = startingRegistered
            toggle = startingRegistered
            guardState.adoptedStatus(startingRegistered)
        }

        /// The user flips the switch: the `Toggle`'s `onChange` handler.
        func flip(to value: Bool) {
            toggle = value
            guard guardState.shouldStartRoundTrip(for: value, at: now) else { return }
            start(value)
        }

        /// `updateLoginItem`: begin a round-trip.
        private func start(_ value: Bool) {
            let call = Call(id: calls.count, value: value)
            tokens[call.id] = guardState.beginRoundTrip(at: now)
            calls.append(call)
            inFlight.append(call)
            peakConcurrency = max(peakConcurrency, inFlight.count)
        }

        /// A specific in-flight call returns: `updateLoginItem`'s do/catch plus `perform`. The
        /// test picks the call and its outcome, so completion order is a test variable.
        /// `reportsNeedsApproval` is the flag a successful round-trip sampled off-main.
        func complete(_ id: Int, succeeded: Bool, reportsNeedsApproval: Bool = false) {
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
            guard let token = tokens[call.id] else {
                // `start` records a token for every call, so this is a harness bug. Minting one
                // here would mutate the guard (a fresh claim `settle` then matches) and turn the
                // bug into a green run.
                Issue.record("harness: no token recorded for call \(call.id)")
                return
            }
            // nil is the superseded settle: it owns nothing, so the call site publishes nothing.
            guard let followUp = guardState.settle(
                token: token, applied: call.value, toggle: toggle, succeeded: succeeded) else { return }
            if succeeded { needsApproval = reportsNeedsApproval }
            switch followUp {
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

        /// `applyLoginItemState`: publish a service status into the toggle.
        private func adopt(_ registered: Bool) {
            toggle = registered
            guardState.adoptedStatus(registered)
        }

        /// `readLoginItemState`'s task begins (the app was activated, or `.task` ran). Returns the
        /// status the detached getter saw, dated by the epoch captured with it. Split from the
        /// landing so a test can slide a whole round-trip in between.
        func beginActivationRead() -> (status: Bool, epoch: LoginItemEchoGuard.StatusReadEpoch) {
            (serviceRegistered, guardState.epoch)
        }

        /// That read returns and publishes, if the guard still lets it.
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

    /// The guard's claim is bounded, so an `smd` that never answers can't kill the toggle.
    ///
    /// Only `settle` clears the claim, and the call site reaches it only after its XPC `await`
    /// returns. Unbounded, a wedged `smd` would shut the guard for the life of the view: every
    /// flip swallowed (the switch moves and nothing happens) and every activation read dropped.
    @MainActor
    @Test func aWedgedRoundTripStopsBlockingOnceItsClaimGoesStale() {
        let driver = Driver(startingRegistered: false)

        driver.flip(to: true)                     // call 0 — wedges, never completes
        #expect(driver.calls.count == 1)

        // Inside the window the claim is live, so ON -> OFF -> ON must not double up. (The OFF is
        // swallowed as an echo of the service's state; the second ON differs from the marker, so
        // the claim is what refuses it.)
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

    /// Only an activation read can re-sync the toggle while a call is wedged, so it is let
    /// through once the claim goes stale, and refused while it is live.
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

    /// The other end of that allowance: once a read has published, the expired round-trip no
    /// longer speaks for the toggle, so its late settle must not drive the service.
    ///
    /// Expiry must be symmetric. If the read publishes but the round-trip isn't superseded, its
    /// settle still matches by token, sees the moved toggle as a mid-flight flip, and reapplies
    /// it: `smd` wedges, the user cmd-tabs back past the window, the read snaps the switch off,
    /// the register succeeds, and the settle unregisters the item it just registered.
    @MainActor
    @Test func aReadPublishedPastTheClaimWindowSupersedesTheWedgedRoundTrip() {
        let driver = Driver(startingRegistered: false)

        driver.flip(to: true)                     // call 0 — wedges inside register()
        driver.now += LoginItemEchoGuard.roundTripGoesStaleAfter
        driver.activate()                         // cmd-tab back; the read publishes "not registered"
        #expect(!driver.toggle, "the stale claim let the read through — that part is intended")

        driver.complete(0, succeeded: true)       // the wedged register finally lands, successfully

        #expect(driver.calls.map(\.value) == [true],
                "the read superseded the expired round-trip; its settle owns nothing to reapply")
        // Drain anything the settle did start, so the service sees whatever it asked for.
        while let call = driver.inFlight.first { driver.complete(call.id, succeeded: true) }
        #expect(!driver.serviceHistory.contains(false),
                "the service must never be driven OFF: the user only ever asked for ON")
        #expect(driver.serviceRegistered, "the registration succeeded; nothing may undo it")
    }

    /// A read that began before another read published is out of date, as one that began before a
    /// round-trip is: publishing it walks the toggle back. Adopting a status dates every read
    /// still in the air.
    @MainActor
    @Test func aReadOvertakenByAFresherReadIsDiscarded() {
        let driver = Driver(startingRegistered: false)

        let stale = driver.beginActivationRead()    // reads "not registered"
        driver.serviceChangedExternally(to: true)   // approved over in Login Items settings
        driver.activate()                           // the fresher read publishes that
        #expect(driver.toggle)

        driver.landActivationRead(stale)

        #expect(driver.toggle, "a read older than the one that published must not undo it")
    }

    /// A superseded call settles into nothing. When the wedged call returns after a later gesture
    /// started its own round-trip, it must not clear the live call's claim, move the marker, or
    /// drive the service from a toggle position two gestures old.
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

    /// "Superseded" and "settled" are opposite instructions, so they can't share a return value.
    /// `.settled` cues the call site to publish the round-trip's approval flag; a superseded call
    /// (nil) must publish nothing.
    @Test func aSupersededSettleIsDistinguishableFromASettledOne() {
        var guardState = LoginItemEchoGuard()
        let first = guardState.beginRoundTrip(at: t0)
        let second = guardState.beginRoundTrip(at: t0)

        #expect(guardState.settle(token: first, applied: true, toggle: true, succeeded: true) == nil,
                "the superseded call owns nothing, and nil is how the call site can tell")
        #expect(guardState.settle(token: second, applied: true, toggle: true, succeeded: true)
                == .settled)
    }

    /// The other direction, so the test below can't pass by never publishing the hint: a settle
    /// that owns the toggle is how a pending approval reaches the footer.
    @MainActor
    @Test func aSettledRoundTripPublishesTheApprovalItSampled() {
        let driver = Driver(startingRegistered: false)

        driver.flip(to: true)
        driver.complete(0, succeeded: true, reportsNeedsApproval: true)

        #expect(driver.needsApproval, "the round-trip's own flag is what raises the hint")
    }

    /// A superseded call must not write the approval hint either: the flag was sampled off-main
    /// and lands an actor hop later, so it would clobber the fresher read that superseded it.
    @MainActor
    @Test func aSupersededSettleDoesNotPublishTheApprovalHint() {
        let driver = Driver(startingRegistered: false)

        driver.flip(to: true)                     // call 0 — wedges
        driver.now += LoginItemEchoGuard.roundTripGoesStaleAfter
        driver.activate()                         // a fresher read takes the toggle: not registered
        #expect(!driver.needsApproval)

        driver.complete(0, succeeded: true, reportsNeedsApproval: true)

        #expect(!driver.needsApproval,
                "a settle that owns nothing must not publish a hint the fresher read contradicts")
    }

    // MARK: - The defect: on -> off -> on starts a SECOND concurrent round-trip

    /// ON, OFF, ON while the first call is in flight. The OFF matches the stale marker and is
    /// suppressed; the second ON doesn't, so without the claim `onChange` would start a second
    /// round-trip. Every reconciliation decision downstream assumes one call in flight.
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

    /// The harmful composition: a first call fails and a second succeeds, the first settling
    /// first. Its catch would re-read "off" and snap the toggle off; the second would then see a
    /// moved toggle and unregister the item it just registered, silently.
    @Test func aFailedCallNeverUndoesARegistrationThatSucceeded() {
        let driver = Driver(startingRegistered: false)

        driver.flip(to: true)
        driver.flip(to: false)
        driver.flip(to: true)

        // Complete every call started, oldest first, the order that lets a stale re-read
        // overwrite a fresh success. Only the first one fails.
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

    /// The same trace when the round-trip succeeds: one call, item registered, switch on.
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

    /// The user flips ON, then cmd-tabs away and back mid-round-trip. Published, the
    /// `didBecomeActive` re-read (not registered yet) would snap the toggle off, and the
    /// succeeding round-trip would then see a moved toggle and unregister.
    @Test func anActivationReadDuringAnInFlightGestureCannotUndoIt() {
        let driver = Driver(startingRegistered: false)

        driver.flip(to: true)
        driver.activate()               // cmd-tab away and back, mid-flight
        driver.complete(0, succeeded: true)

        #expect(driver.serviceRegistered, "the registration succeeded; nothing may undo it")
        #expect(driver.toggle, "and the switch must still show the user's flip")
        #expect(driver.calls.map(\.value) == [true], "no compensating round-trip")
    }

    /// The narrower window: the read begins while idle, but a whole gesture completes before its
    /// detached getter returns, so its status is stale and must not walk the toggle back.
    @Test func anActivationReadOvertakenByAGestureIsDiscarded() {
        let driver = Driver(startingRegistered: false)

        let stale = driver.beginActivationRead()    // reads "not registered"
        driver.flip(to: true)
        driver.complete(0, succeeded: true)         // ...and the gesture lands first
        driver.landActivationRead(stale)

        #expect(driver.serviceRegistered)
        #expect(driver.toggle, "a status read older than the gesture must not walk the switch back")
    }

    /// The read seeds the toggle and brings in an approval granted in System Settings, so an idle
    /// read must still publish.
    @Test func anActivationReadWhileIdleStillPublishes() {
        let driver = Driver(startingRegistered: false)

        // A whole round-trip first, so "idle" means the guard released the toggle, not that it
        // never held it.
        driver.flip(to: true)
        driver.complete(0, succeeded: true)
        #expect(driver.inFlight.isEmpty)

        // The user then removes SyncCloud in Login Items settings, which the app doesn't watch.
        // The toggle still says on; only this read can correct it.
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

    /// Serialising the calls means an in-flight flag, and one never cleared swallows everything
    /// after. Once a round-trip settles the guard must be idle, so the next flip reaches the
    /// service.
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
}

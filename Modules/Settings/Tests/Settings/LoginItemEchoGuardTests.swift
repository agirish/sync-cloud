import Testing
@testable import Settings

/// Pins `LoginItemEchoGuard` — the launch-at-login toggle's echo/reconcile state machine.
///
/// This code was untestable until it was extracted: it lived inside a `View` method wrapped
/// around an `SMAppService` XPC round-trip, so the only way to exercise the failure path was to
/// make registration fail on a real Mac. Reverting the whole failure-path hunk left the suite
/// 113/113 green, which is how a double-fire shipped in it.
@Suite struct LoginItemEchoGuardTests {

    // MARK: - The echo guard

    @Test func theFirstMoveOfTheSwitchIsAlwaysAGesture() {
        // `lastApplied` starts nil: the status read that seeds it is deferred out of view init
        // (the getter is a synchronous XPC call), so the user can reach the switch first.
        let guardState = LoginItemEchoGuard()

        #expect(guardState.isGesture(true))
        #expect(guardState.isGesture(false))
    }

    @Test func aProgrammaticSetIsSwallowed() {
        var guardState = LoginItemEchoGuard()
        guardState.markApplied(true)

        #expect(!guardState.isGesture(true), "the initial read's own write must not register as a flip")
        #expect(guardState.isGesture(false), "but moving away from it is a real gesture")
    }

    // MARK: - Settling a finished round-trip

    @Test func aSuccessWithAStillSwitchIsDone() {
        var guardState = LoginItemEchoGuard()

        #expect(guardState.settle(applied: true, toggle: true, succeeded: true) == .settled)
    }

    @Test func aFailureWithAStillSwitchAdoptsTheServiceState() {
        // Nothing was overwritten, so the UI must stop claiming a state the system rejected.
        var guardState = LoginItemEchoGuard()

        #expect(guardState.settle(applied: true, toggle: true, succeeded: false)
                == .adoptServiceState)
    }

    @Test func aSuccessReappliesAMidFlightFlip() {
        // The flip's own onChange compared against the stale marker and was suppressed, so this
        // follow-up is the only thing left to act on it.
        var guardState = LoginItemEchoGuard()

        #expect(guardState.settle(applied: true, toggle: false, succeeded: true)
                == .reapply(false, refreshApprovalHint: false))
    }

    @Test func aFailureReappliesAMidFlightFlipAndRefreshesTheHint() {
        // The failure path has a freshly re-read status in hand; the approval hint can be
        // published from it without overwriting the toggle the user just moved.
        var guardState = LoginItemEchoGuard()

        #expect(guardState.settle(applied: true, toggle: false, succeeded: false)
                == .reapply(false, refreshApprovalHint: true))
    }

    /// Both paths mark the value applied — the property the failure path was missing.
    @Test(arguments: [true, false])
    func settlingMarksTheValueApplied(_ succeeded: Bool) {
        var guardState = LoginItemEchoGuard()
        _ = guardState.settle(applied: true, toggle: true, succeeded: succeeded)

        #expect(!guardState.isGesture(true),
                "settle must record what it pushed, or the next echo reads as a gesture")
        #expect(guardState.isGesture(false))
    }

    // MARK: - The defect: one gesture, two round-trips

    /// A driver for the whole loop, so a sequence of gestures and outcomes can be replayed and
    /// the ROUND-TRIPS COUNTED. Counting is the point: every individual decision above can be
    /// right while the composition still fires twice for one flip.
    private final class Driver {
        var guardState = LoginItemEchoGuard()
        var toggle = false
        /// Every value handed to the service, in order.
        var roundTrips: [Bool] = []
        /// The call currently in flight, if any.
        private var inFlight: Bool?

        init(startingApplied: Bool) {
            toggle = startingApplied
            guardState.markApplied(startingApplied)
        }

        /// The user flips the switch. Mirrors the `onChange` handler.
        func flip(to value: Bool) {
            toggle = value
            guard guardState.isGesture(value) else { return }
            start(value)
        }

        private func start(_ value: Bool) {
            roundTrips.append(value)
            inFlight = value
        }

        /// The in-flight call returns. Mirrors `updateLoginItem`'s do/catch plus `perform`.
        func finish(succeeded: Bool) {
            guard let applied = inFlight else { return }
            inFlight = nil
            switch guardState.settle(applied: applied, toggle: toggle, succeeded: succeeded) {
            case .settled:
                break
            case .adoptServiceState:
                // The service's real state wins; `applyLoginItemState` marks it applied.
                guardState.markApplied(toggle)
            case .reapply(let value, _):
                start(value)
            }
        }
    }

    /// The review's exact sequence. Before the fix this ended with TWO concurrent round-trips
    /// for one flip — the failure path never moved the marker, so the third gesture was not
    /// suppressed and both `onChange` and the follow-up started a call.
    @Test func repeatedFailuresNeverFanOutIntoConcurrentRoundTrips() {
        let driver = Driver(startingApplied: false)

        driver.flip(to: true)                  // user turns it on
        #expect(driver.roundTrips == [true])
        driver.toggle = false                  // mid-flight flip OFF...
        #expect(!driver.guardState.isGesture(false), "the mid-flight flip must be suppressed")
        driver.finish(succeeded: false)        // ...and the call fails
        #expect(driver.roundTrips == [true, false], "the suppressed flip is re-applied, once")

        driver.toggle = true                   // mid-flight flip back ON...
        #expect(!driver.guardState.isGesture(true),
                "the marker moved on the failure path, so this flip is suppressed too")
        driver.finish(succeeded: false)        // ...and that call fails as well

        #expect(driver.roundTrips == [true, false, true],
                "one gesture per round-trip; a second failure must not fan out")
    }

    /// The same shape on the success path, which always did move the marker — kept so the two
    /// paths are pinned to the same behaviour rather than only the repaired one being checked.
    @Test func aMidFlightFlipCostsExactlyOneExtraRoundTripOnSuccess() {
        let driver = Driver(startingApplied: false)

        driver.flip(to: true)
        driver.toggle = false
        driver.finish(succeeded: true)
        #expect(driver.roundTrips == [true, false])

        driver.toggle = true
        #expect(!driver.guardState.isGesture(true))
        driver.finish(succeeded: true)

        #expect(driver.roundTrips == [true, false, true])
    }

    /// A settled toggle stops the loop rather than ping-ponging: the common case is one flip,
    /// one round-trip, done.
    @Test func anUndisturbedFlipIsASingleRoundTrip() {
        let driver = Driver(startingApplied: false)

        driver.flip(to: true)
        driver.finish(succeeded: true)

        #expect(driver.roundTrips == [true])
        #expect(!driver.guardState.isGesture(true))
    }
}

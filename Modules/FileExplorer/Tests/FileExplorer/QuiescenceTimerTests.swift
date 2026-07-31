import Testing
import Foundation
@testable import FileExplorer

/// Pins `QuiescenceTimer`, which is what the two pane scroll watchdogs re-arm on every bounds
/// change — i.e. at frame cadence, per open column, for the whole length of a scroll.
///
/// It has to satisfy two claims at once, and only one of them is the optimization. It must arm far
/// fewer timers than it receives reports (that is why it exists), and it must still run the action
/// exactly `quiescence` after the LAST report — because running early is what the watchdogs'
/// cancel-and-reallocate design existed to prevent, and a correction that lands mid-gesture fights
/// the platform on the paths the platform handles.
///
/// Both the clock and the scheduler are injected, so nothing here waits on real time. A test that
/// slept through a 0.14s window to prove a timer coalesced would be racing that window, which is
/// the shape of flakiness this codebase has already paid for more than once.
@MainActor
@Suite struct QuiescenceTimerTests {

    /// A hand-cranked clock and run loop: `schedule` records the pending block and its delay rather
    /// than dispatching it, so a test decides when time passes and when the timer fires.
    private final class Harness {
        var now: TimeInterval = 1_000
        var scheduled: [(delay: TimeInterval, work: @MainActor () -> Void)] = []
        var armCount: Int { scheduled.count }

        /// Advances the clock and runs the block armed most recently, as the real scheduler would
        /// once its delay elapsed.
        @MainActor func fireNext(advancingBy elapsed: TimeInterval) {
            guard !scheduled.isEmpty else { return }
            let next = scheduled.removeFirst()
            now += elapsed
            next.work()
        }
    }

    private func make(quiescence: TimeInterval = 0.14) -> (QuiescenceTimer, Harness) {
        let harness = Harness()
        let timer = QuiescenceTimer(
            quiescence: quiescence,
            now: { harness.now },
            schedule: { delay, work in harness.scheduled.append((delay, work)) })
        return (timer, harness)
    }

    // MARK: The optimization

    /// The headline. A scroll delivers bounds changes at frame cadence; the old code allocated and
    /// scheduled a work item for every one of them.
    @Test("A burst of activity arms exactly one timer")
    func burstArmsOneTimer() {
        let (timer, harness) = make()
        var ran = 0
        for _ in 0..<240 {
            harness.now += 1.0 / 120.0   // two seconds of 120Hz reports
            timer.noteActivity { ran += 1 }
        }
        #expect(harness.armCount == 1)
        #expect(ran == 0)
    }

    /// The mutation check for the one above: a timer that armed per report would still pass
    /// "the action eventually runs", so the count is what makes that test mean anything.
    @Test("Reports arriving while a timer is in flight cost no new timer")
    func reportsDuringFlightDoNotArm() {
        let (timer, harness) = make()
        timer.noteActivity {}
        #expect(harness.armCount == 1)
        #expect(timer.isPending)

        timer.noteActivity {}
        timer.noteActivity {}
        #expect(harness.armCount == 1)
    }

    // MARK: The guarantee it must not trade away

    @Test("The action runs once the stream has genuinely gone quiet")
    func runsAfterQuiescence() {
        let (timer, harness) = make(quiescence: 0.14)
        var ran = 0
        timer.noteActivity { ran += 1 }
        harness.fireNext(advancingBy: 0.14)
        #expect(ran == 1)
        #expect(!timer.isPending)
    }

    /// The correctness half. The timer was armed at the first report, but activity continued after
    /// it — so when it fires the stream has NOT been idle long enough, and it must wait out the
    /// remainder rather than correcting mid-gesture.
    @Test("A timer that fires while activity is still recent re-arms instead of running early")
    func lateActivityDefersTheRun() {
        let (timer, harness) = make(quiescence: 0.14)
        var ran = 0
        timer.noteActivity { ran += 1 }          // armed at t=1000
        harness.now += 0.10
        timer.noteActivity { ran += 1 }          // still pending: no new timer, but t moves to 1000.10

        harness.fireNext(advancingBy: 0.04)      // t=1000.14, but idle is only 0.04
        #expect(ran == 0)
        #expect(harness.armCount == 1)           // re-armed rather than run
        #expect(timer.isPending)

        harness.fireNext(advancingBy: 0.10)      // t=1000.24, idle is now 0.14
        #expect(ran == 1)
    }

    /// The deferred re-arm waits the REMAINDER, not a fresh full window — otherwise a steady stream
    /// of activity would push the correction further out on every cycle instead of landing one
    /// quiescence after the last report.
    @Test("The re-arm waits only the remaining time")
    func reArmWaitsTheRemainder() throws {
        let (timer, harness) = make(quiescence: 0.14)
        timer.noteActivity {}
        harness.now += 0.10
        timer.noteActivity {}
        harness.fireNext(advancingBy: 0.04)      // idle 0.04, so 0.10 remains
        // Approximately: the remainder is a difference of real-clock doubles, and pinning it to
        // the bit would be asserting on floating-point arithmetic rather than on the rule.
        let remaining = try #require(harness.scheduled.first?.delay)
        #expect(abs(remaining - 0.10) < 0.001)
    }

    @Test("A fresh burst after the action ran arms a new timer")
    func armsAgainAfterRunning() {
        let (timer, harness) = make(quiescence: 0.14)
        var ran = 0
        timer.noteActivity { ran += 1 }
        harness.fireNext(advancingBy: 0.14)
        #expect(ran == 1)

        timer.noteActivity { ran += 1 }
        #expect(harness.armCount == 1)
        harness.fireNext(advancingBy: 0.14)
        #expect(ran == 2)
    }

    /// The most recent caller's closure wins: the watchdogs re-resolve what they are guarding as
    /// SwiftUI rebuilds the view tree under them, so an action captured before a rebuild must not
    /// be the one that runs.
    @Test("The newest action is the one that runs")
    func newestActionWins() {
        let (timer, harness) = make(quiescence: 0.14)
        var ranOld = false
        var ranNew = false
        timer.noteActivity { ranOld = true }
        timer.noteActivity { ranNew = true }
        harness.fireNext(advancingBy: 0.14)
        #expect(!ranOld)
        #expect(ranNew)
    }

    /// A view leaving its window cancels. The scheduled block still fires — nothing can un-schedule
    /// it — so what matters is that it finds no action and does nothing, and that the pending flag
    /// clears so a later re-attach can arm again.
    @Test("Cancelling stops the run without stranding the timer")
    func cancelStopsTheRun() {
        let (timer, harness) = make(quiescence: 0.14)
        var ran = 0
        timer.noteActivity { ran += 1 }
        timer.cancel()
        harness.fireNext(advancingBy: 0.14)
        #expect(ran == 0)
        #expect(!timer.isPending)

        timer.noteActivity { ran += 1 }
        harness.fireNext(advancingBy: 0.14)
        #expect(ran == 1)
    }
}

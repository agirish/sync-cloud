import Testing
import Foundation
@testable import FileExplorer

/// Pins `QuiescenceTimer`, which the two pane scroll watchdogs re-arm on every bounds change: at
/// frame cadence, per open column, for the whole scroll.
///
/// It must arm far fewer timers than it receives reports (why it exists), and still run the action
/// exactly `quiescence` after the last report: a correction that lands mid-gesture fights the
/// platform on the paths the platform handles.
///
/// The clock and the scheduler are injected, so nothing here waits on real time; a test that slept
/// through the 0.14 s window would be racing it.
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

    /// A scroll delivers bounds changes at frame cadence; arming a work item for each is the cost
    /// this type exists to avoid. Every report after the first lands while that timer is in flight.
    @Test("A burst of activity arms exactly one timer")
    func burstArmsOneTimer() {
        let (timer, harness) = make()
        var ran = 0
        for _ in 0..<240 {
            harness.now += 1.0 / 120.0   // two seconds of 120Hz reports
            timer.noteActivity { ran += 1 }
        }
        #expect(harness.armCount == 1)
        #expect(timer.isPending)
        #expect(ran == 0)
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

    /// The timer was armed at the first report but activity continued, so when it fires the stream
    /// has not been idle long enough: it must wait out the remainder, not a fresh full window, or a
    /// steady stream would push the correction further out each cycle.
    @Test("A timer that fires while activity is still recent re-arms instead of running early")
    func lateActivityDefersTheRun() throws {
        let (timer, harness) = make(quiescence: 0.14)
        var ran = 0
        timer.noteActivity { ran += 1 }          // armed at t=1000
        harness.now += 0.10
        timer.noteActivity { ran += 1 }          // still pending: no new timer, but t moves to 1000.10

        harness.fireNext(advancingBy: 0.04)      // t=1000.14, but idle is only 0.04
        #expect(ran == 0)
        #expect(harness.armCount == 1)           // re-armed rather than run
        #expect(timer.isPending)
        // Approximately: the remainder is a difference of doubles; pinning it to the bit would
        // test floating-point arithmetic, not the rule.
        let remaining = try #require(harness.scheduled.first?.delay)
        #expect(abs(remaining - 0.10) < 0.001)

        harness.fireNext(advancingBy: 0.10)      // t=1000.24, idle is now 0.14
        #expect(ran == 1)
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

    /// A view leaving its window cancels. The scheduled block still fires (nothing can un-schedule
    /// it), so it must find no action and do nothing, and clear the pending flag so a later
    /// re-attach can arm again.
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

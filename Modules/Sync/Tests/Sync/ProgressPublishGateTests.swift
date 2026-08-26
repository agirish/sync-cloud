import Testing
@testable import Sync

/// Pins `ProgressPublishGate`: the rule that decides how many times a bulk run is allowed to
/// re-render the window.
///
/// Two properties matter and they pull against each other. The gate has to *suppress* — that is the
/// entire reason it exists — but it must never suppress an update whose absence the user would see,
/// which is the first report (the bar has to start where the run actually is) and the last one (it
/// has to finish full). Everything below is one of those two claims.
@Suite struct ProgressPublishGateTests {

    /// Runs `total` reports through a gate and returns the ones it let through.
    private func published(total: Int, reports: [Int]) -> [Int] {
        var gate = ProgressPublishGate()
        return reports.filter { gate.admits(completed: $0, total: total) }
    }

    @Test("A large run is capped at about one update per percent, not one per file")
    func largeRunIsThrottled() {
        let admitted = published(total: 500, reports: Array(0...500))
        // 0…99 inclusive plus the terminal 100% — the point is the order of magnitude, and that
        // it is bounded by the percentage scale rather than by the file count.
        #expect(admitted.count == 101)
        #expect(admitted.count < 500)
    }

    @Test("A ten-thousand file run costs no more than a five-hundred file one")
    func throttleIsIndependentOfRunSize() {
        let small = published(total: 500, reports: Array(0...500))
        let large = published(total: 10_000, reports: Array(0...10_000))
        #expect(small.count == large.count)
    }

    /// The suppression must not reach small runs: with twenty items each file moves the bar five
    /// points, which is a change worth drawing.
    @Test("A small run is not throttled at all")
    func smallRunIsUnthrottled() {
        let admitted = published(total: 20, reports: Array(0...20))
        #expect(admitted == Array(0...20))
    }

    @Test("The first report always lands, so the bar starts where the run does")
    func firstReportAlwaysPublishes() {
        var gate = ProgressPublishGate()
        let admitted = gate.admits(completed: 0, total: 500)
        #expect(admitted)
    }

    /// Without this the bar ends on the last whole percent before completion — visibly short of
    /// full on exactly the frame the user is looking at.
    @Test("The terminal report always lands, so the bar finishes full")
    func terminalReportAlwaysPublishes() {
        var gate = ProgressPublishGate()
        for i in 0..<500 { _ = gate.admits(completed: i, total: 500) }
        let terminal = gate.admits(completed: 500, total: 500)
        #expect(terminal)
    }

    /// A resumed or pre-credited run can report past its own total (the skip-credited bulk copy
    /// starts at a non-zero base); that must publish rather than divide its way into silence.
    @Test("A report beyond the total still lands")
    func overshootPublishes() {
        var gate = ProgressPublishGate()
        let overshoot = gate.admits(completed: 12, total: 10)
        #expect(overshoot)
    }

    /// Workers finish in parallel and hop to the main actor to report, so a lower count can arrive
    /// after a higher one. The gate compares against what it last PUBLISHED, so such a report is
    /// let through — the same brief backwards step the ungated code already showed, rather than a
    /// bar that sticks because a stale report moved the high-water mark.
    @Test("An out-of-order report is let through rather than sticking the bar")
    func outOfOrderReportPublishes() {
        var gate = ProgressPublishGate()
        let half = gate.admits(completed: 250, total: 500)        // 50%
        let backwards = gate.admits(completed: 245, total: 500)   // 49% — different, so it lands
        #expect(half)
        #expect(backwards)
    }

    /// A caller with no denominator cannot render a fraction, and silently swallowing its reports
    /// would leave it with no progress at all. Degenerate input opts out of the gate entirely.
    @Test("A run with no total is not gated")
    func zeroTotalIsUngated() {
        var gate = ProgressPublishGate()
        let admitted = (0...2).map { gate.admits(completed: $0, total: 0) }
        #expect(admitted == [true, true, true])
    }

    /// The mutation check: a gate that admitted everything would pass every assertion above except
    /// this one, so this is what makes the suite mean "throttles" rather than "does not crash".
    @Test("Repeating a report inside the same percent is suppressed")
    func repeatWithinAPercentIsSuppressed() {
        var gate = ProgressPublishGate()
        let onePercent = gate.admits(completed: 100, total: 10_000)
        let stillOne = gate.admits(completed: 101, total: 10_000)
        let stillOneAgain = gate.admits(completed: 199, total: 10_000)
        let twoPercent = gate.admits(completed: 200, total: 10_000)
        #expect(onePercent)
        #expect(!stillOne)
        #expect(!stillOneAgain)
        #expect(twoPercent)
    }

    /// The duplicate scan does not use the gate alone — it keeps its `% 50` floor and consults the
    /// gate inside the main-actor hop. This pins why BOTH are needed, because each is wrong on its
    /// own at one end of the range and the wrong choice is a regression rather than a smaller win.
    ///
    /// Counted here rather than asserted in prose: the traffic figure is the whole claim, and a
    /// figure that is not computed has not been checked.
    @Test("The scan's `% 50` floor and the percent gate each cover the other's bad end")
    func fiftyFloorAndPercentGateCompose() {
        func publishes(total: Int, floor: Bool, percent: Bool) -> Int {
            var gate = ProgressPublishGate()
            var count = 0
            for done in 1...total {
                if floor, !(done % 50 == 0 || done == total) { continue }
                if percent, !gate.admits(completed: done, total: total) { continue }
                count += 1
            }
            return count
        }

        // Small scan: the percent gate ALONE is worse than the modulo it would replace — 120
        // candidates move the percent on nearly every file, so it publishes 101 times against
        // the modulo's 3. This is the case that makes a drop-in replacement a regression, and
        // it is why the scan keeps its floor instead of adopting the gate the way Verify does.
        #expect(publishes(total: 120, floor: true, percent: false) == 3)
        #expect(publishes(total: 120, floor: false, percent: true) == 101)
        #expect(publishes(total: 120, floor: true, percent: true) == 3)

        // Large scan: the modulo ALONE is the 460-publish case the gate exists to cut.
        #expect(publishes(total: 23_000, floor: true, percent: false) == 460)
        #expect(publishes(total: 23_000, floor: true, percent: true) == 101)

        // Composed, neither end regresses: the traffic is min(total / 50, ~101).
        for total in [120, 1_000, 5_000, 23_000, 90_000] {
            let composed = publishes(total: total, floor: true, percent: true)
            let floorOnly = publishes(total: total, floor: true, percent: false)
            #expect(composed <= floorOnly, "composition must never publish more than the floor alone")
            #expect(composed <= 101, "composition must never exceed the percent cap")
        }
    }
}

import Testing
@testable import Sync

/// Pins `ProgressPublishGate`, which decides how often a bulk run may re-render the window. It must
/// suppress, but never an update whose absence the user would see: the first report (the bar
/// starts where the run is) and the last (it finishes full). Every test below is one of the two.
@Suite struct ProgressPublishGateTests {

    /// Runs `total` reports through a gate and returns the ones it let through.
    private func published(total: Int, reports: [Int]) -> [Int] {
        var gate = ProgressPublishGate()
        return reports.filter { gate.admits(completed: $0, total: total) }
    }

    @Test("A large run is capped at about one update per percent, not one per file")
    func largeRunIsThrottled() {
        let admitted = published(total: 500, reports: Array(0...500))
        // 0…99 plus the terminal 100%: bounded by the percentage scale, not the file count.
        #expect(admitted.count == 101)
        #expect(admitted.count < 500)
    }

    @Test("A ten-thousand file run costs no more than a five-hundred file one")
    func throttleIsIndependentOfRunSize() {
        let small = published(total: 500, reports: Array(0...500))
        let large = published(total: 10_000, reports: Array(0...10_000))
        #expect(small.count == large.count)
    }

    /// Suppression must not reach small runs: with twenty items each file moves the bar five points,
    /// a change worth drawing.
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

    /// Otherwise the bar ends on the last whole percent before completion, visibly short of full.
    @Test("The terminal report always lands, so the bar finishes full")
    func terminalReportAlwaysPublishes() {
        var gate = ProgressPublishGate()
        for i in 0..<500 { _ = gate.admits(completed: i, total: 500) }
        let terminal = gate.admits(completed: 500, total: 500)
        #expect(terminal)
    }

    /// A resumed or pre-credited run can report past its own total (the skip-credited bulk copy
    /// starts at a non-zero base); that must publish, not divide its way into silence.
    @Test("A report beyond the total still lands")
    func overshootPublishes() {
        var gate = ProgressPublishGate()
        let overshoot = gate.admits(completed: 12, total: 10)
        #expect(overshoot)
    }

    /// Workers finish in parallel and hop to the main actor to report, so a lower count can arrive
    /// after a higher one. The gate compares against what it last published, so the report lands as
    /// a brief backwards step rather than a bar stuck behind a stale high-water mark.
    @Test("An out-of-order report is let through rather than sticking the bar")
    func outOfOrderReportPublishes() {
        var gate = ProgressPublishGate()
        let half = gate.admits(completed: 250, total: 500)        // 50%
        let backwards = gate.admits(completed: 245, total: 500)   // 49% — different, so it lands
        #expect(half)
        #expect(backwards)
    }

    /// A caller with no denominator can't render a fraction, and swallowing its reports would leave
    /// it no progress at all, so degenerate input opts out of the gate.
    @Test("A run with no total is not gated")
    func zeroTotalIsUngated() {
        var gate = ProgressPublishGate()
        let admitted = (0...2).map { gate.admits(completed: $0, total: 0) }
        #expect(admitted == [true, true, true])
    }

    /// Must fail for a gate that admits everything, which would pass every test above.
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

    /// The duplicate scan keeps its `% 50` floor and consults the gate inside the main-actor hop.
    /// Each alone is wrong at one end of the range, so both are needed; the publish counts are
    /// computed here, not claimed.
    @Test("The scan's `% 50` floor and the percent gate each cover the other's bad end")
    func fiftyFloorAndPercentGateCompose() {
        func publishes(total: Int, everyFiftieth: Bool, percent: Bool) -> Int {
            var gate = ProgressPublishGate()
            var count = 0
            for done in 1...total {
                if everyFiftieth, !(done % 50 == 0 || done == total) { continue }
                if percent, !gate.admits(completed: done, total: total) { continue }
                count += 1
            }
            return count
        }

        // Small scan: the percent gate alone is worse than the modulo. 120 candidates move the
        // percent on nearly every file, so it publishes 101 times against the modulo's 3, which
        // is why the scan keeps its floor instead of adopting the gate as Verify does.
        #expect(publishes(total: 120, everyFiftieth: true, percent: false) == 3)
        #expect(publishes(total: 120, everyFiftieth: false, percent: true) == 101)
        #expect(publishes(total: 120, everyFiftieth: true, percent: true) == 3)

        // Large scan: the modulo alone publishes 460 times, which the gate cuts.
        #expect(publishes(total: 23_000, everyFiftieth: true, percent: false) == 460)
        #expect(publishes(total: 23_000, everyFiftieth: true, percent: true) == 101)

        // Composed, neither end regresses: the traffic is min(total / 50, ~101).
        for total in [120, 1_000, 5_000, 23_000, 90_000] {
            let composed = publishes(total: total, everyFiftieth: true, percent: true)
            let modulusOnly = publishes(total: total, everyFiftieth: true, percent: false)
            #expect(composed <= modulusOnly,
                    "composition must never publish more than the modulus alone")
            #expect(composed <= 101, "composition must never exceed the percent cap")
        }
    }
}

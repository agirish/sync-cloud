import Foundation
import Testing
@testable import FileExplorer

/// Only a short, idle stall over a hidden, inactive app is counted; any doubt keeps its line.
@Suite struct StallClassifierTests {
    static let hidden = StallAppState(active: false, everyWindowOccluded: true)

    func verdict(app: StallAppState? = hidden, began: TimeInterval = 100, ended: TimeInterval? = 102,
                 cpu: TimeInterval? = 0.05, now: TimeInterval = 110, activations: [TimeInterval] = [])
        -> StallClassifier.Verdict {
        StallClassifier.classify(StallFacts(began: began, ended: ended, cpu: cpu, app: app),
                                 now: now, beat: 0.5, activations: activations)
    }

    @Test func aShortIdleStallOverAHiddenAppIsCounted() {
        #expect(verdict() == .counted)
    }

    @Test func anyStallTheUserMayHaveFeltKeepsItsLine() {
        #expect(verdict(app: StallAppState(active: true, everyWindowOccluded: true)) == .warn)
        #expect(verdict(app: StallAppState(active: false, everyWindowOccluded: false)) == .warn)
        #expect(verdict(app: nil) == .warn, "unknown state")
        #expect(verdict(cpu: 0.5) == .warn, "busy: 25% of 2 s")
        #expect(verdict(cpu: nil) == .warn, "unknown CPU")
        #expect(verdict(ended: nil) == .warn, "still going")
        #expect(verdict(ended: 110.5, now: 120) == .warn, "over 10 s")
    }

    /// From a beat before it began to a beat after it ended.
    @Test func anActivationNearTheStallKeepsItsLine() {
        #expect(verdict(activations: [99.6]) == .warn)
        #expect(verdict(activations: [101]) == .warn)
        #expect(verdict(activations: [102.4]) == .warn)
        #expect(verdict(activations: [99.4, 102.6]) == .counted)
    }

    /// An activation made during the stall is delivered after it ends: the verdict waits a beat.
    @Test func theVerdictWaitsABeatPastTheEnd() {
        #expect(verdict(now: 102.2) == .wait(until: 102.5))
        #expect(verdict(now: 102.5) == .counted)
    }
}

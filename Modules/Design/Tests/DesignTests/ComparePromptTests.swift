import Foundation
import Testing
@testable import Design

/// Compare's cold-open copy. Pure formatting, so each case is a fixture — and the plural seams are
/// where this kind of sentence goes wrong.
@Suite struct ComparePromptTests {

    private let scanned = Date(timeIntervalSinceReferenceDate: 0)

    private func text(count: Int, ageSeconds: TimeInterval) -> String {
        ComparePrompt.lastScan(differenceCount: count, date: scanned,
                               now: scanned.addingTimeInterval(ageSeconds))
    }

    @Test func testItReportsTheCountAndTheAge() {
        #expect(text(count: 412, ageSeconds: 3 * 86_400)
                == "Last scanned 3 days ago — 412 differences. Scan again to see what has changed since.")
    }

    /// Both plural seams. "1 differences" and "0 differences" are the two ways this sentence reads
    /// as machine output, and zero is a real outcome — a scan that found nothing is exactly the
    /// state someone is most likely to be re-opening the app to confirm.
    @Test func testTheCountReadsAsEnglishAtOneAndZero() {
        #expect(text(count: 1, ageSeconds: 60).contains("— 1 difference."))
        #expect(text(count: 0, ageSeconds: 60).contains("— no differences."))
    }

    /// The age comes from `ScanFreshness`'s ladder, not a second one — the app must not have two
    /// answers to "how old is this scan?" — in its words form, because this is a sentence: the
    /// compact "3d ago" is pill shorthand, and VoiceOver reads it as "3 d".
    @Test func testTheAgeUsesTheSharedFreshnessLadder() {
        for seconds: TimeInterval in [0, 45, 90, 4000, 100_000, 300_000] {
            let expected = ScanFreshness.spokenRelative(seconds)
            #expect(text(count: 2, ageSeconds: seconds).contains("Last scanned \(expected) —"),
                    "\(seconds)s should read as “\(expected)”")
        }
    }

    /// A clock change can put the recorded scan in the future. Clamped, so the card never reports
    /// a negative age.
    @Test func testAFutureScanDateDoesNotProduceANegativeAge() {
        #expect(text(count: 2, ageSeconds: -5_000).contains("Last scanned just now —"))
    }
}

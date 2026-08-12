import Foundation
import Testing
@testable import Sync

/// ``FilingRouter/margin(top:runnerUp:)`` — the number `Ranking.confidence` is entirely derived
/// from, and therefore what decides whether a folder is offered, auto-filed, or paid to refine.
@Suite struct FilingRouterMarginTests {

    /// The ordinary separation, unchanged: a clear winner is high, a near-tie is low.
    @Test func theMarginSeparatesAWinnerFromATie() {
        #expect(FilingRouter.margin(top: 1.0, runnerUp: 0.2) == 0.8)
        #expect(abs(FilingRouter.margin(top: 1.0, runnerUp: 0.95) - 0.05) < 1e-12)
    }

    /// Unopposed and positive is the case the 1.0 was written for.
    @Test func aLonePositiveCandidateRunsUnopposed() {
        #expect(FilingRouter.margin(top: 0.4, runnerUp: nil) == 1.0)
    }

    /// **A top score the scorer pushed to or below zero is not confident.** This is the rule; the
    /// old expression answered 1.0 here, which `Ranking.confidence` reads as `.high`.
    @Test func aNonPositiveTopIsNeverConfident() {
        for top in [-0.55, -3.0, 0.0] {
            #expect(FilingRouter.margin(top: top, runnerUp: nil) == 0,
                    "a lone candidate scoring \(top) reported a margin above zero")
            #expect(FilingRouter.margin(top: top, runnerUp: top - 1) == 0,
                    "a contradicted candidate with a worse runner-up reported a margin above zero")
        }
    }

    /// The consequence, stated where it is actually read — a margin of 0 is `.low`, and `.low` is
    /// what keeps `route` from promoting the folder and the blind batch from moving the file.
    @Test func aZeroMarginRankingIsLowConfidence() {
        let ranking = FilingRouter.Ranking(
            candidates: [.init(relativePath: "School/Divit", score: -0.55,
                               evidenceToken: nil, sharedAnchors: 0)],
            margin: FilingRouter.margin(top: -0.55, runnerUp: nil))
        #expect(ranking.confidence == .low)
    }

    /// A runner-up the scorer argued against separates MORE than a neutral one — the ratio can
    /// exceed 1, and that is meaningful rather than a bug to clamp away.
    @Test func aContradictedRunnerUpSeparatesMoreThanAZeroOne() {
        #expect(FilingRouter.margin(top: 1.0, runnerUp: -1.0) > FilingRouter.margin(top: 1.0, runnerUp: 0))
    }

    /// **The call site**, because a rule extracted for testability is one revert away from being
    /// unused: `rank` must reach its margin through this function and not re-derive it inline.
    @Test func rankAsksThisFunctionForItsMargin() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Sync/FilingRouter.swift")
        let source = try #require(try? String(contentsOf: url, encoding: .utf8),
                                  "cannot read FilingRouter.swift — this scan would be vacuous")
        try #require(source.count > 500, "FilingRouter.swift is implausibly short")
        #expect(source.contains("let margin = Self.margin(top: best[0].value"),
                "rank no longer derives its margin from the tested rule")
    }
}

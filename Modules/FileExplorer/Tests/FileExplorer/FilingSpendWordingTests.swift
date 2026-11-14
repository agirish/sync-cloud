import Testing
import Foundation
@testable import Sync
@testable import FileExplorer

/// The two tooltips that explain what the filing scan spent: `refineHelp` on the "refined" pill,
/// `reuseHelp` on "reused". They describe the same cache a few points apart, so they must agree in
/// number: "1 had already been answered by this model, so they cost nothing" is the disagreement
/// to keep out. Pure functions of their summaries, so string assertions rather than a render.
@MainActor
@Suite struct FilingSpendWordingTests {

    private static func refine(reused: Int) -> String {
        LensWorkspaceView.refineHelp(FileSyncManager.FilingRefineSummary(asked: 4, reused: reused,
                                                                classified: 2, changed: 1))
    }

    private static func reuse(reused: Int) -> String {
        LensWorkspaceView.reuseHelp(FileSyncManager.FilingCacheReuse(reused: reused, classified: 2))
    }

    /// Neither tooltip says "they" about one file. A sweep for plural pronouns rather than the exact
    /// sentence, so the wording stays editable.
    @Test func neitherTooltipIsPluralAboutASingleFile() {
        for text in [Self.refine(reused: 1), Self.reuse(reused: 1)] {
            #expect(!text.contains(" they "), "“\(text)” says “they” about one file")
            #expect(!text.contains(" their "), "“\(text)” says “their” about one file")
            // The guard against a vacuous sweep: the sentence has to be about one file at all.
            #expect(text.contains("1 "), "“\(text)” never mentions the single file it is about")
        }
    }

    /// Both are plural above one, so the fix above cannot be making every sentence singular.
    @Test func bothTooltipsArePluralAboveOne() {
        #expect(Self.refine(reused: 6).contains("so they cost nothing"))
        #expect(Self.reuse(reused: 6).contains("their suggestions were reused"))
    }

    /// The clause disappears entirely at zero rather than saying "0 had already been answered", the
    /// same absent-not-zero rule the rail badges follow.
    @Test func theReuseClauseIsAbsentAtZero() {
        #expect(!Self.refine(reused: 0).contains("already been answered"))
        #expect(Self.reuse(reused: 0).contains("0 files"))   // reuse's own pill only shows above 0
    }

    private static func refine(classified: Int, changed: Int = 0,
                               outcome: FileSyncManager.FilingRefineSummary.Outcome) -> String {
        LensWorkspaceView.refineHelp(FileSyncManager.FilingRefineSummary(
            asked: 4, reused: 0, classified: classified, changed: changed, outcome: outcome))
    }

    /// "Nothing needed sending" is a claim about the cache, and only one of three ways to reach
    /// `classified == 0` earns it. The other two, a declined charge and an unreadable Claude key,
    /// must not tell a user who just pressed Cancel that every answer came from the cache; this
    /// rides on the durable "refined" pill. Asserted as "does not claim the cache", not exact wording.
    @Test func onlyAnExhaustedCacheIsExplainedByTheCache() {
        let cached = Self.refine(classified: 0, outcome: .ran)
        #expect(cached.contains("every answer came from the cache"),
                "the one case that IS the cache stopped saying so — this check would be vacuous")

        for outcome in [FileSyncManager.FilingRefineSummary.Outcome.declined, .downgraded] {
            let text = Self.refine(classified: 0, outcome: outcome)
            #expect(!text.contains("came from the cache"),
                    "a \(outcome.rawValue) pass is explained as an exhausted cache: “\(text)”")
            #expect(!text.contains("Nothing needed sending"),
                    "a \(outcome.rawValue) pass claims nothing NEEDED sending: “\(text)”")
        }
    }

    /// Each refusal says which it was: a declined pass cost nothing and can be re-run, an unreadable
    /// key is a setting to go and fix.
    @Test func theTwoRefusalsAreToldApart() {
        #expect(Self.refine(classified: 0, outcome: .declined).contains("declined"))
        #expect(Self.refine(classified: 0, outcome: .downgraded).contains("key"))
        #expect(Self.refine(classified: 0, outcome: .downgraded).contains("this Mac"),
                "the downgraded pass does not say where the answers actually came from")
    }

    /// "The free pass had already found the same homes" describes an answer that came back, which a
    /// declined pass does not have.
    @Test func aDeclinedPassDoesNotCreditTheFreePassForFindingTheSameHomes() {
        #expect(!Self.refine(classified: 0, outcome: .declined)
                    .contains("already found the same homes"))
        #expect(Self.refine(classified: 0, outcome: .ran).contains("already found the same homes"),
                "the ordinary no-change explanation is gone — this check would be vacuous")
    }

    /// A declined pass can still have moved a home on the strength of cached answers, so the count
    /// sentence is the ordinary one rather than being suppressed with the explanation.
    @Test func aDeclinedPassStillReportsHomesTheCacheMoved() {
        #expect(Self.refine(classified: 0, changed: 2, outcome: .declined)
                    .contains("2 suggestions moved to better homes"))
    }

    /// The pill says how many files hidden from Claude the pass left out, and says nothing at zero.
    @Test func thePillCountsFilesHiddenFromClaude() {
        func help(_ hidden: Int) -> String {
            LensWorkspaceView.refineHelp(FileSyncManager.FilingRefineSummary(
                asked: 4, reused: 0, classified: 4, changed: 1, hiddenFromClaude: hidden))
        }
        #expect(help(0).contains("hidden from Claude") == false)
        #expect(help(1).hasSuffix(" 1 file hidden from Claude was left out."))
        #expect(help(3).hasSuffix(" 3 files hidden from Claude were left out."))
    }
}

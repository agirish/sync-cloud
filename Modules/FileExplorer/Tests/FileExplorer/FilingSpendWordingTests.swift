import Testing
import Foundation
@testable import Sync
@testable import FileExplorer

/// The two tooltips that explain what the filing scan spent — `refineHelp` on the "refined" pill,
/// `reuseHelp` on "reused".
///
/// They describe **the same cache from two pills**, a few points apart, so a reader comparing them
/// sees both sentences at once. `reuseHelp` already handled one file explicitly and carries a
/// comment saying the halves must agree in number; `refineHelp`'s reuse clause did not, and read
/// "1 had already been answered by this model, so **they** cost nothing".
///
/// Pure functions of their summaries, which is why these are assertions about strings rather than a
/// render: nothing else about them is view-shaped.
@MainActor
@Suite struct FilingSpendWordingTests {

    private static func refine(reused: Int) -> String {
        TidyView.refineHelp(FileSyncManager.FilingRefineSummary(asked: 4, reused: reused,
                                                                classified: 2, changed: 1))
    }

    private static func reuse(reused: Int) -> String {
        TidyView.reuseHelp(FileSyncManager.FilingCacheReuse(reused: reused, classified: 2))
    }

    /// **Neither tooltip says "they" about one file.**
    ///
    /// Written as a sweep for plural pronouns rather than as a match on the exact sentence: the
    /// wording of these is meant to be editable, and what must not come back is the disagreement.
    @Test func neitherTooltipIsPluralAboutASingleFile() {
        for text in [Self.refine(reused: 1), Self.reuse(reused: 1)] {
            #expect(!text.contains(" they "), "“\(text)” says “they” about one file")
            #expect(!text.contains(" their "), "“\(text)” says “their” about one file")
            // The guard against a vacuous sweep: the sentence has to be about one file at all.
            #expect(text.contains("1 "), "“\(text)” never mentions the single file it is about")
        }
    }

    /// And both are plural above one — the direction that would otherwise be "fixed" by making
    /// every sentence singular, which reads just as wrong at 340.
    @Test func bothTooltipsArePluralAboveOne() {
        #expect(Self.refine(reused: 6).contains("so they cost nothing"))
        #expect(Self.reuse(reused: 6).contains("their suggestions were reused"))
    }

    /// The clause disappears entirely at zero rather than saying "0 had already been answered" —
    /// the same absent-not-zero rule the rail badges follow.
    @Test func theReuseClauseIsAbsentAtZero() {
        #expect(!Self.refine(reused: 0).contains("already been answered"))
        #expect(Self.reuse(reused: 0).contains("0 files"))   // reuse's own pill only shows above 0
    }
}

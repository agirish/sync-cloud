import Testing
import Foundation
@testable import FileExplorer

/// **Absent beats a wrong zero.**
///
/// Three readouts claimed a number they could not support, each in the same way: a count drawn from
/// a source that had not looked where the label said it had. The rail's badge rule already settles
/// this for findings — `badge(count:)` returns nil at zero rather than drawing a greyed "0" — and
/// these are the same question asked about a folder tally, an inbox and a survey.
@Suite struct OrganizeScopeUnknownCountsTests {

    // MARK: The inbox offer

    /// The count is claimed only when the last scan actually covered the inbox.
    ///
    /// `filingSuggestions` holds ONE scan's output, so scoped to `Legal` — or before any scan at
    /// all — nothing in it sits under `TODO`, and the offer read "Inbox (TODO) — **0 loose files**"
    /// while the inbox held fifty. That is the worst possible wording for this control: it talks
    /// the user out of the single click the inbox was promoted from a hidden default to make
    /// available.
    @Test func anUnknownInboxCountNamesTheFolderInsteadOfClaimingZero() {
        #expect(OrganizeOverview.inboxSubtitle(nil) == "Organize just this folder")
        // The wrong-zero string must not be reachable from nil.
        #expect(!OrganizeOverview.inboxSubtitle(nil).contains("0"))
    }

    @Test func aKnownInboxCountIsStatedAndPluralized() {
        #expect(OrganizeOverview.inboxSubtitle(1) == "1 loose file — organize just this folder")
        #expect(OrganizeOverview.inboxSubtitle(50) == "50 loose files — organize just this folder")
    }

    @Test func aKNOWNZeroStillReadsAsZero() {
        // The discriminating half. Nil is "we did not look"; zero is "we looked and it is empty",
        // and a scan that really covered an empty inbox must be allowed to say so — otherwise the
        // fix would just be a blanket suppression that hides a true answer along with the false one.
        #expect(OrganizeOverview.inboxSubtitle(0) == "0 loose files — organize just this folder")
        #expect(OrganizeOverview.inboxSubtitle(0) != OrganizeOverview.inboxSubtitle(nil))
    }

    // MARK: Restructure's clean state

    /// "Checked 3,013 folders" beside a list narrowed to one subtree is a claim about a tree this
    /// lens did not look at.
    @Test func theCleanStateCountsWhatItActuallyChecked() {
        #expect(RestructureLens.cleanMessage(folderCount: 79).hasPrefix("Checked 79 folders."))
        // Grouped past a thousand — the real tree is 3,013 folders, and this sentence and the
        // setup card's footnote both say so the same way.
        #expect(RestructureLens.cleanMessage(folderCount: 3_013).hasPrefix("Checked 3,013 folders."))
        #expect(RestructureLens.cleanMessage(folderCount: 1).hasPrefix("Checked 1 folder."))
    }

    @Test func anUnknownSurveyDropsTheCountRatherThanInventingOne() {
        let unknown = RestructureLens.cleanMessage(folderCount: nil)
        #expect(!unknown.contains("Checked"))
        #expect(!unknown.contains("0"))
        // Still says the thing that matters — that nothing disagreed.
        #expect(unknown.contains("No family of sibling folders"))
        // And differs from every known count, so the two states cannot be confused.
        #expect(unknown != RestructureLens.cleanMessage(folderCount: 0))
    }

    @Test func theCleanTitleDoesNotClaimTheWholeTreeUnderAScope() {
        // "The tree agrees with itself" is a claim about the whole tree, and under a scope this
        // lens has only looked at part of it.
        #expect(RestructureLens.cleanTitle(isScoped: false) == "The tree agrees with itself")
        #expect(RestructureLens.cleanTitle(isScoped: true) == "This folder agrees with itself")
        #expect(RestructureLens.cleanTitle(isScoped: true) != RestructureLens.cleanTitle(isScoped: false))
    }
}

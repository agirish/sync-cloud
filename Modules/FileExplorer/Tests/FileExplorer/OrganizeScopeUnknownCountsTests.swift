import Testing
import Foundation
@testable import FileExplorer

/// Absent beats a wrong zero: a readout states a count only when its source looked where the label
/// says it did. The same rule as `badge(count:)`, which returns nil at zero rather than a greyed
/// "0", applied to a folder tally, an inbox and a survey.
@Suite struct OrganizeScopeUnknownCountsTests {

    // MARK: The inbox offer

    /// The inbox count is claimed only when the last scan covered the inbox. `filingSuggestions`
    /// holds one scan's output, so scoped elsewhere, or before any scan, it would read "0 loose
    /// files" for a full inbox and talk the user out of the click the offer exists for.
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
        // Nil is "we did not look"; zero is "we looked and it is empty". A real empty inbox must
        // still say so, or the rule would hide true answers along with false ones.
        #expect(OrganizeOverview.inboxSubtitle(0) == "0 loose files — organize just this folder")
        #expect(OrganizeOverview.inboxSubtitle(0) != OrganizeOverview.inboxSubtitle(nil))
    }

    // MARK: Restructure's clean state

    /// "Checked 3,013 folders" beside a list narrowed to one subtree is a claim about a tree this
    /// lens did not look at.
    @Test func theCleanStateCountsWhatItActuallyChecked() {
        #expect(RestructureLens.cleanMessage(folderCount: 79).hasPrefix("Checked 79 folders."))
        // Grouped past a thousand, the same way the setup card's footnote writes it.
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

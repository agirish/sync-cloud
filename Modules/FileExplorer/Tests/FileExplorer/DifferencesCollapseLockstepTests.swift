import Testing
@testable import FileExplorer

/// Pins the collapse rule the differences pane's HEIGHT and its CONTENT both answer to.
///
/// `ContentView.bottomPaneIsCollapsed` shrinks the pane to a header strip; `DifferencesView`
/// decides whether to render a strip or a full list. Each used to restate "stored preference AND
/// no guided review" on its own side, kept honest only by comments — and the commit that
/// introduced the review override said plainly what happens if they drift: "if one said collapsed
/// while the other drew a full list, the list would be clipped". They now call this one function.
@Suite struct DifferencesCollapseLockstepTests {

    @Test func theStoredPreferenceCollapsesThePane() {
        #expect(DifferencesView.isCollapsedToHeaderStrip(storedCollapse: true, isReviewing: false))
        #expect(!DifferencesView.isCollapsedToHeaderStrip(storedCollapse: false, isReviewing: false))
    }

    @Test func aGuidedReviewOverridesTheStoredCollapse() {
        // The review card carries a cursor and progress that exist nowhere else, so a session
        // re-opens the pane rather than leaving itself hidden behind a chevron.
        #expect(!DifferencesView.isCollapsedToHeaderStrip(storedCollapse: true, isReviewing: true))
        #expect(!DifferencesView.isCollapsedToHeaderStrip(storedCollapse: false, isReviewing: true))
    }

    @Test func theOverrideDoesNotConsumeThePreference() {
        // Ending the review must return the pane to the strip the user asked for — which holds
        // because the rule is a pure function of the CURRENT preference, never a mutation of it.
        let duringReview = DifferencesView.isCollapsedToHeaderStrip(storedCollapse: true, isReviewing: true)
        let afterReview = DifferencesView.isCollapsedToHeaderStrip(storedCollapse: true, isReviewing: false)
        #expect(duringReview == false)
        #expect(afterReview == true)
    }
}

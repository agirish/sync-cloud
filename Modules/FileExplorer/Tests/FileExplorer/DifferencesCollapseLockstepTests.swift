import Testing
@testable import FileExplorer

/// The collapse rule the differences pane's height and its content both answer to.
/// `ContentView.bottomPaneIsCollapsed` shrinks the pane to a header strip, and `DifferencesView`
/// decides whether to draw a strip or a full list; both call this one function, since a drift
/// would clip the list.
@Suite struct DifferencesCollapseLockstepTests {

    @Test func theStoredPreferenceCollapsesThePane() {
        #expect(DifferencesView.isCollapsedToHeaderStrip(storedCollapse: true, isReviewing: false))
        #expect(!DifferencesView.isCollapsedToHeaderStrip(storedCollapse: false, isReviewing: false))
    }

    @Test func aGuidedReviewOverridesTheStoredCollapse() {
        // The review card carries a cursor and progress found nowhere else, so a session re-opens
        // the pane rather than hiding behind a chevron.
        #expect(!DifferencesView.isCollapsedToHeaderStrip(storedCollapse: true, isReviewing: true))
        #expect(!DifferencesView.isCollapsedToHeaderStrip(storedCollapse: false, isReviewing: true))
    }

    @Test func theOverrideDoesNotConsumeThePreference() {
        // Ending the review returns the pane to the strip the user asked for, because the rule is
        // a pure function of the current preference, never a mutation of it.
        let duringReview = DifferencesView.isCollapsedToHeaderStrip(storedCollapse: true, isReviewing: true)
        let afterReview = DifferencesView.isCollapsedToHeaderStrip(storedCollapse: true, isReviewing: false)
        #expect(duringReview == false)
        #expect(afterReview == true)
    }
}

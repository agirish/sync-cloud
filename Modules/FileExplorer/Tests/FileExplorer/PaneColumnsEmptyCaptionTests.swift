import Testing
@testable import FileExplorer

/// **What a column with no rows says about itself.**
///
/// It said "Empty", always — a claim the walk never made. Reported from the running app on
/// 2026-08-24 as "why is content empty everywhere?" after the sidebar made the home folder one
/// click away: browsing `~` means deep-walking Library, all of CloudStorage and every runner
/// checkout, and `loadTree` paints at `maxDepth: 1` first so the pane appears at once. Every child
/// directory therefore arrives with no children and `isUnexplored` set, and the column announced
/// each of them as empty until the deep walk caught up.
///
/// Three states, one caption each. The wording is `DestinationFolderListing.emptyMessage`'s, whose
/// columns learned the same lesson first — an app that says two different things about one state is
/// worse than one that says nothing.
@Suite struct PaneColumnsEmptyCaptionTests {

    /// An empty tree at depth 0 already draws the pane's "Folder is empty" placeholder in the same
    /// space, and the two used to render stacked — this one clipped against the placeholder's
    /// folder glyph.
    @Test func rootColumnNeverCaptionsAnEmptyTree() {
        for unexplored in [true, false] {
            for loading in [true, false] {
                #expect(PaneColumnsView.emptyCaption(rowsEmpty: true, depth: 0,
                                                     isUnexplored: unexplored, isLoading: loading, isBeingRead: false) == nil,
                        "the root column captioned (unexplored: \(unexplored), loading: \(loading))")
            }
        }
    }

    /// The caption's whole purpose: a column opened into a folder with nothing in it must say so,
    /// because the pane placeholder does not show once the tree has rows.
    @Test func drilledIntoAGenuinelyEmptyFolderStillSaysEmpty() {
        #expect(PaneColumnsView.emptyCaption(rowsEmpty: true, depth: 1,
                                             isUnexplored: false, isLoading: false, isBeingRead: false) == .empty)
        #expect(PaneColumnsView.emptyCaption(rowsEmpty: true, depth: 3,
                                             isUnexplored: false, isLoading: false, isBeingRead: false) == .empty)
    }

    @Test func populatedColumnsNeverCaption() {
        #expect(PaneColumnsView.emptyCaption(rowsEmpty: false, depth: 0,
                                             isUnexplored: false, isLoading: false, isBeingRead: false) == nil)
        #expect(PaneColumnsView.emptyCaption(rowsEmpty: false, depth: 2,
                                             isUnexplored: true, isLoading: true, isBeingRead: false) == nil,
                "a column with rows captioned anyway — rows are the first thing the rule asks about")
    }

    // MARK: - The two states that used to be called "Empty"

    /// **A folder the walk reported but did not read is not empty.** This is the reported bug:
    /// `FileSyncManager` marks it `isUnexplored` and logs "shown as unexplored, not empty", and the
    /// column threw that away.
    @Test func anUnexploredFolderSaysItCannotBeRead() {
        #expect(PaneColumnsView.emptyCaption(rowsEmpty: true, depth: 1,
                                             isUnexplored: true, isLoading: false, isBeingRead: false) == .unreadable)
    }

    /// **Loading outranks unexplored**, and that ordering is the fix for the reported symptom
    /// rather than an optimisation. During the shallow first paint *every* directory is unexplored,
    /// so without this the pane would swap one wrong answer for another — announcing "can't be
    /// read" about folders that are merely next in the queue, which is further from the truth than
    /// "Empty" was.
    @Test func loadingOutranksUnexplored() {
        #expect(PaneColumnsView.emptyCaption(rowsEmpty: true, depth: 1,
                                             isUnexplored: true, isLoading: true, isBeingRead: false) == .loading)
        #expect(PaneColumnsView.emptyCaption(rowsEmpty: true, depth: 1,
                                             isUnexplored: false, isLoading: true, isBeingRead: false) == .loading)
    }

    /// The three are distinct values, so a caller cannot collapse two of them by accident — which
    /// is exactly what the single `Bool` did.
    @Test func theThreeStatesAreDistinct() {
        let states: [PaneColumnsView.Caption] = [.empty, .unreadable, .loading]
        #expect(Set(states.map(String.init(describing:))).count == 3)
    }

    // MARK: - Wording

    /// The loading state draws a spinner and no text: a caption beside it would say the same thing
    /// twice.
    @Test func onlyTheTwoSettledStatesCarryText() {
        #expect(PaneColumnsView.Caption.empty.text == "Empty")
        #expect(PaneColumnsView.Caption.unreadable.text == "Can’t be read")
        #expect(PaneColumnsView.Caption.loading.text == nil)
    }

    /// **The apostrophe is the typographic one**, matching `DestinationFolderListing.emptyMessage`
    /// exactly. Two surfaces phrasing one state two ways is the drift this borrows the wording to
    /// avoid, and an ASCII `'` would be that drift in the one character nobody proofreads.
    @Test func theUnreadableWordingMatchesTheDestinationPickers() {
        let text = PaneColumnsView.Caption.unreadable.text
        #expect(text == "Can\u{2019}t be read")
        #expect(text?.contains("'") == false, "the caption uses an ASCII apostrophe")
    }
}

/// **A folder being read is not a folder that cannot be read**, and the column said the second
/// about the first for every folder past the node budget.
///
/// Found by reviewing the budget work rather than by using it, which is the tell: the wrong caption
/// shows only in the window between a column opening a budgeted-out directory and its listing
/// landing — short on a warm cache, long on a cold one, and never in a test that did not model the
/// wait at all.
@Suite struct PaneColumnBeingReadCaptionTests {

    /// The reported case: unexplored, the pane's own walk finished, and a listing on its way.
    @Test func aDirectoryWithAListingInFlightShowsTheSpinner() {
        #expect(PaneColumnsView.emptyCaption(rowsEmpty: true, depth: 1, isUnexplored: true,
                                             isLoading: false, isBeingRead: true) == .loading,
                "a folder the app is actively reading was captioned as unreadable")
    }

    /// **And once the request comes back with the mark still on, it IS unreadable.** This is the
    /// half that keeps the fix honest: without it the spinner would simply replace the wrong
    /// caption with a permanent one, which is worse — a wrong sentence at least ends.
    @Test func aDirectoryWhoseRequestFinishedAndStayedUnexploredCannotBeRead() {
        #expect(PaneColumnsView.emptyCaption(rowsEmpty: true, depth: 1, isUnexplored: true,
                                             isLoading: false, isBeingRead: false) == .unreadable)
    }

    /// An in-flight request cannot invent a caption where there was none — a populated column and
    /// the root column both stay silent.
    @Test func beingReadNeverAddsACaptionWhereThereWasNotOne() {
        #expect(PaneColumnsView.emptyCaption(rowsEmpty: false, depth: 1, isUnexplored: true,
                                             isLoading: false, isBeingRead: true) == nil)
        #expect(PaneColumnsView.emptyCaption(rowsEmpty: true, depth: 0, isUnexplored: true,
                                             isLoading: false, isBeingRead: true) == nil)
    }

    /// A genuinely empty folder stays "Empty" even if something asked about it — the request is
    /// idempotent and can be outstanding for a folder that turns out to have nothing in it.
    @Test func anEmptyWalkedFolderIsStillEmptyWhileARequestIsOutstanding() {
        #expect(PaneColumnsView.emptyCaption(rowsEmpty: true, depth: 1, isUnexplored: false,
                                             isLoading: false, isBeingRead: true) == .empty)
    }

    /// The pane's own walk still outranks everything: during the shallow paint every directory is
    /// unexplored and the deep walk is coming, so a per-directory request is not what will fill it.
    @Test func thePanesOwnWalkStillOutranksTheColumnRequest() {
        #expect(PaneColumnsView.emptyCaption(rowsEmpty: true, depth: 1, isUnexplored: true,
                                             isLoading: true, isBeingRead: true) == .loading)
    }
}

/// **When a column asks for a directory the walk did not read** — the other half of the same rule.
///
/// The caption above says what the column DRAWS; this says what it DOES, and the two failure modes
/// are opposite. Ask too eagerly and the pane re-lists directories by hand: during the shallow
/// first paint every folder is unexplored, so a rule missing the `isLoading` term queues one
/// listing per visible row and duplicates the deep walk that is already coming. Ask too rarely —
/// drop the request entirely — and a column past `FileSyncManager.paneNodeBudget` is blank for as
/// long as the pane stays on that root, which is the state the budget was introduced to avoid.
///
/// Both live in a `private func` whose only call sites are `.onAppear` and `.onChange`, neither of
/// which a test can fire, so the decision is a pure static and this is what checks it.
@Suite struct PaneColumnRequestRuleTests {

    /// The one state that asks: the walk has settled and this folder was left unread.
    @Test func aSettledPaneAsksForAnUnreadFolder() {
        #expect(PaneColumnsView.asksForChildren(isLoading: false, isUnexplored: true))
    }

    /// **Never mid-walk.** Every directory is unexplored during the shallow paint.
    @Test func aLoadingPaneNeverAsks() {
        #expect(!PaneColumnsView.asksForChildren(isLoading: true, isUnexplored: true))
        #expect(!PaneColumnsView.asksForChildren(isLoading: true, isUnexplored: false))
    }

    /// **Never for a folder that was read.** An empty folder is not a missing one, and the mark is
    /// what separates them — a request here would relist the same empty directory on every render,
    /// because the answer can never clear a mark that is not set.
    @Test func aWalkedFolderIsNeverAskedFor() {
        #expect(!PaneColumnsView.asksForChildren(isLoading: false, isUnexplored: false))
    }

    /// Stated as the whole table, so a third term added later has to decide about these four cells
    /// rather than inheriting them.
    @Test func theRuleIsBothConditionsAndNothingElse() {
        let asked = [(false, true), (false, false), (true, true), (true, false)]
            .filter { PaneColumnsView.asksForChildren(isLoading: $0.0, isUnexplored: $0.1) }
        #expect(asked.count == 1, "the rule asks in \(asked.count) of the four states, not 1")
    }
}

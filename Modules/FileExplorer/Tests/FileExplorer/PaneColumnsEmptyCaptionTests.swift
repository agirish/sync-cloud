import Testing
@testable import FileExplorer

/// What a column with no rows says about itself. "Empty" is a claim only the walk can make:
/// `loadTree` paints at `maxDepth: 1` first, so every child directory arrives childless and
/// `isUnexplored`. Three states, one caption each, worded as `DestinationFolderListing.emptyMessage`.
@Suite struct PaneColumnsEmptyCaptionTests {

    /// An empty tree at depth 0 already draws the pane's "Folder is empty" placeholder in the same
    /// space; a caption too would render stacked against the placeholder's folder glyph.
    @Test func rootColumnNeverCaptionsAnEmptyTree() {
        for unexplored in [true, false] {
            for loading in [true, false] {
                #expect(PaneColumnsView.emptyCaption(rowsEmpty: true, depth: 0,
                                                     isUnexplored: unexplored, isLoading: loading, isBeingRead: false) == nil,
                        "the root column captioned (unexplored: \(unexplored), loading: \(loading))")
            }
        }
    }

    /// A column opened into a folder with nothing in it says so: the pane placeholder doesn't show
    /// once the tree has rows.
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

    /// A folder the walk reported but didn't read is not empty: `FileSyncManager` marks it
    /// `isUnexplored` and logs "shown as unexplored, not empty", and the column must keep that.
    @Test func anUnexploredFolderSaysItCannotBeRead() {
        #expect(PaneColumnsView.emptyCaption(rowsEmpty: true, depth: 1,
                                             isUnexplored: true, isLoading: false, isBeingRead: false) == .unreadable)
    }

    /// The pane's walk outranks unexplored: during the shallow first paint every directory is
    /// unexplored. The answer is silence; the walk's one busy indicator is `PaneBusyIndicator`.
    @Test func thePanesWalkSilencesEveryEmptyColumn() {
        for unexplored in [true, false] {
            for beingRead in [true, false] {
                #expect(PaneColumnsView.emptyCaption(rowsEmpty: true, depth: 1, isUnexplored: unexplored,
                                                     isLoading: true, isBeingRead: beingRead) == nil,
                        "a column spoke during the pane's walk (unexplored: \(unexplored), being read: \(beingRead))")
            }
        }
    }

    /// Under a type filter a column with no rows is filtered, not empty; an unread folder still says
    /// it can't be read.
    @Test func aColumnTheTypeFilterEmptiedSaysSo() {
        #expect(PaneColumnsView.emptyCaption(rowsEmpty: true, depth: 1, isUnexplored: false,
                                             isLoading: false, isBeingRead: false, typeFiltered: true) == .filteredOut)
        #expect(PaneColumnsView.emptyCaption(rowsEmpty: true, depth: 1, isUnexplored: true,
                                             isLoading: false, isBeingRead: false, typeFiltered: true) == .unreadable)
        #expect(PaneColumnsView.emptyCaption(rowsEmpty: true, depth: 0, isUnexplored: false,
                                             isLoading: false, isBeingRead: false, typeFiltered: true) == nil,
                "the pane's own filtered-out placeholder answers for the root column")
        #expect(PaneColumnsView.Caption.filteredOut.text == "No matching files")
    }

    // MARK: - Wording

    /// The loading state draws a spinner and no text. The apostrophe is U+2019, matching
    /// `DestinationFolderListing.emptyMessage` exactly.
    @Test func onlyTheTwoSettledStatesCarryText() {
        #expect(PaneColumnsView.Caption.empty.text == "Empty")
        #expect(PaneColumnsView.Caption.unreadable.text == "Can’t be read")
        #expect(PaneColumnsView.Caption.loading.text == nil)
    }
}

/// A folder being read is not a folder that can't be read: a column waiting for its listing shows a
/// spinner, not "Can't be read".
@Suite struct PaneColumnBeingReadCaptionTests {

    /// Unexplored, the pane's own walk finished, and a listing on its way.
    @Test func aDirectoryWithAListingInFlightShowsTheSpinner() {
        #expect(PaneColumnsView.emptyCaption(rowsEmpty: true, depth: 1, isUnexplored: true,
                                             isLoading: false, isBeingRead: true) == .loading,
                "a folder the app is actively reading was captioned as unreadable")
    }

    /// An in-flight request can't invent a caption where there was none: a populated column and the
    /// root column both stay silent.
    @Test func beingReadNeverAddsACaptionWhereThereWasNotOne() {
        #expect(PaneColumnsView.emptyCaption(rowsEmpty: false, depth: 1, isUnexplored: true,
                                             isLoading: false, isBeingRead: true) == nil)
        #expect(PaneColumnsView.emptyCaption(rowsEmpty: true, depth: 0, isUnexplored: true,
                                             isLoading: false, isBeingRead: true) == nil)
    }

    /// A genuinely empty folder stays "Empty" while a request about it is outstanding.
    @Test func anEmptyWalkedFolderIsStillEmptyWhileARequestIsOutstanding() {
        #expect(PaneColumnsView.emptyCaption(rowsEmpty: true, depth: 1, isUnexplored: false,
                                             isLoading: false, isBeingRead: true) == .empty)
    }
}

/// When a column asks for a directory the walk didn't read. Too eager duplicates the deep walk
/// during the shallow first paint; too rare leaves a column past `FileSyncManager.paneNodeBudget`
/// blank. The call sites (`.onAppear`, `.onChange`) can't be fired, so the rule is a pure static.
@Suite struct PaneColumnRequestRuleTests {

    /// Every cell of the table, pinned, so a third term added later has to decide about each.
    @Test(arguments: [
        // The one state that asks: the walk has settled and this folder was left unread.
        (false, true, true),
        // Never mid-walk: every directory is unexplored during the shallow paint.
        (true, true, false), (true, false, false),
        // Never for a folder that was read, or an empty one would be relisted on every render.
        (false, false, false),
    ])
    func theRequestRule(isLoading: Bool, isUnexplored: Bool, asks: Bool) {
        #expect(PaneColumnsView.asksForChildren(isLoading: isLoading, isUnexplored: isUnexplored) == asks,
                "loading \(isLoading), unexplored \(isUnexplored)")
    }
}

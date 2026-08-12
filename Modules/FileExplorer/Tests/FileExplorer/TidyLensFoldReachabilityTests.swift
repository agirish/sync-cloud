import Testing
import Foundation
@testable import FileExplorer

/// **Why `TidyLens.rename` is unreachable, held as a property rather than as a comment.**
///
/// `TidyView` still carries a whole apparatus behind `.rename` — `renameContent`, the `RenameLens`
/// view, `.names` arms in `lensActions` and `organizeSummary`. None of it can run: the rail's
/// selection goes through `resolvedForPresentation`, which folds `.names` into `.renames`, and
/// `.renames` searches as `.filing`. Risky names are drawn by `RenamePassLens.toFixSection`.
///
/// That is worth pinning rather than restating, for two opposite readers: someone deleting the
/// apparatus needs to know what makes it safe, and someone *un*-folding Names into its own rail
/// item needs this to fail so they find the code that wakes back up.
@Suite struct TidyLensFoldReachabilityTests {

    /// The fold itself: no rail selection survives `resolvedForPresentation` as `.names`.
    @Test func noPresentedRailItemIsTheFoldedNamesLens() {
        for lens in OrganizeLens.allCases {
            #expect(lens.resolvedForPresentation != .names,
                    "\(lens) presents as .names, which TidyView has no live apparatus for")
        }
    }

    /// And therefore no *presented* rail item searches as `.rename`, which is what
    /// `TidyView.effectiveLens` is computed from.
    @Test func noPresentedRailItemSearchesAsTheRenameLens() {
        for lens in OrganizeLens.allCases {
            #expect(lens.resolvedForPresentation.searchLens != .rename,
                    "\(lens) reaches TidyLens.rename — its dead arms are live again")
        }
        // Non-vacuity: the mapping that WOULD reach it still exists, so this is a statement about
        // the fold rather than about `.rename` having been quietly deleted.
        #expect(OrganizeLens.names.searchLens == .rename,
                "nothing maps to .rename any more — this suite is asserting nothing")
    }

    /// The lens that actually shows risky names now, so "unreachable" is paired with "and here is
    /// what replaced it" rather than leaving the feature unaccounted for.
    @Test func riskyNamesAreShownByTheRenamePass() {
        #expect(OrganizeLens.names.isFoldedIntoRenames)
        #expect(OrganizeLens.renames.searchLens == .filing)
        #expect(!OrganizeLens.renames.isFoldedIntoRenames, "the fold's destination folds into itself")
    }
}

import Testing
import Foundation
@testable import FileExplorer

/// **Why `WorkspaceLensKind.rename` is unreachable, held as a property rather than as a comment.**
///
/// `LensWorkspaceView` still carries a whole apparatus behind `.rename` — `renameContent`, the `RenameLens`
/// view, `.names` arms in `lensActions` and `organizeSummary`. None of it can run: the rail's
/// selection goes through `resolvedForPresentation`, which folds `.names` into `.renames`, and
/// `.renames` searches as `.filing`. Risky names are drawn by `RenamePassLens.toFixSection`.
///
/// That is worth pinning rather than restating, for two opposite readers: someone deleting the
/// apparatus needs to know what makes it safe, and someone *un*-folding Names into its own rail
/// item needs this to fail so they find the code that wakes back up.
@Suite struct LensFoldReachabilityTests {

    /// The fold itself: no rail selection survives `resolvedForPresentation` as `.names`.
    @Test func noPresentedRailItemIsTheFoldedNamesLens() {
        for lens in OrganizeLens.allCases {
            #expect(lens.resolvedForPresentation != .names,
                    "\(lens) presents as .names, which LensWorkspaceView has no live apparatus for")
        }
    }

    /// And therefore no *presented* rail item searches as `.rename`, which is what
    /// `LensWorkspaceView.effectiveLens` is computed from.
    @Test func noPresentedRailItemSearchesAsTheRenameLens() {
        for lens in OrganizeLens.allCases {
            #expect(lens.resolvedForPresentation.searchLens != .rename,
                    "\(lens) reaches WorkspaceLensKind.rename — its dead arms are live again")
        }
        // Non-vacuity: the mapping that WOULD reach it still exists, so this is a statement about
        // the fold rather than about `.rename` having been quietly deleted.
        #expect(OrganizeLens.names.searchLens == .rename,
                "nothing maps to .rename any more — this suite is asserting nothing")
    }

    /// **The call site, which is what actually applies the fold.**
    ///
    /// The three tests above are about `OrganizeLens`. `effectiveLens` is
    /// `organizeLens?.searchLens ?? lens`, and `organizeLens` is where `resolvedForPresentation` is
    /// invoked — drop it there (`railLens?.resolvedForPresentation` → `railLens`) and a stored
    /// `.names` selection reaches `.rename`, waking the whole apparatus, with every assertion above
    /// still green. A rule is only unreachable if the call site keeps making it so.
    @Test func theRailSelectionIsResolvedBeforeItBecomesASearchLens() throws {
        let view = try OrganizeScopeCallSiteTests.source("LensWorkspaceView.swift")
        let body = try OrganizeScopeCallSiteTests.body(of: "private var organizeLens: OrganizeLens? {",
                                                       in: view)
        #expect(body.contains("railLens?.resolvedForPresentation"),
                "the rail selection reaches `effectiveLens` unresolved — `.names` can present again")
        // And the other half of `effectiveLens`: its fallback is the workspace's lens, which is
        // `MacApp`'s to supply. This module cannot see `Workspace`, so what is pinned here is that
        // the fallback exists and is the workspace value rather than something rail-derived.
        #expect(try OrganizeScopeCallSiteTests.body(of: "private var effectiveLens: WorkspaceLensKind {", in: view)
                    .contains("organizeLens?.searchLens ?? lens"),
                "effectiveLens no longer resolves through organizeLens")
    }

    /// **The `WorkspaceLensKind` bridge never answers the folded case.** `OrganizeLens(.rename)` used to be
    /// `.names`, which handed every caller a value that must not be stored or presented and left
    /// each one to remember `resolvedForPresentation` — `Workspace.destination(for:)` was that
    /// caller. The bridge resolves now, so a destination minted from a `WorkspaceLensKind` cannot write the
    /// folded lens into a stored selection from outside the migration seam.
    @Test func theWorkspaceLensKindBridgeAnswersOnlyPresentedRailItems() {
        #expect(OrganizeLens(.rename) == .renames,
                "the bridge minted the folded lens — a caller storing it selects nothing on the rail")
        for lens in WorkspaceLensKind.allCases {
            guard let item = OrganizeLens(lens) else { continue }   // `.storage` is a workspace
            #expect(!item.isFoldedIntoRenames,
                    "\(lens.rawValue) bridges to a folded rail item")
            #expect(item.resolvedForPresentation == item,
                    "\(lens.rawValue) bridges to a lens that still needs resolving")
        }
    }

    /// The lens that actually shows risky names now, so "unreachable" is paired with "and here is
    /// what replaced it" rather than leaving the feature unaccounted for.
    @Test func riskyNamesAreShownByTheRenamePass() {
        #expect(OrganizeLens.names.isFoldedIntoRenames)
        #expect(OrganizeLens.renames.searchLens == .filing)
        #expect(!OrganizeLens.renames.isFoldedIntoRenames, "the fold's destination folds into itself")
    }
}

import Foundation
import SwiftUI
import Sync
import Testing
@testable import FileExplorer

/// §5.2's decided route for the folders that were already empty: the crowding strip's third
/// filter gets the removal sheet, the same one a landing's own emptied folders go through.
///
/// The build shipped the filter and the count without the button — the audit's G1. These are the
/// text rules that route it, tested as text (a SwiftUI `Button` is not drivable from a unit test),
/// plus a render smoke over the state that grew the control.
@MainActor
@Suite struct RestructureStandingEmptiesTests {

    /// The chip's tooltip promised a sheet "when Apply lands". Apply landed; the sentence had to
    /// stop describing a future and start describing the control under the list.
    @Test func theEmptiesChipPointsAtTheListItOpens() {
        let help = RestructureLens.crowdingHelp(.empty)
        #expect(!help.contains("when Apply lands"),
                "the promise this made came due — the button exists now")
        #expect(help.contains("Trash"), "the Trash-only rule is the reassurance, and it stays")
        #expect(RestructureLens.crowdingHelp(.passThrough).contains("Report-only"))
        #expect(RestructureLens.crowdingHelp(.singleFileLeaf).contains("Report-only"),
                "only the empties gained an action — the other two say why they did not")
    }

    /// The sheet's opening sentence is its whole claim about where the list came from, so the two
    /// origins say different things. The rule underneath — date buckets are debt, categories are
    /// destinations — is shared, and must stay in both.
    @Test func theSheetSaysWhichListItIsLookingAt() {
        let standing = RestructureRemovalSheet.introText(isStanding: true)
        let landing = RestructureRemovalSheet.introText(isStanding: false)
        #expect(standing != landing)
        #expect(standing.contains("already empty when the survey looked"))
        #expect(!standing.contains("this reorganisation itself emptied"),
                "no landing drained these — the provenance sentence must not claim one did")
        #expect(landing.contains("this reorganisation itself emptied"))
        for text in [standing, landing] {
            #expect(text.contains("Trash"))
            #expect(text.contains("Date buckets start ticked"))
        }
    }

    /// `"."` is the profile's own spelling for the tree root and the family a scattered removal
    /// gets. Rendered raw it heads the card with a full stop.
    @Test func aRootLevelLandingIsHeadedInWords() {
        #expect(RestructureLens.familyHeading(".") == "Across the tree")
        #expect(RestructureLens.familyHeading("Finance/US/Income Tax")
                    == "Finance/US/Income Tax",
                "every real family renders as itself — this rule has exactly one special case")
    }

    /// The state that grew the control: a clean tree whose only remaining work is the crowding
    /// strip, with the empties filter open. A layout crash fails here rather than on a real tree.
    @Test func theLensRendersTheEmptiesListWithItsRemovalButton() {
        let lens = RestructureLens(
            findings: [], hasProfile: true, folderCount: 3013,
            deadWeight: ["Travel/2019": .empty,
                         "Finance/IN/SBI NRE/2013-2014": .empty,
                         "Work/HPE/Offer Letter": .singleFileLeaf],
            accent: .blue, onReveal: { _ in }, hasReviewed: true,
            onRemoveStandingEmpties: {})
        let hosting = NSHostingView(rootView: lens.frame(width: 640, height: 480))
        hosting.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        hosting.layoutSubtreeIfNeeded()
        #expect(hosting.fittingSize.width > 0)
    }

    /// The sheet the button opens, in its standing form.
    @Test func theStandingSheetRendersItsCandidates() {
        let sheet = RestructureRemovalSheet(
            family: ".",
            candidates: [
                .init(path: "Travel/2019", isStillEmpty: true),
                .init(path: "Finance/IN/SBI NRE/Statements", isStillEmpty: true),
                .init(path: "Health/Dental/2024", isStillEmpty: false),
            ],
            accent: .blue, isStanding: true,
            onRemove: { _ in .landed(caveat: nil) }, onClose: {})
        let hosting = NSHostingView(rootView: sheet.frame(width: 480, height: 400))
        hosting.frame = NSRect(x: 0, y: 0, width: 480, height: 400)
        hosting.layoutSubtreeIfNeeded()
        #expect(hosting.fittingSize.width > 0)
    }
}

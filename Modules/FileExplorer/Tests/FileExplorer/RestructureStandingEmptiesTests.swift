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

    /// *Emptied* is a provenance claim: something drained these. True of a landing's folders,
    /// false of the ones that were empty all along.
    @Test func theTitleDoesNotClaimSomethingEmptiedThem() {
        #expect(RestructureRemovalSheet.titleText(isStanding: true) == "Remove empty folders")
        #expect(RestructureRemovalSheet.titleText(isStanding: false) == "Remove emptied folders")
    }

    /// One folder trashed used to read "1 emptied folders removed" — the removal is the landing
    /// most likely to have a count of one, and the ledger sentence is what its card carries.
    @Test func theLedgerCountsReadInTheSingular() {
        var outcome = FileSyncManager.RestructureApplyOutcome()
        outcome.removedEmpty = 1
        outcome.foldersMovedWhole = 1
        #expect(outcome.summary.contains("1 empty folder removed"))
        #expect(outcome.summary.contains("1 folder carried whole"))
        var many = FileSyncManager.RestructureApplyOutcome()
        many.removedEmpty = 3
        many.foldersMovedWhole = 2
        #expect(many.summary.contains("3 empty folders removed"))
        #expect(many.summary.contains("2 folders carried whole"))
        // The DURABLE record, which outlives the sheet that made the provenance split. §5.2's
        // standing empties were empty all along — nothing emptied them — so this sentence may
        // not say "emptied" the way a landing-scoped removal could.
        #expect(!many.summary.contains("emptied"),
                "the ledger card carries this sentence for both removal origins")
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

    // MARK: The crowding lists, grouped (O9)

    /// Below the threshold a flat list is the better answer — grouping a dozen paths adds a
    /// disclosure to open before anything can be read. Both sides of the boundary are asserted,
    /// because a threshold tested on one side is a constant, not a rule.
    @Test func shortCrowdingListsStayFlat() {
        // The VALUE, not just the boundary: deriving the fixture from the constant compares the
        // rule to itself, and 25 or 60 would both have passed.
        #expect(RestructureLens.crowdingGroupingThreshold == 40)
        let few = (1...RestructureLens.crowdingGroupingThreshold).map { "Finance/\($0)" }
        #expect(RestructureLens.crowdingBranches(few) == nil)
        #expect(RestructureLens.crowdingBranches(few + ["Finance/extra"]) != nil,
                "one past the threshold groups")
        #expect(RestructureLens.crowdingBranches([]) == nil)
    }

    /// Grouped by top-level folder, biggest branch first — the pile worth opening leads — with
    /// the paths inside each sorted and every path accounted for.
    @Test func longCrowdingListsGroupByBranchBiggestFirst() throws {
        var paths = (1...30).map { "Work/\($0)" }
        paths += (1...8).map { "Finance/\($0)" }
        paths += (1...5).map { "Travel/\($0)" }
        paths.append("Loose")
        let groups = try #require(RestructureLens.crowdingBranches(paths))

        #expect(groups.map(\.branch) == ["Work", "Finance", "Travel", "Loose"])
        #expect(groups.map(\.paths.count) == [30, 8, 5, 1])
        #expect(groups.flatMap(\.paths).count == paths.count, "no path is dropped")
        #expect(Set(groups.flatMap(\.paths)) == Set(paths))
        // Pinned as a literal on a group whose INPUT order is not already sorted — comparing a
        // list to its own `sorted()` is the model against itself, and the Finance group happened
        // to arrive in order anyway.
        #expect(groups[0].paths.prefix(3) == ["Work/1", "Work/10", "Work/11"])
        // A top-level folder is its own branch rather than being dropped for having no first
        // component to group under.
        #expect(groups.last?.paths == ["Loose"])
    }

    /// Two branches of equal size order by name, so the list does not reshuffle between renders.
    @Test func equalBranchesOrderByName() throws {
        let paths = (1...21).map { "Zulu/\($0)" } + (1...21).map { "Alpha/\($0)" }
        let groups = try #require(RestructureLens.crowdingBranches(paths))
        #expect(groups.map(\.branch) == ["Alpha", "Zulu"])
    }

    /// The real tree's three classes: the two big ones group, and the empties — 20 of them —
    /// stay flat, which is also what keeps their removal button one click from the chip.
    @Test func theRealTreesEmptiesStayFlatAndKeepTheirButtonReachable() {
        #expect(RestructureLens.crowdingBranches((1...503).map { "F/\($0)" }) != nil)
        #expect(RestructureLens.crowdingBranches((1...86).map { "F/\($0)" }) != nil)
        #expect(RestructureLens.crowdingBranches((1...20).map { "F/\($0)" }) == nil)
    }

    // MARK: The two decisions the button rests on

    /// The button's own gate. A render smoke test cannot see this — deleting the whole button
    /// block left the entire FileExplorer package green — so the decision is a rule, and the
    /// scan below pins that the view still asks it.
    @Test func onlyTheEmptiesEndInATrashRoute() {
        #expect(RestructureLens.offersStandingRemoval(.empty, pathCount: 3, hasHandler: true))
        for other in [DeadWeightClass.passThrough, .singleFileLeaf] {
            #expect(!RestructureLens.offersStandingRemoval(other, pathCount: 3, hasHandler: true),
                    "a report-only class must not offer to trash anything")
        }
        #expect(!RestructureLens.offersStandingRemoval(.empty, pathCount: 0, hasHandler: true))
        #expect(!RestructureLens.offersStandingRemoval(.empty, pathCount: 3, hasHandler: false),
                "no handler means no button, rather than one that does nothing")
    }

    /// What the sheet is allowed to be seeded with. Widening this filter to "anything that is not
    /// pass-through" survived the whole package, and it routes folders that hold a file into a
    /// sheet whose own sentence says they were empty.
    @Test func onlyWhollyEmptyFoldersAreOfferedForTheTrash() {
        let classified: [String: DeadWeightClass] = [
            "Travel/2019": .empty,
            "Finance/IN/SBI NRE/2013-2014": .empty,
            "Work/HPE/Offer Letter": .singleFileLeaf,
            "Work/MapR": .passThrough,
        ]
        #expect(LensWorkspaceView.standingEmptyPaths(in: classified)
                    == ["Finance/IN/SBI NRE/2013-2014", "Travel/2019"],
                "sorted, and the two folders that hold something are not in it")
        #expect(LensWorkspaceView.standingEmptyPaths(in: [:]) == [])
    }

    /// The rules above are one revert away from being unused, and the display rules in this
    /// change were each shown to survive being unwired. This pins every call site.
    @Test func theSurfacesActuallyAskTheseRules() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/FileExplorer")
        func read(_ name: String) throws -> String {
            try String(contentsOf: sources.appendingPathComponent(name), encoding: .utf8)
        }
        let lens = try read("RestructureLens.swift")
        #expect(lens.contains("Self.offersStandingRemoval(weightClass, pathCount: paths.count,"),
                "the button's gate is the rule, not an inline condition")
        #expect(lens.contains("Text(Self.familyHeading(record.family))"),
                "the card renders a root family in words")
        let host = try read("LensWorkspaceView.swift")
        #expect(host.contains("Self.standingEmptyPaths(in: scopedDeadWeight)"))
        let sheet = try read("RestructureRemovalSheet.swift")
        #expect(sheet.contains("Text(Self.titleText(isStanding: isStanding))"))
        #expect(sheet.contains("Text(Self.introText(isStanding: isStanding))"),
                "both halves of the provenance split have to be wired, not just written")
        let plan = try read("RestructurePlanSheet.swift")
        #expect(plan.contains("Text(planFamily)"),
                "the header names the folder being planned, never a bare empty family")
    }

    /// The ⌘Z action name is the one place `familyLabel` earns its keep, and reverting its call
    /// site to `lastPathComponent` survived all 3,054 Sync tests.
    @Test func theGroupedUndoNamesARootFamilyInWords() throws {
        let engine = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sync/Sources/Sync/FileSyncManager+RestructureApply.swift")
        let text = try String(contentsOf: engine, encoding: .utf8)
        #expect(text.contains("RestructurePaths.familyLabel(manifest.family)"),
                "\"Reorganise \" with nothing after it was a real menu item")
        #expect(!text.contains("\"Reorganise \\((manifest.family as NSString).lastPathComponent)\""))
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
            candidates: [
                .init(path: "Travel/2019", isStillEmpty: true),
                .init(path: "Finance/IN/SBI NRE/Statements", isStillEmpty: true),
                .init(path: "Health/Dental/2024", isStillEmpty: false),
            ],
            accent: .blue, isStanding: true,
            onRemove: { _ in .landed(removed: 2, skippedCount: 0, caveat: nil) },
            onClose: {})
        let hosting = NSHostingView(rootView: sheet.frame(width: 480, height: 400))
        hosting.frame = NSRect(x: 0, y: 0, width: 480, height: 400)
        hosting.layoutSubtreeIfNeeded()
        #expect(hosting.fittingSize.width > 0)
    }
}

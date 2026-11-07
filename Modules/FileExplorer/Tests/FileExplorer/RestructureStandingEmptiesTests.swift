import Foundation
import SwiftUI
import Sync
import Testing
@testable import FileExplorer

/// The route for folders that were already empty: the crowding strip's empties filter opens the
/// removal sheet, the same one a landing's emptied folders go through. The text rules that route
/// it are tested as text (a SwiftUI `Button` isn't drivable from a unit test), plus a render
/// smoke over the state that shows the control.
@MainActor
@Suite struct RestructureStandingEmptiesTests {

    /// The chip's tooltip describes the control under the list, not a future "when Apply lands".
    @Test func theEmptiesChipPointsAtTheListItOpens() {
        let help = RestructureLens.crowdingHelp(.empty)
        #expect(!help.contains("when Apply lands"),
                "the promise this made came due — the button exists now")
        #expect(help.contains("Trash"), "the Trash-only rule is the reassurance, and it stays")
        #expect(RestructureLens.crowdingHelp(.passThrough).contains("Report-only"))
        #expect(RestructureLens.crowdingHelp(.singleFileLeaf).contains("Report-only"),
                "only the empties gained an action — the other two say why they did not")
    }

    /// *Emptied* is a provenance claim, that something drained these: true of a landing's folders,
    /// false of ones empty all along.
    @Test func theTitleDoesNotClaimSomethingEmptiedThem() {
        #expect(RestructureRemovalSheet.titleText(isStanding: true) == "Remove empty folders")
        #expect(RestructureRemovalSheet.titleText(isStanding: false) == "Remove emptied folders")
    }

    /// The ledger counts read in the singular: a removal is the landing most likely to count one,
    /// and its card carries this sentence.
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
        // The durable record, which outlives the sheet that made the provenance split. Standing
        // empties were empty all along, so this sentence must not say "emptied".
        #expect(!many.summary.contains("emptied"),
                "the ledger card carries this sentence for both removal origins")
    }

    /// The sheet's opening sentence says where the list came from, so the two origins differ. The
    /// rule underneath (date buckets are debt, categories are destinations) is shared by both.
    @Test func theSheetSaysWhichListItIsLookingAt() {
        let standing = RestructureRemovalSheet.introText(isStanding: true)
        let landing = RestructureRemovalSheet.introText(isStanding: false)
        #expect(standing != landing)
        #expect(standing.contains("already empty when the survey looked"))
        #expect(!standing.contains("this reorganization itself emptied"),
                "no landing drained these — the provenance sentence must not claim one did")
        #expect(landing.contains("this reorganization itself emptied"))
        for text in [standing, landing] {
            #expect(text.contains("Trash"))
            #expect(text.contains("Date buckets start ticked"))
        }
    }

    /// `"."` is the profile's spelling for the tree root, and the family a scattered removal gets;
    /// rendered raw it would head the card with a full stop.
    @Test func aRootLevelLandingIsHeadedInWords() {
        #expect(RestructureLens.familyHeading(".") == "Across the tree")
        #expect(RestructureLens.familyHeading("Finance/US/Income Tax")
                    == "Finance/US/Income Tax",
                "every real family renders as itself — this rule has exactly one special case")
    }

    // MARK: The crowding lists, grouped (O9)

    /// Below the threshold a flat list is better: grouping a dozen paths adds a disclosure to open
    /// before anything can be read. Both sides of the boundary are asserted.
    @Test func shortCrowdingListsStayFlat() {
        // The value, not just the boundary: a fixture derived from the constant compares the rule
        // to itself.
        #expect(RestructureLens.crowdingGroupingThreshold == 40)
        let few = (1...RestructureLens.crowdingGroupingThreshold).map { "Finance/\($0)" }
        #expect(RestructureLens.crowdingBranches(few) == nil)
        #expect(RestructureLens.crowdingBranches(few + ["Finance/extra"]) != nil,
                "one past the threshold groups")
        #expect(RestructureLens.crowdingBranches([]) == nil)
    }

    /// Grouped by top-level folder, biggest branch first so the pile worth opening leads, with each
    /// group's paths sorted and every path accounted for.
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
        // A literal, on a group whose input order isn't already sorted: comparing a list to its
        // own `sorted()` checks the model against itself.
        #expect(groups[0].paths.prefix(3) == ["Work/1", "Work/10", "Work/11"])
        // A top-level folder is its own branch, not dropped for having no component to group under.
        #expect(groups.last?.paths == ["Loose"])
    }

    /// Two branches of equal size order by name, so the list doesn't reshuffle between renders.
    @Test func equalBranchesOrderByName() throws {
        let paths = (1...21).map { "Zulu/\($0)" } + (1...21).map { "Alpha/\($0)" }
        let groups = try #require(RestructureLens.crowdingBranches(paths))
        #expect(groups.map(\.branch) == ["Alpha", "Zulu"])
    }

    /// Realistic class sizes: the two big classes group, and a couple of dozen empties stay flat,
    /// which keeps their removal button one click from the chip.
    @Test func theRealTreesEmptiesStayFlatAndKeepTheirButtonReachable() {
        #expect(RestructureLens.crowdingBranches((1...503).map { "F/\($0)" }) != nil)
        #expect(RestructureLens.crowdingBranches((1...86).map { "F/\($0)" }) != nil)
        #expect(RestructureLens.crowdingBranches((1...20).map { "F/\($0)" }) == nil)
    }

    // MARK: The two decisions the button rests on

    /// The button's own gate. A render smoke test can't see it, so the decision is a rule, and the
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

    /// What the sheet may be seeded with: wholly empty folders only. Widening it to "anything not
    /// pass-through" would route folders holding a file into a sheet that says they were empty.
    @Test func onlyWhollyEmptyFoldersAreOfferedForTheTrash() {
        let classified: [String: DeadWeightClass] = [
            "Travel/2019": .empty,
            "Finance/IN/SBI NRE/2013-2014": .empty,
            "Work/EMP/Offer Letter": .singleFileLeaf,
            "Work/Acme": .passThrough,
        ]
        #expect(LensWorkspaceView.standingEmptyPaths(in: classified)
                    == ["Finance/IN/SBI NRE/2013-2014", "Travel/2019"],
                "sorted, and the two folders that hold something are not in it")
        #expect(LensWorkspaceView.standingEmptyPaths(in: [:]) == [])
    }

    /// The rules above are one revert away from being unused, so this pins every call site.
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

    /// The ⌘Z action name is where `familyLabel` earns its keep, and no Sync test catches its call
    /// site reverting to `lastPathComponent`.
    @Test func theGroupedUndoNamesARootFamilyInWords() throws {
        let engine = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sync/Sources/Sync/FileSyncManager+RestructureApply.swift")
        let text = try String(contentsOf: engine, encoding: .utf8)
        #expect(text.contains("RestructurePaths.familyLabel(manifest.family)"),
                "\"Reorganize \" with nothing after it was a real menu item")
        #expect(!text.contains("\"Reorganize \\((manifest.family as NSString).lastPathComponent)\""))
    }

    /// A clean tree whose only remaining work is the crowding strip, with the empties filter open,
    /// and the button visibly there. An ink floor can't say that, since the strip inks plenty
    /// either way, so the handler is the only difference between the two renders.
    @Test func theLensRendersTheEmptiesListWithItsRemovalButton() throws {
        func lens(remover: (() -> Void)?) -> RestructureLens {
            RestructureLens(
                findings: [], hasProfile: true, folderCount: 3013,
                deadWeight: ["Travel/2019": .empty,
                             "Finance/IN/SBI NRE/2013-2014": .empty,
                             "Work/EMP/Offer Letter": .singleFileLeaf],
                accent: .blue, onReveal: { _ in }, hasReviewed: true,
                onRemoveStandingEmpties: remover,
                // The button lives under the expanded empty list, and the filter is state a chip
                // toggles, so without this seed both renders would show a closed strip.
                initialCrowdingFilter: .empty)
        }
        let without = try #require(RestructureRender.raster(lens(remover: nil),
                                                            width: 640, height: 480))
        let with = try #require(RestructureRender.raster(lens(remover: {}),
                                                         width: 640, height: 480))
        #expect(RestructureRender.inkedPixels(without) > 1000, "the strip drew either way")
        #expect(RestructureRender.differingPixels(without, with) > 100,
                "\u{201c}Remove empty folders\u{2026}\u{201d} is on the strip")

        let lens = lens(remover: {})
        // An ink floor, not a width: `fittingSize.width > 0` holds for an empty `VStack`.
        let rep = try #require(RestructureRender.raster(lens, width: 640, height: 480))
        #expect(RestructureRender.inkedPixels(rep) > 1000)
    }

    /// The sheet the button opens, in its standing form.
    @Test func theStandingSheetRendersItsCandidates() throws {
        let sheet = RestructureRemovalSheet(
            candidates: [
                .init(path: "Travel/2019", isStillEmpty: true),
                .init(path: "Finance/IN/SBI NRE/Statements", isStillEmpty: true),
                .init(path: "Health/Dental/2024", isStillEmpty: false),
            ],
            accent: .blue, isStanding: true,
            onRemove: { _ in .landed(removed: 2, skippedCount: 0, caveat: nil) },
            onClose: {})
        // An ink floor, not a width: `fittingSize.width > 0` holds for an empty `VStack`.
        let rep = try #require(RestructureRender.raster(sheet, width: 480, height: 400))
        #expect(RestructureRender.inkedPixels(rep) > 1000)
    }
}

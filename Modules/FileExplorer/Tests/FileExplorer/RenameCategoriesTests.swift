import Testing
import Foundation
@testable import Sync
@testable import FileExplorer

/// The category-first reorganization of the rename backlog. The claims that could rot: the
/// partition is total (every plan with steps in exactly one section, skip-only plans in the
/// footnote), classification follows the most consequential step (a mixed folder is a judgment
/// call, never buried under "to pad"), sections keep consequence order and vanish at zero, the
/// groups are immediate parents in path order, and the inline sample is of the section's own
/// kind — a ridden-along pad must not stand in as proof of a naming.
@Suite struct RenameCategoriesTests {

    private func step(_ kind: RenameStep.Kind, _ current: String = "a.pdf",
                      _ proposed: String = "b.pdf") -> RenameStep {
        RenameStep(currentPath: "/T/\(current)", currentName: current, proposedName: proposed,
                   kind: kind, reason: "why")
    }

    private func plan(_ relativePath: String, steps: [RenameStep],
                      skips: [RenameSkip] = []) -> RenamePlan {
        RenamePlan(folderPath: "/root/" + relativePath, relativePath: relativePath,
                   scheme: .monthNumber, steps: steps, skips: skips)
    }

    @Test func classificationFollowsTheMostConsequentialStep() {
        #expect(RenameCategories.category(of: plan("A", steps: [step(.tidied)])) == .pad)
        #expect(RenameCategories.category(of: plan("B", steps: [step(.renumbered), step(.tidied)])) == .reshuffle)
        // The mixed case that must not be buried: nine pads and one naming is a judgment call.
        #expect(RenameCategories.category(of:
            plan("C", steps: [step(.tidied), step(.tidied), step(.placed)])) == .name)
        // Skip-only plans have no category — they are the footnote.
        #expect(RenameCategories.category(of:
            plan("D", steps: [], skips: [RenameSkip(path: "/x", fileName: "x", reason: "r")])) == nil)
    }

    @Test func thePartitionIsTotalAndSectionsVanishAtZero() {
        let plans = [
            plan("Finance/IN/SBI/2019", steps: [step(.tidied)]),
            plan("Finance/IN/SBI/2020", steps: [step(.tidied)]),
            plan("Scans/Aditi", steps: [step(.placed)]),
            plan("Health/Records", steps: [], skips: [RenameSkip(path: "/y", fileName: "y", reason: "r")]),
        ]
        let sections = RenameCategories.sections(plans)
        // No reshuffle plans → no reshuffle section, not an empty one.
        #expect(sections.map(\.category) == [.name, .pad])
        let sectioned = sections.flatMap(\.plans).map(\.relativePath)
        let leftAlone = RenameCategories.leftAlone(plans).map(\.relativePath)
        #expect(Set(sectioned).count == sectioned.count)
        #expect(Set(sectioned + leftAlone) == Set(plans.map(\.relativePath)))
    }

    @Test func groupsAreImmediateParentsInPathOrder() {
        let plans = [
            plan("Finance/US/eTrade/2015", steps: [step(.tidied)]),
            plan("Finance/IN/SBI/2019", steps: [step(.tidied)]),
            plan("Finance/IN/SBI/2020", steps: [step(.tidied)]),
        ]
        let pad = RenameCategories.sections(plans).first { $0.category == .pad }!
        #expect(pad.groups.map(\.parent) == ["Finance/IN/SBI", "Finance/US/eTrade"])
        #expect(pad.groups[0].plans.map(\.relativePath) == ["Finance/IN/SBI/2019", "Finance/IN/SBI/2020"])
    }

    @Test func theSampleIsOfTheSectionsOwnKind() {
        // A mixed plan in the name section: its proof must be the naming, not a pad that
        // happens to come first in plan order.
        let mixed = plan("C", steps: [step(.tidied, "1. Jan.pdf", "01. Jan.pdf"),
                                      step(.placed, "IMG_4501.pdf", "07. Jul.pdf")])
        let sample = RenameCategories.sampleStep(mixed, category: .name)
        #expect(sample?.currentName == "IMG_4501.pdf")
    }

    @Test func onlyThePadCategoryStartsCollapsed() {
        // Pad is the mechanical bulk this screen accepts wholesale; the judgment categories'
        // rows need eyes before their buttons, so they start open. A new category added later
        // fails this sweep until it declares which kind it is.
        for category in RenameCategories.Category.allCases {
            #expect(RenameCategories.groupsStartCollapsed(category) == (category == .pad),
                    "\(category) has the wrong default disclosure")
        }
    }

    @Test func aToggleAlwaysMeansTheOtherStateOfTheDefault() {
        // Stored as a toggled set so the category default keeps applying to groups the next
        // scan adds — toggling must invert whatever the default is, both ways.
        #expect(RenameCategories.isCollapsed(category: .pad, toggled: false))
        #expect(!RenameCategories.isCollapsed(category: .pad, toggled: true))
        #expect(!RenameCategories.isCollapsed(category: .name, toggled: false))
        #expect(RenameCategories.isCollapsed(category: .name, toggled: true))
    }

    @Test func theKindCountClaimsOnlyItsOwnKind() {
        // The pill says "1 to name"; the bulk button says "Rename 3 files" — different claims,
        // both true, and the kind count must not inflate to the folder total.
        let mixed = plan("C", steps: [step(.tidied), step(.tidied), step(.placed)])
        let section = RenameCategories.sections([mixed]).first!
        #expect(section.category == .name)
        #expect(section.kindCount == 1)
        #expect(section.fileCount == 3)
    }
}

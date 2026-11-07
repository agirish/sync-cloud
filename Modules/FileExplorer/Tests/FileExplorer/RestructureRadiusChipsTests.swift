import Foundation
import SwiftUI
import Sync
import Testing
@testable import FileExplorer

/// The blast radius once a draft makes it knowable: the tertiary-grey sentence becomes chips
/// carrying the numbers the plan derived.
@MainActor
@Suite struct RestructureRadiusChipsTests {

    private static func manifest(_ actions: [RestructureManifest.Action])
        -> RestructureManifest {
        RestructureManifest(profileId: "p", manifestId: "m", createdAt: "t",
                            family: "Finance/US/Income Tax", kind: .shape, actions: actions)
    }

    /// Derived, never pasted: the host builds the info from the manifest rather than the card
    /// estimating from the finding.
    @Test func theCountsComeFromTheManifest() {
        let info = LensWorkspaceView.plannedInfo(of: Self.manifest([
            .init(action: .renameDir, src: "F/2013/Federal", dst: "F/2013/Forms",
                  filesCarried: 12),
            .init(action: .moveFile, src: "F/2013/State/a.pdf", dst: "F/2013/Forms/a.pdf"),
            .init(action: .moveFile, src: "F/2013/State/b.pdf", dst: "F/2013/Forms/b.pdf"),
            .init(action: .keep, src: "F/2013/Transcripts"),
        ]))
        // Three, not four: `keep` rows are the manifest's signature block, and counting them
        // would overstate "Review N operations".
        #expect(info.operations == 3)
        #expect(info.renames == 1)
        #expect(info.merges == 1, "one source folder is drained")
        #expect(info.filesMove == 2)
        #expect(info.summary == RestructureLedger(of: Self.manifest([
            .init(action: .renameDir, src: "F/2013/Federal", dst: "F/2013/Forms",
                  filesCarried: 12),
            .init(action: .moveFile, src: "F/2013/State/a.pdf", dst: "F/2013/Forms/a.pdf"),
            .init(action: .moveFile, src: "F/2013/State/b.pdf", dst: "F/2013/Forms/b.pdf"),
            .init(action: .keep, src: "F/2013/Transcripts"),
        ])).summary, "the sentence and the chips read one ledger")
    }

    /// A whole-folder carry is its own word, in the chips and the sentence alike: the ledger
    /// sentence a line below prints it as its own clause, and the chips are that sentence's
    /// numbers, so folding it into "renames" would make the two disagree.
    @Test func aWholeFolderCarryIsCarriedNotRenamed() {
        let manifest = Self.manifest([
            .init(action: .moveDir, src: "Work/Badge", dst: "Work/Acme/Badge",
                  filesCarried: 7, movesWholeFolder: true),
        ])
        let info = LensWorkspaceView.plannedInfo(of: manifest)
        #expect(info.renames == 0)
        #expect(info.carried == 1)
        #expect(info.merges == 0, "a relocation drains nothing")
        #expect(info.filesMove == 0, "no file was moved one at a time")

        // The two must agree word for word, because they render one line apart.
        let sentence = RestructureLedger(of: manifest).summary
        #expect(sentence.contains("0 renames"))
        #expect(sentence.contains("1 folder carried whole"))
        #expect(info.radiusChips.map(\.text) == ["1 folder carried"])
        #expect(sentence.contains("7 carried"),
                "the relocation's files ride along and the ledger has to count them")
    }

    /// Zero counts stay out of the row: a rename-only plan says "3 renames", not
    /// "3 renames · 0 merges · 0 files move".
    @Test func onlyTheNonZeroCountsBecomeChips() {
        let renamesOnly = PlannedPlanInfo(operations: 3, summary: "s",
                                          renames: 3, carried: 0, merges: 0, filesMove: 0)
        #expect(renamesOnly.radiusChips.map(\.text) == ["3 renames"])

        let full = PlannedPlanInfo(operations: 9, summary: "s",
                                   renames: 3, carried: 0, merges: 2, filesMove: 41)
        #expect(full.radiusChips.map(\.text) == ["3 renames", "2 merges", "41 files move"])

        let singular = PlannedPlanInfo(operations: 2, summary: "s",
                                       renames: 1, carried: 1, merges: 1, filesMove: 1)
        #expect(singular.radiusChips.map(\.text)
                    == ["1 rename", "1 folder carried", "1 merge", "1 file moves"])
    }

    /// The warm tint marks the chips whose numbers are files leaving where they are: a moved file
    /// and a carried folder both do; a rename and a merge count folders. Tinting every chip would
    /// say nothing.
    @Test func onlyTheFileMovingChipsAreWarm() {
        let full = PlannedPlanInfo(operations: 9, summary: "s",
                                   renames: 3, carried: 1, merges: 2, filesMove: 41)
        #expect(full.radiusChips.map(\.movesFiles) == [false, true, false, true])
    }

    /// With no draft there are no numbers to state, and the prose sentence is the honest answer.
    @Test func aCardWithNoDraftKeepsItsSentence() {
        let noCounts = PlannedPlanInfo(operations: 0, summary: "s",
                                       renames: 0, carried: 0, merges: 0, filesMove: 0)
        #expect(noCounts.radiusChips.isEmpty,
                "an empty chip row falls through to the blast-radius sentence")
        #expect(RestructureLens.blastRadius(for: StructureFinding(
            family: "F",
            schemes: [.init(vocabulary: ["a"], members: ["2013", "2014"]),
                      .init(vocabulary: ["b"], members: ["2016"])])) != nil)
    }

    /// Pins the host's wiring: the derivation is a static function and the render test builds its
    /// own value, so unwiring the host would pass every test above.
    @Test func theHostBuildsEveryCardsInfoFromTheSharedDerivation() throws {
        let host = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/FileExplorer/LensWorkspaceView.swift"),
            encoding: .utf8)
        #expect(host.contains("(key.findingId, Self.plannedInfo(of: draft.manifest))"),
                "every drafted card's chips come from the one derivation")
        // Exactly one construction of the value in the host, the shared derivation; a second
        // would let the chips and the sentence disagree.
        #expect(host.components(separatedBy: "PlannedPlanInfo(").count - 1 == 1,
                "the card's info is built in one place")
    }

    /// The chips replace the sentence rather than join it: two statements of one cost, one vaguer,
    /// would come to disagree.
    @Test func theCardShowsChipsOrTheSentenceNeverBoth() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/FileExplorer/RestructureLens.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        #expect(text.contains("if let chips = plannedPlans[finding.id]?.radiusChips, !chips.isEmpty"))
        #expect(text.contains("} else if let radius = Self.blastRadius(for: finding) {"),
                "the sentence is the fallback branch, not a sibling")
    }

    /// The chips are drawn: the drafted card is compared against the same card with no draft, so
    /// deleting the chip row fails.
    @Test func aDraftedCardRendersItsChips() throws {
        let finding = StructureFinding(
            family: "Finance/US/Income Tax",
            schemes: [.init(vocabulary: ["forms"], members: ["2013", "2014"]),
                      .init(vocabulary: ["federal"], members: ["2016"])])
        func lens(planned: Bool) -> RestructureLens {
            RestructureLens(
                findings: [finding], hasProfile: true, folderCount: 10,
                accent: .blue, onReveal: { _ in }, onPlan: { _ in },
                plannedPlans: planned
                    ? [finding.id: PlannedPlanInfo(operations: 9, summary: "s", renames: 3,
                                                   carried: 0, merges: 2, filesMove: 41)]
                    : [:],
                hasReviewed: true)
        }
        let undrafted = try #require(RestructureRender.raster(lens(planned: false),
                                                              width: 640, height: 300))
        let drafted = try #require(RestructureRender.raster(lens(planned: true),
                                                            width: 640, height: 300))
        #expect(RestructureRender.inkedPixels(undrafted) > 0, "the card drew at all")
        #expect(RestructureRender.differingPixels(undrafted, drafted) > 200,
                "the radius chips are on the drafted card")
    }
}

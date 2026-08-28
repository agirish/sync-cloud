import Foundation
import SwiftUI
import Sync
import Testing
@testable import FileExplorer

/// §5.4's sheet rules, tested as the pure text rules they are — the lens's own `cleanTitle` /
/// `revealTitle` pattern. The derivation itself is `RestructurePlannerTests`' (in Sync); this
/// suite owns what the sheet SAYS about it.
@MainActor
@Suite struct RestructurePlanSheetTests {

    private static func shapeFinding(
        schemes: [StructureFinding.Scheme],
        drift: [String] = [], shapeless: [String] = []) -> StructureFinding {
        StructureFinding(kind: .shape, family: "Finance/US/Income Tax", schemes: schemes,
                         drift: drift, shapeless: shapeless)
    }

    // MARK: The chooser's labels (§5.4 step 1)

    /// *The most recent* is derived from the members' year tokens, never from scheme order — the
    /// flagship's own trap: its most recent vouched scheme is the `IRS Docs - 2023/2024` pair,
    /// which sorts nowhere near first.
    @Test func mostRecentComesFromYearTokensNotSchemeOrder() {
        let finding = Self.shapeFinding(schemes: [
            .init(vocabulary: ["forms", "reference"], members: ["2016", "2017", "2018", "2019"]),
            .init(vocabulary: ["docs"], members: ["IRS Docs - 2023", "IRS Docs - 2024"]),
        ])
        #expect(RestructurePlanSheet.mostRecentSchemeIndex(of: finding) == 1)
        #expect(RestructurePlanSheet.schemeLabel(index: 0, in: finding) == "the largest group")
        #expect(RestructurePlanSheet.schemeLabel(index: 1, in: finding) == "the most recent")
    }

    /// One scheme wearing both labels reads as one chip, and a lone scheme is not "the largest
    /// group" of anything.
    @Test func labelsCombineAndALoneSchemeGetsNoMajorityLabel() {
        let both = Self.shapeFinding(schemes: [
            .init(vocabulary: ["forms"], members: ["2022", "2023", "2024"]),
            .init(vocabulary: ["docs"], members: ["2016", "2017"]),
        ])
        #expect(RestructurePlanSheet.schemeLabel(index: 0, in: both)
                == "the largest group · the most recent")
        let lone = Self.shapeFinding(schemes: [
            .init(vocabulary: ["forms"], members: ["2022", "2023"]),
        ])
        #expect(RestructurePlanSheet.schemeLabel(index: 0, in: lone) == nil,
                "a lone scheme is the only choice, not the largest of anything")
    }

    /// When the genuinely newest members are drift, there is no current shape — and saying so is
    /// the finding, not a failure to produce one (§5.4 step 1). The flagship's 2023–2025 are all
    /// drift; its newest vouched scheme stops at 2024.
    @Test func newestMembersBeingDriftMeansNoCurrentShape() {
        let flagshipShaped = Self.shapeFinding(
            schemes: [.init(vocabulary: ["docs"], members: ["IRS Docs - 2023", "IRS Docs - 2024"])],
            drift: ["2023", "2024", "2025"])
        #expect(RestructurePlanSheet.newestMembersAreDrift(flagshipShaped))

        let settled = Self.shapeFinding(
            schemes: [.init(vocabulary: ["forms"], members: ["2023", "2024"])],
            drift: ["2016"])
        #expect(!RestructurePlanSheet.newestMembersAreDrift(settled))
        #expect(!RestructurePlanSheet.newestMembersAreDrift(Self.shapeFinding(schemes: [])))
    }

    /// The year reader: period spans read their last year, embedded years read, non-years and
    /// five-digit runs read nothing.
    @Test func theYearTokenReaderIsExactlyFourDigitsInRange() {
        #expect(RestructurePlanSheet.maxYear(in: "2016-2019") == 2019)
        #expect(RestructurePlanSheet.maxYear(in: "IRS Docs - 2023") == 2023)
        #expect(RestructurePlanSheet.maxYear(in: "CA State") == nil)
        #expect(RestructurePlanSheet.maxYear(in: "20255") == nil)
        #expect(RestructurePlanSheet.maxYear(in: "1899") == nil)
        #expect(RestructurePlanSheet.maxYear(in: "Form 1098") == nil,
                "a form number is not a year")
    }

    // MARK: The review list

    /// The sheet groups primitives the way §5.4 words them: a merge is one line per
    /// source-into-target with its counts, in the order the manifest runs.
    @Test func operationLinesGroupMergesAndKeepManifestOrder() {
        let family = "Finance/US/Income Tax"
        let manifest = RestructureManifest(
            profileId: "p", manifestId: "m", createdAt: "t", family: family, kind: .shape,
            actions: [
                .init(action: .renameDir, src: "\(family)/2013/Federal Tax",
                      dst: "\(family)/2013/Forms", filesCarried: 12),
                .init(action: .moveFile, src: "\(family)/2013/State Tax (California)/a.pdf",
                      dst: "\(family)/2013/Forms/a.pdf"),
                .init(action: .moveFile, src: "\(family)/2013/State Tax (California)/b.pdf",
                      dst: "\(family)/2013/Forms/b.pdf"),
                .init(action: .moveDir, src: "\(family)/2013/State Tax (California)/Refund",
                      dst: "\(family)/2013/Forms/Refund"),
                .init(action: .keep, src: "\(family)/2013/Transcripts"),
            ])
        let lines = RestructurePlanSheet.operationLines(of: manifest)
        #expect(lines == [
            "2013 · rename Federal Tax → Forms (12 files)",
            "2013 · merge State Tax (California) into Forms (2 files, 1 folder)",
            "2013 · keep Transcripts",
        ])
    }

    /// Each refusal is its own sentence — a person reads why, not that.
    @Test func refusalSentencesAreDistinctAndNonEmpty() {
        let sentences = [
            RestructurePlanSheet.refusalText(.nothingMapped),
            RestructurePlanSheet.refusalText(.unknownFiles(source: "F/2016/A")),
            RestructurePlanSheet.refusalText(.unresolvableOrder(member: "2016")),
            RestructurePlanSheet.refusalText(.conflictingTargets("Forms", "forms")),
        ]
        #expect(Set(sentences).count == 4)
        #expect(sentences.allSatisfy { !$0.isEmpty })
        #expect(sentences[1].contains("F/2016/A"), "the refusal names the folder it is about")
        #expect(sentences[3].contains("Forms") && sentences[3].contains("forms"),
                "the clash names both spellings")
    }

    // MARK: The card's trigger (§5.7)

    /// *Plan…* creates; *Review N operations* reopens what exists. The pair never both show —
    /// one title, switched by whether a draft is saved.
    @Test func theTriggerOffersReviewOnceADraftExists() {
        #expect(RestructureLens.planTriggerTitle(planned: nil) == "Plan…")
        #expect(RestructureLens.planTriggerTitle(
            planned: PlannedPlanInfo(operations: 9, summary: "s")) == "Review 9 operations")
        #expect(RestructureLens.planTriggerTitle(
            planned: PlannedPlanInfo(operations: 1, summary: "s")) == "Review 1 operation")
    }

    // MARK: Render smoke

    /// The sheet renders offscreen against a dictionary-backed tree — layout crashes and
    /// unresolved bindings fail here rather than at first click.
    @Test func theSheetRendersAgainstAFixtureTree() {
        let family = "Finance/US/Income Tax"
        let finding = Self.shapeFinding(schemes: [
            .init(vocabulary: ["federal tax"], members: ["2013"]),
        ], drift: ["2014"])
        let files: [String: [String]] = [
            family: [], "\(family)/2013": [], "\(family)/2014": [],
            "\(family)/2013/Federal Tax": ["a.pdf"],
            "\(family)/2014/Notes": ["b.pdf"],
        ]
        let known = Set(files.keys)
        let tree = RestructureTreeView(
            childFolders: { path in
                guard known.contains(path) else { return nil }
                let prefix = path + "/"
                return known.compactMap { other in
                    guard other.hasPrefix(prefix),
                          !other.dropFirst(prefix.count).contains("/") else { return nil }
                    return String(other.dropFirst(prefix.count))
                }.sorted()
            },
            files: { files[$0] },
            fileCount: { files[$0]?.count })
        let sheet = RestructurePlanSheet(
            finding: finding, members: ["2013", "2014"], tree: tree, profileId: "p",
            accent: .blue, initialRows: nil, onExport: { _ in nil }, onClose: {})
        let hosting = NSHostingView(rootView: sheet.frame(width: 620, height: 560))
        hosting.frame = NSRect(x: 0, y: 0, width: 620, height: 560)
        hosting.layoutSubtreeIfNeeded()
        #expect(hosting.fittingSize.width > 0)
    }
}

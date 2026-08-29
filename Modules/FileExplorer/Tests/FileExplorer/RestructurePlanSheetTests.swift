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
            RestructurePlanSheet.refusalText(.invalidTargetName(target: "Tax/2024")),
            RestructurePlanSheet.refusalText(.targetTakenByFile(target: "Forms",
                                                               member: "2016")),
        ]
        #expect(Set(sentences).count == 6)
        #expect(sentences.allSatisfy { !$0.isEmpty })
        #expect(sentences[1].contains("F/2016/A"), "the refusal names the folder it is about")
        #expect(sentences[3].contains("Forms") && sentences[3].contains("forms"),
                "the clash names both spellings")
        #expect(sentences[4].contains("Tax/2024"), "the refusal names the offending target")
        #expect(sentences[5].contains("FILE"),
                "a file occupant is named as one — the fix is moving the file")
    }

    // MARK: The refine slot's text rules (§5.6)

    /// The disclosure is itemised: the toggle's clause appears exactly when the payload carries
    /// it, and the never-clause is always there.
    @Test func thePayloadDisclosureMatchesTheToggle() {
        let off = RestructurePlanSheet.payloadDisclosure(includesFileNames: false)
        #expect(!off.contains("file names per folder"))
        #expect(off.contains("File contents are never sent"))
        let on = RestructurePlanSheet.payloadDisclosure(includesFileNames: true)
        #expect(on.contains("up to 5 file names per folder"))
        #expect(on.contains("File contents are never sent"))
        #expect(on.contains("Billed to your API key"))
    }

    /// Declined is a first-class rendered outcome — its row has its own words, not an absence.
    @Test func everyVerdictHasItsOwnLine() {
        #expect(RestructurePlanSheet.proposalLine(
            .init(source: "s", verdict: .propose(target: "Forms"), why: "w")) == "→ Forms")
        #expect(RestructurePlanSheet.proposalLine(
            .init(source: "s", verdict: .keep, why: "w")) == "keep")
        #expect(RestructurePlanSheet.proposalLine(
            .init(source: "s", verdict: .declined, why: "w"))
            == "declined — not enough evidence to say")
    }

    // MARK: The card's trigger (§5.7)

    /// *Plan…* creates; *Review N operations* reopens what exists. The pair never both show —
    /// one title, switched by whether a draft is saved.
    @Test func theTriggerOffersReviewOnceADraftExists() {
        #expect(RestructureLens.planTriggerTitle(planned: nil) == "Plan…")
        #expect(RestructureLens.planTriggerTitle(
            planned: PlannedPlanInfo(operations: 9, summary: "s", renames: 0, carried: 0,
                                    merges: 0, filesMove: 0)) == "Review 9 operations")
        #expect(RestructureLens.planTriggerTitle(
            planned: PlannedPlanInfo(operations: 1, summary: "s", renames: 0, carried: 0,
                                    merges: 0, filesMove: 0)) == "Review 1 operation")
    }

    // MARK: Render smoke

    /// The sheet renders offscreen against a dictionary-backed tree — layout crashes and
    /// unresolved bindings fail here rather than at first click.
    @Test func theSheetRendersAgainstAFixtureTree() throws {
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
            finding: finding, family: finding.family, members: ["2013", "2014"],
            tree: tree, profileId: "p",
            accent: .blue, initialRows: nil, onExport: { _, _ in .saved(filename: "f.json") },
            onClose: {})
        // An ink floor, not a width: `fittingSize.width > 0` is true of an empty
        // `VStack`, so it passed with the subject of this test deleted.
        let rep = try #require(RestructureRender.raster(sheet, width: 620, height: 560))
        #expect(RestructureRender.inkedPixels(rep) > 1000)
    }
}

/// §5.4's review section grew a before/after of one member (proposal O3) — the words it puts on
/// each row, and the choice of which member to draw.
@MainActor
@Suite struct RestructureTreePreviewSurfaceTests {

    /// Every fate the rule can produce has words except the one that means "nothing happened" —
    /// an annotation on every row is an annotation nobody reads.
    @Test func everyFateThatMattersCarriesANote() {
        typealias Fate = RestructurePlanner.RestructurePreview.Fate
        #expect(RestructurePlanSheet.fateNote(.renamedFrom("Federal Tax")) == "was Federal Tax")
        #expect(RestructurePlanSheet.fateNote(
            .mergedFrom(renamedFrom: nil, sources: ["State Tax", "Payments"]))
                    == "absorbed State Tax, Payments")
        #expect(RestructurePlanSheet.fateNote(
            .mergedFrom(renamedFrom: "Federal Tax", sources: ["State Tax"]))
                    == "was Federal Tax, absorbed State Tax")
        #expect(RestructurePlanSheet.fateNote(.created) == "created")
        #expect(RestructurePlanSheet.fateNote(.kept) == "kept — no slot in the target shape")
        #expect(RestructurePlanSheet.fateNote(.unchanged) == nil,
                "an untouched folder says nothing rather than saying \"unchanged\"")
    }

    /// A kept folder's note is the one that has to explain itself: it is there BECAUSE the target
    /// shape has no slot for it, and "kept" alone reads as a choice the user made.
    @Test func theKeptNoteSaysWhy() {
        let note = try? #require(RestructurePlanSheet.fateNote(.kept))
        #expect(note?.contains("no slot") == true)
    }

    /// The sheet draws the preview from the planner's rule rather than deriving a second answer,
    /// and it picks a member the plan actually touches — two identical columns teach nothing.
    @Test func theSheetDrawsTheRulesPreviewForATouchedMember() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/FileExplorer/RestructurePlanSheet.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        #expect(text.contains("RestructurePlanner.preview(member: exemplar, in: manifest,"),
                "the columns come from the shared rule, not a second derivation")
        #expect(text.contains("for action in manifest.actions where action.action != .keep"),
                "the exemplar is a member the plan touches")
        #expect(text.contains("Self.previewMember(of: manifest, family: family,"),
                "the sheet asks the rule; a private method could be stubbed to nil unnoticed")
    }

    /// The exemplar is a member the plan TOUCHES, and nil when it touches none — the case that
    /// draws two identical columns and teaches nothing.
    @Test func theExemplarIsAMemberThePlanActuallyTouches() {
        let family = "Finance/US/Income Tax"
        let members = ["2013", "2014"]
        let touching = RestructureManifest(
            profileId: "p", manifestId: "m", createdAt: "t", family: family, kind: .shape,
            actions: [.init(action: .keep, src: "\(family)/2013/Transcripts"),
                      .init(action: .renameDir, src: "\(family)/2014/Federal",
                            dst: "\(family)/2014/Forms")])
        #expect(RestructurePlanSheet.previewMember(of: touching, family: family,
                                                   members: members) == "\(family)/2014",
                "the first member with a real operation, not the first keep")

        let allKeep = RestructureManifest(
            profileId: "p", manifestId: "m", createdAt: "t", family: family, kind: .shape,
            actions: [.init(action: .keep, src: "\(family)/2013/Transcripts")])
        #expect(RestructurePlanSheet.previewMember(of: allKeep, family: family,
                                                   members: members) == nil)

        let elsewhere = RestructureManifest(
            profileId: "p", manifestId: "m", createdAt: "t", family: family, kind: .shape,
            actions: [.init(action: .renameDir, src: "Other/2013/A", dst: "Other/2013/B")])
        #expect(RestructurePlanSheet.previewMember(of: elsewhere, family: family,
                                                   members: members) == nil,
                "an operation outside every member names no exemplar")
    }

    /// Renders the sheet over a family, with the mapping either doing something or all-keep.
    static func renderPlanSheet(mapped: Bool) throws -> Data {
        let finding = StructureFinding(
            family: "F",
            schemes: [.init(vocabulary: ["forms"], members: ["2013"]),
                      .init(vocabulary: ["federal tax"], members: ["2014"])])
        let files: [String: [String]] = [
            "F/2013/Federal Tax": ["a.pdf", "b.pdf"],
            "F/2013/State Tax": ["c.pdf"],
            "F/2014/Forms": ["d.pdf"],
        ]
        let folders: [String: [String]] = [
            "F": ["2013", "2014"],
            "F/2013": ["Federal Tax", "State Tax"],
            "F/2014": ["Forms"],
        ]
        let tree = RestructureTreeView(
            childFolders: { folders[$0] ?? (files[$0] != nil ? [] : nil) },
            files: { files[$0] },
            fileCount: { files[$0]?.count })
        let sheet = RestructurePlanSheet(
            finding: finding, family: "F", members: ["2013", "2014"], tree: tree,
            profileId: "p", accent: .blue,
            initialRows: mapped ? [.init(source: "Federal Tax", target: "Forms"),
                                   .init(source: "State Tax", target: "Forms")]
                                : [.init(source: "Federal Tax"), .init(source: "State Tax")],
            onExport: { _, _ in .saved(filename: "f.json") }, onClose: {})
        let host = NSHostingView(rootView: sheet.frame(width: 620, height: 700))
        host.frame = NSRect(x: 0, y: 0, width: 620, height: 700)
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    /// The whole sheet renders with the preview present — a layout crash fails here rather than
    /// on a real family.
    @Test func thePlanSheetRendersWithItsPreview() throws {
        let finding = StructureFinding(
            family: "F",
            schemes: [.init(vocabulary: ["forms"], members: ["2013"]),
                      .init(vocabulary: ["federal tax"], members: ["2014"])])
        let files: [String: [String]] = [
            "F/2013/Federal Tax": ["a.pdf", "b.pdf"],
            "F/2013/State Tax": ["c.pdf"],
            "F/2014/Forms": ["d.pdf"],
        ]
        let folders: [String: [String]] = [
            "F": ["2013", "2014"],
            "F/2013": ["Federal Tax", "State Tax"],
            "F/2014": ["Forms"],
        ]
        let tree = RestructureTreeView(
            childFolders: { folders[$0] ?? (files[$0] != nil ? [] : nil) },
            files: { files[$0] },
            fileCount: { files[$0]?.count })
        let sheet = RestructurePlanSheet(
            finding: finding, family: "F", members: ["2013", "2014"], tree: tree,
            profileId: "p", accent: .blue,
            initialRows: [.init(source: "Federal Tax", target: "Forms"),
                          .init(source: "State Tax", target: "Forms")],
            onExport: { _, _ in .saved(filename: "f.json") }, onClose: {})
        // An ink floor, not a width: `fittingSize.width > 0` is true of an empty
        // `VStack`, so it passed with the subject of this test deleted.
        let rep = try #require(RestructureRender.raster(sheet, width: 620, height: 620))
        #expect(RestructureRender.inkedPixels(rep) > 1000)
    }
}

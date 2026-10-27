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
                                    merges: 0, filesMove: 0)) == "Review 9 Operations")
        #expect(RestructureLens.planTriggerTitle(
            planned: PlannedPlanInfo(operations: 1, summary: "s", renames: 0, carried: 0,
                                    merges: 0, filesMove: 0)) == "Review 1 Operation")
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

    // MARK: Closing keeps the plan (§5.4's store table)

    private static let keptPlan = RestructureManifest(
        profileId: "p", manifestId: "m", createdAt: "t", family: "Tax", kind: .shape,
        actions: [.init(action: .renameDir, src: "Tax/2013/Federal", dst: "Tax/2013/Forms",
                        filesCarried: 3)])

    private static func disposition(
        plan: Result<RestructureManifest, RestructurePlanner.PlanRefusal> = .success(keptPlan),
        changed: Bool = true, vocabularyOnly: Bool = false, landedOrExported: Bool = false,
        openedFromDraft: Bool = false) -> RestructurePlanSheet.CloseDisposition {
        let seeded = [RestructureMapping.Row(source: "Federal")]
        let edited = [RestructureMapping.Row(source: "Federal", target: "Forms")]
        return RestructurePlanSheet.closeDisposition(
            plan: plan, rows: changed && !vocabularyOnly ? edited : seeded,
            vocabulary: changed && vocabularyOnly ? ["Forms"] : [],
            baseline: .init(rows: seeded, vocabulary: [], hasDraft: openedFromDraft),
            landedOrExported: landedOrExported)
    }

    /// **A draft saved by Export earlier in the same sheet could not be dropped from it.** Opened
    /// fresh, mapped, exported, then set back to all-keep: the rows matched the seed, so closing
    /// did nothing, and Discard Plan showed only on a sheet opened on a draft — the draft and its
    /// card stood over a plan just undone. The export moves the baseline and marks a draft saved.
    @Test func aDraftExportedInThisSheetCanBeDroppedFromIt() {
        let allKeep = [RestructureMapping.Row(source: "Federal")]
        let mapped = [RestructureMapping.Row(source: "Federal", target: "Forms")]
        var baseline = RestructurePlanSheet.Baseline(rows: allKeep, vocabulary: [], hasDraft: false)
        baseline.exported(rows: mapped, vocabulary: ["Forms"])
        #expect(baseline == .init(rows: mapped, vocabulary: ["Forms"], hasDraft: true))

        // Back to all-keep after the export: the close removes the draft the export saved.
        #expect(RestructurePlanSheet.closeDisposition(
            plan: .failure(.nothingMapped), rows: allKeep, vocabulary: ["Forms"],
            baseline: baseline, landedOrExported: false) == .discard)
        // Edited and then put back to exactly what was exported: the draft already is this plan.
        #expect(RestructurePlanSheet.closeDisposition(
            plan: .success(Self.keptPlan), rows: mapped, vocabulary: ["Forms"],
            baseline: baseline, landedOrExported: false) == .nothing,
                "a close re-saved the plan the export had just saved, dropping its file name")
        #expect(RestructurePlanSheet.closeTitle(applied: false, disposition: .discard,
                                                hasDraft: baseline.hasDraft,
                                                landedOrExported: false) == "Close")
    }

    /// **Esc threw a hand-built mapping away**, because only Export saved the draft. A changed
    /// mapping that derives a plan is kept when the sheet closes — fresh or opened on a draft.
    @Test func closingAChangedMappingKeepsItsPlan() {
        #expect(Self.disposition() == .keep(Self.keptPlan))
        #expect(Self.disposition(openedFromDraft: true) == .keep(Self.keptPlan))
        // A vocabulary choice alone is part of the draft too.
        #expect(Self.disposition(vocabularyOnly: true) == .keep(Self.keptPlan))
    }

    /// **Nothing could remove a draft except landing it.** Reopening a saved plan, setting every
    /// row back to keep and closing left the old draft — and its *Review N operations* card —
    /// standing. Now that close removes it; on a sheet that opened fresh there is nothing to
    /// remove.
    @Test func closingADraftSetBackToAllKeepRemovesIt() {
        #expect(Self.disposition(plan: .failure(.nothingMapped), openedFromDraft: true) == .discard)
        #expect(Self.disposition(plan: .failure(.nothingMapped), openedFromDraft: false) == .nothing,
                "a fresh sheet has no draft to remove")
    }

    /// And the closes that must leave the store alone: opened and closed untouched (no *Planned,
    /// not applied* card for a plan nobody made, and a reopened draft stays as it was), already
    /// landed or exported (a re-save would drop the export's file name), and a mapping that
    /// refuses for a reason other than all-keep — a half-finished clash is not a discard.
    @Test func closingKeepsNothingElse() {
        #expect(Self.disposition(changed: false) == .nothing, "an untouched sheet minted a draft")
        #expect(Self.disposition(changed: false, openedFromDraft: true) == .nothing)
        #expect(Self.disposition(plan: .failure(.nothingMapped), changed: false,
                                 openedFromDraft: true) == .nothing,
                "an untouched draft was thrown away")
        #expect(Self.disposition(landedOrExported: true) == .nothing,
                "an exported plan was saved over, losing its file name")
        #expect(Self.disposition(plan: .failure(.nothingMapped), landedOrExported: true,
                                 openedFromDraft: true) == .nothing)
        #expect(Self.disposition(plan: .failure(.conflictingTargets("Forms", "forms")),
                                 openedFromDraft: true) == .nothing,
                "a clashing mapping threw the saved plan away")
    }

    /// **Close silently dropped a clashing edit** to a saved plan, beside Help's promise that
    /// closing keeps a changed plan. The disposition is right — a clash is not a discard — so the
    /// footer says so before the click; only the clash on a saved plan gets the sentence.
    @Test func closingAClashingEditToASavedPlanSaysItKeepsTheOldOne() throws {
        let seeded = [RestructureMapping.Row(source: "Federal")]
        let edited = [RestructureMapping.Row(source: "Federal", target: "Forms")]
        let clash: Result<RestructureManifest, RestructurePlanner.PlanRefusal> =
            .failure(.conflictingTargets("Forms", "forms"))
        func drops(_ plan: Result<RestructureManifest, RestructurePlanner.PlanRefusal>,
                   rows: [RestructureMapping.Row] = edited, saved: Bool = true,
                   exported: Bool = false) -> Bool {
            RestructurePlanSheet.closeDropsEdit(
                plan: plan, rows: rows, vocabulary: [],
                baseline: .init(rows: seeded, vocabulary: [], hasDraft: saved),
                landedOrExported: exported)
        }
        #expect(drops(clash))
        #expect(!drops(clash, saved: false), "Cancel already says nothing is kept")
        #expect(!drops(clash, rows: seeded), "nothing changed, nothing dropped")
        #expect(!drops(.success(Self.keptPlan)), "a change that plans is kept")
        #expect(!drops(.failure(.nothingMapped)), "all-keep discards, and the title says Close")
        #expect(!drops(clash, exported: true))

        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FileExplorer")
        let sheet = try String(contentsOf: sources.appendingPathComponent("RestructurePlanSheet.swift"),
                               encoding: .utf8)
        #expect(sheet.contains("Text(Self.closeDropsEditSentence)"), "the footer draws it")
    }

    /// **"Cancel" read as a discard** over a close that keeps the plan. Done after a landing;
    /// Close whenever a plan is or will be kept; Cancel only when closing leaves no trace.
    @Test func theCloseButtonSaysWhatClosingDoes() {
        typealias Sheet = RestructurePlanSheet
        let keep = Sheet.CloseDisposition.keep(Self.keptPlan)
        #expect(Sheet.closeTitle(applied: true, disposition: .nothing, hasDraft: true,
                                 landedOrExported: true) == "Done")
        #expect(Sheet.closeTitle(applied: false, disposition: keep, hasDraft: false,
                                 landedOrExported: false) == "Close")
        #expect(Sheet.closeTitle(applied: false, disposition: .nothing, hasDraft: true,
                                 landedOrExported: false) == "Close",
                "closing a reopened draft keeps it")
        #expect(Sheet.closeTitle(applied: false, disposition: .discard, hasDraft: true,
                                 landedOrExported: false) == "Close")
        #expect(Sheet.closeTitle(applied: false, disposition: .nothing, hasDraft: false,
                                 landedOrExported: true) == "Close",
                "an exported plan is kept")
        #expect(Sheet.closeTitle(applied: false, disposition: .nothing, hasDraft: false,
                                 landedOrExported: false) == "Cancel")
    }

    /// The rules are the footer's: a rule extracted for testing is one revert away from unused.
    @Test func theFooterAndTheHostUseTheCloseRules() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/FileExplorer")
        let sheet = try String(contentsOf: sources.appendingPathComponent(
            "RestructurePlanSheet.swift"), encoding: .utf8)
        #expect(sheet.contains("let disposition = Self.closeDisposition("))
        #expect(sheet.contains("Button(Self.closeTitle(applied: isApplied, disposition: disposition,"))
        #expect(sheet.contains("case .keep(let manifest): onKeepDraft?(manifest, vocabulary)"))
        #expect(sheet.contains("case .discard: onDiscardDraft?()"))
        #expect(sheet.contains("baseline = Baseline(rows: rows, vocabulary: vocabulary, hasDraft: hasSavedDraft)"))
        #expect(sheet.contains("if baseline.hasDraft, onDiscardDraft != nil"),
                "Discard Plan is offered on a different condition from the close's discard")
        // Both exports move the baseline when they save.
        let single = try OrganizeScopeCallSiteTests.body(of: "private func exportPlan(", in: sheet)
        #expect(single.contains("case .saved(let filename):\n"
                                + "            baseline.exported(rows: rows, vocabulary: vocabulary)"))
        let group = try OrganizeScopeCallSiteTests.body(of: "private func exportGroup(", in: sheet)
        #expect(group.contains("if !names.isEmpty { baseline.exported(rows: rows, vocabulary: vocabulary) }"))
        let host = try String(contentsOf: sources.appendingPathComponent(
            "LensWorkspaceView.swift"), encoding: .utf8)
        #expect(host.contains("hasSavedDraft: store.draft(for: key) != nil"))
        #expect(host.contains("onDiscardDraft: { store.removeDraft(for: key) }"))
    }

    /// *Discard Plan* paints on a sheet opened from a saved draft. The comparison holds the close
    /// button's title fixed (both read Close) so the difference is the Discard button alone.
    @Test func discardPlanPaintsOnASheetOpenedFromADraft() throws {
        func render(discard: Bool) throws -> NSBitmapImageRep {
            let finding = StructureFinding(
                family: "F",
                schemes: [.init(vocabulary: ["forms"], members: ["2013"]),
                          .init(vocabulary: ["federal tax"], members: ["2014"])])
            let files: [String: [String]] = [
                "F/2013/Federal Tax": ["a.pdf"], "F/2014/Forms": ["d.pdf"],
            ]
            let folders: [String: [String]] = [
                "F": ["2013", "2014"], "F/2013": ["Federal Tax"], "F/2014": ["Forms"],
            ]
            let tree = RestructureTreeView(
                childFolders: { folders[$0] ?? (files[$0] != nil ? [] : nil) },
                files: { files[$0] }, fileCount: { files[$0]?.count })
            let sheet = RestructurePlanSheet(
                finding: finding, family: "F", members: ["2013", "2014"], tree: tree,
                profileId: "p", accent: .blue,
                initialRows: [.init(source: "Federal Tax", target: "Forms")],
                onExport: { _, _ in .saved(filename: "f.json") },
                hasSavedDraft: true, onDiscardDraft: discard ? {} : nil, onClose: {})
            return try #require(RestructureRender.raster(sheet, width: 620, height: 700))
        }
        let with = try render(discard: true)
        let without = try render(discard: false)
        #expect(RestructureRender.inkedPixels(with) > 1000)
        #expect(RestructureRender.differingPixels(with, without) > 100,
                "Discard Plan drew nothing on a sheet opened from a saved draft")
    }
}

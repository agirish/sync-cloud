import Testing
import AppKit
import SwiftUI
import Design
@testable import Sync
@testable import FileExplorer

/// **Every lens opens on its setup card at launch — including the one that already knows the
/// answer.**
///
/// ## The rule, and why it needed writing down
///
/// Four of the five lenses get this for nothing: their findings live only in memory, so a fresh
/// `FileSyncManager` has none and the content switch falls through to the card. Restructure does
/// not. Its findings are a pure function of the folder profile, and that profile is read off disk
/// during startup — so it arrived at an answer before anyone asked, and it was the only lens that
/// never showed the card.
///
/// Fixing that one lens is not the same as making it a rule. What follows is the rule: at launch,
/// with a manager in the state startup leaves it in, **no lens shows results**. A future lens that
/// derives its answer from a startup artifact fails here rather than quietly becoming the second
/// exception.
///
/// The gate is deliberately per-launch and not persisted (see
/// ``FileSyncManager/hasReviewedStructure``) — that is what makes "these are cached results, and
/// here is how to refresh them" something the user is told each session rather than once, ever.
@MainActor
@Suite(.serialized) struct LensLaunchGateTests {

    /// A manager in the state startup leaves it in: the folder profile loaded (`SyncCloudApp`
    /// does this before the first frame), nothing scanned.
    static func launched(withProfile: Bool = true) -> FileSyncManager {
        let m = FileSyncManager()
        if withProfile { m.filingFolderProfile = profile() }
        return m
    }

    /// Four sibling events in two shapes: two keep Photos/Invitations, two keep Certificates.
    ///
    /// **The subfolders are the point.** A sibling's "shape" is its own children's names, so a
    /// family of four leaves has no vocabulary at all and the detector correctly reports nothing
    /// — which would make every test in this suite pass with the launch gate deleted.
    /// `restructureHasFindingsBeforeAnythingIsAsked` is what holds this fixture to its job.
    static func profile() -> FolderProfile {
        let family = "Family/Aditi/Events"
        let shapes: [(String, [String])] = [
            ("Naming Ceremony", ["Photos", "Invitations"]),
            ("Birthday", ["Photos", "Invitations"]),
            ("Graduation", ["Certificates"]),
            ("Sports Day", ["Certificates"]),
        ]
        var folders: [String: FolderProfileEntry] = [:]
        for (event, children) in shapes {
            let path = "\(family)/\(event)"
            folders[path] = entry(path)
            for child in children {
                folders["\(path)/\(child)"] = entry("\(path)/\(child)")
            }
        }
        return FolderProfile(profileId: "test", root: "/root", folders: folders,
                             personTokens: [], personAliases: [:])
    }

    static func entry(_ path: String) -> FolderProfileEntry {
        FolderProfileEntry(path: path, role: nil, naming: nil, anchors: [], acceptsNewFiles: true,
                           fileCount: 0, subfolderCount: 0, axes: [:])
    }

    // MARK: The rule

    @Test("No lens has an answer to show at launch")
    func nothingIsScannedOnAFreshManager() {
        let m = Self.launched()
        // The four scan lifecycles. Each of these being false is what puts its lens on the card,
        // so each is part of the same rule rather than incidental state — named individually
        // because "some flag is false" is not the claim.
        #expect(!m.hasSuggestedFiling, "To File would open on results at launch")
        #expect(!m.hasFoundDuplicates, "Duplicates would open on results at launch")
        #expect(!m.hasScannedNames, "Renames would open on results at launch")
        #expect(!m.hasBuiltStorageLens, "Storage would open on results at launch")
        // And Restructure's, which is the one that had to be declared because it has no scan.
        #expect(!m.hasReviewedStructure, "Restructure would open on results at launch")
    }

    /// The half the flags above cannot show: Restructure's answer **exists** at launch.
    ///
    /// Without this, `nothingIsScannedOnAFreshManager` passes just as happily on a machine with
    /// no profile at all — where every lens is empty for the boring reason and the gate is doing
    /// nothing. This is the fixture proving the gate has something to hold back.
    @Test("…and Restructure's answer is sitting there regardless")
    func restructureHasFindingsBeforeAnythingIsAsked() {
        let m = Self.launched()
        #expect(!m.structureFindings.isEmpty, """
                The profile fixture produces no structure findings, so every other test here \
                would pass with the gate removed entirely.
                """)
        #expect(!m.hasReviewedStructure)
    }

    @Test("Revealing is what opens it, and it stays open for the session")
    func reviewingLatchesForTheRestOfTheLaunch() {
        let m = Self.launched()
        m.hasReviewedStructure = true
        #expect(m.hasReviewedStructure)
        // Not tied to the findings themselves: a re-survey that changes the answer must not shut
        // the gate again mid-session and hide the new result behind a second click.
        m.filingFolderProfile = Self.profile()
        #expect(m.hasReviewedStructure, "a re-survey re-closed the launch gate mid-session")
    }

    // MARK: The call site

    /// **The gate is wired, not merely available.**
    ///
    /// Everything above tests a flag and a view input. Neither notices if `TidyView` stops passing
    /// the flag to the view — and that is the whole change. `hasReviewed` is deliberately a `let`
    /// with no default so the compiler catches an omitted argument; this catches the other half,
    /// an argument still present but fed something that is not the launch flag (a literal `true`
    /// while debugging, say, or a different manager property).
    ///
    /// A source scan, for the reason `OrganizeScopeCallSiteTests` gives: the alternative is
    /// mounting `TidyView` with a live manager and reading pixels back to infer which state it
    /// chose, which is a lot of machinery to answer a question the call site states outright.
    @Test func tidyViewFeedsTheGateToTheLens() throws {
        let tidy = try OrganizeScopeCallSiteTests.source("TidyView.swift")
        let content = try OrganizeScopeCallSiteTests.body(
            of: "private func restructureContent(rows: FilteredRows,", in: tidy)
        #expect(content.contains("hasReviewed: syncManager.hasReviewedStructure"), """
                restructureContent no longer feeds the launch flag to RestructureLens — the gate \
                still exists and no longer decides anything.
                """)
        #expect(content.contains("onReview:"), "the card has no way to open the answer it gates")
        // The overview's exception, which is a decision rather than an accident: arriving from
        // "Open Restructure — 12 ›" skips the card, because that button already stated the count.
        // If it stops being deliberate it should fail here rather than drift.
        let overview = try OrganizeScopeCallSiteTests.body(
            of: "private func organizeOverview(rows: FilteredRows,", in: tidy)
        #expect(overview.contains("if item == .restructure { syncManager.hasReviewedStructure = true }"),
                "the overview's Open-Restructure link no longer skips the reveal card")
    }

    // MARK: The reveal trigger's words

    @Test func theTriggerCountsWhatItWouldShow() {
        // The rail badge beside this button carries a number; a trigger that said "Show findings"
        // next to a badge saying 12 invites the question of whether they are the same twelve.
        #expect(RestructureLens.revealTitle(findingCount: 1) == "Show 1 finding")
        #expect(RestructureLens.revealTitle(findingCount: 12) == "Show 12 findings")
        // Zero is its own phrasing. "Show 0 findings" reads as a button that does nothing; what
        // it actually opens is the earned clean state, which is a result and not an absence.
        #expect(RestructureLens.revealTitle(findingCount: 0) == "Check the shapes")
    }

    @Test func theFootnoteClaimsCoverageAndNeverFreshness() {
        let known = RestructureLens.surveyNoteText(folderCount: 3_013)
        // Grouped, like the clean state's "Checked 3,013 folders" one state over — a bare 3013
        // in running prose is a number the eye has to stop and parse.
        #expect(known.contains("3,013 folders"))
        #expect(known.contains("not from your disk"))
        #expect(known.contains("Update it"))
        // **The count is what the ANSWER covers, never the size of the survey.** `folderCount` is
        // scoped, so under a narrowing it is 79 where the survey is 3,013 — and "a survey of 79
        // folders" would attach the scoped number to the artifact and describe neither. Same slip
        // `cleanMessage` was fixed for one state over.
        #expect(known.hasPrefix("Covers 3,013 folders."))
        #expect(!known.contains("survey of"))
        // **No date, deliberately.** The survey's stamp is rewritten only when a re-survey
        // changes something, so on a settled tree it names the last change rather than the last
        // look — "surveyed 3 days ago" would be a claim this view cannot back. If a real
        // surveyed-at ever gets plumbed through, this is the assertion to revisit on purpose
        // rather than the sentence to quietly reword.
        for stale in ["ago", "days", "Last surveyed", "yesterday"] {
            #expect(!known.contains(stale), "the footnote invented a freshness claim: “\(stale)”")
        }
        // An unknown count drops the number rather than inventing a zero — the same rule the
        // clean state's "Checked N folders" follows one screen over.
        let unknown = RestructureLens.surveyNoteText(folderCount: nil)
        #expect(!unknown.contains("0 folder"))
        #expect(unknown.contains("Update it"))
    }

    @Test func oneFolderReadsAsASentence() {
        #expect(RestructureLens.surveyNoteText(folderCount: 1).contains("1 folder."))
        #expect(!RestructureLens.surveyNoteText(folderCount: 1).contains("1 folders"))
    }
}

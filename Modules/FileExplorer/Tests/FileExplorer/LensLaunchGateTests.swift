import Testing
import AppKit
import SwiftUI
import Design
@testable import Sync
@testable import FileExplorer

/// Every lens opens on its setup card at launch, including the one that already knows the answer.
///
/// Most lenses get this for nothing: their findings live only in memory. Restructure's are a pure
/// function of the folder profile, read off disk at startup, so it has an answer before anyone
/// asks. Pinned: with a manager in its startup state, no lens shows results; a future lens deriving
/// its answer from a startup artifact fails here rather than becoming a second exception.
///
/// The gate is per-launch, not persisted (``FileSyncManager/hasReviewedStructure``), so "these are
/// cached results, and here is how to refresh them" is said each session.
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
    /// The subfolders are the point: a sibling's shape is its own children's names, so four bare
    /// leaves have no vocabulary and the detector rightly reports nothing, which would let every
    /// test here pass with the gate deleted. `restructureHasFindingsBeforeAnythingIsAsked` holds
    /// this fixture to its job.
    static func profile() -> FolderProfile {
        let family = "Family/Daughter/Events"
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
        // The four scan lifecycles. Each being false is what puts its lens on the card, so each is
        // named, because "some flag is false" is not the claim.
        #expect(!m.hasSuggestedFiling, "To File would open on results at launch")
        #expect(!m.hasFoundDuplicates, "Duplicates would open on results at launch")
        #expect(!m.hasScannedNames, "Renames would open on results at launch")
        #expect(!m.storageLensLifecycle.hasCompleted, "Storage would open on results at launch")
        // And Restructure's, which has to be declared because it has no scan.
        #expect(!m.hasReviewedStructure, "Restructure would open on results at launch")
    }

    /// The half the flags above can't show: Restructure's answer exists at launch. Without this,
    /// `nothingIsScannedOnAFreshManager` passes just as well with no profile at all, where every
    /// lens is empty for the boring reason and the gate holds nothing back.
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

    /// The gate is wired, not merely available: `hasReviewed` is a `let` with no default, so the
    /// compiler catches an omitted argument; this catches one fed something other than the launch
    /// flag (a literal `true`, say). A source scan, because the alternative is mounting
    /// `LensWorkspaceView` and reading pixels back for what the call site states outright.
    @Test func lensWorkspaceViewFeedsTheGateToTheLens() throws {
        let view = try SourceText.fileExplorer("LensWorkspaceView.swift")
        let content = try SourceText.body(
            of: "private func restructureContent(rows: FilteredRows,", in: view)
        #expect(content.contains("hasReviewed: syncManager.hasReviewedStructure"), """
                restructureContent no longer feeds the launch flag to RestructureLens — the gate \
                still exists and no longer decides anything.
                """)
        #expect(content.contains("onReview:"), "the card has no way to open the answer it gates")
        // The overview's exception, by decision: arriving from a reporting card's "Open
        // Restructure" skips the card, because the pill beside that button already stated the
        // count. Fails here if it stops being deliberate.
        let overview = try SourceText.body(
            of: "private func organizeOverview(rows: FilteredRows,", in: view)
        #expect(overview.contains("if item == .restructure { syncManager.hasReviewedStructure = true }"),
                "the overview's Open-Restructure link no longer skips the reveal card")
    }

    // MARK: The reveal trigger's words

    @Test func theTriggerCountsWhatItWouldShow() {
        // The rail badge beside this button carries a number, so a bare "Show findings" next to a
        // badge saying 12 invites the question of whether they are the same twelve.
        #expect(RestructureLens.revealTitle(findingCount: 1) == "Show 1 Finding")
        #expect(RestructureLens.revealTitle(findingCount: 12) == "Show 12 Findings")
        // Zero has its own phrasing: "Show 0 findings" reads as a button that does nothing, while
        // it opens the earned clean state, a result and not an absence.
        #expect(RestructureLens.revealTitle(findingCount: 0) == "Check the Shapes")
    }

    @Test func theFootnoteClaimsCoverageAndNeverFreshness() {
        let known = RestructureLens.surveyNoteText(folderCount: 3_013)
        // Grouped, like the clean state's "Checked 3,013 folders": a bare 3013 in prose is a
        // number the eye has to stop and parse.
        #expect(known.contains("3,013 folders"))
        #expect(known.contains("not from your disk"))
        #expect(known.contains("Update it"))
        // The count is what the answer covers, never the survey's size. `folderCount` is scoped,
        // so under a narrowing it is 79 where the survey is 3,013, and "a survey of 79 folders"
        // would describe neither. `cleanMessage` follows the same rule.
        #expect(known.hasPrefix("Covers 3,013 folders."))
        #expect(!known.contains("survey of"))
        // No date without a stamp: a corpus with no `surveyedAt` gets the coverage-only sentence
        // rather than a freshness claim it can't back.
        for stale in ["ago", "days", "Surveyed", "yesterday"] {
            #expect(!known.contains(stale), "the footnote invented a freshness claim: “\(stale)”")
        }
        // An unknown count drops the number rather than inventing a zero, as the clean state's
        // "Checked N folders" does.
        let unknown = RestructureLens.surveyNoteText(folderCount: nil)
        #expect(!unknown.contains("0 folder"))
        #expect(unknown.contains("Update it"))
    }

    /// The dated variant, truthful because the corpus stamp moves on every survey, including one
    /// that changes nothing (`FilingSurveyStoreTests` pins that half).
    @Test func theFootnoteDatesTheSurveyWhenTheStampExists() {
        let calendar = Calendar.current
        let now = calendar.date(from: DateComponents(year: 2026, month: 8, day: 28, hour: 14))!
        func note(daysAgo: Int) -> String {
            RestructureLens.surveyNoteText(
                folderCount: 3_013,
                surveyedAt: calendar.date(byAdding: .day, value: -daysAgo, to: now)!,
                now: now, locale: Locale(identifier: "en_GB"))
        }
        #expect(note(daysAgo: 0).contains("Surveyed today."))
        #expect(note(daysAgo: 1).contains("Surveyed yesterday."))
        #expect(note(daysAgo: 5).contains("Surveyed 5 days ago."))
        // Past two weeks the phrase goes absolute: a checkable date beats a big round number.
        #expect(note(daysAgo: 30).contains("Surveyed on 29 Jul 2026."))
        #expect(!note(daysAgo: 30).contains("ago"))
        // The date claim is independent of the count claim: a scoped view can know when the survey
        // ran without knowing how many folders the narrowing covers.
        let dated = RestructureLens.surveyNoteText(folderCount: nil, surveyedAt: now, now: now)
        #expect(dated.contains("Surveyed today."))
        #expect(!dated.contains("Covers"))
        // A stamp from the future is a wrong clock somewhere; the date is still the fact, and
        // "in -3 days" is the sentence this guards against.
        let future = RestructureLens.surveyedPhrase(
            calendar.date(byAdding: .day, value: 3, to: now)!, now: now, locale: Locale(identifier: "en_GB"))
        #expect(future == "on 31 Aug 2026")
    }

    @Test func oneFolderReadsAsASentence() {
        #expect(RestructureLens.surveyNoteText(folderCount: 1).contains("1 folder."))
        #expect(!RestructureLens.surveyNoteText(folderCount: 1).contains("1 folders"))
    }
}

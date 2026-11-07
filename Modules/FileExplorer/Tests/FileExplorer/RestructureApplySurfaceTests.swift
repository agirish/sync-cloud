import Foundation
import SwiftUI
import Sync
import Testing
@testable import FileExplorer

/// The landing surfaces: the removal sheet's split-by-name rule and the Applied/Undone card
/// sentences, the text rules tested as text and the views as render smoke.
@MainActor
@Suite struct RestructureApplySurfaceTests {

    // MARK: The removal split (§5.5)

    /// An empty date bucket is debt and starts ticked; an empty category is a destination and
    /// doesn't. The split is by the shape of the name: a year, or a year span.
    @Test func theRemovalSplitReadsTheShapeOfTheName() {
        #expect(RestructureRemovalSheet.Candidate.isDateBucket("Finance/US/Income Tax/2016"))
        #expect(RestructureRemovalSheet.Candidate.isDateBucket("Immigration/H-1B/2016-2019"))
        #expect(!RestructureRemovalSheet.Candidate.isDateBucket("Finance/US/Income Tax/Payment"))
        #expect(!RestructureRemovalSheet.Candidate.isDateBucket("Tax/2013/State Tax"),
                "a category under a year is still a category")
    }

    // MARK: §5.7's sentences

    /// Applied and Undone are different claims and neither borrows the other's words. The Undone
    /// line carries the undo run's own counts, because an undo never pretends the tree was
    /// untouched. The stamp renders in words, never as the ledger's machine stamp.
    @Test func appliedAndUndoneNeverBorrowEachOthersWords() {
        // A fixed "now" well after the stamp's day, so the phrase is the absolute form whatever
        // day the test runs.
        let now = ISO8601DateFormatter().date(from: "2026-09-20T10:00:00Z")!
        let applied = ReorganisationDisplay(
            manifestId: "m1", family: "Finance/US/Income Tax",
            at: "2026-08-28T12:00:00", summary: "8 renames · 12 moved",
            undoneAt: nil, undoSummary: nil, canUndo: true, hasEmptiedFolders: true)
        let britain = Locale(identifier: "en_GB")
        let appliedLine = RestructureLens.reorganisationLine(applied, now: now, locale: britain)
        #expect(appliedLine == "Applied on 28 Aug 2026 at 12:00 — 8 renames · 12 moved.")
        #expect(!appliedLine.contains("Undone"))

        let undone = ReorganisationDisplay(
            manifestId: "m1", family: "Finance/US/Income Tax",
            at: "2026-08-28T12:00:00", summary: "8 renames · 12 moved",
            undoneAt: "2026-08-28T13:00:00", undoSummary: "8 renames · 11 moved · 1 skipped",
            canUndo: false, hasEmptiedFolders: false)
        let undoneLine = RestructureLens.reorganisationLine(undone, now: now, locale: britain)
        #expect(undoneLine.contains("Undone on 28 Aug 2026 at 13:00"))
        #expect(undoneLine.contains("1 skipped"),
                "an undo never pretends the tree was untouched")
        #expect(undoneLine.contains("named in the log"))
        #expect(!undoneLine.hasPrefix("Applied"))
    }

    /// The stamp-in-words rule: today and yesterday by name, the absolute form beyond, and an
    /// unparseable stamp rendered as itself, since a raw truth beats a pretty invention.
    @Test func theLandingPhraseSpeaksInWords() {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = .current
        parser.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let now = parser.date(from: "2026-08-28T15:00:00")!
        let britain = Locale(identifier: "en_GB")
        #expect(RestructureLens.landingPhrase("2026-08-28T09:14:00", now: now, locale: britain)
                == "today at 09:14")
        #expect(RestructureLens.landingPhrase("2026-08-27T18:40:00", now: now, locale: britain)
                == "yesterday at 18:40")
        #expect(RestructureLens.landingPhrase("2026-08-12T08:00:00", now: now, locale: britain)
                == "on 12 Aug 2026 at 08:00")
        #expect(RestructureLens.landingPhrase("not-a-stamp", now: now) == "not-a-stamp")
    }

    /// The clock and date follow the reader's region: a 12-hour, month-first region reads the
    /// stamps that way, which a fixed format can't. (U+202F is the narrow no-break space macOS
    /// puts before AM/PM.)
    @Test func theLandingPhraseFollowsTheReadersClockAndRegion() {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = .current
        parser.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let now = parser.date(from: "2026-08-28T15:00:00")!
        let us = Locale(identifier: "en_US")
        #expect(RestructureLens.landingPhrase("2026-08-28T14:04:00", now: now, locale: us)
                == "today at 2:04\u{202F}PM")
        #expect(RestructureLens.landingPhrase("2026-08-12T08:00:00", now: now, locale: us)
                == "on Aug 12, 2026 at 8:00\u{202F}AM")
    }

    // MARK: Render smoke

    /// The lens renders both card states offscreen, so a layout crash fails here, not at first
    /// apply on a real tree.
    @Test func theLensRendersAppliedAndUndoneCards() throws {
        let lens = RestructureLens(
            findings: [], hasProfile: true, folderCount: 10,
            accent: .blue, onReveal: { _ in }, hasReviewed: true,
            reorganisations: [
                ReorganisationDisplay(manifestId: "m1", family: "Finance/US/Income Tax",
                                      at: "t1", summary: "1 rename · 2 moved",
                                      undoneAt: nil, undoSummary: nil,
                                      canUndo: true, hasEmptiedFolders: true),
                ReorganisationDisplay(manifestId: "m0", family: "Immigration/H-4",
                                      at: "t0", summary: "2 renames · 0 moved",
                                      undoneAt: "t2", undoSummary: "2 renames · 0 moved",
                                      canUndo: false, hasEmptiedFolders: false),
            ],
            onUndoReorganisation: { _ in }, onRemoveEmptied: { _ in })
        // An ink floor, not a width: `fittingSize.width > 0` holds for an empty `VStack`.
        let rep = try #require(RestructureRender.raster(lens, width: 640, height: 480))
        #expect(RestructureRender.inkedPixels(rep) > 1000)
    }

    @Test func theRemovalSheetRendersItsCandidates() throws {
        let sheet = RestructureRemovalSheet(
            candidates: [
                .init(path: "Finance/US/Income Tax/2013/State Tax", isStillEmpty: true),
                .init(path: "Finance/US/Income Tax/2013/2013", isStillEmpty: true),
                .init(path: "Finance/US/Income Tax/2016/Payment", isStillEmpty: false),
            ],
            accent: .blue, onRemove: { _ in .landed(removed: 1, skippedCount: 0, caveat: nil) },
            onClose: {})
        // An ink floor, not a width: `fittingSize.width > 0` holds for an empty `VStack`.
        let rep = try #require(RestructureRender.raster(sheet, width: 480, height: 400))
        #expect(RestructureRender.inkedPixels(rep) > 1000)
    }

    // MARK: The plan sheet's disk root

    /// `FolderProfile.root` is stored tilde-abbreviated, and `URL(fileURLWithPath:)` doesn't expand
    /// tildes: unexpanded, the sheet's tree reads `<cwd>/~/Documents`, every listing is nil, and
    /// Plan… derives nothing. This is the one spelling the sheet's wiring goes through.
    @Test func thePlanDiskRootExpandsTheTilde() {
        #expect(LensWorkspaceView.planDiskRoot("~/Documents").path
                    == NSHomeDirectory() + "/Documents")
        #expect(LensWorkspaceView.planDiskRoot("~").path == NSHomeDirectory())
        #expect(LensWorkspaceView.planDiskRoot("/tmp/absolute").path == "/tmp/absolute",
                "an already-absolute root passes through untouched")
    }

    /// The call site, pinned by source scan: the helper test above stays green if the wiring
    /// reverts to the bare `URL(fileURLWithPath: profile.root)`, which resolves a tilde root
    /// against cwd.
    @Test func thePlanSheetWiringGoesThroughPlanDiskRoot() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FileExplorer (tests)
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // Modules/FileExplorer
            .appendingPathComponent("Sources/FileExplorer/LensWorkspaceView.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        #expect(text.contains(".fromDisk(root: Self.planDiskRoot(profile.root)).memoized()"),
                "the sheet's tree must go through the expanding, memoizing spelling")
        #expect(!text.contains("fromDisk(root: URL(fileURLWithPath: profile.root)"),
                "the bare spelling is the shipped bug — a tilde root resolves against cwd")
    }

    // MARK: The stamp, written and read across the module boundary

    /// The ledger cards parse `AppliedRecord.at` back into words, and the writer lives in Sync.
    /// The phrase tests above feed literal strings, so this round-trips a stamp the real writer
    /// produced: if the writer gains fractional seconds or a zone suffix, the phrase falls back to
    /// the raw stamp and this fails.
    @Test func theLedgerStampRoundTripsThroughTheSharedWriter() {
        let instant = Date(timeIntervalSince1970: 1_756_400_000)
        let stamp = FilingArtifactStamp.string(from: instant)
        let phrase = RestructureLens.landingPhrase(stamp, now: instant)
        #expect(phrase.hasPrefix("today at "),
                "a stamp written now must read as words, not as \(stamp)")
        #expect(!phrase.contains("T"), "the raw-stamp fallback leaks the literal T")
    }

    // MARK: The removal sheet's landing sentence

    /// The three shapes of "landed", from the engine's own counts: a bare "Moved to the Trash"
    /// would be false over a run that skipped some or every ticked folder.
    @Test func theRemovalLandingSentenceFollowsTheCounts() {
        let clean = RestructureRemovalSheet.landedSentence(removed: 2, skippedCount: 0,
                                                          caveat: nil)
        #expect(clean.contains("Moved to the Trash") && clean.contains("Undo"))

        let partial = RestructureRemovalSheet.landedSentence(removed: 2, skippedCount: 1,
                                                            caveat: nil)
        #expect(partial.contains("Moved 2 folders") && partial.contains("1 skipped"),
                "a partial landing names both counts")

        let none = RestructureRemovalSheet.landedSentence(removed: 0, skippedCount: 3,
                                                         caveat: nil)
        #expect(none.contains("Nothing was moved"),
                "an all-skip landing must not claim anything was trashed")
        #expect(!none.contains("Undo"),
                "nothing moved, so there is nothing the undo sentence could promise back")

        let caveated = RestructureRemovalSheet.landedSentence(
            removed: 1, skippedCount: 0, caveat: "the survey could not be refreshed")
        #expect(caveated.contains("Moved to the Trash")
                && caveated.contains("the survey could not be refreshed"),
                "the caveat composes with the landing, never replaces it")
    }

    // MARK: The badge call site

    /// The rail badge's filter, pinned at its call site: `carriesPlan` is table-pinned in the store
    /// tests, but a badge counting every finding would fail nowhere else.
    @Test func theRailBadgeCountsOnlyPlanBearingKinds() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FileExplorer (tests)
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // Modules/FileExplorer
            .appendingPathComponent("Sources/FileExplorer/LensWorkspaceView.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        #expect(text.contains("restructure: structureFindings.count {\n                $0.kind.carriesPlan"),
                "the badge must filter on carriesPlan before it counts")
    }

    // MARK: The plan sheet's lockdown seam

    /// One seam for "finished or busy", read by the whole editing surface. Without it, a row edit
    /// after a successful Apply clears the outcome, un-retires the sheet and re-arms Export, which
    /// mints a "Planned, not applied" draft over a landed reorganisation.
    @Test func thePlanSheetEditorsLockOnTheOneSeam() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/FileExplorer/RestructurePlanSheet.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        #expect(text.contains("private var locked: Bool { applying || isApplied }"),
                "the seam itself")
        #expect(text.contains(".disabled(locked)"),
                "the editing surface must read the seam")
        #expect(text.contains("guard !isApplied else { return }"),
                "the outcome-clearing onChange must not un-retire an applied sheet")
    }
}

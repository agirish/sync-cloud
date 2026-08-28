import Foundation
import SwiftUI
import Sync
import Testing
@testable import FileExplorer

/// §5.5's surfaces: the removal sheet's split-by-name rule, and §5.7's Applied/Undone card
/// sentences — the text rules tested as text, the views as render smoke.
@MainActor
@Suite struct RestructureApplySurfaceTests {

    // MARK: The removal split (§5.5)

    /// An empty date bucket is debt and starts ticked; an empty category is a destination and
    /// does not. The split is by the shape of the NAME — a year, or a year span.
    @Test func theRemovalSplitReadsTheShapeOfTheName() {
        #expect(RestructureRemovalSheet.Candidate.isDateBucket("Finance/US/Income Tax/2016"))
        #expect(RestructureRemovalSheet.Candidate.isDateBucket("Immigration/H-1B/2016-2019"))
        #expect(!RestructureRemovalSheet.Candidate.isDateBucket("Finance/US/Income Tax/Payment"))
        #expect(!RestructureRemovalSheet.Candidate.isDateBucket("Tax/2013/State Tax"),
                "a category under a year is still a category")
    }

    // MARK: §5.7's sentences

    /// Applied and Undone are different claims and neither borrows the other's words — and the
    /// Undone line carries the undo run's own counts, because an undo never pretends the tree
    /// was untouched. The stamp renders in WORDS: this was the one user sentence in the app
    /// carrying the ledger's machine stamp verbatim, literal `T` included.
    @Test func appliedAndUndoneNeverBorrowEachOthersWords() {
        // A fixed "now" well after the stamp's day, so the phrase is the absolute form and the
        // test does not depend on the day it runs.
        let now = ISO8601DateFormatter().date(from: "2026-09-20T10:00:00Z")!
        let applied = ReorganisationDisplay(
            manifestId: "m1", family: "Finance/US/Income Tax",
            at: "2026-08-28T12:00:00", summary: "8 renames · 12 moved",
            undoneAt: nil, undoSummary: nil, canUndo: true, hasEmptiedFolders: true)
        let appliedLine = RestructureLens.reorganisationLine(applied, now: now)
        #expect(appliedLine == "Applied on 28 Aug 2026 at 12:00 — 8 renames · 12 moved.")
        #expect(!appliedLine.contains("Undone"))

        let undone = ReorganisationDisplay(
            manifestId: "m1", family: "Finance/US/Income Tax",
            at: "2026-08-28T12:00:00", summary: "8 renames · 12 moved",
            undoneAt: "2026-08-28T13:00:00", undoSummary: "8 renames · 11 moved · 1 skipped",
            canUndo: false, hasEmptiedFolders: false)
        let undoneLine = RestructureLens.reorganisationLine(undone, now: now)
        #expect(undoneLine.contains("Undone on 28 Aug 2026 at 13:00"))
        #expect(undoneLine.contains("1 skipped"),
                "an undo never pretends the tree was untouched")
        #expect(undoneLine.contains("named in the log"))
        #expect(!undoneLine.hasPrefix("Applied"))
    }

    /// The stamp-in-words rule itself: today and yesterday by name, the absolute form beyond,
    /// and an unparseable stamp rendered as itself — a wrong spelling of the truth beats a
    /// pretty invention.
    @Test func theLandingPhraseSpeaksInWords() {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = .current
        parser.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let now = parser.date(from: "2026-08-28T15:00:00")!
        #expect(RestructureLens.landingPhrase("2026-08-28T09:14:00", now: now)
                == "today at 09:14")
        #expect(RestructureLens.landingPhrase("2026-08-27T18:40:00", now: now)
                == "yesterday at 18:40")
        #expect(RestructureLens.landingPhrase("2026-08-12T08:00:00", now: now)
                == "on 12 Aug 2026 at 08:00")
        #expect(RestructureLens.landingPhrase("not-a-stamp", now: now) == "not-a-stamp")
    }

    // MARK: Render smoke

    /// The lens renders both card states offscreen — a layout crash fails here, not at first
    /// apply on a real tree.
    @Test func theLensRendersAppliedAndUndoneCards() {
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
        let hosting = NSHostingView(rootView: lens.frame(width: 640, height: 480))
        hosting.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        hosting.layoutSubtreeIfNeeded()
        #expect(hosting.fittingSize.width > 0)
    }

    @Test func theRemovalSheetRendersItsCandidates() {
        let sheet = RestructureRemovalSheet(
            family: "Finance/US/Income Tax",
            candidates: [
                .init(path: "Finance/US/Income Tax/2013/State Tax", isStillEmpty: true),
                .init(path: "Finance/US/Income Tax/2013/2013", isStillEmpty: true),
                .init(path: "Finance/US/Income Tax/2016/Payment", isStillEmpty: false),
            ],
            accent: .blue, onRemove: { _ in nil }, onClose: {})
        let hosting = NSHostingView(rootView: sheet.frame(width: 480, height: 400))
        hosting.frame = NSRect(x: 0, y: 0, width: 480, height: 400)
        hosting.layoutSubtreeIfNeeded()
        #expect(hosting.fittingSize.width > 0)
    }
}

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
    /// was untouched.
    @Test func appliedAndUndoneNeverBorrowEachOthersWords() {
        let applied = ReorganisationDisplay(
            manifestId: "m1", family: "Finance/US/Income Tax",
            at: "2026-08-28T12:00:00", summary: "8 renames · 12 moved",
            undoneAt: nil, undoSummary: nil, canUndo: true, hasEmptiedFolders: true)
        let appliedLine = RestructureLens.reorganisationLine(applied)
        #expect(appliedLine == "Applied 2026-08-28T12:00:00 — 8 renames · 12 moved.")
        #expect(!appliedLine.contains("Undone"))

        let undone = ReorganisationDisplay(
            manifestId: "m1", family: "Finance/US/Income Tax",
            at: "2026-08-28T12:00:00", summary: "8 renames · 12 moved",
            undoneAt: "2026-08-28T13:00:00", undoSummary: "8 renames · 11 moved · 1 skipped",
            canUndo: false, hasEmptiedFolders: false)
        let undoneLine = RestructureLens.reorganisationLine(undone)
        #expect(undoneLine.contains("Undone 2026-08-28T13:00:00"))
        #expect(undoneLine.contains("1 skipped"),
                "an undo never pretends the tree was untouched")
        #expect(undoneLine.contains("named in the log"))
        #expect(!undoneLine.hasPrefix("Applied"))
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

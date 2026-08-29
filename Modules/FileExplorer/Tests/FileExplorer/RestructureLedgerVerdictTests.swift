import Foundation
import SwiftUI
import Sync
import Testing
@testable import FileExplorer

/// §5.7's Applied card gains the two facts it was missing: what step 4's verifier concluded, and
/// why an older landing's undo is not on offer (proposal O11).
@MainActor
@Suite struct RestructureLedgerVerdictTests {

    // MARK: The verifier's verdict

    /// **Absent is not a pass.** Every record written before the field existed decodes with it
    /// nil, and a landing that refused before the verifier ran has nothing to report — both say
    /// nothing rather than claiming the tree checked out.
    @Test func aRecordWithNoVerdictSaysNothing() {
        #expect(RestructureLens.verifierLine(verifiedOK: nil, note: nil) == nil)
        #expect(RestructureLens.verifierLine(verifiedOK: nil, note: "ignored") == nil,
                "a note without a verdict is still not a verdict")
    }

    @Test func agreementAndDisagreementReadDifferently() throws {
        let ok = try #require(RestructureLens.verifierLine(verifiedOK: true, note: nil))
        #expect(ok.contains("Verified"))
        #expect(!ok.contains("disagreement"))

        let bad = try #require(RestructureLens.verifierLine(
            verifiedOK: false, note: "Forms/ is missing after its move"))
        #expect(bad.contains("disagreement"))
        #expect(bad.contains("Forms/ is missing after its move"),
                "the card names what disagreed, not just that something did")
        #expect(!bad.contains("Verified"))
    }

    /// A verdict of false with no note still says something — the log has it.
    @Test func aDisagreementWithNoNoteStillPointsSomewhere() throws {
        let line = try #require(RestructureLens.verifierLine(verifiedOK: false, note: nil))
        #expect(line.contains("log"))
    }

    // MARK: Why an older landing offers no undo

    /// The ledger unwinds newest first. Saying so on the card is the difference between a row
    /// with no button and a mystery.
    @Test func anOlderLandingSaysWhyItsUndoIsNotOffered() {
        #expect(RestructureLens.blockedByNewerText.contains("newer"))
        #expect(RestructureLens.blockedByNewerText.contains("newest back"))
    }

    /// **The order comes from the store, not the view.** A second copy of that rule is how a card
    /// ends up offering an undo the engine refuses — the exact defect a previous round moved
    /// everything onto `undoableReorganisation` to prevent.
    @Test func theCardReadsTheStoresUndoOrder() throws {
        let host = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/FileExplorer/LensWorkspaceView.swift"),
            encoding: .utf8)
        #expect(host.contains("undoableReorganisation("))
        #expect(host.contains("record.manifest.manifestId != undoableId"),
                "the blocked reason is derived from the same id the button is")
    }

    /// The undoable record shows no blocked reason, and an undone one shows neither.
    @Test func onlyABlockedRecordCarriesTheReason() {
        let undoable = ReorganisationDisplay(
            manifestId: "new", family: "F", at: "t", summary: "s", undoneAt: nil,
            undoSummary: nil, canUndo: true, hasEmptiedFolders: false,
            verifierLine: nil, blockedReason: nil)
        #expect(undoable.blockedReason == nil)

        let blocked = ReorganisationDisplay(
            manifestId: "old", family: "F", at: "t", summary: "s", undoneAt: nil,
            undoSummary: nil, canUndo: false, hasEmptiedFolders: false,
            verifierLine: nil, blockedReason: RestructureLens.blockedByNewerText)
        #expect(blocked.canUndo == false)
        #expect(blocked.blockedReason != nil)
    }

    /// Both new lines render on a real card.
    @Test func theCardRendersItsVerdictAndItsBlockedReason() {
        let lens = RestructureLens(
            findings: [], hasProfile: true, folderCount: 10,
            accent: .blue, onReveal: { _ in }, hasReviewed: true,
            reorganisations: [
                ReorganisationDisplay(
                    manifestId: "m2", family: "Finance/US/Income Tax", at: "2026-08-28T12:00:00",
                    summary: "8 renames · 41 moved", undoneAt: nil, undoSummary: nil,
                    canUndo: true, hasEmptiedFolders: true,
                    verifierLine: RestructureLens.verifierLine(verifiedOK: true, note: nil),
                    blockedReason: nil),
                ReorganisationDisplay(
                    manifestId: "m1", family: "Immigration/H-4", at: "2026-08-27T09:00:00",
                    summary: "2 renames", undoneAt: nil, undoSummary: nil,
                    canUndo: false, hasEmptiedFolders: false,
                    verifierLine: RestructureLens.verifierLine(
                        verifiedOK: false, note: "Forms/ is missing after its move"),
                    blockedReason: RestructureLens.blockedByNewerText),
            ],
            onUndoReorganisation: { _ in })
        let hosting = NSHostingView(rootView: lens.frame(width: 640, height: 420))
        hosting.frame = NSRect(x: 0, y: 0, width: 640, height: 420)
        hosting.layoutSubtreeIfNeeded()
        #expect(hosting.fittingSize.width > 0)
    }
}

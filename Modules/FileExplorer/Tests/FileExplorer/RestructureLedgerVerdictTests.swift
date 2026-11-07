import Foundation
import SwiftUI
import Sync
import Testing
@testable import FileExplorer

/// The Applied card's two facts beyond the summary: what the landing's verifier concluded, and why
/// an older landing's undo isn't on offer.
@MainActor
@Suite struct RestructureLedgerVerdictTests {

    // MARK: The verifier's verdict

    /// Absent is not a pass. An older record decodes with no verdict, and a landing that refused
    /// before the verifier ran has none; both say nothing rather than claim the tree checked out.
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

    /// A verdict of false with no note still says something: the log has it.
    @Test func aDisagreementWithNoNoteStillPointsSomewhere() throws {
        let line = try #require(RestructureLens.verifierLine(verifiedOK: false, note: nil))
        #expect(line.contains("log"))
    }

    // MARK: Why an older landing offers no undo

    /// The ledger unwinds newest first, and the card says so, or a row with no button is a mystery.
    @Test func anOlderLandingSaysWhyItsUndoIsNotOffered() {
        #expect(RestructureLens.blockedByNewerText.contains("newer"))
        #expect(RestructureLens.blockedByNewerText.contains("newest back"))
    }

    // MARK: The mapping itself

    private static func record(_ id: String, undoneAt: String? = nil, summary: String? = "s",
                               verifiedOK: Bool? = nil, verifierNote: String? = nil,
                               under: String? = "p") -> RestructureStore.AppliedRecord {
        let manifest = RestructureManifest(
            profileId: "p", manifestId: id, createdAt: "t", family: "Tax", kind: .shape,
            actions: [.init(action: .renameDir, src: "Tax/A", dst: "Tax/B", filesCarried: 1)])
        var r = RestructureStore.AppliedRecord(
            manifest: manifest, inverse: manifest.inverse, at: "2026-08-2\(id.count)T09:00:00",
            created: 0, skipped: 0, appliedUnderProfileId: under,
            verifiedOK: verifiedOK, verifierNote: verifierNote)
        r.undoneAt = undoneAt
        r.summary = summary
        return r
    }

    /// Every clause of the card mapping, at its call site: nulling the verdict, dropping the
    /// `undoneAt` half of the block reason, or inverting the scaffold filter must each fail here.
    @Test func theRowsCarryEveryClauseOfTheMapping() throws {
        let rows = ReorganisationDisplay.rows(
            from: [Self.record("old", verifiedOK: false, verifierNote: "Forms/ is missing"),
                   Self.record("new", verifiedOK: true)],
            undoableId: "new",
            stillHasEmptiedFolders: { _ in true })

        #expect(rows.map(\.manifestId) == ["new", "old"], "newest first")

        let newest = try #require(rows.first)
        #expect(newest.canUndo)
        #expect(newest.blockedReason == nil, "nothing stands in the undoable record's way")
        #expect(newest.verifierLine == RestructureLens.verifierLine(verifiedOK: true, note: nil))
        #expect(newest.hasEmptiedFolders)

        let older = try #require(rows.last)
        #expect(!older.canUndo)
        #expect(older.blockedReason == RestructureLens.blockedByNewerText)
        #expect(older.verifierLine?.contains("Forms/ is missing") == true,
                "the note travels, not just the verdict")
    }

    /// The two halves of the block reason, each on its own. An undone landing isn't "blocked by
    /// something newer", it is finished; and with nothing undoable there is no newer thing to name.
    @Test func anUndoneOrUnblockedRecordCarriesNoReason() throws {
        let undone = ReorganisationDisplay.rows(
            from: [Self.record("old", undoneAt: "2026-08-28T10:00:00"), Self.record("new")],
            undoableId: "new", stillHasEmptiedFolders: { _ in true })
        #expect(undone.last?.blockedReason == nil, "an undone landing is finished, not blocked")
        #expect(undone.last?.hasEmptiedFolders == false,
                "and its drained folders were put back")

        let noneUndoable = ReorganisationDisplay.rows(
            from: [Self.record("a"), Self.record("b")],
            undoableId: nil, stillHasEmptiedFolders: { _ in true })
        #expect(noneUndoable.allSatisfy { $0.blockedReason == nil },
                "with nothing undoable there is no newer landing to name")
    }

    /// A landing whose Undo a walk back withheld says why, alone and when a newer landing is
    /// undoable too: undoing that one wouldn't bring this one back.
    @Test func aWithheldUndoSaysWhy() throws {
        var withheld = Self.record("old")
        withheld.undoWithheldBy = "~/Documents/Tax"
        let alone = ReorganisationDisplay.rows(from: [withheld], undoableId: nil,
                                               stillHasEmptiedFolders: { _ in true })
        let reason = RestructureLens.withheldText(by: "~/Documents/Tax")
        #expect(alone.first?.blockedReason == reason, "a withheld Undo showed no reason")
        #expect(reason.contains("~/Documents/Tax"))
        let underNewer = ReorganisationDisplay.rows(from: [withheld, Self.record("new")],
                                                    undoableId: "new",
                                                    stillHasEmptiedFolders: { _ in true })
        #expect(underNewer.last?.blockedReason == reason)
        #expect(underNewer.first?.blockedReason == nil)

        // Withheld because the other folder's history couldn't say: no reorganization is blamed.
        withheld.undoWithheldUnsure = true
        let unsure = ReorganisationDisplay.rows(from: [withheld], undoableId: nil,
                                                stillHasEmptiedFolders: { _ in true })
        let unsureReason = try #require(unsure.first?.blockedReason)
        #expect(unsureReason == RestructureLens.withheldText(by: "~/Documents/Tax", unsure: true))
        #expect(!unsureReason.contains("has moved"), "an unreadable history was blamed as a reorganization")
        #expect(!unsureReason.contains("any more") && !reason.contains("any more"))
    }

    /// The filter and the two fallbacks: a scaffold (no `appliedUnderProfileId`) is not a plan
    /// landing, an unfinished record still gets a card, and the disk probe can veto the button.
    @Test func scaffoldsAreExcludedAndAnUnfinishedRecordStillShows() throws {
        let rows = ReorganisationDisplay.rows(
            from: [Self.record("scaffold", under: nil), Self.record("half", summary: nil)],
            undoableId: nil, stillHasEmptiedFolders: { _ in true })
        #expect(rows.map(\.manifestId) == ["half"], "a scaffold is not a plan landing")
        #expect(rows[0].summary.contains("did not finish recording"))
        #expect(rows[0].hasEmptiedFolders == false, "an unfinished record offers no removal")

        let probed = ReorganisationDisplay.rows(
            from: [Self.record("m")], undoableId: "m", stillHasEmptiedFolders: { _ in false })
        #expect(probed[0].hasEmptiedFolders == false,
                "the disk probe alone can withdraw the button")
    }


    private static func ledgerLens(verifier: Bool, blocked: Bool) -> RestructureLens {
        RestructureLens(
            findings: [], hasProfile: true, folderCount: 10,
            accent: .blue, onReveal: { _ in }, hasReviewed: true,
            reorganisations: [
                ReorganisationDisplay(
                    manifestId: "m2", family: "Finance/US/Income Tax", at: "2026-08-28T12:00:00",
                    summary: "8 renames · 41 moved", undoneAt: nil, undoSummary: nil,
                    canUndo: true, hasEmptiedFolders: true,
                    verifierLine: verifier
                        ? RestructureLens.verifierLine(verifiedOK: true, note: nil) : nil,
                    blockedReason: nil),
                ReorganisationDisplay(
                    manifestId: "m1", family: "Immigration/H-4", at: "2026-08-27T09:00:00",
                    summary: "2 renames", undoneAt: nil, undoSummary: nil,
                    canUndo: false, hasEmptiedFolders: false,
                    verifierLine: verifier
                        ? RestructureLens.verifierLine(
                            verifiedOK: false, note: "Forms/ is missing after its move") : nil,
                    blockedReason: blocked ? RestructureLens.blockedByNewerText : nil),
            ],
            onUndoReorganisation: { _ in })
    }

    /// The verdict line and the blocked reason are each drawn, toggled one at a time and the
    /// pixels compared, so deleting either fails.
    @Test func theCardRendersItsVerdictAndItsBlockedReason() throws {
        let bare = try #require(RestructureRender.raster(
            Self.ledgerLens(verifier: false, blocked: false), width: 640, height: 420))
        #expect(RestructureRender.inkedPixels(bare) > 0, "the ledger drew its rows")

        let withVerdict = try #require(RestructureRender.raster(
            Self.ledgerLens(verifier: true, blocked: false), width: 640, height: 420))
        #expect(RestructureRender.differingPixels(bare, withVerdict) > 200,
                "step 4's verdict is on the card")

        let withBoth = try #require(RestructureRender.raster(
            Self.ledgerLens(verifier: true, blocked: true), width: 640, height: 420))
        #expect(RestructureRender.differingPixels(withVerdict, withBoth) > 200,
                "and the blocked reason is its own line, not a re-render of the verdict")
    }
}

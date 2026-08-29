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

    /// **Every clause of the card mapping, at the call site.** These all used to live in a
    /// private `var` on the workspace, where each was unreachable: the verdict could be nulled,
    /// the `undoneAt` half of the block reason dropped, and the scaffold filter inverted, with
    /// the suite green throughout.
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

    /// The two halves of the block reason, each mutated on its own. An undone landing is not
    /// "blocked by something newer" — it is finished — and with nothing undoable at all there is
    /// no newer thing to name.
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

    /// **Both new lines are drawn, and each on its own.** The previous closer here was
    /// `fittingSize.width > 0`, which passed with the verdict line and the blocked reason both
    /// deleted — so the two are toggled one at a time and the pixels compared.
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

import Design
import Foundation
import Sync

/// *Undo this reorganisation*, from the Applied card and from Organize ▸ Undo This Reorganisation.
///
/// **One path, and it asks first.** Both surfaces used to call the engine directly: one click on a
/// plain text link — or one menu item — ran a landing's stored inverse, which can move hundreds of
/// files, with no question and no redo. And a success said nothing at all, so from the menu with
/// Restructure off screen the files moved and the window stayed silent.
///
/// `confirmChange`, not `confirmDestructive`: the inverse moves files back to where they were and
/// trashes nothing, and the red caution style is kept for the dialogs that really do.
@MainActor
public enum ReorganisationUndo {

    /// What the question says — the family, when the landing was, and the ledger's own sentence for
    /// what it did, so the person can see what is about to be reversed.
    static func question(for record: RestructureStore.AppliedRecord,
                         now: Date = Date()) -> (title: String, detail: String) {
        let family = record.manifest.family
        let title = family == "." || family.isEmpty
            ? "Undo the reorganisation across the tree?"
            : "Undo the reorganisation of “\(family)”?"
        let did = record.summary.map { " It did: \($0)." } ?? ""
        let detail = "Applied \(RestructureLens.landingPhrase(record.at, now: now)).\(did) "
            + "Undoing moves those files and folders back and points the folder survey at the tree "
            + "as it was. This is not ⌘Z, and it can’t be redone."
        return (title, detail)
    }

    /// The banner an undo leaves — success included.
    static func banner(after outcome: FileSyncManager.RestructureApplyOutcome) -> OperationBanner {
        if let refusal = outcome.refusal { return .warning(refusal) }
        if let failure = outcome.surveyRefreshFailure { return .warning(failure) }
        if !outcome.skipped.isEmpty || !outcome.verifierMismatches.isEmpty {
            return .warning("Reorganisation undone — \(outcome.summary). The log names what "
                            + "could not be moved back.")
        }
        return .success("Reorganisation undone — \(outcome.summary).")
    }

    /// Asks, then runs the inverse and reports. A record the ledger no longer has is not asked
    /// about: the engine refuses it and says why, which is the answer worth showing.
    public static func run(
        manifestId: String,
        on manager: FileSyncManager,
        confirm: (_ title: String, _ detail: String) -> Bool = { title, detail in
            NativeAlerts.confirmChange(messageText: title, informativeText: detail,
                                       confirmTitle: "Undo Reorganisation")
        }
    ) async {
        if let record = manager.restructureStore?.applied
            .first(where: { $0.manifest.manifestId == manifestId }) {
            let question = question(for: record)
            guard confirm(question.title, question.detail) else { return }
        }
        let outcome = await manager.undoReorganisation(manifestId: manifestId)
        manager.banner = banner(after: outcome)
    }
}

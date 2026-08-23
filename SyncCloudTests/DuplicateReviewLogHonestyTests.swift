import Testing
import Foundation

/// Pins the one thing `DuplicateReviewCoordinator` says about a trash that may not have been one.
///
/// **A scan, and the reason it used to give is no longer true.** It said `trashRightCopy` reaches
/// the Trash through a `deleteItems(at:)` taking its OWN defaulted file manager, so no injection
/// could drive the permanent-delete branch. That call now passes `fileManager: fm` — the manager's
/// own, the one the coordinator's drift assessment already measures through, which is what makes
/// the gate and the removal answer for the same filesystem. `aPermanentlyDeletedRightCopyIs…` in
/// `DuplicateReviewCoordinatorTests` (where the harness lives) is that branch driven for real;
/// this scan stays as the cheap structural guard beside it.
///
/// What it guards: `deleteItems` answers a `DeleteOutcome` separating "reached the Trash" from
/// "destroyed permanently", and this caller logged "Trashed the right duplicate copy" for both. On
/// a Trash-less volume — exFAT, most SMB shares — that names a Trash which never received the copy,
/// in the log he audits. Reverting the line to its unconditional form drops both the branch and the
/// second sentence, which is what the assertions below are looking for.
@Suite struct DuplicateReviewLogHonestyTests {

    /// Located from this file and comment-stripped inline, rather than through the shared helpers:
    /// `macAppDirectory`/`sourceCodeOnly` exist on `main` and not on the maintenance lines, and the
    /// caller this pins is on both. Self-contained, so the file cherry-picks between them unchanged.
    private static func coordinatorSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // …/SyncCloudTests
            .deletingLastPathComponent()      // repo root
            .appendingPathComponent("MacApp/DuplicateReviewCoordinator.swift")
        let text = try #require(try? String(contentsOf: url, encoding: .utf8),
                                "DuplicateReviewCoordinator.swift could not be read — this scan would be vacuous")
        #expect(text.count > 5_000,
                "read only \(text.count) characters — not the real file, so the checks below prove nothing")
        // Whole-line comments removed: the prose around this branch quotes both sentences, and a
        // scan that counts a comment as the code would pass with the branch deleted.
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    @Test func theTrashOfTheRightCopyLogsWhichWayItActuallyWent() throws {
        let code = try Self.coordinatorSource()
        // The premise: this really is the site that removes the right copy. Without it a rename of
        // the call would leave every assertion below quietly true of a file that no longer deletes
        // anything.
        // The call carries two things a revert would drop, so both are pinned: the last-moment
        // `removalGate` (the drift re-check `deleteItems` runs when the queued operation starts and
        // again after a confirmed permanent delete), and the explicit `fileManager:`, without which
        // the gate re-assesses through the manager's file manager while the removal reaches for
        // `FileManager.default`.
        //
        // Three fragments rather than one literal: this pinned the whole call as a SPELLING, and
        // inserting the argument between `at:` and `removalGate:` broke it while the subject sat
        // exactly where it always had. A scan that fails on formatting is a scan that gets relaxed
        // under pressure.
        #expect(code.contains("deleteItems(at: [review.deletePath]"),
                "the right copy is no longer removed here — this scan has lost its subject")
        #expect(code.contains("fileManager: fm"),
                "the removal no longer names a file manager, so it and its own gate can measure different filesystems")
        #expect(code.contains("removalGate:"),
                "the removal lost its last-moment gate")
        // The branch, and both of its answers. An unconditional revert loses all three.
        #expect(code.contains("outcome.trashed > 0"),
                "the log no longer asks how the copy left, so it reports one outcome for both")
        #expect(code.contains("Trashed the right duplicate copy"),
                "the trashed case lost its sentence")
        #expect(code.contains("Permanently deleted the right duplicate copy"),
                "a copy destroyed permanently is logged as “Trashed” — it names a Trash that never received it")
    }

    /// The guard on the removal itself, which the same edit converted: `removed` folded the two
    /// outcomes together, and `DeleteOutcome.removed` is what restores its exact old meaning.
    @Test func theRemovalGuardCountsBothWaysAnItemCanLeave() throws {
        let code = try Self.coordinatorSource()
        #expect(code.contains("outcome.removed > 0"),
                "the guard no longer asks whether the copy left by either route")
    }

    /// **The gate must refuse the set it was ASKED about.** It re-assesses the review's own pair,
    /// so echoing the argument is the same set by construction — while naming `review.deletePath`
    /// a second time is a set that can DIVERGE from it: `deleteItems` feeds the post-confirmation
    /// pass URL round-tripped paths, and a refusal it cannot match back is a refusal banner posted
    /// over a copy that was destroyed anyway. Scanned for the same structural reason as the rest of
    /// this file — the branch cannot be driven from a test without a Trash-less volume.
    @Test func theReviewsRemovalGateRefusesTheSetItWasAskedAbout() throws {
        let code = try Self.coordinatorSource()
        #expect(code.contains("removalGate: { about in"),
                "the gate no longer names its argument, so it cannot be answering about it")
        #expect(code.contains("return Set(about)"),
                "the gate's refusal is not the set it was asked about")
        #expect(!code.contains("return [review.deletePath]"),
                "the refusal names the review's own spelling again instead of the paths handed to it — a spelling the delete cannot match back fails open")
    }
}

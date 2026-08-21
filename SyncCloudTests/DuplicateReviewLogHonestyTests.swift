import Testing
import Foundation

/// Pins the one thing `DuplicateReviewCoordinator` says about a trash that may not have been one.
///
/// **A scan rather than a run, and the reason is structural.** `trashRightCopy` reaches the Trash
/// through `syncManager.deleteItems(at:)`, which takes its OWN defaulted file manager — the
/// `FileManaging` a test injects into the manager reaches only the keeper stat, as the coordinator
/// suite's harness documents. So no injection available to a test can make that call take the
/// permanent-delete branch; driving it for real would need a Trash-less volume. The branch is
/// therefore pinned where it is written.
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
        // The call now carries the last-moment `removalGate` (the drift re-check `deleteItems`
        // runs when the queued operation starts and again after a confirmed permanent delete), so
        // the pinned spelling includes it — a revert to the gateless call fails here on purpose.
        #expect(code.contains("deleteItems(at: [review.deletePath], removalGate:"),
                "the right copy is no longer removed here (or lost its removal gate) — this scan has lost its subject")
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
}

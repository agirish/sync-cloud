import Testing
import Foundation

/// Pins the one thing `DuplicateReviewCoordinator` says about a trash that may not have been one.
///
/// `deleteItems` answers a `DeleteOutcome` separating "reached the Trash" from "destroyed
/// permanently", and the log must say which. On a Trash-less volume (exFAT, most SMB shares) a
/// "Trashed" line would name a Trash that never received the copy, in the log he audits.
///
/// A cheap structural scan beside `aPermanentlyDeletedRightCopyIs…` in
/// `DuplicateReviewCoordinatorTests`, which drives the permanent-delete branch for real.
@Suite struct DuplicateReviewLogHonestyTests {

    /// Located and comment-stripped inline, not through the shared helpers, which the maintenance
    /// lines lack. Self-contained, so the file works unchanged on every line.
    private static func coordinatorSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // …/SyncCloudTests
            .deletingLastPathComponent()      // repo root
            .appendingPathComponent("MacApp/DuplicateReviewCoordinator.swift")
        let text = try #require(try? String(contentsOf: url, encoding: .utf8),
                                "DuplicateReviewCoordinator.swift could not be read — this scan would be vacuous")
        #expect(text.count > 5_000,
                "read only \(text.count) characters — not the real file, so the checks below prove nothing")
        // Whole-line comments removed: the prose around this branch quotes both sentences, so a
        // scan reading comments would pass with the branch deleted.
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    @Test func theTrashOfTheRightCopyLogsWhichWayItActuallyWent() throws {
        let code = try Self.coordinatorSource()
        // The premise: this is the site that removes the right copy, or a renamed call would leave
        // every assertion below quietly true of a file that deletes nothing.
        // Two arguments are pinned too: the last-moment `removalGate` (the drift re-check
        // `deleteItems` runs when the queued operation starts and after a confirmed permanent
        // delete), and the explicit `fileManager:`, without which the gate measures through the
        // manager's file manager while the removal uses `FileManager.default`.
        //
        // Three fragments, not one literal, so a reformatted call doesn't fail the scan.
        #expect(code.contains("deleteItems(at: [review.deletePath]"),
                "the right copy is no longer removed here — this scan has lost its subject")
        #expect(code.contains("fileManager: fm"),
                "the removal no longer names a file manager, so it and its own gate can measure different filesystems")
        #expect(code.contains("removalGate:"),
                "the removal lost its last-moment gate")
        // The branch and both its answers; an unconditional log line loses all three. It asks the
        // permanent count: a copy the Trash took without a location counts in neither `trashed`
        // nor `permanentlyDeleted`, so asking `trashed > 0` would log it as permanently deleted.
        #expect(code.contains("outcome.permanentlyDeleted == 0"),
                "the log no longer asks how the copy left, so it reports one outcome for both")
        #expect(code.contains("Trashed the right duplicate copy"),
                "the trashed case lost its sentence")
        #expect(code.contains("Permanently deleted the right duplicate copy"),
                "a copy destroyed permanently is logged as “Trashed” — it names a Trash that never received it")
    }

    /// The guard on the removal itself counts both ways a copy can leave, through
    /// `DeleteOutcome.removed`.
    @Test func theRemovalGuardCountsBothWaysAnItemCanLeave() throws {
        let code = try Self.coordinatorSource()
        #expect(code.contains("outcome.removed > 0"),
                "the guard no longer asks whether the copy left by either route")
    }

    /// The gate must refuse the set it was asked about. It re-assesses the review's own pair, so
    /// echoing the argument is the same set by construction, while naming `review.deletePath` again
    /// can diverge: `deleteItems` feeds the post-confirmation pass URL-round-tripped paths, and a
    /// refusal it can't match back posts a refusal banner over a copy destroyed anyway. Scanned,
    /// because the branch can't be driven without a Trash-less volume.
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

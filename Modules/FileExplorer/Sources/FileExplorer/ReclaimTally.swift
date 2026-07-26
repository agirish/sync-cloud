import SwiftUI

// MARK: - Reclaimed-space payoff (H5)

/// Accumulates the bytes reclaimed across resolves within one Tidy session — a view-level tally only,
/// deliberately not new engine/Sync state. Pure so the count-up payoff (H5) can be unit-tested.
///
/// The engine already publishes how much is *still* reclaimable (`duplicateSummary.reclaimableBytes`,
/// which counts down as groups resolve); this counts the payoff *up*, so the win the feature exists
/// for reads as a growing number rather than a shrinking one.
struct ReclaimTally: Equatable {
    /// Total bytes reclaimed so far this session.
    private(set) var totalBytes: Int = 0

    /// Credits a completed resolve. Non-positive deltas are ignored, so a failed or no-op resolve
    /// (or a batch that reclaimed nothing) never moves the counter — the number only ever grows.
    mutating func credit(_ bytes: Int) {
        guard bytes > 0 else { return }
        totalBytes += bytes
    }

    /// Clears the tally — a fresh scan starts a fresh session, so the "this session" figure is only
    /// ever earned by the current results' work.
    mutating func reset() {
        totalBytes = 0
    }

    var hasReclaimed: Bool { totalBytes > 0 }

    /// The bytes a BATCH resolve may credit, given the drop it caused in the engine's
    /// still-reclaimable figure and this tally's total read just before the batch started.
    ///
    /// The batch is measured by that drop rather than by the total its dialog promised, so a
    /// partial failure counts only what really landed. But the drop is a *shared* meter: a per-card
    /// resolve that completes while the batch runs credits its own `group.reclaimableBytes` to this
    /// tally AND lowers the engine's figure by the same bytes, so crediting the raw drop counts
    /// that group twice and "freed this session" overstates the win. Subtracting whatever this
    /// tally banked in the meantime attributes each group exactly once. Per-card resolves outside
    /// the batch-eligible set credit 0 here and move the engine's figure by 0, so they cancel out.
    func netBatchCredit(reclaimableDrop: Int, bankedAtStart: Int) -> Int {
        reclaimableDrop - (totalBytes - bankedAtStart)
    }

    /// The "… freed this session" caption from an already-formatted byte string. Formatting is kept
    /// out of this type on purpose — `ByteCountFormatter`'s output is locale-dependent, so the label
    /// stays deterministic and testable by taking the pre-formatted string. nil until something's
    /// been reclaimed, so the caller can hide the caption entirely at zero.
    func freedCaption(_ formattedBytes: String) -> String? {
        hasReclaimed ? "\(formattedBytes) freed this session" : nil
    }
}

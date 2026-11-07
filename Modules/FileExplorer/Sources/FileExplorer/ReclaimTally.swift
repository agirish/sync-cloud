import SwiftUI

// MARK: - Reclaimed-space payoff (H5)

/// The bytes reclaimed across resolves in one Duplicates session: a view-level tally, deliberately
/// not engine state, and pure so it can be unit-tested. The engine's
/// `duplicateSummary.reclaimableBytes` counts down as groups resolve; this counts the payoff up, so
/// the win reads as a growing number.
struct ReclaimTally: Equatable {
    /// Total bytes reclaimed so far this session.
    private(set) var totalBytes: Int = 0

    /// Credits a completed resolve. Non-positive deltas are ignored, so a failed or no-op resolve
    /// never moves the counter: it only grows.
    mutating func credit(_ bytes: Int) {
        guard bytes > 0 else { return }
        totalBytes += bytes
    }

    /// Clears the tally: a fresh scan starts a fresh session, so "this session" counts only the
    /// current results' work.
    mutating func reset() {
        totalBytes = 0
    }

    var hasReclaimed: Bool { totalBytes > 0 }

    /// The bytes a batch resolve may credit, given the drop it caused in the engine's
    /// still-reclaimable figure and this tally's total just before the batch started.
    ///
    /// Measured by the drop, not the dialog's promise, so a partial failure counts only what
    /// landed. The drop is a shared meter, though: a per-card resolve finishing mid-batch credits
    /// this tally and lowers the engine's figure too, so the raw drop would count it twice.
    /// Subtracting what this tally banked meanwhile counts each group once.
    func netBatchCredit(reclaimableDrop: Int, bankedAtStart: Int) -> Int {
        reclaimableDrop - (totalBytes - bankedAtStart)
    }

    /// The "… freed this session" caption from an already-formatted byte string, so the label
    /// stays testable despite `ByteCountFormatter`'s locale-dependent output. nil until something
    /// has been reclaimed, so the caller hides the caption at zero.
    func freedCaption(_ formattedBytes: String) -> String? {
        hasReclaimed ? "\(formattedBytes) freed this session" : nil
    }
}

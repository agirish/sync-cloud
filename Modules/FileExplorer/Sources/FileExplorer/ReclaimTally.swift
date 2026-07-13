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

    /// The "… freed this session" caption from an already-formatted byte string. Formatting is kept
    /// out of this type on purpose — `ByteCountFormatter`'s output is locale-dependent, so the label
    /// stays deterministic and testable by taking the pre-formatted string. nil until something's
    /// been reclaimed, so the caller can hide the caption entirely at zero.
    func freedCaption(_ formattedBytes: String) -> String? {
        hasReclaimed ? "\(formattedBytes) freed this session" : nil
    }
}

import Foundation

/// The differences a bulk copy or move could not transfer, published so the Differences table can
/// show *which* ones instead of naming the first and sending the user to the Activity Log.
///
/// `removeResolvedDifferences(matching:)` drops only the successes, so a partial run leaves its
/// failures in the list, but unmarked they look like rows never attempted and are lost in a large
/// diff. This marks them.
public struct TransferFailures: Equatable, Sendable {
    /// Per-publish identity, deliberately part of equality, as in `OperationBanner`: two runs that
    /// fail on the same rows have equal `ids`, and a view watching for new failures would miss the
    /// second.
    public let id: UUID
    /// The failed rows, by `FileDifference.id`.
    ///
    /// Ids, not values: a rescan regenerates every row's UUID, so a stale set matches nothing
    /// rather than resurrecting rows. No invalidation is needed beyond the clear on a new scan.
    public let ids: Set<UUID>

    public init(ids: Set<UUID>, id: UUID = UUID()) {
        self.id = id
        self.ids = ids
    }
}

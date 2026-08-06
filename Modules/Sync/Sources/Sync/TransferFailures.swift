import Foundation

/// The differences a bulk copy or move could not transfer, published so the Differences table can
/// show *which* ones instead of naming the first and sending the user to the Activity Log.
///
/// The rows are already there. `removeResolvedDifferences(matching:)` drops only the successes, so
/// a partial run leaves its failures sitting in the list — unmarked, indistinguishable from rows
/// that were never attempted, and (on a large diff) not findable at all. Every failed
/// `FileDifference` is in hand at the moment the alert is composed; before this it was thrown away.
public struct TransferFailures: Equatable, Sendable {
    /// Per-publish identity, deliberately part of equality — the same reason `OperationBanner`
    /// carries one. Two runs that fail on exactly the same rows produce an equal `ids` set, and a
    /// view watching for "new failures" would never see the second one: it would sit on whatever
    /// filter the user had switched back to, with a fresh alert on screen and nothing to click.
    public let id: UUID
    /// The failed rows, by `FileDifference.id`.
    ///
    /// Ids, not values: a rescan regenerates every row's UUID, so a stale set simply matches
    /// nothing rather than resurrecting rows that no longer exist. That is the desired failure
    /// mode, and it is why this needs no invalidation beyond the explicit clear on a new scan.
    public let ids: Set<UUID>

    public init(ids: Set<UUID>, id: UUID = UUID()) {
        self.id = id
        self.ids = ids
    }
}

import Foundation

/// Pure filtering for the Sync History window, the analogue of the Activity Log's
/// `LogEntryFilter`. Kept out of the view so it is testable without any `@State`.
public enum SyncHistoryFilter {

    /// Filters `records` by action, an inclusive `[start, end]` date range, and a
    /// case-insensitive substring over the source and destination paths, then returns them
    /// newest-first.
    ///
    /// - Parameters:
    ///   - action: The single action to keep, or `nil` for all actions.
    ///   - search: Case-insensitive needle matched against `sourcePath` and `destPath`. Empty
    ///     matches everything.
    ///   - start: Keep records at or after this instant. `nil` imposes no lower bound.
    ///   - end: Keep records at or before this instant. `nil` imposes no upper bound.
    ///   - runId: Keep only this run's records, for Activity's Show in History. `nil` keeps all.
    public static func apply(
        _ records: [SyncHistoryRecord],
        action: SyncAction?,
        search: String,
        start: Date? = nil,
        end: Date? = nil,
        runId: UUID? = nil
    ) -> [SyncHistoryRecord] {
        var result = records

        if let runId {
            result = result.filter { $0.runId == runId }
        }

        if let action {
            result = result.filter { $0.action == action }
        }

        if let start {
            result = result.filter { $0.timestamp >= start }
        }
        if let end {
            result = result.filter { $0.timestamp <= end }
        }

        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !needle.isEmpty {
            result = result.filter { record in
                record.sourcePath.localizedCaseInsensitiveContains(needle)
                    || (record.destPath?.localizedCaseInsensitiveContains(needle) ?? false)
            }
        }

        return result.reversed() // Newest at the top, mirroring the Activity Log.
    }
}

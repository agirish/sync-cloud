import Foundation

/// Pure filtering for the Sync History window — the analogue of `LogEntryFilter` for the
/// Activity Log. Kept out of the view so the action filter, date-range gate, case-insensitive
/// path search, and newest-first ordering are unit-testable without any `@State`.
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
    public static func apply(
        _ records: [SyncHistoryRecord],
        action: SyncAction?,
        search: String,
        start: Date? = nil,
        end: Date? = nil
    ) -> [SyncHistoryRecord] {
        var result = records

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

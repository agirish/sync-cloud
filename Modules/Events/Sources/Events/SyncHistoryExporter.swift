import Foundation

/// Pure, testable serialization of `SyncHistoryRecord`s to the two formats the Sync History
/// window offers: CSV (for a spreadsheet) and JSON (for tooling). Both are total functions of
/// their input — no file I/O, no clock, no locale surprises — so the escaping and shape can be
/// pinned by unit tests and the on-disk export can't drift from what the tests assert.
public enum SyncHistoryExporter {

    /// One ISO-8601 formatter shared by both exporters, in UTC, so timestamps are unambiguous
    /// and stable across machines. (The internal store persists a numeric interval instead;
    /// exports are for humans and other tools, hence the readable form here.) `nonisolated(unsafe)`
    /// because `ISO8601DateFormatter` is thread-safe for formatting but not `Sendable`.
    nonisolated(unsafe) private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    /// The CSV column order, also used as the header row.
    private static let columns = [
        "Timestamp", "Action", "Direction", "Source", "Destination", "Size (bytes)", "Checksum", "Backup", "Run ID",
    ]

    /// Renders the records as CSV: a header row plus one row per record, RFC-4180 quoted. Any
    /// field containing a comma, quote, or newline is wrapped in double quotes with internal
    /// quotes doubled, so a path like `a,b` or one bearing a `"` never breaks the column count.
    public static func csv(_ records: [SyncHistoryRecord]) -> String {
        var rows: [String] = [columns.map(escapeCSVField).joined(separator: ",")]
        for record in records {
            let fields = [
                iso8601.string(from: record.timestamp),
                record.action.rawValue,
                record.direction ?? "",
                record.sourcePath,
                record.destPath ?? "",
                record.sizeBytes.map(String.init) ?? "",
                record.checksum ?? "",
                record.backupPath ?? "",
                record.runId.uuidString,
            ]
            rows.append(fields.map(escapeCSVField).joined(separator: ","))
        }
        // Trailing newline so the file ends on a clean line boundary (what most tools expect).
        return rows.joined(separator: "\n") + "\n"
    }

    /// Quotes a single CSV field when it carries a comma, double quote, CR, or LF, doubling any
    /// embedded double quotes. Plain fields pass through untouched.
    private static func escapeCSVField(_ field: String) -> String {
        guard field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r") else {
            return field
        }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Renders the records as a pretty-printed JSON array, with ISO-8601 timestamps and sorted
    /// keys (stable output). Round-trips through `jsonDecoder()`.
    public static func json(_ records: [SyncHistoryRecord]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(records),
              let string = String(data: data, encoding: .utf8) else { return "[]" }
        return string
    }

    /// A decoder matching `json(_:)`'s date strategy — for round-trip tests and any tool that
    /// reads an exported JSON file back into records.
    public static func jsonDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

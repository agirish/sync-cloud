import Testing
import Foundation
@testable import Events

/// Coverage for `SyncHistoryExporter`: the CSV header + RFC-4180 escaping (paths with commas
/// and quotes) and a JSON round-trip.
@Suite struct SyncHistoryExporterTests {

    private func sampleRecord(
        runId: UUID = UUID(),
        action: SyncAction = .copy,
        source: String = "/src/a.txt",
        dest: String? = "/dst/a.txt",
        direction: String? = "→ Right"
    ) -> SyncHistoryRecord {
        SyncHistoryRecord(
            runId: runId,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            action: action,
            sourcePath: source,
            destPath: dest,
            sizeBytes: 2048,
            checksum: nil,
            backupPath: nil,
            direction: direction
        )
    }

    /// **A trash move is labelled "Move to Trash"; only a permanent delete says "Delete"** (FD2),
    /// told apart by the Trash location the record keeps. The raw value stays `delete`, so the
    /// history file and the CSV/JSON a script reads are unchanged.
    @Test func aDeleteIsLabelledByWhetherItReachedTheTrash() throws {
        let trashed = SyncHistoryRecord(runId: UUID(), action: .delete, sourcePath: "/src/a.txt",
                                        backupPath: "/Users/me/.Trash/a.txt")
        let permanent = SyncHistoryRecord(runId: UUID(), action: .delete, sourcePath: "/Volumes/X/b.txt")
        #expect(SyncAction.delete.label == "Move to Trash")
        #expect(trashed.actionLabel == "Move to Trash")
        #expect(!trashed.isPermanentDelete)
        #expect(permanent.actionLabel == "Delete")
        #expect(permanent.isPermanentDelete)
        // A copy or move with no backup is not a delete of any kind.
        #expect(sampleRecord(action: .copy).actionLabel == "Copy")
        #expect(sampleRecord(action: .move).actionLabel == "Move")

        #expect(SyncAction.delete.rawValue == "delete")
        let csvRow = try #require(SyncHistoryExporter.csv([trashed]).split(separator: "\n").dropFirst().first)
        #expect(csvRow.contains(",delete,"), "\(csvRow)")
        #expect(!csvRow.contains("Trash,"), "the CSV printed the label, not the raw value: \(csvRow)")
    }

    /// **An item the Trash took with no location reported is a move to the Trash, not a delete**
    /// (RD2). `deleteItems` records whether each item reached the Trash, so the label no longer
    /// guesses from the missing location; a record that says it did not reach the Trash is
    /// "Delete" whatever its `backupPath`.
    @Test func reachingTheTrashDecidesTheLabelNotTheLocation() throws {
        let noLocation = SyncHistoryRecord(runId: UUID(), action: .delete, sourcePath: "/src/a.txt",
                                           backupPath: nil, reachedTrash: true)
        #expect(noLocation.actionLabel == "Move to Trash")
        #expect(!noLocation.isPermanentDelete)
        let removed = SyncHistoryRecord(runId: UUID(), action: .delete, sourcePath: "/Volumes/X/b.txt",
                                        reachedTrash: false)
        #expect(removed.actionLabel == "Delete")
        #expect(removed.isPermanentDelete)

        // The JSON export carries the field and reads it back; the CSV gains no column for it.
        let json = SyncHistoryExporter.json([noLocation])
        #expect(json.contains("\"reachedTrash\" : true"), "\(json)")
        let decoded = try SyncHistoryExporter.jsonDecoder().decode([SyncHistoryRecord].self, from: Data(json.utf8))
        #expect(decoded.first?.reachedTrash == true)
        #expect(decoded.first?.actionLabel == "Move to Trash")
        #expect(SyncHistoryExporter.csv([noLocation]).hasPrefix(
            "Timestamp,Action,Direction,Source,Destination,Size (bytes),Checksum,Backup,Run ID,Previous Date\n"))
    }

    /// **A record written before the field existed still decodes, and falls back to the location**:
    /// with a Trash location it is a move to the Trash, without one a delete — what it said before.
    @Test func aRecordWithoutTheFieldFallsBackToTheLocation() throws {
        func decoded(_ backup: String?) throws -> SyncHistoryRecord {
            let backupField = backup.map { #""backupPath" : "\#($0)","# } ?? ""
            let old = """
                [{ "id" : "\(UUID().uuidString)", "runId" : "\(UUID().uuidString)",
                   "timestamp" : "2026-10-01T10:00:00Z", "action" : "delete",
                   \(backupField) "sourcePath" : "/src/a.txt" }]
                """
            return try #require(try SyncHistoryExporter.jsonDecoder()
                .decode([SyncHistoryRecord].self, from: Data(old.utf8)).first)
        }
        let trashed = try decoded("/Users/me/.Trash/a.txt")
        #expect(trashed.reachedTrash == nil)
        #expect(trashed.actionLabel == "Move to Trash")
        let permanent = try decoded(nil)
        #expect(permanent.reachedTrash == nil)
        #expect(permanent.actionLabel == "Delete")
    }

    @Test func testCSVHasHeaderAndOneRowPerRecord() {
        let records = [sampleRecord(), sampleRecord(action: .delete, dest: nil, direction: nil)]
        let csv = SyncHistoryExporter.csv(records)
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: true)

        #expect(lines.count == 3) // header + 2 rows
        #expect(lines[0].hasPrefix("Timestamp,Action,Direction,Source,Destination,Size (bytes),Checksum,Backup,Run ID"))
        #expect(lines[1].contains("copy"))
        #expect(lines[1].contains("2048"))
        #expect(lines[2].contains("delete"))
    }

    @Test func testCSVQuotesFieldsWithCommasAndQuotes() {
        // A path containing a comma must be quoted; an embedded quote must be doubled.
        let recordWithComma = sampleRecord(source: "/src/a,b.txt")
        let recordWithQuote = sampleRecord(source: "/src/say \"hi\".txt")

        let csvComma = SyncHistoryExporter.csv([recordWithComma])
        #expect(csvComma.contains("\"/src/a,b.txt\""))

        let csvQuote = SyncHistoryExporter.csv([recordWithQuote])
        // The field is quoted and the inner quote doubled.
        #expect(csvQuote.contains("\"/src/say \"\"hi\"\".txt\""))
    }

    @Test func testCSVDoesNotQuotePlainFields() {
        let csv = SyncHistoryExporter.csv([sampleRecord(source: "/plain/path.txt")])
        // A plain path is emitted without surrounding quotes.
        #expect(csv.contains("/plain/path.txt"))
        #expect(!csv.contains("\"/plain/path.txt\""))
    }

    @Test func testJSONRoundTrips() throws {
        let runId = UUID()
        let original = [
            sampleRecord(runId: runId, action: .copy),
            sampleRecord(runId: runId, action: .move, source: "/src/b.txt", dest: "/dst/b.txt"),
        ]
        let json = SyncHistoryExporter.json(original)
        let data = try #require(json.data(using: .utf8))
        let decoded = try SyncHistoryExporter.jsonDecoder().decode([SyncHistoryRecord].self, from: data)

        #expect(decoded.count == 2)
        #expect(decoded.map(\.id) == original.map(\.id))
        #expect(decoded.map(\.action) == [.copy, .move])
        #expect(decoded[0].sourcePath == "/src/a.txt")
        #expect(decoded[1].destPath == "/dst/b.txt")
        #expect(decoded[0].direction == "→ Right")
        // Timestamps survive the ISO-8601 round trip to the second.
        #expect(abs(decoded[0].timestamp.timeIntervalSince1970 - 1_700_000_000) < 1)
    }

    @Test func testEmptyRecordsProduceHeaderOnlyCSVAndEmptyJSONArray() throws {
        let csv = SyncHistoryExporter.csv([])
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 1) // header only

        // The JSON export of nothing is a valid, empty array (whitespace form left to Foundation).
        let json = SyncHistoryExporter.json([])
        let data = try #require(json.data(using: .utf8))
        let decoded = try SyncHistoryExporter.jsonDecoder().decode([SyncHistoryRecord].self, from: data)
        #expect(decoded.isEmpty)
    }

    /// **A date match records the date it replaced, and the CSV carries it** (review E11). The
    /// record kept only that a date was set. Last column, so the earlier ones keep their places;
    /// empty for a record with none.
    @Test func testADateMatchRecordCarriesItsPreviousDateIntoTheCSV() throws {
        let match = SyncHistoryRecord(runId: UUID(), timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                                      action: .matchDates, sourcePath: "/l/a.txt", destPath: "/r/a.txt",
                                      direction: "→ Right", previousModificationDate: Date(timeIntervalSince1970: 1_600_000_000))
        let lines = SyncHistoryExporter.csv([match, sampleRecord()]).split(separator: "\n").map(String.init)
        #expect(lines[0].hasSuffix(",Run ID,Previous Date"))
        #expect(lines[1].hasSuffix(",\(match.runId.uuidString),2020-09-13T12:26:40Z"), "\(lines[1])")
        #expect(lines[2].hasSuffix(","), "a record with no previous date filled the column: \(lines[2])")
    }

    /// **A history line written before the field existed still loads** (review E11): absent is
    /// nil, through the store's own codec (the default `Date` strategy), and the field survives a
    /// round trip when present.
    @Test func testALineWithoutAPreviousDateStillDecodes() throws {
        let old = #"{"id":"6F1C3C2A-0000-4000-8000-000000000001","runId":"6F1C3C2A-0000-4000-8000-000000000002","timestamp":700000000,"action":"matchDates","sourcePath":"/l/a.txt","destPath":"/r/a.txt","sizeBytes":9,"direction":"→ Right"}"#
        let decoded = try JSONDecoder().decode(SyncHistoryRecord.self, from: Data(old.utf8))
        #expect(decoded.action == .matchDates)
        #expect(decoded.previousModificationDate == nil)

        let dated = SyncHistoryRecord(runId: UUID(), action: .matchDates, sourcePath: "/l/a.txt",
                                      previousModificationDate: Date(timeIntervalSince1970: 1_600_000_000))
        let back = try JSONDecoder().decode(SyncHistoryRecord.self, from: JSONEncoder().encode(dated))
        #expect(back.previousModificationDate == Date(timeIntervalSince1970: 1_600_000_000))
    }
}

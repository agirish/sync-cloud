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
}

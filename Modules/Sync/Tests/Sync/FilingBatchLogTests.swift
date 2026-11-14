import Foundation
import Testing
import Events
import EventsTestSupport
@testable import Sync

/// A filing batch says where each file went, and its lines never take the Activity Log's
/// per-card fold prefix, `"Filing: filed "`. Batch filing writes no per-file line, so these lines
/// are the only record of which file landed where; and a summary matching the prefix would fold in
/// with neighbouring cards, so the fold's header would count lines, not files.
@Suite struct FilingBatchLogTests {

    private func filed(_ name: String, in folder: String, source: String = "its name") -> FilingBatchLog.Filed {
        FilingBatchLog.Filed(fileName: name, landedAs: name, folder: folder, source: source)
    }

    @Test func namesAreGroupedByTheFolderTheyLandedInSorted() {
        let lines = FilingBatchLog.lines(
            operation: "Filing batch",
            filed: [filed("c.pdf", in: "/r/Bills"), filed("b.pdf", in: "/r/Tax", source: "a rule you taught"),
                    filed("a.pdf", in: "/r/Bills")],
            summary: "S")
        #expect(lines == [
            "Filing batch → /r/Bills: 2 file(s): “a.pdf” (its name), “c.pdf” (its name)",
            "Filing batch → /r/Tax: 1 file(s): “b.pdf” (a rule you taught)",
            "S",
        ])
    }

    @Test func aRenamedLandingNamesBoth() {
        let file = FilingBatchLog.Filed(fileName: "Bill.pdf", landedAs: "Bill 2.pdf", folder: "/r", source: "its name")
        #expect(FilingBatchLog.lines(operation: "Filing batch", filed: [file], summary: "S").first?
                    .contains("“Bill.pdf” as “Bill 2.pdf”") == true)
    }

    /// Every name is kept, at most 200 a line: a group of thousands is split, never one line the
    /// Activity Log renders whole, and never cut short.
    @Test func aLargeGroupIsSplitAtTwoHundredNamesAndKeepsEveryOne() {
        let files = (1...450).map { filed("f\($0).pdf", in: "/r/Bills") }
        let lines = FilingBatchLog.lines(operation: "Filing batch", filed: files, summary: "S")
        #expect(lines.count == 4)
        #expect(lines[0].hasPrefix("Filing batch → /r/Bills: names 1–200 of 450: "))
        #expect(lines[2].hasPrefix("Filing batch → /r/Bills: names 401–450 of 450: "))
        for n in [1, 200, 201, 450] {
            #expect(lines.contains { $0.contains("“f\(n).pdf”") }, "f\(n).pdf was dropped")
        }
        #expect(!lines.contains { $0.contains("\n") }, "a line spans more than one physical line")
    }

    @Test func theSummaryCountsFilesAndFoldersAndNeverTakesTheFoldPrefix() {
        let summary = FilingBatchLog.recommendedSummary(
            filed: [filed("a", in: "/x"), filed("b", in: "/y"), filed("c", in: "/x")], failures: 1, alreadyHome: 2)
        #expect(summary == "Filing batch: 3 file(s) filed into 2 folder(s), 1 couldn’t be filed, 2 already in place")
        #expect(!summary.hasPrefix("Filing: filed "))
    }

    /// The real batch writes these lines, end to end.
    @MainActor
    @Test func theRecommendedBatchNamesEachFileAndWhereItWent() async throws {
        let root = try makeCanonicalTempRoot(prefix: "FilingBatchLog")
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ url: URL, bytes: Int) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0x41, count: bytes).write(to: url)
        }
        try write(root.appendingPathComponent("Documents/Tesla Policy/.keep"), bytes: 1)
        try write(root.appendingPathComponent("Downloads/Tesla Policy.pdf"), bytes: 4096)

        let manager = FileSyncManager()
        await manager.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"), providerRoot: root)
        let eligible = manager.batchEligibleFilingSuggestions
        try #require(eligible.count == 1, "the fixture's file should have a confident, name-derived home")

        let log = LogCapture()
        await manager.applyRecommendedFiling(eligible)
        let mine = await log.entries.map(\.message).filter { $0.contains(root.path) || $0.hasPrefix("Filing batch: ") }

        let folder = root.appendingPathComponent("Documents/Tesla Policy").path
        #expect(mine.contains("Filing batch → \(folder): 1 file(s): “Tesla Policy.pdf” (its name)"), "\(mine)")
        #expect(mine.contains("Filing batch: 1 file(s) filed into 1 folder(s)"), "\(mine)")
        #expect(!mine.contains { $0.hasPrefix("Filing: filed ") }, "a batch line takes the per-card fold prefix")
    }
}

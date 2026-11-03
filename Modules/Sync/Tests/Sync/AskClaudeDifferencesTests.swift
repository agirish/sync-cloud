import Foundation
import Testing
@testable import Sync

/// Compare's differences as Ask Claude reads them (TE261).
@Suite struct AskClaudeDifferencesTests {

    private let now = Date(timeIntervalSince1970: 1_792_000_000)
    private let utc = TimeZone(identifier: "UTC")!

    private var comparison: AskClaudeDifferences.Comparison {
        AskClaudeDifferences.Comparison(leftName: "iCloud", rightName: "Dropbox",
                                        leftFolder: "Documents/H-1B", rightFolder: "Documents/H-1B",
                                        readAt: now.addingTimeInterval(-120), isScanning: false, hasScanned: true)
    }

    private func row(_ path: String, _ type: FileDifference.DifferenceType, _ action: FileDifference.SyncAction,
                     left: Int? = nil, right: Int? = nil, leftDate: Date? = nil, rightDate: Date? = nil,
                     held: FileDifference.HeldBack? = nil, enclosed: Int? = nil, folder: Bool = false) -> FileDifference {
        FileDifference(relativePath: path, leftItemPath: "/icloud/H-1B/" + path, rightItemPath: "/dropbox/H-1B/" + path,
                       type: type, action: action, description: "note for \(path)",
                       leftFileSize: left, leftModified: leftDate, rightFileSize: right, rightModified: rightDate,
                       enclosedItemCount: enclosed, leftIsDirectory: folder && type != .missingOnLeft,
                       rightIsDirectory: folder && type != .missingOnRight, heldBack: held)
    }

    private var rows: [FileDifference] {
        [row("2019-2022/I-797.pdf", .missingOnLeft, .copyToLeft, right: 1_200_000),
         row("2019-2022/Paystubs", .missingOnLeft, .copyToLeft, right: 4_000_000, enclosed: 18, folder: true),
         row("2026-2029/LCA.pdf", .differentDates, .copyToRight, left: 310_000, right: 298_000,
             leftDate: now.addingTimeInterval(-86_400), rightDate: now.addingTimeInterval(-4 * 86_400)),
         row("Notes.txt", .missingOnRight, .copyToRight, left: 900),
         row("2026-2029/Draft.docx", .differentDates, .copyToRight, left: 100, right: 120, held: .sizesDifferWithoutANewerSide)]
    }

    @Test func kindsFoldersAndWordsNarrowTheRows() {
        typealias D = AskClaudeDifferences
        #expect(D.filter(rows, kind: .onlyRight, folder: nil, words: []).map(\.relativePath) == ["2019-2022/I-797.pdf", "2019-2022/Paystubs"])
        #expect(D.filter(rows, kind: .onlyLeft, folder: nil, words: []).map(\.relativePath) == ["Notes.txt"])
        #expect(D.filter(rows, kind: .changed, folder: "2026-2029/", words: []).count == 2)
        #expect(D.filter(rows, kind: .heldBack, folder: nil, words: []).map(\.relativePath) == ["2026-2029/Draft.docx"])
        #expect(D.filter(rows, kind: .all, folder: nil, words: ["lca"]).map(\.relativePath) == ["2026-2029/LCA.pdf"])
        // A folder argument is a whole folder name, not a prefix of one.
        #expect(D.filter(rows, kind: .all, folder: "2019", words: []).isEmpty)
        // And its case is the disk's: ignored.
        let mixed = [row("Taxes/2025/W-2.pdf", .missingOnLeft, .copyToLeft, right: 10)]
        #expect(D.filter(mixed, kind: .all, folder: "taxes/2025", words: []).count == 1)
    }

    @Test func kindsAreNamedForTheirSides() {
        #expect(AskClaudeDifferences.label(.onlyRight, comparison: comparison) == "only on Dropbox")
        #expect(AskClaudeDifferences.label(.onlyLeft, comparison: comparison) == "only on iCloud")
        #expect(AskClaudeDifferences.label(.all, comparison: comparison) == nil)
    }

    /// "The two sides match" only when nothing was left out of what was compared.
    @Test func anEmptyListSaysMatchOnlyWhenNothingWasLeftOut() {
        var handles = AskClaudeHandles()
        func last(_ hidden: Int, _ comparison: AskClaudeDifferences.Comparison) -> String? {
            AskClaudeDifferences.render([], allRows: [], hiddenCount: hidden, comparison: comparison, from: 0,
                                        handles: &handles, now: now).split(separator: "\n").last.map(String.init)
        }
        #expect(last(0, comparison) == "No differences: the two sides match.")
        #expect(last(2, comparison) == "No differences besides the ones hidden from Claude.")
        var partial = comparison
        partial.partial = "Dropbox could be read only in part"
        #expect(last(0, partial) == "No differences in what could be read; the comparison is partial.")
    }

    @Test func theScreenLineCountsByKindAndSaysHowFresh() {
        let line = AskClaudeDifferences.summaryLine(rows, hiddenCount: 3, comparison: comparison, now: now)
        #expect(line == "differences: 5 · scanned 2 min ago · 2 only on Dropbox · 1 only on iCloud · 2 changed · 3 hidden from Claude")
        var never = comparison
        never.hasScanned = false
        #expect(AskClaudeDifferences.summaryLine([], hiddenCount: 0, comparison: never, now: now) == "differences: not compared yet")
        never.isScanning = true
        #expect(AskClaudeDifferences.summaryLine([], hiddenCount: 0, comparison: never, now: now) == "differences: scanning now")
    }

    @Test func rowsAreGroupedByFolderWithDatesSizesAndAHandleOnTheSideThatHasThem() {
        var handles = AskClaudeHandles()
        let text = AskClaudeDifferences.render(rows, allRows: rows, hiddenCount: 0, comparison: comparison, from: 0,
                                               handles: &handles, now: now, timeZone: utc)
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines[0] == "differences: iCloud › Documents/H-1B  vs  Dropbox › Documents/H-1B")
        #expect(lines[1] == "scanned 2 min ago · 5 differences: 2 only on Dropbox · 1 only on iCloud · 2 changed")
        #expect(lines.contains("2019-2022 (2 → iCloud)"))
        #expect(lines.contains("2026-2029 (2 → Dropbox)"))
        #expect(lines.contains("(top level) (1 → Dropbox)"))
        let lca = try! #require(lines.first { $0.contains("LCA.pdf") })
        #expect(lca.contains("|2026-10-13 17:46:40|2026-10-10 17:46:40|copy to Dropbox"))
        // Only on Dropbox: the handle names the Dropbox copy, the one that exists.
        let i797 = try! #require(lines.first { $0.contains("I-797.pdf") })
        let handle = String(i797.split(separator: "|")[0])
        #expect(handles.path(for: handle) == "/dropbox/H-1B/2019-2022/I-797.pdf")
        #expect(text.contains("note for 2019-2022/Paystubs, 18 items inside"))
        #expect(text.contains("held back (sizes differ and neither side is newer); not copied by bulk runs"))
    }

    /// A compared folder on the Hidden from Claude list isn't named in the answer's first line,
    /// though every row in it is left out anyway.
    @Test func aHiddenComparedFolderIsntNamed() {
        var handles = AskClaudeHandles()
        var hidden = comparison
        hidden.leftFolder = "Documents/Medical"
        hidden.leftFolderHidden = true
        let text = AskClaudeDifferences.render([], allRows: [], hiddenCount: 5, comparison: hidden, from: 0,
                                               handles: &handles, now: now, timeZone: utc)
        #expect(text.hasPrefix("differences: iCloud › (a folder hidden from Claude)  vs  Dropbox › Documents/H-1B\n"))
        #expect(!text.contains("Medical"))
    }

    @Test func aLongListPagesAndSaysWhereToGoOn() {
        let many = (0..<75).map { row(String(format: "f%02d.txt", $0), .missingOnRight, .copyToRight, left: 1) }
        var handles = AskClaudeHandles()
        let first = AskClaudeDifferences.render(many, allRows: many, hiddenCount: 0, comparison: comparison, from: 0,
                                                handles: &handles, now: now)
        #expect(first.contains("15 more; call again with from 60."))
        let second = AskClaudeDifferences.render(many, allRows: many, hiddenCount: 0, comparison: comparison, from: 60,
                                                 handles: &handles, now: now)
        #expect(second.contains("f74.txt") && !second.contains("f00.txt") && !second.contains("more; call again"))
    }

    @Test func anHourOldComparisonIsStale() {
        var fresh = comparison
        #expect(!fresh.isStale(now: now))
        fresh.readAt = now.addingTimeInterval(-3601)
        #expect(fresh.isStale(now: now))
        fresh.readAt = nil
        #expect(fresh.isStale(now: now))
    }

    @Test func aSwapTradesTheDatesWithTheSides() {
        let lca = rows[2]
        let swapped = lca.mirrored()
        #expect(swapped.leftModified == lca.rightModified && swapped.rightModified == lca.leftModified)
        #expect(lca.redirected(to: .copyToLeft).leftModified == lca.leftModified)
    }

    @Test func theScanKeepsBothDates() throws {
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        let older = Date(timeIntervalSince1970: 1_790_000_000), newer = older.addingTimeInterval(3 * 86_400)
        mockFM.virtualDisk["/src/a.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: [.modificationDate: newer, .size: 10], contents: nil)
        mockFM.virtualDisk["/dst/a.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: [.modificationDate: older, .size: 12], contents: nil)
        mockFM.virtualDisk["/src/only.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: [.modificationDate: older, .size: 5], contents: nil)
        let src = CloudProvider(id: "src", displayName: "Source", imageName: "folder", rootPath: "/src", type: .iCloud)
        let dst = CloudProvider(id: "dst", displayName: "Dest", imageName: "folder", rootPath: "/dst", type: .iCloud)
        let diffs = FileDiffEngine.computeDifferences(
            left: src, leftURL: URL(fileURLWithPath: "/src"), right: dst, rightURL: URL(fileURLWithPath: "/dst"),
            leftFilesInfo: try FileDiffEngine.getFilesInDirectory(URL(fileURLWithPath: "/src"), fileManager: mockFM),
            rightFilesInfo: try FileDiffEngine.getFilesInDirectory(URL(fileURLWithPath: "/dst"), fileManager: mockFM))
        let changed = try #require(diffs.first { $0.relativePath == "a.txt" })
        #expect(changed.leftModified == newer && changed.rightModified == older)
        let only = try #require(diffs.first { $0.relativePath == "only.txt" })
        #expect(only.leftModified == older && only.rightModified == nil)
    }
}

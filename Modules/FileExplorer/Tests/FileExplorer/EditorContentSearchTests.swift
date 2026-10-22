import Testing
import Foundation
import Sync
@testable import FileExplorer

/// Search inside files (RD38): what the text half reads, what it never reads, and what it reports.
@Suite struct EditorContentSearchTests {

    // MARK: Fixtures

    private func scratch() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("content-search-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func write(_ text: String, to relative: String, in root: URL) throws -> String {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url.path
    }

    /// Every event of one search, to its end.
    private func run(_ query: String, in root: URL,
                     facts: @escaping @Sendable (String) -> EditorContentSearch.FileFacts? = EditorContentSearch.FileFacts.real,
                     read: @escaping @Sendable (String) -> BoundedTextRead.Outcome = { BoundedTextRead.read(path: $0) },
                     limits: EditorContentSearch.Limits = .standard)
        async -> (hits: [(EditorContentHit, Int)], summary: EditorContentSearch.Summary?) {
        var hits: [(EditorContentHit, Int)] = []
        var summary: EditorContentSearch.Summary?
        for await event in EditorContentSearch.search(query, in: root.path, facts: facts, read: read, limits: limits) {
            switch event {
            case .hit(let hit, let order): hits.append((hit, order))
            case .finished(let s): summary = s
            case .progress: break
            }
        }
        hits.sort { $0.1 < $1.1 }
        return (hits, summary)
    }

    /// Paths under `root`, relative, in walk order.
    private func relative(_ hits: [(EditorContentHit, Int)], to root: URL) -> [String] {
        hits.map { String($0.0.path.dropFirst(root.path.count + 1)) }
    }

    // MARK: Matching a line

    /// Line numbers by the editor's count — CRLF one break, a lone CR one break — the column in
    /// characters, and the highlight inside the snippet the row shows.
    @Test func linesAreNumberedAsTheEditorNumbersThem() {
        let text = "alpha\n  Red Lentils soup\r\nbeta\rgamma lentils\n"
        let (lines, count) = EditorContentSearch.matchingLines(in: text, needle: "lentils", keeping: 20)
        #expect(count == 2)
        #expect(lines.map(\.line) == [2, 4])
        #expect(lines.map(\.column) == [7, 7])
        #expect(lines[0].snippet == "Red Lentils soup", "leading space is dropped from the snippet")
        #expect((lines[0].snippet as NSString).substring(with: lines[0].highlight) == "Lentils")
        #expect((lines[1].snippet as NSString).substring(with: lines[1].highlight) == "lentils")
        #expect(lines.allSatisfy { $0.length == 7 })
        // The number is the line Go to Line lands on, in the editor's own index.
        let index = EditorLineIndex(text: text)
        let offset = EditorGoToLine.utf16Offset(of: .init(line: 4, column: 7), in: text, using: index)
        #expect((text as NSString).substring(with: NSRange(location: offset, length: 7)) == "lentils")
    }

    /// The name filter's rule, for contents: case and accents do not matter.
    @Test func caseAndAccentsAreIgnored() {
        let (lines, _) = EditorContentSearch.matchingLines(in: "Le CAFÉ du coin", needle: "cafe", keeping: 5)
        #expect(lines.count == 1)
        #expect((lines[0].snippet as NSString).substring(with: lines[0].highlight) == "CAFÉ")
    }

    /// An emoji is one column, as the status line counts it; the length stays in UTF-16, which is
    /// what the text view selects.
    @Test func theColumnCountsCharactersNotUTF16Units() {
        let text = "👍👍 word"
        let (lines, _) = EditorContentSearch.matchingLines(in: text, needle: "word", keeping: 5)
        #expect(lines.first?.column == 4)
        let offset = EditorGoToLine.utf16Offset(of: .init(line: 1, column: 4), in: text,
                                                using: EditorLineIndex(text: text))
        #expect(offset == 5, "two emoji are four UTF-16 units, then the space")
    }

    /// A line is one row however often it matches; the count is of lines.
    @Test func aLineIsOneRowHoweverOftenItMatches() {
        let text = "word word word\nnothing\nword\n"
        let (lines, count) = EditorContentSearch.matchingLines(in: text, needle: "word", keeping: 5)
        #expect(lines.map(\.line) == [1, 3])
        #expect(count == 2)
    }

    /// The first `keeping` lines are kept and every one is counted — the row says how many more.
    @Test func linesPastTheLimitAreCountedNotKept() {
        let text = (1...30).map { "line \($0) has the word" }.joined(separator: "\n")
        let (lines, count) = EditorContentSearch.matchingLines(in: text, needle: "word", keeping: 20)
        #expect(lines.count == 20)
        #expect(count == 30)
        #expect(lines.last?.line == 20)
    }

    /// A long line is cut to a little before the match, so the match is never off the row.
    @Test func aLongLineIsCutAroundTheMatch() throws {
        let text = String(repeating: "x", count: 300) + " needle " + String(repeating: "y", count: 300)
        let (lines, _) = EditorContentSearch.matchingLines(in: text, needle: "needle", keeping: 1)
        let line = try #require(lines.first)
        #expect(line.snippet.hasPrefix("…"))
        #expect(line.highlight.location <= EditorContentSearch.leadBeforeMatch + 1)
        #expect((line.snippet as NSString).substring(with: line.highlight) == "needle")
        #expect((line.snippet as NSString).length <= EditorContentSearch.snippetLength + 1)
        #expect(line.column == 302)
    }

    // MARK: The walk

    /// The folder and the folders inside, folder by folder in Finder's order; hidden files and
    /// folders, packages, and kinds Edit does not open are left out.
    @Test func searchesTheFoldersInsideAndSkipsWhatIsNotADocument() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("a word", to: "note 10.md", in: root)
        try write("a word", to: "note 2.md", in: root)
        try write("a word", to: "Sub/inner.txt", in: root)
        try write("a word", to: "Sub/Deeper/deep.yml", in: root)
        try write("a word", to: ".hidden.md", in: root)
        try write("a word", to: ".git/config.md", in: root)
        try write("a word", to: "Tool.app/Contents/readme.txt", in: root)
        try write("a word", to: "photo.jpg", in: root)
        try write("no match", to: "other.md", in: root)

        let (hits, summary) = await run("word", in: root)
        #expect(relative(hits, to: root) == ["note 2.md", "note 10.md", "Sub/inner.txt", "Sub/Deeper/deep.yml"])
        #expect(hits.map(\.0.subfolder) == ["", "", "Sub", "Sub/Deeper"])
        #expect(summary?.read == 5, "the four matches and other.md are read; nothing else is")
        #expect(summary?.stop == nil)
    }

    /// **A file whose content is not on this Mac is never opened.** `SF_DATALESS` cannot be set
    /// outside a File Provider, so the flag is reported by the seam for one real local file — which
    /// holds the word, so reading it would show. It is counted, and the read never asks for it.
    @Test func aFileNotDownloadedIsNeverRead() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let local = try write("lentils here", to: "local.md", in: root)
        let evicted = try write("lentils here too", to: "evicted.md", in: root)
        let reads = Reads()
        let facts: @Sendable (String) -> EditorContentSearch.FileFacts? = { path in
            guard var fact = EditorContentSearch.FileFacts.real(path) else { return nil }
            if path == evicted { fact.isDataless = true }
            return fact
        }
        let read: @Sendable (String) -> BoundedTextRead.Outcome = { path in
            reads.add(path)
            return BoundedTextRead.read(path: path)
        }

        let (hits, summary) = await run("lentils", in: root, facts: facts, read: read)
        #expect(hits.map(\.0.path) == [local])
        #expect(!reads.paths.contains(evicted), "the evicted file was opened")
        #expect(reads.paths == [local], "the positive control: the local file is read")
        #expect(summary?.notDownloaded == 1)

        // And without the flag the same file is read and found — so the absence above is the flag.
        let (control, _) = await run("lentils", in: root)
        #expect(control.map(\.0.path) == [evicted, local])
    }

    /// Over the editor's read cap: counted, not read.
    @Test func aFileOverTheReadCapIsCountedNotRead() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let big = root.appendingPathComponent("big.txt")
        try Data(("word " + String(repeating: "x", count: BoundedTextRead.maxBytes)).utf8).write(to: big)
        try write("word", to: "small.txt", in: root)
        let (hits, summary) = await run("word", in: root)
        #expect(relative(hits, to: root) == ["small.txt"])
        #expect(summary?.tooLarge == 1)
    }

    /// Decoded as the editor decodes: a UTF-16 file with its mark is text, a file with NULs is not,
    /// and invalid UTF-8 is read leniently.
    @Test func filesAreDecodedAsTheEditorDecodesThem() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        var utf16 = Data([0xFF, 0xFE])
        utf16.append("red lentils".data(using: .utf16LittleEndian)!)
        try utf16.write(to: root.appendingPathComponent("a-utf16.txt"))
        var binary = Data("lentils".utf8)
        binary.append(contentsOf: [0, 0, 1, 2])
        try binary.write(to: root.appendingPathComponent("b-binary.txt"))
        var lossy = Data("lentils ".utf8)
        lossy.append(contentsOf: [0xC3, 0x28])
        try lossy.write(to: root.appendingPathComponent("c-lossy.txt"))

        let (hits, _) = await run("lentils", in: root)
        #expect(relative(hits, to: root) == ["a-utf16.txt", "c-lossy.txt"])
        #expect(hits.first?.0.lines.first?.column == 5)
    }

    /// **A folder reached twice through a link is searched once**, and a link back up the tree does
    /// not walk for ever. Below a folder link the listing spells paths through the link, so the
    /// same file has two names; the walk knows it by device and inode.
    @Test func aFolderLinkedTwiceIsSearchedOnce() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("word", to: "Real/a.md", in: root)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("Link").path,
                                                   withDestinationPath: root.appendingPathComponent("Real").path)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("Real/Up").path,
                                                   withDestinationPath: root.path)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("again.md").path,
                                                   withDestinationPath: root.appendingPathComponent("Real/a.md").path)
        let (hits, _) = await run("word", in: root)
        #expect(hits.count == 1, "found \(relative(hits, to: root))")
    }

    /// A link to a folder outside is walked, and its files keep the link's spelling — iCloud Drive
    /// links Desktop and Documents in this way.
    @Test func aLinkToAFolderOutsideIsWalkedUnderItsOwnName() async throws {
        let root = try scratch()
        let outside = try scratch()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try write("word", to: "a.md", in: outside)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("Documents").path,
                                                   withDestinationPath: outside.path)
        let (hits, _) = await run("word", in: root)
        #expect(relative(hits, to: root) == ["Documents/a.md"])
    }

    /// The walk's limit stops it and says so; the file limit stops reading and says so — and a
    /// limit met by the very last file is a search that looked everywhere.
    @Test func theLimitsStopTheSearchAndSaySo() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        for n in 1...5 { try write("word", to: "f\(n).md", in: root) }

        let few = EditorContentSearch.Limits(entries: 1000, files: 2, linesPerFile: 5)
        let (twoHits, twoSummary) = await run("word", in: root, limits: few)
        #expect(twoHits.count == 2)
        #expect(twoSummary?.stop == .fileLimit(2))

        let exact = EditorContentSearch.Limits(entries: 1000, files: 5, linesPerFile: 5)
        let (allHits, allSummary) = await run("word", in: root, limits: exact)
        #expect(allHits.count == 5)
        #expect(allSummary?.stop == nil, "a limit met on the last file stopped nothing")

        let shallow = EditorContentSearch.Limits(entries: 3, files: 500, linesPerFile: 5)
        let (_, walkSummary) = await run("word", in: root, limits: shallow)
        #expect(walkSummary?.stop == .entryLimit(3))
        #expect(walkSummary?.read == 3)
    }

    /// **Dropping the stream stops the search**: no file is opened after the query changes.
    ///
    /// Held, not timed: past the first ten reads every reader waits at a gate until the stream has
    /// been dropped, so how many files are read cannot depend on how fast the consumer gets its
    /// turn — in a full-package run that took 30 s. Released, the readers already waiting finish,
    /// and no other file is opened: past the count at the drop, at most the readers that were
    /// between the stop check and the read (on CI the consumer's turn outlasted a gate's wait, and
    /// 28 files were read before the drop — the stop held, the old fixed bound did not).
    @Test func droppingTheStreamStopsTheReads() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        for n in 1...200 { try write("word", to: String(format: "f%03d.md", n), in: root) }
        let reads = Reads()
        let gate = DispatchSemaphore(value: 0)
        let read: @Sendable (String) -> BoundedTextRead.Outcome = { path in
            reads.add(path)
            if reads.paths.count > 10 { _ = gate.wait(timeout: .now() + 60) }
            return BoundedTextRead.read(path: path)
        }
        for await event in EditorContentSearch.search("word", in: root.path, read: read) {
            if case .hit = event { break }
        }
        let atDrop = reads.paths.count
        // Opened for good: a search that went on reading would now read all 200.
        for _ in 0..<200 { gate.signal() }
        try await Task.sleep(for: .milliseconds(300))
        let settled = reads.paths.count
        try await Task.sleep(for: .milliseconds(300))
        #expect(reads.paths.count == settled, "files were still being read after the stream was dropped")
        #expect(settled <= atDrop + EditorContentSearch.maxConcurrentReads && settled < 200,
                "read \(settled) of 200 files (\(atDrop) when it was dropped) — files were opened after the drop")
        #expect(atDrop > 0, "the positive control: the search had started")
    }

    /// Nothing to search for is a search that finishes at once, having read nothing.
    @Test func anEmptyQueryReadsNothing() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("word", to: "a.md", in: root)
        let (hits, summary) = await run("   ", in: root)
        #expect(hits.isEmpty)
        #expect(summary?.read == 0)
    }

    // MARK: Opening at the match

    /// The match as it stands in the file opened: where the result said, if it is still there;
    /// else the next one from that line; else the line's start, with nothing selected.
    @Test func theMatchIsLocatedInTheFileAsItOpened() {
        let match = EditorContentMatch(path: "/a.md", line: 2, column: 5, length: 7, word: "lentils")
        let same = "one\nred lentils\n"
        #expect(EditorContentMatch.located(match, in: same, using: .empty) == match)

        let edited = "one\nred, red Lentils\n"
        let moved = EditorContentMatch.located(match, in: edited, using: .empty)
        #expect(moved.line == 2)
        #expect(moved.column == 10)
        #expect(moved.length == 7)

        let gone = EditorContentMatch.located(match, in: "one\nred beans\n", using: .empty)
        #expect(gone.line == 2)
        #expect(gone.column == 1)
        #expect(gone.length == 0)
    }

    /// A request selects its length, clamped to the text; every other request is a bare caret.
    @Test func aRequestSelectsItsLengthClampedToTheText() {
        let request = EditorScrollRequest(line: 1, token: 1, column: 1, length: 7, seedsFind: true)
        #expect(PlainTextEditor.selection(for: request, at: 4, length: 20) == NSRange(location: 4, length: 7))
        #expect(PlainTextEditor.selection(for: request, at: 18, length: 20) == NSRange(location: 18, length: 2))
        #expect(PlainTextEditor.selection(for: request, at: 30, length: 20) == NSRange(location: 20, length: 0))
        let heading = EditorScrollRequest(line: 1, token: 1)
        #expect(PlainTextEditor.selection(for: heading, at: 4, length: 20) == NSRange(location: 4, length: 0))
    }
}

/// The paths a read seam was asked for, across the search's concurrent reads.
final class Reads: @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [String] = []
    func add(_ path: String) { lock.lock(); asked.append(path); lock.unlock() }
    var paths: [String] { lock.lock(); defer { lock.unlock() }; return asked }
}

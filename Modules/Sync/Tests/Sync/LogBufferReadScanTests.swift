import Foundation
import Testing
@testable import Sync

/// **Every read of `Logger.shared.entries` in this package's tests is eviction-proof.**
///
/// The buffer is capped at 1,000 entries and this package runs ~3,500 tests across ~320 suites in
/// parallel, so a bare `Logger.shared.entries.contains { … }` is racing every other suite's
/// logging. When it loses, the assertion reports a missing log line, which is exactly what the test
/// would report if the production code had stopped writing it — "A log assertion reading a window
/// that has already rolled" in `docs/flaky-tests.md`. It reddened the v4.4 release run and two
/// attempts at the v4.5 one, each time in a different suite, and each time passing 3/3 in isolation
/// on the same tree.
///
/// Three shapes are eviction-proof, and only the last one names the buffer:
/// - **`LogCapture`** (`TestSupport.swift`) — accumulates at publish time, so a later trim cannot
///   take an entry away. The preferred form; the test reads `await log.entries`.
/// - **reading the DISK log** — `loggedLineOnDisk`, `Logger.shared.flushToDisk()`. The file is not
///   capped. `DuplicatesGateFailClosedTests` says so in its own comment.
/// - **an index-bounded read** — `firstIndex`/`lastIndex` on a marker the test wrote itself, then
///   a slice. This DIAGNOSES eviction rather than preventing it, so it is allowed but not
///   recommended: the marker is older than the lines it bounds and is evicted first, which makes
///   the test fail more often, not less.
///
/// **There is no allow-list any more.** Sixteen suites predated `LogCapture` and were listed here;
/// the last fifteen were converted on 2026-09-27 and the list went with them. The judgement got
/// stricter at the same time, because the old one excused a whole FILE that built a capture, read
/// the disk log or called an index anywhere, comments included — and with a capture now in every
/// log suite, a new bare read in any of them would have passed. `PaneTabsTests`, which does bound
/// its read, was passing on a comment. Each read is now judged on its own, on code alone.
///
/// It reads only this directory. The app target, `Dashboard` and `FileExplorer` still read the
/// buffer directly in places, and cannot import `LogCapture` — it lives in this test target.
@Suite struct LogBufferReadScanTests {

    /// The Swift files in this directory, read as text, by name.
    static func sources() -> [(name: String, text: String)] {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "swift" }.compactMap { url in
            (try? String(contentsOf: url, encoding: .utf8)).map { (url.lastPathComponent, $0) }
        }
    }

    /// How many lines of code, the read's own included, an index call may sit within and still be
    /// taken as bounding it. Both index-bounded readers here find theirs on the next line.
    static let boundReach = 5

    /// Whether `source` holds a read of the in-memory buffer that nothing bounds. Judged on code
    /// alone — a line starting `//` can neither make a read nor excuse one — and read by read.
    static func readsTheBufferBare(_ source: String) -> Bool {
        let code = source.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") }
        return code.indices.contains { i in
            code[i].contains("Logger.shared.entries")
                && !code[i..<min(i + boundReach, code.endIndex)].contains {
                    $0.contains("firstIndex") || $0.contains("lastIndex")
                }
        }
    }

    @Test func noSuiteReadsTheLogBufferUnbounded() {
        let sources = Self.sources()
        // With nothing listed, a scan that read no files would pass exactly as a clean tree does.
        #expect(sources.count >= 200,
                "the scan read \(sources.count) files — it has stopped reading the test tree")

        let bare = sources.filter { $0.name != "LogBufferReadScanTests.swift" && Self.readsTheBufferBare($0.text) }
            .map(\.name).sorted()
        #expect(bare.isEmpty, """
            \(bare.count) suite(s) read `Logger.shared.entries` with nothing bounding the window: \
            \(bare). Use `LogCapture` from TestSupport — construct it BEFORE the call under test. \
            See "A log assertion reading a window that has already rolled" in docs/flaky-tests.md.
            """)
    }

    /// The tree is clean, so the scan above finds nothing — and a scan that had stopped seeing a
    /// bare read would find nothing too. These are the shapes it has to tell apart.
    @Test func theScanSeesABareReadAndOnlyThat() {
        let far = Array(repeating: "let x = 1", count: Self.boundReach).joined(separator: "\n")
        let cases: [(source: String, bare: Bool, why: Comment)] = [
            ("#expect(Logger.shared.entries.contains { $0.message == m })", true,
             "a bare read"),
            ("let log = LogCapture()\n#expect(Logger.shared.entries.contains { $0.message == m })", true,
             "a capture elsewhere in the file does not bound this read"),
            ("_ = await loggedLineOnDisk(containing: m)\nlet all = Logger.shared.entries", true,
             "nor does a disk read"),
            ("let all = Logger.shared.entries\n\(far)\nlet i = other.lastIndex(where: { $0 == m })", true,
             "nor an index call too far away to be about it"),
            ("let all = Logger.shared.entries\n// then all.lastIndex(where: { … })", true,
             "nor a comment naming one"),
            ("/// Reads `Logger.shared.entries`, in prose\nlet x = 1", false,
             "a comment is not a read"),
            ("#expect(await log.holds(.warning, containing: m))", false,
             "a capture's own read never names the buffer"),
            ("let all = Logger.shared.entries\nlet i = all.lastIndex(where: { $0.message == m })", false,
             "an index-bounded read"),
            ("let all = Logger.shared.entries\nlet i = all.firstIndex { $0.message == m }", false,
             "an index-bounded read, trailing-closure form"),
        ]
        for c in cases { #expect(Self.readsTheBufferBare(c.source) == c.bare, c.why) }
    }
}

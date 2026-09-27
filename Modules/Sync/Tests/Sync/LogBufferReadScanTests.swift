import Foundation
import Testing
@testable import Sync

/// **Every read of `Logger.shared.entries` in the repository's test code is eviction-proof.**
///
/// The buffer is capped at 1,000 entries and every test target runs its suites in parallel against
/// it — this package alone runs ~3,500 tests across ~320 suites — so a bare
/// `Logger.shared.entries.contains { … }` is racing every other suite's logging. When it loses, the
/// assertion reports a missing log line, which is exactly what the test would report if the
/// production code had stopped writing it — "A log assertion reading a window that has already
/// rolled" in `docs/flaky-tests.md`. It reddened the v4.4 release run and two attempts at the v4.5
/// one, each time in a different suite, and each time passing 3/3 in isolation on the same tree.
///
/// Three shapes are eviction-proof, and only the last one names the buffer:
/// - **`LogCapture`** (`EventsTestSupport`) — accumulates at publish time, so a later trim cannot
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
/// **It reads every test tree in the repository, not just this directory** — the app target's,
/// each package's `Tests`, and the test-support libraries under a package's `Sources`. It read only
/// this one until `LogCapture` moved out of this test target, because nothing else could import
/// it; the app target, `Dashboard` and `FileExplorer` held nineteen reads of the buffer between
/// them, and four of their files read it with nothing bounding the window.
@Suite struct LogBufferReadScanTests {

    /// The repository root, walked up from this file: `Modules/Sync/Tests/Sync/<this file>`.
    static let root = URL(fileURLWithPath: #filePath).standardizedFileURL
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    /// This file, below the root. Its own test cases spell bare reads, so it is the one file skipped.
    static let ownPath = String(URL(fileURLWithPath: #filePath).standardizedFileURL.path
        .dropFirst(root.path.count + 1))

    /// Every directory holding test code, below the root: the app target's tests, and for the CLI
    /// and each package under `Modules`, its `Tests` and any `…TestSupport` library in `Sources`.
    /// Found rather than listed, so a new package is covered without anyone remembering to add it.
    static func testTrees() -> [String] {
        let fm = FileManager.default
        func children(_ path: String) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: root.appendingPathComponent(path).path)) ?? []).sorted()
        }
        func isDirectory(_ path: String) -> Bool {
            var directory: ObjCBool = false
            return fm.fileExists(atPath: root.appendingPathComponent(path).path, isDirectory: &directory)
                && directory.boolValue
        }
        let packages = ["SyncCloudCLI"] + children("Modules").map { "Modules/\($0)" }
        let trees = ["SyncCloudTests"] + packages.flatMap { package in
            ["\(package)/Tests"] + children("\(package)/Sources")
                .filter { $0.hasSuffix("TestSupport") }.map { "\(package)/Sources/\($0)" }
        }
        return trees.filter(isDirectory)
    }

    /// The Swift files in every test tree, read as text, by path below the root.
    static func sources() -> [(path: String, text: String)] {
        testTrees().flatMap { tree -> [(path: String, text: String)] in
            let dir = root.appendingPathComponent(tree)
            let below = (FileManager.default.enumerator(atPath: dir.path)?.allObjects as? [String] ?? [])
                .filter { $0.hasSuffix(".swift") }
            return below.compactMap { path in
                (try? String(contentsOf: dir.appendingPathComponent(path), encoding: .utf8))
                    .map { ("\(tree)/\(path)", $0) }
            }
        }
    }

    /// The paths among `sources` that read the buffer with nothing bounding the window.
    static func bareReaders(in sources: [(path: String, text: String)]) -> [String] {
        sources.filter { $0.path != ownPath && readsTheBufferBare($0.text) }.map(\.path).sorted()
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
        #expect(sources.count >= 600, """
            the scan read \(sources.count) files under \(Self.root.path) — it has stopped reading the \
            test trees, so a clean result below means nothing
            """)

        let bare = Self.bareReaders(in: sources)
        #expect(bare.isEmpty, """
            \(bare.count) file(s) read `Logger.shared.entries` with nothing bounding the window: \
            \(bare). Use `LogCapture` from `EventsTestSupport` — construct it BEFORE the call under \
            test. See "A log assertion reading a window that has already rolled" in docs/flaky-tests.md.
            """)
    }

    /// **The positive control for the walk.** The tree is clean, so the scan above finds nothing —
    /// and it would find nothing just the same in a tree it had stopped reading. So a bare read is
    /// planted in one real file of every tree it walks, and the judgement has to name that file.
    ///
    /// The trees are found, not listed, so the ones that held the bare reads this scan was widened
    /// for are required by name: a walk that stopped finding one would otherwise drop it from this
    /// control too, and pass.
    @Test func theScanSeesABareReadPlantedInEveryTestTree() {
        let trees = Self.testTrees()
        for tree in ["SyncCloudTests", "Modules/Sync/Tests", "Modules/Dashboard/Tests",
                     "Modules/FileExplorer/Tests"] {
            #expect(trees.contains(tree), "the scan no longer finds \(tree) under \(Self.root.path)")
        }
        let sources = Self.sources()
        for tree in trees {
            guard let victim = sources.first(where: { $0.path.hasPrefix(tree + "/") && $0.path != Self.ownPath }) else {
                Issue.record("the scan reads no Swift file under \(tree), so a bare read there would pass")
                continue
            }
            let planted = (path: victim.path, text: victim.text + "\nlet all = Logger.shared.entries\n")
            #expect(Self.bareReaders(in: [planted]) == [victim.path],
                    "a bare read planted in \(victim.path) was not reported")
        }
    }

    /// **…and for the judgement.** One that had stopped seeing a bare read would find nothing in a
    /// clean tree either. These are the shapes it has to tell apart.
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

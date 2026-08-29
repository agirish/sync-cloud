import Foundation
import Testing
@testable import Sync

/// **Every read of `Logger.shared.entries` in a test is either eviction-proof or listed here.**
///
/// The buffer is capped at 1,000 entries and this package runs ~2,850 tests across ~260 suites in
/// parallel, so a bare `Logger.shared.entries.contains { … }` is racing every other suite's
/// logging. When it loses, the assertion reports a missing log line, which is exactly what the test
/// would report if the production code had stopped writing it. Mechanism 12 in
/// `docs/flaky-tests.md`. It reddened the v4.4 release run and two attempts at the v4.5 one, each
/// time in a different suite, and each time passing 3/3 in isolation on the same tree.
///
/// Three shapes are eviction-proof, and the scan recognises all three:
/// - **`LogCapture`** (`TestSupport.swift`) — accumulates at publish time, so a later trim cannot
///   take an entry away. The preferred form; converting a suite is a one-line property plus
///   pointing its helper at it.
/// - **reading the DISK log** — `loggedLineOnDisk`, `Logger.shared.flushToDisk()`. The file is not
///   capped. `DuplicatesGateFailClosedTests` says so in its own comment.
/// - **an index-bounded read** — `firstIndex(where:)`/`lastIndex(where:)` on a marker the test
///   wrote itself, then a slice. This DIAGNOSES eviction rather than preventing it, so it is
///   allowed but not recommended: the marker is older than the lines it bounds and is evicted
///   first, which makes the test fail more often, not less.
///
/// **This list is allowed to shrink and must never grow.** A new bare read fails here until its
/// author either uses `LogCapture` or writes down why this one cannot.
@Suite struct LogBufferReadScanTests {

    /// Suites whose bare reads predate `LogCapture`. Each is a live flake risk, not an exemption on
    /// the merits — convert them when you touch them. Listed by file so the count is honest.
    static let unconverted: Set<String> = [
        "AnthropicKeychainTests.swift",
        "BulkFailureAggregationTests.swift",
        "CopyMoveBehaviorPinTests.swift",
        "CopyUndoDriftAndTransientTests.swift",
        "FileSyncManagerFilingTests.swift",
        "FilingProfileWriteTests.swift",
        "FilingResurveyTests.swift",
        "FilingScanAbandonmentLogTests.swift",
        "FilingVerdictSetAsideTests.swift",
        "IgnoredItemsStoreTests.swift",
        "MergeUndoPromiseTests.swift",
        "PersonTagTests.swift",
        "RedoFailureReportingTests.swift",
        "StorageLensPreservationTests.swift",
        "UndoRedoLogLabelTests.swift",
    ]

    private static func testFiles() -> [URL] {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        return ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "swift" }
    }

    /// Files holding a read of the in-memory buffer that nothing bounds.
    static func bareReaders() -> [String] {
        var found: [String] = []
        for url in testFiles() {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let lines = text.components(separatedBy: .newlines)
            let reads = lines.enumerated().filter { _, l in
                let t = l.trimmingCharacters(in: .whitespaces)
                return t.contains("Logger.shared.entries") && !t.hasPrefix("//") && !t.hasPrefix("///")
            }
            guard !reads.isEmpty else { continue }
            // Eviction-proof if the file uses a capture, reads the disk log, or bounds by an index.
            let proof = text.contains("LogCapture(")
                || text.contains("loggedLineOnDisk") || text.contains("flushToDisk()")
                || text.contains("firstIndex(where:") || text.contains("lastIndex(where:")
            if !proof { found.append(url.lastPathComponent) }
        }
        return found.sorted()
    }

    @Test func noSuiteReadsTheLogBufferUnbounded() {
        let bare = Set(Self.bareReaders())
        #expect(!bare.isEmpty || !Self.unconverted.isEmpty,
                "the scan found nothing at all — it has stopped reading the test tree")

        let newOnes = bare.subtracting(Self.unconverted).sorted()
        #expect(newOnes.isEmpty, """
            \(newOnes.count) suite(s) read `Logger.shared.entries` with nothing bounding the window: \
            \(newOnes). Use `LogCapture` from TestSupport — construct it BEFORE the call under test. \
            See mechanism 12 in docs/flaky-tests.md.
            """)
    }

    /// The list may only shrink. An entry naming a file that no longer reads the buffer is a
    /// conversion someone finished without crossing it off, and leaving it there hides the next one.
    @Test func theUnconvertedListHasNoStaleEntries() {
        let bare = Set(Self.bareReaders())
        let stale = Self.unconverted.subtracting(bare).sorted()
        #expect(stale.isEmpty, """
            \(stale.count) entr(y/ies) name a suite that no longer reads the buffer bare — \
            delete them from `unconverted`: \(stale)
            """)
    }
}

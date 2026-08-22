import Testing
import Foundation
@testable import Sync

/// Coverage for ``FilingSurvey/isAvailable(_:)`` — the guard that decides whether a document can be
/// read without materializing it.
///
/// **Every other test of this predicate injects past it.** `PDFTextExtractorTests` passes
/// `isAvailable: { _ in false }` and `FilingResurveyTests` sets
/// `manager.filingDocumentIsAvailable`, so a green suite said nothing whatever about what the
/// production predicate answers. It answered on iCloud's eviction signals alone, and every other
/// File Provider — Dropbox, OneDrive, Google Drive, Box under `~/Library/CloudStorage` — reports
/// `isUbiquitousItem == false`, so a dataless file of theirs fell through to "available". Both
/// halves of that are bad: online the survey opens the placeholder and the provider downloads the
/// whole file (a metadata scan must never do that), offline the extractor returns `""` and the
/// corpus stamps it blank against a size and mtime that do not move when the content later lands,
/// so it is written off permanently — the exact outcome the predicate's own doc comment exists to
/// prevent, for the one provider family it happened to know about.
///
/// These tests take the `statFlags` seam, so the flag math, the fold to a Bool and the predicate
/// itself all run as production runs them; only the `lstat` is stated, because `SF_DATALESS` is an
/// `SF_` flag a File Provider sets and `chflags` refuses to anyone but root.
@Suite struct FilingSurveyAvailabilityTests {

    /// A real file on disk, with no iCloud attributes at all — what a Dropbox/OneDrive/Drive item
    /// under `~/Library/CloudStorage` looks like to `resourceValues`.
    private func temporaryFile() throws -> (URL, () -> Void) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FilingSurveyAvailability-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("statement.pdf")
        try Data("x".utf8).write(to: file)
        return (file, { try? FileManager.default.removeItem(at: dir) })
    }

    /// The finding. A dataless file that is not an iCloud item is not readable, and saying it is
    /// costs a download online and a permanent blank stamp offline.
    @Test func aDatalessNonICloudFileIsNotAvailable() throws {
        let (file, cleanup) = try temporaryFile()
        defer { cleanup() }

        // Not ubiquitous — the real file has no iCloud attributes — but dataless, which is how
        // every non-Apple File Provider says "the content lives on the provider".
        #expect(FilingSurvey.isAvailable(file.path,
                                         statFlags: { _ in MaterializationStatus.datalessFlag }) == false)
    }

    /// The dataless bit alongside whatever else the provider set still reads as unavailable — the
    /// predicate must ask ``MaterializationStatus`` rather than compare `st_flags` for equality.
    @Test func theDatalessBitAmongOtherFlagsStillWithholdsTheFile() throws {
        let (file, cleanup) = try temporaryFile()
        defer { cleanup() }

        let withOthers = MaterializationStatus.datalessFlag | 0x0000_0002 | 0x0008_0000
        #expect(FilingSurvey.isAvailable(file.path, statFlags: { _ in withOthers }) == false)
    }

    /// And the other direction, so the fix cannot be "return false more often": an ordinary local
    /// file whose content is right there stays readable. Every non-dataless flag word must.
    @Test func aMaterializedFileStaysAvailable() throws {
        let (file, cleanup) = try temporaryFile()
        defer { cleanup() }

        #expect(FilingSurvey.isAvailable(file.path, statFlags: { _ in 0 }) == true)
        #expect(FilingSurvey.isAvailable(file.path, statFlags: { _ in 0x0000_0002 }) == true)
        // A path the stat cannot answer for is not withheld: it is not a placeholder, and the read
        // that follows fails on its own. Same fold `MaterializationStatus.isCloudOnly` documents.
        #expect(FilingSurvey.isAvailable(file.path, statFlags: { _ in nil }) == true)
    }

    /// The seam is asked about the file being judged, not some other path — a predicate that
    /// statted, say, the parent directory would pass every test above and never see a placeholder.
    @Test func theStatIsTakenOnThePathBeingJudged() throws {
        let (file, cleanup) = try temporaryFile()
        defer { cleanup() }

        let asked = Mutex<[String]>([])
        _ = FilingSurvey.isAvailable(file.path, statFlags: { path in
            asked.withLock { $0.append(path) }
            return 0
        })
        #expect(asked.withLock { $0 } == [file.path])
    }

    /// The public one-argument entry point is wired to the real `lstat`, not left on a stub — and
    /// it agrees with ``MaterializationStatus/isCloudOnly(atPath:)`` on a real file.
    @Test func thePublicEntryPointUsesTheRealStat() throws {
        let (file, cleanup) = try temporaryFile()
        defer { cleanup() }

        #expect(MaterializationStatus.isCloudOnly(atPath: file.path) == false)
        #expect(FilingSurvey.isAvailable(file.path) == true)
        // Same answer as spelling the real seam out by hand.
        #expect(FilingSurvey.isAvailable(file.path,
                                         statFlags: MaterializationStatus.realStatFlags) == true)
    }

    /// A directory is not a document to withhold, and a missing path is the reader's problem — both
    /// keep answering as they did before the dataless check was added.
    @Test func directoriesAndMissingPathsAreUnchanged() throws {
        let (file, cleanup) = try temporaryFile()
        defer { cleanup() }
        #expect(FilingSurvey.isAvailable(file.deletingLastPathComponent().path) == true)
        #expect(FilingSurvey.isAvailable("/no/such/file-\(UUID().uuidString).pdf") == true)
    }

    /// The whole point of the guard, one layer up: the extractor must decline a dataless
    /// non-iCloud PDF rather than open it, because opening a placeholder is what makes the
    /// provider download it.
    @Test func theExtractorDeclinesADatalessNonICloudPDF() throws {
        let (file, cleanup) = try temporaryFile()
        defer { cleanup() }

        let cloudOnly: (String) -> Bool = { path in
            !FilingSurvey.isAvailable(path, statFlags: { _ in MaterializationStatus.datalessFlag })
        }
        #expect(cloudOnly(file.path) == true)
        #expect(PDFTextExtractor.readSync(file.path, isAvailable: { !cloudOnly($0) }) == nil)
    }
}

/// Minimal lock so the recording stub above is `@Sendable` without importing anything new.
private final class Mutex<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
}

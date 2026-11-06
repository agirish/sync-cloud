import Testing
import Foundation
@testable import Sync

/// Coverage for ``FilingSurvey/isAvailable(_:)``, which decides whether a document can be read
/// without materializing it. Other suites inject past it, so these test the production predicate.
/// Non-iCloud File Providers (Dropbox, OneDrive, Google Drive, Box under `~/Library/CloudStorage`)
/// report `isUbiquitousItem == false`, so the dataless flag must be checked too. Otherwise a
/// placeholder is opened and downloaded online, or stamped blank offline and written off forever.
/// Only the `lstat` is stubbed (`statFlags`): `chflags` won't set `SF_DATALESS` for anyone but root.
@Suite struct FilingSurveyAvailabilityTests {

    /// A real file with no iCloud attributes, as a Dropbox, OneDrive or Drive item under
    /// `~/Library/CloudStorage` looks to `resourceValues`.
    private func temporaryFile() throws -> (URL, () -> Void) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FilingSurveyAvailability-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("statement.pdf")
        try Data("x".utf8).write(to: file)
        return (file, { try? FileManager.default.removeItem(at: dir) })
    }

    /// A dataless file that is not an iCloud item is not available; calling it available costs a
    /// download online and a permanent blank stamp offline.
    @Test func aDatalessNonICloudFileIsNotAvailable() throws {
        let (file, cleanup) = try temporaryFile()
        defer { cleanup() }

        // Not ubiquitous, but dataless: how every non-Apple File Provider says the content lives
        // on the provider.
        #expect(FilingSurvey.isAvailable(file.path,
                                         statFlags: { _ in MaterializationStatus.datalessFlag }) == false)
    }

    /// The dataless bit among other flags still reads as unavailable: the predicate asks
    /// ``MaterializationStatus`` rather than comparing `st_flags` for equality.
    @Test func theDatalessBitAmongOtherFlagsStillWithholdsTheFile() throws {
        let (file, cleanup) = try temporaryFile()
        defer { cleanup() }

        let withOthers = MaterializationStatus.datalessFlag | 0x0000_0002 | 0x0008_0000
        #expect(FilingSurvey.isAvailable(file.path, statFlags: { _ in withOthers }) == false)
    }

    /// The other direction, so the guard isn't just "return false more often": a local file with
    /// its content stays available, whatever its non-dataless flags.
    @Test func aMaterializedFileStaysAvailable() throws {
        let (file, cleanup) = try temporaryFile()
        defer { cleanup() }

        #expect(FilingSurvey.isAvailable(file.path, statFlags: { _ in 0 }) == true)
        #expect(FilingSurvey.isAvailable(file.path, statFlags: { _ in 0x0000_0002 }) == true)
        // A path the stat can't answer for is not withheld: it isn't a placeholder, and the read
        // fails on its own. Same fold as `MaterializationStatus.isCloudOnly`.
        #expect(FilingSurvey.isAvailable(file.path, statFlags: { _ in nil }) == true)
    }

    /// The seam is asked about the file being judged; one that statted the parent directory would
    /// pass every test above and never see a placeholder.
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

    /// The one-argument entry point is wired to the real `lstat`, and agrees with
    /// ``MaterializationStatus/isCloudOnly(atPath:statFlags:)`` on a real file.
    @Test func thePublicEntryPointUsesTheRealStat() throws {
        let (file, cleanup) = try temporaryFile()
        defer { cleanup() }

        #expect(MaterializationStatus.isCloudOnly(atPath: file.path) == false)
        #expect(FilingSurvey.isAvailable(file.path) == true)
        // Same answer as spelling the real seam out by hand.
        #expect(FilingSurvey.isAvailable(file.path,
                                         statFlags: MaterializationStatus.realStatFlags) == true)
    }

    /// A directory is not a document to withhold, and a missing path is the reader's problem: both
    /// answer available.
    @Test func directoriesAndMissingPathsAreUnchanged() throws {
        let (file, cleanup) = try temporaryFile()
        defer { cleanup() }
        #expect(FilingSurvey.isAvailable(file.deletingLastPathComponent().path) == true)
        #expect(FilingSurvey.isAvailable("/no/such/file-\(UUID().uuidString).pdf") == true)
    }

    /// One layer up: the extractor declines a dataless non-iCloud PDF rather than open it, since
    /// opening a placeholder makes the provider download it.
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

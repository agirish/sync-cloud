import Foundation
import Testing
@testable import Sync

/// "The tree already holds this document" — the filing queue reading the content indexes that until
/// now only the Duplicates lens read.
@Suite struct FilingAlreadyFiledTests {

    private func suggestion(_ name: String, confidence: FilingConfidence = .high,
                            alreadyFiledAt: [String] = []) -> FilingSuggestion {
        FilingSuggestion(
            filePath: "/P/TODO/" + name, fileName: name, size: 10, modificationDate: nil,
            candidates: [FilingDestination(path: "/P/Work/Pay", confidence: confidence,
                                           reasons: ["name match"], newSegments: [])],
            providerRoot: "/P", alreadyFiledAt: alreadyFiledAt)
    }

    @Test("A document the tree already holds is never in the blind batch")
    func alreadyFiledIsNotBatchEligible() {
        // The batch files without the user looking. A second copy is the one outcome they cannot
        // review afterwards: it lands under a name of its own, in a folder that genuinely fits, and
        // nothing about it says it is a copy.
        #expect(suggestion("Payslip.jpg").isBatchEligible)
        #expect(!suggestion("Payslip.jpg", alreadyFiledAt: ["Work/HPE/Pay/2026"]).isBatchEligible)
        // The per-file "File here" is untouched — this withholds the BLIND path, not the choice.
        #expect(suggestion("Payslip.jpg", alreadyFiledAt: ["Work/HPE/Pay/2026"]).hasConfidentHome)
    }

    @Test("Being already filed is reported, not inferred from the candidates")
    func flagIsCarried() {
        #expect(!suggestion("a.pdf").isAlreadyFiled)
        #expect(suggestion("a.pdf", alreadyFiledAt: ["X"]).isAlreadyFiled)
        #expect(suggestion("a.pdf").alreadyFiled(at: ["X", "Y"]).alreadyFiledAt == ["X", "Y"])
        // The copy keeps everything else — a suggestion that lost its candidates on the way through
        // this would be a card with no home at all.
        #expect(suggestion("a.pdf").alreadyFiled(at: ["X"]).candidates.count == 1)
    }

    @Test("A loose file is not a copy of itself")
    func ownFolderExcluded() {
        // The inbox is in the index the moment a duplicate scan has run over it, so without the
        // exclusion every loose file would report itself as already filed where it already is.
        let index = DocumentIdentityIndex.build(
            hashes: [ContentHashRecord(path: "/P/TODO/a.pdf", mtime: 0, size: 1, hex: "h",
                                       storedAt: Date(timeIntervalSince1970: 0)),
                     ContentHashRecord(path: "/P/Work/Pay/b.pdf", mtime: 0, size: 1, hex: "h",
                                       storedAt: Date(timeIntervalSince1970: 0))],
            fingerprints: [], providerRoot: "/P", existsOnDisk: { _ in true })
        #expect(index.folders(holding: "b:h", excluding: "TODO") == ["Work/Pay"])
        // Non-vacuity: without the exclusion both folders come back, so the line above is measuring
        // the exclusion and not a one-element index.
        #expect(index.folders(holding: "b:h") == ["TODO", "Work/Pay"])
    }

    @Test("A re-stamped PDF is still the same document")
    func fingerprintSeesWhatBytesCannot() {
        // The case the whole feature exists for. Two downloads of one payslip: different bytes,
        // same text. A byte-hash-only reading reports nothing and the queue files a second copy.
        func rec(_ path: String, _ hex: String) -> ContentHashRecord {
            ContentHashRecord(path: path, mtime: 0, size: 1, hex: hex,
                              storedAt: Date(timeIntervalSince1970: 0))
        }
        let bytesOnly = DocumentIdentityIndex.build(
            hashes: [rec("/P/TODO/Payslip.pdf", "bytesA"), rec("/P/Work/Pay/01. Jan.pdf", "bytesB")],
            fingerprints: [], providerRoot: "/P", existsOnDisk: { _ in true })
        #expect(bytesOnly.folders(holding: "b:bytesA", excluding: "TODO").isEmpty)

        let withText = DocumentIdentityIndex.build(
            hashes: [rec("/P/TODO/Payslip.pdf", "bytesA"), rec("/P/Work/Pay/01. Jan.pdf", "bytesB")],
            fingerprints: [rec("/P/TODO/Payslip.pdf", "text"), rec("/P/Work/Pay/01. Jan.pdf", "text")],
            providerRoot: "/P", existsOnDisk: { _ in true })
        #expect(withText.folders(holding: "f:text", excluding: "TODO") == ["Work/Pay"])
    }
}

/// **The phase itself, driven through a real scan — which nothing in the repo did.**
///
/// The four tests above hand-build a suggestion or call the index directly. The marking phase
/// returns early on `guard let contentIndexDirectory`, and that property was set in NO test
/// anywhere: the phase was a no-op repo-wide, and deleting its call from the scan passed the whole
/// Sync package. What it protects is the one outcome the blind batch's user cannot review — a
/// second copy of a document the tree already holds, landing under a name of its own in a folder
/// that genuinely fits.
@MainActor
@Suite struct FilingAlreadyFiledScanTests {

    static func write(_ url: URL, _ bytes: Data) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try bytes.write(to: url)
    }

    /// A loose file whose bytes the tree already holds elsewhere comes back marked, and therefore
    /// out of the blind batch.
    @Test func theScanMarksALooseFileTheTreeAlreadyHolds() async throws {
        let root = try makeCanonicalTempRoot(prefix: "AlreadyFiledScan")
        defer { try? FileManager.default.removeItem(at: root) }
        let indexDir = root.appendingPathComponent("index")
        try FileManager.default.createDirectory(at: indexDir, withIntermediateDirectories: true)

        // The same bytes in two places: filed under Work, and loose in the inbox.
        let payload = Data(repeating: 0x50, count: 4096)
        let filed = root.appendingPathComponent("Work/Pay/payslip-june.jpg")
        let loose = root.appendingPathComponent("Downloads/Payslip.jpg")
        try Self.write(filed, payload)
        try Self.write(loose, payload)

        // The content index as a duplicates scan leaves it — the filed copy, by byte hash.
        let hex = await FileSyncManager.hashFiles([filed.path], fileManager: FileManager.default,
                                                  cache: nil)[filed.path] ?? ""
        try #require(!hex.isEmpty, "the fixture could not hash its own file")
        let records = [ContentHashRecord(path: filed.path, mtime: 0, size: payload.count,
                                         hex: hex, storedAt: Date())]
        ContentHashIndexStore.saveInBackground(records,
                                               to: indexDir.appendingPathComponent("content-hash-index.json"))
        ContentHashIndexStore.waitForPendingWrites()

        let m = FileSyncManager()
        m.contentIndexDirectory = indexDir      // the seam no test set

        let marked = await m.markingAlreadyFiled([
            FilingSuggestion(filePath: loose.path, fileName: "Payslip.jpg", size: payload.count,
                             modificationDate: nil,
                             candidates: [FilingDestination(path: root.appendingPathComponent("Work/Pay").path,
                                                            confidence: .high, reasons: ["r"],
                                                            newSegments: [])],
                             providerRoot: root.path)
        ], providerRoot: root.path)

        let card = try #require(marked.first)
        #expect(card.isAlreadyFiled, "the tree already holds these bytes and the card does not say so")
        #expect(card.isBatchEligible == false,
                "a document the tree already holds must not be filed by the blind batch")
    }

    /// The other direction, so the test above cannot pass by marking everything: bytes the index
    /// has never seen come back unmarked and batch-eligible.
    @Test func aFileTheTreeDoesNotHoldIsLeftAlone() async throws {
        let root = try makeCanonicalTempRoot(prefix: "AlreadyFiledScanNeg")
        defer { try? FileManager.default.removeItem(at: root) }
        let indexDir = root.appendingPathComponent("index")
        try FileManager.default.createDirectory(at: indexDir, withIntermediateDirectories: true)

        let filed = root.appendingPathComponent("Work/Pay/other.jpg")
        let loose = root.appendingPathComponent("Downloads/Fresh.jpg")
        try Self.write(filed, Data(repeating: 0x41, count: 4096))
        try Self.write(loose, Data(repeating: 0x42, count: 4096))
        let hex = await FileSyncManager.hashFiles([filed.path], fileManager: FileManager.default,
                                                  cache: nil)[filed.path] ?? ""
        ContentHashIndexStore.saveInBackground(
            [ContentHashRecord(path: filed.path, mtime: 0, size: 4096, hex: hex, storedAt: Date())],
            to: indexDir.appendingPathComponent("content-hash-index.json"))
        ContentHashIndexStore.waitForPendingWrites()

        let m = FileSyncManager()
        m.contentIndexDirectory = indexDir
        let marked = await m.markingAlreadyFiled([
            FilingSuggestion(filePath: loose.path, fileName: "Fresh.jpg", size: 4096,
                             modificationDate: nil,
                             candidates: [FilingDestination(path: root.appendingPathComponent("Work/Pay").path,
                                                            confidence: .high, reasons: ["r"],
                                                            newSegments: [])],
                             providerRoot: root.path)
        ], providerRoot: root.path)

        // Non-vacuity: the index is non-empty and the loose file really was hashed, so this is
        // the phase deciding NOT to mark rather than the phase never running. (The first draft of
        // this test used `.pdf`, which routes to the fingerprint extractor: nothing was hashed,
        // nothing was marked, and it passed for a reason that had nothing to do with the answer.)
        let looseHex = await FileSyncManager.hashFiles([loose.path], fileManager: FileManager.default,
                                                       cache: nil)[loose.path] ?? ""
        #expect(!looseHex.isEmpty && looseHex != hex, "the fixture stopped exercising the byte path")
        #expect(marked.first?.isAlreadyFiled == false)
        #expect(marked.first?.isBatchEligible == true)
    }

    /// **The scan's own call, which is what was actually missing.** The three tests above drive
    /// the phase directly, so deleting the line in `filingScan` still passes them — which is
    /// precisely the finding: the call was removed and the whole Sync package stayed green. This
    /// runs the real scan end to end and asserts the published card carries the marker.
    @Test func theScanItselfMarksTheCard() async throws {
        let root = try makeCanonicalTempRoot(prefix: "AlreadyFiledWiring")
        defer { try? FileManager.default.removeItem(at: root) }
        let indexDir = root.appendingPathComponent("index")
        try FileManager.default.createDirectory(at: indexDir, withIntermediateDirectories: true)

        // The tree already holds these bytes under Work; the same bytes sit loose in Downloads.
        let payload = Data(repeating: 0x50, count: 4096)
        let filed = root.appendingPathComponent("Work/Pay/payslip-june.jpg")
        let loose = root.appendingPathComponent("Downloads/Payslip.jpg")
        try Self.write(filed, payload)
        try Self.write(loose, payload)

        let hex = await FileSyncManager.hashFiles([filed.path], fileManager: FileManager.default,
                                                  cache: nil)[filed.path] ?? ""
        try #require(!hex.isEmpty)
        ContentHashIndexStore.saveInBackground(
            [ContentHashRecord(path: filed.path, mtime: 0, size: payload.count, hex: hex,
                               storedAt: Date())],
            to: indexDir.appendingPathComponent("content-hash-index.json"))
        ContentHashIndexStore.waitForPendingWrites()

        let m = FileSyncManager()
        m.contentIndexDirectory = indexDir

        await m.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"),
                                      providerRoot: root)

        let card = try #require(m.filingSuggestions.first { $0.fileName == "Payslip.jpg" },
                                "the scan produced no card for the loose file")
        #expect(card.isAlreadyFiled,
                "the scan did not run the already-filed phase — a second copy would be filed blind")
        #expect(card.alreadyFiledAt.contains { $0.contains("Work/Pay") })
    }

    /// **With no index directory the phase is a no-op** — which is correct, and is also exactly why
    /// it went untested for so long: every suite ran in that state without noticing.
    @Test func withoutAnIndexDirectoryNothingIsMarked() async throws {
        let m = FileSyncManager()
        #expect(m.contentIndexDirectory == nil, "the default must stay nil — never a real home path")
        let out = await m.markingAlreadyFiled([
            FilingSuggestion(filePath: "/P/TODO/a.pdf", fileName: "a.pdf", size: 10,
                             modificationDate: nil, candidates: [], providerRoot: "/P")
        ], providerRoot: "/P")
        #expect(out.first?.isAlreadyFiled == false)
    }
}

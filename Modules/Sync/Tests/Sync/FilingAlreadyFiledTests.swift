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
        #expect(suggestion("Payslip.pdf").isBatchEligible)
        #expect(!suggestion("Payslip.pdf", alreadyFiledAt: ["Work/HPE/Pay/2026"]).isBatchEligible)
        // The per-file "File here" is untouched — this withholds the BLIND path, not the choice.
        #expect(suggestion("Payslip.pdf", alreadyFiledAt: ["Work/HPE/Pay/2026"]).hasConfidentHome)
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

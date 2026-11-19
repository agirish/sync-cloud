import Foundation
import Testing
@testable import Sync

/// The log line one Read Documents leaves (``VaultReadTally``), and the line under the cards
/// (``VaultModel/emptyCategories``).
@MainActor
@Suite struct VaultReadTallyTests {
    typealias Rig = VaultModelTests.Rig

    static let ssnCard = VaultIDReadingTests.ssnCard
    static let panCard = VaultIDReadingTests.panCard

    @Test func theLogLineCountsKindsAndNeverPrintsANumberOrAName() {
        var tally = VaultReadTally()
        tally.documents = 4
        for (path, pages) in [("/d/Legal/SSN/Anna/123-45-6789 card.pdf", [Self.ssnCard]),
                              ("/d/Legal/PAN/e-PAN Anna - ABCPE1234F.pdf", [Self.panCard]),
                              ("/d/Legal/PAN/copy of ABCPE1234F.pdf", [Self.panCard]),
                              ("/d/Legal/blank.pdf", [[" ", ""]])] {
            tally.record(pages, VaultReading.read(pages: pages, from: path))
        }
        tally.added = 2
        let line = tally.summary(seconds: 1872)
        #expect(line == "Vault: 4 document(s), 4 opened in 31m 12s (1 gave no text); read 1 Social Security & ITIN, "
                + "1 PAN Cards; 2 new number(s) to confirm")
        for secret in ["6789", "123456789", "ABCPE", "1234F", "Anna", "Eriksson", "e-PAN"] {
            #expect(!line.contains(secret), "the log line carries \(secret)")
        }
    }

    @Test func aReadWithNothingFoundSaysSo() {
        var tally = VaultReadTally()
        tally.documents = 1
        tally.record([["Nothing to see here"]], VaultReading.read(pages: [["Nothing to see here"]], from: "/d/x.pdf"))
        #expect(tally.summary(seconds: 4) == "Vault: 1 document(s), 1 opened in 4s; no numbers read; 0 new number(s) to confirm")
    }

    @Test func aNumberANotherDocumentOnlyNamesIsCountedApart() {
        var tally = VaultReadTally()
        let i94 = ["Admission I-94 Number: 123456789A1", "Document Number: X1234567"]
        tally.record([i94], VaultReading.read(pages: [i94], from: "/d/i94.pdf"))
        #expect(tally.byCategory == [.i94: 1])
        #expect(tally.mentions == 1)
        #expect(tally.summary(seconds: 0).contains("; 1 named only;"))
    }

    @Test func durationsReadAsAPersonWouldSayThem() {
        #expect(VaultReadTally.duration(45) == "45s")
        #expect(VaultReadTally.duration(1872) == "31m 12s")
        #expect(VaultReadTally.duration(3720) == "1h 02m")
    }

    // MARK: The line under the cards

    /// Pages handed in one file at a time, asking `during` what the Vault shows while each is read.
    struct WatchedDocuments: VaultDocumentReading {
        let pages: [String: [String]]
        let during: @MainActor @Sendable () -> Void
        func files() async -> [URL] { pages.keys.sorted().map { URL(fileURLWithPath: $0) } }
        func pages(in file: URL) async -> [[String]] {
            await during()
            return [pages[file.path] ?? []]
        }
        func stamp(of file: URL) -> String? { nil }
    }

    @Test func theNothingYetLineWaitsForTheReadToFinishAndNamesTheNewCards() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = rig.model()
        #expect(model.emptyCategories.contains(.ssn))
        #expect(model.emptyCategories.contains(.pan))
        #expect(model.emptyCategories.contains(.aadhaar))
        #expect(model.emptyCategories.contains(.voterID))
        #expect(!model.emptyCategories.contains(.other))

        var seenWhileReading: [[VaultCategory]] = []
        let documents = WatchedDocuments(pages: ["/d/Legal/SSN/card.pdf": Self.ssnCard],
                                         during: { seenWhileReading.append(model.emptyCategories) })
        await model.readDocuments(with: documents)
        #expect(seenWhileReading == [[]], "the line showed while the read was running")
        #expect(!model.emptyCategories.contains(.ssn))
        #expect(model.emptyCategories.contains(.pan))
    }
}

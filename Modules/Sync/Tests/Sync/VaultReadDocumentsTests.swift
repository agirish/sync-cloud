import Foundation
import Testing
@testable import Sync

/// Read Documents over time: reading again, confirming, correcting, files that come and go.
@MainActor
@Suite struct VaultReadDocumentsTests {
    /// Twelve member cards; the tenth opened stops the read, as Stop on the banner does.
    struct StopsAtTheTenth: VaultDocumentReading {
        final class Count: @unchecked Sendable { var opened = 0 }
        let count = Count()
        static func path(_ n: Int) -> String { "/Users/anna/Documents/Health/Dental/ID Cards/card \(n).pdf" }
        func files() async -> [URL] { (1...12).map { URL(fileURLWithPath: Self.path($0)) } }
        func pages(in file: URL) async -> [[String]] {
            count.opened += 1
            if count.opened == 10 { withUnsafeCurrentTask { $0?.cancel() } }
            let n = (1...12).first { Self.path($0) == file.path } ?? 0
            return [["Delta Dental", "Member Name: ANNA ERIKSSON", String(format: "Member ID: XZB1234567%02d", n)]]
        }
        func stamp(of file: URL) -> String? { "1" }
        func modified(of file: URL) -> Date? { nil }
        var followsReadPlan: Bool { false }
        func exists(_ file: URL) -> Bool { true }
    }

    /// Files handed over in the order given, every one read.
    final class InOrder: VaultDocumentReading, @unchecked Sendable {
        let pages: [(String, [String])]
        init(_ pages: [(String, [String])]) { self.pages = pages }
        func files() async -> [URL] { pages.map { URL(fileURLWithPath: $0.0) } }
        func pages(in file: URL) async -> [[String]] { pages.first { $0.0 == file.path }.map { [$0.1] } ?? [] }
        func stamp(of file: URL) -> String? { "1" }
        func modified(of file: URL) -> Date? { nil }
        var followsReadPlan: Bool { false }
        func exists(_ file: URL) -> Bool { true }
    }

    /// The order identity papers are read in changes nothing that is found: an original read
    /// before or after its copies gives the same numbers, sources, details and rows (VT107).
    @Test @MainActor func originalsFirstOrLastFindTheSame() async throws {
        let root = "/Users/anna/Documents/Immigration"
        let original = (root + "/Passport/Anna/scan.pdf", [VaultReadingTests.nameLine, VaultReadingTests.numberLine])
        // The copy says less than the original: its number in a cover letter, no zone.
        let copy = (root + "/Visa/Supporting Documents/passport copy.pdf",
                    ["Passport number L898902C3", "Name ANNA MARIA ERIKSSON", "Issued 2012"])
        let old = (root + "/Passport/Archive/old.pdf",
                   ["P<UTOERIKSSON<<ANNA<MARIA<<<<<<<<<<<<<<<<<<<", "X7654321<5UTO7408122F0204159<<<<<<<<<<<<<<02"])
        func read(_ order: [(String, [String])]) async throws -> (finds: [String], rows: [String], sealed: String) {
            let rig = try VaultModelTests.Rig(); defer { rig.cleanUp() }
            VaultReadFolders.add("/Users/anna/Documents", in: rig.defaults)
            let model = rig.model()
            await model.opened()
            await model.readDocuments(with: InOrder(order))
            // All of what was read, as sealed (finds, copies, mentions, the read index), with the
            // ids a read makes afresh taken out and every list in a fixed order.
            var state = try #require(rig.store.loadReading())
            state.finds.sort { $0.value < $1.value }
            state.lastRefreshed = nil; state.lastDiscovered = nil
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            var sealed = String(decoding: try encoder.encode(state), as: UTF8.self)
            sealed = sealed.replacingOccurrences(of: #""id":"[0-9A-F-]{36}""#, with: #""id":"-""#, options: .regularExpression)
            let finds = model.finds.map { find in
                "\(find.value) \(find.title) \(find.facts.holder ?? "") \(find.facts.primary?.path ?? "") "
                    + find.facts.sources.map(\.path).sorted().joined(separator: ",")
                    + " \(find.facts.dated.map { "\($0.timeIntervalSince1970)" } ?? "") \(find.facts.validUntil.map { "\($0.timeIntervalSince1970)" } ?? "")"
            }.sorted()
            let rows = model.rows.map { "\($0.value) \($0.title) \($0.pin.map { "\($0)" } ?? "")" }.sorted()
            return (finds, rows, sealed)
        }
        let first = try await read([original, copy, old])
        let last = try await read([old, copy, original])
        #expect(!first.finds.isEmpty)
        #expect(first.finds == last.finds)
        #expect(first.rows == last.rows)
        #expect(first.sealed == last.sealed, "what was sealed differs with the order read")
    }

    /// The plan opens an ID's own folder first, packets and archives last.
    @Test func thePlanReadsOriginalsFirst() {
        let root = "/Users/anna/Documents"
        let files = ["/Immigration/Visa/Supporting Documents/passport copy.pdf", "/Immigration/Passport/Archive/old.pdf",
                     "/Immigration/Letters/cover.pdf", "/Immigration/Passport/Anna/scan.pdf", "/Immigration/Letters/b.pdf"]
            .map { URL(fileURLWithPath: root + $0) }
        let order = VaultReadPlan(files: files, under: [root]).steps.map { $0.file.path.replacingOccurrences(of: root, with: "") }
        // Ties keep the order given.
        #expect(order == ["/Immigration/Passport/Anna/scan.pdf", "/Immigration/Passport/Archive/old.pdf",
                          "/Immigration/Letters/cover.pdf", "/Immigration/Letters/b.pdf",
                          "/Immigration/Visa/Supporting Documents/passport copy.pdf"])
        #expect(VaultReadPlan.every(files, under: [root]).first?.file.path == root + "/Immigration/Passport/Anna/scan.pdf")
    }

    /// A passport saved in its own folder and, byte for byte, in a visa packet.
    final class Twins: VaultDocumentReading, @unchecked Sendable {
        static let own = "/Users/anna/Documents/Immigration/Passport/Anna/scan.pdf"
        static let copy = "/Users/anna/Documents/Immigration/Visa/Supporting Documents/passport.pdf"
        private let lock = NSLock()
        private var reads: [String] = []
        var read: [String] { lock.withLock { reads } }
        func files() async -> [URL] { [Self.own, Self.copy].map { URL(fileURLWithPath: $0) } }
        func pages(in file: URL) async -> [[String]] { await reading(file).pages }
        func reading(_ file: URL) async -> (pages: [[String]], complete: Bool) {
            lock.withLock { reads.append(file.path) }
            return ([[VaultReadingTests.nameLine, VaultReadingTests.numberLine]], true)
        }
        func contentKey(of file: URL) async -> String? { "same bytes" }
        func size(of file: URL) -> Int? { 1024 }
        func stamp(of file: URL) -> String? { "1" }
        func modified(of file: URL) -> Date? { nil }
        var followsReadPlan: Bool { false }
        func exists(_ file: URL) -> Bool { true }
    }

    /// A file whose bytes were read already in this read is not read again: its pages are reused,
    /// and it is still named as one of the number's documents (VT107).
    @Test @MainActor func aByteIdenticalCopyIsReadOnceAndStillNamed() async throws {
        let rig = try VaultModelTests.Rig(); defer { rig.cleanUp() }
        VaultReadFolders.add("/Users/anna/Documents", in: rig.defaults)
        let model = rig.model()
        await model.opened()
        let reader = Twins()
        await model.readDocuments(with: reader)
        #expect(reader.read.count == 1, "the same bytes were read twice: \(reader.read)")
        let find = try #require(model.finds.first)
        #expect(Set(find.facts.sources.map(\.path)) == [Twins.own, Twins.copy], "the copy is not named")
    }

    /// Files of different sizes cannot be copies of each other: none is hashed.
    final class Unlike: VaultDocumentReading, @unchecked Sendable {
        private let lock = NSLock()
        private var hashed = 0
        var hashes: Int { lock.withLock { hashed } }
        func files() async -> [URL] { [Twins.own, Twins.copy].map { URL(fileURLWithPath: $0) } }
        func pages(in file: URL) async -> [[String]] { [[VaultReadingTests.nameLine, VaultReadingTests.numberLine]] }
        func contentKey(of file: URL) async -> String? { lock.withLock { hashed += 1 }; return file.path }
        func size(of file: URL) -> Int? { file.path == Twins.own ? 1000 : 2000 }
        func stamp(of file: URL) -> String? { "1" }
        func modified(of file: URL) -> Date? { nil }
        var followsReadPlan: Bool { false }
        func exists(_ file: URL) -> Bool { true }
    }

    @Test @MainActor func onlyFilesOfOneSizeAreHashed() async throws {
        let rig = try VaultModelTests.Rig(); defer { rig.cleanUp() }
        VaultReadFolders.add("/Users/anna/Documents", in: rig.defaults)
        let model = rig.model()
        await model.opened()
        let reader = Unlike()
        await model.readDocuments(with: reader)
        #expect(reader.hashes == 0, "a file no other shares a size with was hashed")
    }

    /// Two member cards, the second read with a page left out.
    final class OnePageLeftOut: VaultDocumentReading, @unchecked Sendable {
        static let whole = "/Users/anna/Documents/Health/Dental/ID Cards/card.pdf"
        static let partial = "/Users/anna/Documents/Health/Vision/ID Cards/card.pdf"
        private let lock = NSLock()
        private var opens: [String] = []
        var opened: [String] { lock.withLock { opens } }
        func files() async -> [URL] { [Self.whole, Self.partial].map { URL(fileURLWithPath: $0) } }
        func pages(in file: URL) async -> [[String]] { await reading(file).pages }
        func reading(_ file: URL) async -> (pages: [[String]], complete: Bool) {
            lock.withLock { opens.append(file.path) }
            let id = file.path == Self.whole ? "XZB123456789" : "VSP99887766"
            return ([["Member Name: ANNA ERIKSSON", "Member ID: \(id)"]], file.path == Self.whole)
        }
        func stamp(of file: URL) -> String? { "1" }
        func modified(of file: URL) -> Date? { nil }
        var followsReadPlan: Bool { false }
        func exists(_ file: URL) -> Bool { true }
    }

    /// A file read with a page left out gives what it gave, and is not marked read: the next read
    /// opens it again for the rest (VT54). A whole one is not opened again.
    @Test @MainActor func aFileWithAPageLeftOutIsReadAgainNextTime() async throws {
        let rig = try VaultModelTests.Rig(); defer { rig.cleanUp() }
        VaultReadFolders.add("/Users/anna/Documents", in: rig.defaults)
        let model = rig.model()
        await model.opened()
        let reader = OnePageLeftOut()
        await model.readDocuments(with: reader)
        #expect(Set(model.finds.map(\.value)) == ["XZB123456789", "VSP99887766"], "what the partial file gave was dropped")
        await model.readDocuments(with: reader)
        #expect(reader.opened == [OnePageLeftOut.whole, OnePageLeftOut.partial, OnePageLeftOut.partial])
        // Left out again as it stands: marked read until it changes, not opened at every read.
        await model.readDocuments(with: reader)
        #expect(reader.opened.count == 3, "a page that never reads reopens its file at every read")
    }

    /// Stop keeps what was read: sealed at once, not at the next 25th file, so a quit loses none
    /// of it (VT68).
    @Test @MainActor func whatAStoppedReadFoundIsSealed() async throws {
        let rig = try VaultModelTests.Rig(); defer { rig.cleanUp() }
        VaultReadFolders.add("/Users/anna/Documents", in: rig.defaults)
        let model = rig.model()
        await model.opened()
        let reader = StopsAtTheTenth()
        await Task { await model.readDocuments(with: reader) }.value
        #expect(reader.count.opened == 10, "the read went on past Stop")
        let found = model.finds.count
        #expect(found == 9, "the tenth was opened as the read stopped, and is not taken")

        // What a quit would leave: the sealed file, opened by a model of its own.
        let after = rig.model()
        await after.opened()
        #expect(after.finds.count == found, "what the stopped read found was not sealed")
    }

    typealias Rig = VaultModelTests.Rig
    typealias InterruptingProof = VaultFixtures.InterruptingProof

    @Test func typingInAWaitingNumberKeepsWhatWasReadAndChosen() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = rig.model()
        await model.readDocuments(with: VaultFakeDocuments(pages: ["/r/a.pdf": VaultFixtures.licensePage]))
        let find = try #require(model.finds.first)
        model.assign(find.id, to: .household)
        model.setGeo(find.id, to: .india)

        _ = model.add(VaultModel.Draft(title: "License", value: "D1234567"))

        let entry = try #require(model.entries.first)
        #expect(entry.facts?.validUntil == VaultFixtures.day(2030, 5, 16), "what was read for it was let go")
        #expect(entry.assignment == .household)
        #expect(entry.geo == .india)
        #expect(model.rows.first?.documents.map(\.path) == ["/r/a.pdf"])
    }

    @Test func confirmingKeepsUsedIn() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = rig.model()
        await model.readDocuments(with: VaultFakeDocuments(pages: ["/r/a.pdf": VaultFixtures.licensePage]))
        let find = try #require(model.finds.first)
        model.setGeo(find.id, to: .india)
        let updated = try #require(model.finds.first)
        _ = model.confirm(updated.id, as: VaultModel.Draft(updated))
        #expect(model.entries.first?.geo == .india)
    }

    @Test func aCorrectedMisreadIsNotOfferedAgain() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = rig.model()
        var documents = VaultFakeDocuments(pages: ["/r/a.pdf": VaultFixtures.licensePage])
        documents.knowsContents = true
        model.fileContents = { [documents] in await documents.contentKey(of: $0) }
        await model.readDocuments(with: documents)
        let find = try #require(model.finds.first)
        var draft = VaultModel.Draft(find)
        draft.value = "D1234568"
        _ = model.confirm(find.id, as: draft)
        await model.notesWritten()

        await model.readDocuments(with: documents, again: true)
        #expect(model.finds.isEmpty, "the misread came back")
    }

    @Test func aFileThatCouldNotBeOpenedKeepsWhatItGaveAndIsTriedAgain() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = rig.model()
        await model.readDocuments(with: FlakyDocuments(gone: false), again: true)
        let id = try #require(model.finds.first?.id)
        model.pin(id, .older)

        await model.readDocuments(with: FlakyDocuments(gone: true), again: true)
        #expect(model.finds.first?.id == id)
        #expect(model.finds.first?.pin == .older)
    }

    @Test func aMisreadCopyTakesItsDatesWithItWhenItGoes() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = rig.model()
        // One scan misread the year as 2035; the other reads 2030.
        await model.readDocuments(with: VaultFakeDocuments(pages: ["/r/A.pdf": VaultFixtures.front(expiring: "05/16/2035"),
                                                                    "/r/B.pdf": VaultFixtures.front(expiring: "05/16/2030")]))
        #expect(model.finds.first?.validUntil == VaultIDReadingTests.day(2035, 5, 16))

        await model.readDocuments(with: VaultFakeDocuments(pages: ["/r/B.pdf": VaultFixtures.front(expiring: "05/16/2030")]))

        let find = try #require(model.finds.first)
        #expect(find.validUntil == VaultIDReadingTests.day(2030, 5, 16))
        #expect(find.facts.sources.map(\.path) == ["/r/B.pdf"])
        #expect(!find.note.contains("2035"))
    }

    @Test func aReadThatSeesNoFilesKeepsWhatWasRead() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        VaultReadFolders.add("/r", in: rig.defaults)
        let model = rig.model()
        await model.readDocuments(with: VaultFakeDocuments(pages: ["/r/A.pdf": VaultFixtures.front(expiring: "05/16/2030")]))
        let id = try #require(model.finds.first?.id)
        model.pin(id, .current)

        // The folder is unmounted, or Documents not yet allowed: nothing comes back.
        await model.readDocuments(with: VaultFakeDocuments(pages: [:]))

        #expect(model.finds.map(\.id) == [id])
        #expect(model.finds.first?.pin == .current)
    }

    @Test func aFileGoneFromAFolderThatWasReadIsStillLetGo() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        VaultReadFolders.add("/r", in: rig.defaults)
        let model = rig.model()
        await model.readDocuments(with: VaultFakeDocuments(pages: ["/r/A.pdf": VaultFixtures.front(expiring: "05/16/2030"),
                                                                    "/r/note.pdf": ["Nothing here"]]))
        #expect(model.finds.count == 1)
        await model.readDocuments(with: VaultFakeDocuments(pages: ["/r/note.pdf": ["Nothing here"]]))
        #expect(model.finds.isEmpty)
    }

    @Test func aSavedNumberTakesItsRenewedCardsDates() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = rig.model()
        await model.readDocuments(with: VaultFakeDocuments(pages: ["/r/old.pdf": VaultFixtures.front(expiring: "05/16/2025")]))
        let find = try #require(model.finds.first)
        _ = model.confirm(find.id, as: VaultModel.Draft(find))

        // The card is renewed under the same number.
        await model.readDocuments(with: VaultFakeDocuments(pages: ["/r/old.pdf": VaultFixtures.front(expiring: "05/16/2025"),
                                                                    "/r/new.pdf": VaultFixtures.front(expiring: "05/16/2030")]))

        let row = try #require(model.rows.first { $0.isSaved })
        #expect(row.facts?.validUntil == VaultIDReadingTests.day(2030, 5, 16))
        #expect(row.standing.expired == false)
        #expect(model.finds.isEmpty, "the saved number was offered again")
    }

    @Test func typingInANumberAlreadyWaitingShowsItOnce() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = rig.model()
        await model.readDocuments(with: VaultFakeDocuments(pages: ["/r/A.pdf": VaultFixtures.front(expiring: "05/16/2030")]))
        #expect(model.finds.count == 1)

        _ = model.add(VaultModel.Draft(title: "License", value: "D1234567"))

        #expect(model.finds.isEmpty)
        #expect(model.rows.filter { VaultReading.normalized($0.value) == "D1234567" }.count == 1)
    }

    @Test func aChangeOfRulesKeepsTheChoicesMadeAndSaysSo() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let documents = VaultFakeDocuments(pages: ["/r/A.pdf": VaultFixtures.front(expiring: "05/16/2030")])
        do {
            let model = rig.model()
            await model.readDocuments(with: documents)
            let id = try #require(model.finds.first?.id)
            model.assign(id, to: .household)
            model.pin(id, .older)
            model.closed()
        }
        // As an older build sealed it.
        var state = try #require(rig.store.loadReading())
        state.version -= 1
        try rig.store.saveReading(state)

        let model = rig.model()
        await model.opened()
        #expect(model.finds.isEmpty)
        #expect(model.needsReadAgain, "the panel does not say to read again")
        // Closed and opened again without reading: it still says so.
        model.closed()
        let reopened = rig.model()
        await reopened.opened()
        #expect(reopened.needsReadAgain)

        await reopened.readDocuments(with: documents)
        #expect(!reopened.needsReadAgain)
        let find = try #require(reopened.finds.first)
        #expect(find.assignment == .household)
        #expect(find.pin == .older)
    }

    @Test func forgetWhileTheVaultStaysLoadedReadsEveryFileAgain() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let documents = VaultFakeDocuments(pages: ["/r/A.pdf": VaultFixtures.front(expiring: "05/16/2030")],
                                           stamps: ["/r/A.pdf": "1"])
        let model = rig.model()
        await model.readDocuments(with: documents)
        let id = try #require(model.finds.first?.id)
        model.setAside(id)
        #expect(model.finds.isEmpty)

        VaultSetAside.forget(in: rig.defaults)
        await model.readDocuments(with: documents)

        #expect(model.finds.count == 1, "a forgotten number did not come back")
    }

    @Test func aReadNumberCorrectedByHandIsNotOfferedAgain() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = rig.model()
        await model.opened()
        let front = VaultFixtures.front(expiring: "05/16/2030")
        var documents = VaultFakeDocuments(pages: ["/r/A.pdf": front])
        documents.knowsContents = true
        model.fileContents = { [documents] in await documents.contentKey(of: $0) }
        await model.readDocuments(with: documents)
        let find = try #require(model.finds.first)
        let id = try #require(model.confirm(find.id, as: VaultModel.Draft(title: "License", value: find.value,
                                                                           category: .driversLicense)))
        let changed = await model.update(id, to: VaultModel.Draft(title: "License", value: "D7654321",
                                                                    category: .driversLicense))
        #expect(changed)
        await model.notesWritten()
        await model.readDocuments(with: documents, again: true)
        #expect(model.finds.isEmpty, "the misreading was offered again")
    }

    /// A file that gives nothing back at all (locked, gone for a moment).
    struct FlakyDocuments: VaultDocumentReading {
        let gone: Bool
        func files() async -> [URL] { [URL(fileURLWithPath: "/r/a.pdf")] }
        func pages(in file: URL) async -> [[String]] { gone ? [] : [VaultFixtures.licensePage] }
        func stamp(of file: URL) -> String? { "1" }
    }

    struct WalkWithAGap: VaultDocumentReading {
        let pages: [String: [String]]
        let unreachable: [String]
        func files() async -> [URL] { pages.keys.sorted().map { URL(fileURLWithPath: $0) } }
        func walk() async -> (files: [URL], unreachable: [String]) { (await files(), unreachable) }
        func pages(in file: URL) async -> [[String]] { pages[file.path].map { [$0] } ?? [] }
        func stamp(of file: URL) -> String? { "1" }
    }

    @Test func whatWasReadInAFolderThatCouldNotBeOpenedIsKept() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        VaultReadFolders.add("/r", in: rig.defaults)
        let model = rig.model()
        await model.opened()
        let front = VaultFixtures.front(expiring: "05/16/2030")
        await model.readDocuments(with: VaultFakeDocuments(pages: ["/r/Sub/A.pdf": front, "/r/B.pdf": ["nothing here"]]))
        #expect(model.finds.count == 1)
        // The subfolder cannot be opened this time; the rest of /r can.
        await model.readDocuments(with: WalkWithAGap(pages: ["/r/B.pdf": ["nothing here"]], unreachable: ["/r/Sub"]))
        #expect(model.finds.count == 1, "a folder that could not be opened was taken for deleted")
    }

    /// A file grown past the reader's size cap since it was read: passed over, as the reader says
    /// (``VaultReadNotes/tooLarge``), and counted each time it is opened.
    final class GrownPastTheCap: VaultDocumentReading, @unchecked Sendable {
        private let lock = NSLock()
        private var opens = 0
        var opened: Int { lock.withLock { opens } }
        func files() async -> [URL] { [URL(fileURLWithPath: "/r/A.pdf")] }
        func pages(in file: URL) async -> [[String]] { [] }
        func noted(_ file: URL) async -> (pages: [[String]], complete: Bool, notes: VaultReadNotes) {
            lock.withLock { opens += 1 }
            var notes = VaultReadNotes()
            notes.tooLarge = 1
            return ([], true, notes)
        }
        func stamp(of file: URL) -> String? { "2" }
    }

    /// VT81 (owner): what a file gave stays once it grows past the cap, and it is marked read as
    /// it is, so the next read does not open it again until it changes.
    @Test func aFileGrownPastTheCapKeepsItsIDAndIsNotOpenedAgain() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        VaultReadFolders.add("/r", in: rig.defaults)
        let model = rig.model()
        await model.opened()
        await model.readDocuments(with: VaultFakeDocuments(pages: ["/r/A.pdf": VaultFixtures.front(expiring: "05/16/2030")]))
        #expect(model.finds.count == 1)
        let grown = GrownPastTheCap()
        await model.readDocuments(with: grown)
        #expect(grown.opened == 1)
        #expect(model.finds.count == 1, "what it gave before was let go")
        await model.readDocuments(with: grown)
        #expect(grown.opened == 1, "opened again though it has not changed")
        #expect(model.finds.count == 1)
    }
}

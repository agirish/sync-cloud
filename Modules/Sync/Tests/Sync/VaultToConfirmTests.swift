import CryptoKit
import Foundation
import Security
import Testing
@testable import Sync

/// Pages handed to Read Documents by the test, file by file.
struct VaultFakeDocuments: VaultDocumentReading {
    let pages: [String: [String]]
    /// Each file's size and date as the test sets them; a file missing here is read every time.
    var stamps: [String: String] = [:]
    /// Every file `lines(in:)` was asked for, in order.
    let opened = OpenedFiles()

    final class OpenedFiles: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []
        func add(_ path: String) { lock.withLock { paths.append(path) } }
        var all: [String] { lock.withLock { paths } }
    }

    func files() async -> [URL] { pages.keys.sorted().map { URL(fileURLWithPath: $0) } }
    func pages(in file: URL) async -> [[String]] {
        opened.add(file.path)
        return [pages[file.path] ?? []]
    }
    func stamp(of file: URL) -> String? { stamps[file.path] }
    /// Whether a file's size and bytes are known (``VaultDocumentReading/contentKey(of:)``): its
    /// page's text stands for its bytes. Off, every file is read as it comes.
    var knowsContents = false
    func size(of file: URL) -> Int? { knowsContents ? Self.bytes(pages[file.path])?.count : nil }
    func contentKey(of file: URL) async -> String? { knowsContents ? Self.contents(of: pages[file.path]) : nil }

    static func bytes(_ page: [String]?) -> Data? { page.map { Data($0.joined(separator: "\n").utf8) } }
    /// A page's key, as ``VaultFileContents/key(of:)`` gives a file's.
    static func contents(of page: [String]?) -> String? {
        bytes(page).map { VaultFileContents.key(size: $0.count, digest: SHA256.hash(data: $0)) }
    }
}

/// Read Documents and To Confirm (``VaultModel/readDocuments(with:)``).
@MainActor
@Suite struct VaultToConfirmTests {
    typealias Rig = VaultModelTests.Rig

    static let passportPage = [VaultReadingTests.nameLine, VaultReadingTests.numberLine]
    static let noticePage = ["Receipt Number WAC2412345678", "I-94 Number 123456789A1"]

    static var documents: VaultFakeDocuments {
        VaultFakeDocuments(pages: ["/docs/passport.pdf": passportPage,
                                   "/docs/notice.pdf": noticePage,
                                   "/docs/letter.pdf": ["Nothing to see here"]])
    }

    @Test func readingOffersEachNumberOnceAndSavesNothing() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = rig.model()
        await model.readDocuments(with: Self.documents)

        #expect(model.finds.map(\.value).sorted() == ["123456789A1", "L898902C3", "WAC2412345678"])
        #expect(model.lastReading == .init(documents: 3, newNumbers: 3))
        #expect(model.reading == nil)
        #expect(model.entries.isEmpty)
        #expect(try rig.store.savedOnDisk().isEmpty, "a find was written before it was confirmed")
        #expect(rig.auth.reasons.isEmpty, "reading asked for a proof")
        #expect(model.selection == model.visibleRows.first?.id)

        // A second read offers nothing new.
        await model.readDocuments(with: Self.documents)
        #expect(model.finds.count == 3)
        #expect(model.lastReading == .init(documents: 3, newNumbers: 0))
    }

    @Test func aNumberAlreadyInTheVaultIsNotOffered() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        try rig.seed([VaultEntry(title: "Receipt", value: "WAC-24-123-45678", addedAt: VaultLockTests.t0)])
        let model = rig.model()
        await model.readDocuments(with: Self.documents)
        #expect(!model.finds.contains { $0.value == "WAC2412345678" })
        #expect(model.finds.count == 2)
    }

    @Test func aFindIsHiddenUntilProvedLikeAnyNumber() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = rig.model()
        await model.readDocuments(with: Self.documents)
        let find = try #require(model.finds.first { $0.title == "Passport" })
        let row = try #require(model.rows.first { $0.id == find.id })
        #expect(!model.canShow(find))
        #expect(model.masked(row) == "•••••02C3")

        #expect(await model.show(find.id))
        #expect(rig.auth.reasons == ["show Passport"])
        #expect(model.canShow(find))
    }

    @Test func confirmingSealsItWithItsSourceAndTakesItOffTheList() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = rig.model()
        await model.readDocuments(with: Self.documents)
        let find = try #require(model.finds.first { $0.title == "Passport" })

        var draft = VaultModel.Draft(find)
        draft.title = "Anna’s passport"
        let id = try #require(model.confirm(find.id, as: draft))

        #expect(!model.finds.contains { $0.id == find.id })
        let saved = try #require(try rig.store.savedOnDisk().first)
        #expect(saved.id == id)
        #expect(saved.title == "Anna’s passport")
        #expect(saved.value == "L898902C3")
        #expect(saved.savedFrom == "/docs/passport.pdf")
        #expect(saved.category == .passport)
    }

    @Test func notThisKeepsItOutOfTheNextRead() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = rig.model()
        await model.readDocuments(with: Self.documents)
        let find = try #require(model.finds.first { $0.title == "I-94 admission number" })

        model.setAside(find.id)
        #expect(!model.finds.contains { $0.id == find.id })
        await model.readDocuments(with: Self.documents)
        #expect(!model.finds.contains { $0.value == "123456789A1" })
        #expect(try rig.store.savedOnDisk().isEmpty)
    }

    @Test func setAsideOutlivesTheAppAndIsKeptAsAKeyedFingerprint() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let first = rig.model()
        await first.readDocuments(with: Self.documents)
        let find = try #require(first.finds.first { $0.title == "Passport" })
        first.setAside(find.id)

        // A new model on the same defaults and Keychain: the next launch.
        let second = rig.model()
        await second.readDocuments(with: Self.documents)
        #expect(!second.finds.contains { $0.value == "L898902C3" })
        #expect(second.finds.count == 2)

        // What is stored is not the number, nor a plain hash anyone could recompute.
        let stored = rig.store.setAsideOnDisk(rig.defaults)
        #expect(stored.count == 1)
        let plain = SHA256.hash(data: Data("L898902C3".utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(!stored.contains(plain))
        #expect(!stored.contains { $0.contains("L898902C3") })
        #expect(try rig.store.savedOnDisk().isEmpty, "setting a number aside wrote the Vault")

        // Forget: everything is offered again.
        await second.opened()
        #expect(second.forgetSetAside())
        second.closed()
        let third = rig.model()
        await third.readDocuments(with: Self.documents)
        #expect(third.finds.contains { $0.value == "L898902C3" })
    }

    @Test func aRemovedReadNumberIsNotOfferedBack() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = rig.model()
        await model.readDocuments(with: Self.documents)
        let find = try #require(model.finds.first { $0.title == "USCIS receipt number" })
        let id = try #require(model.confirm(find.id, as: VaultModel.Draft(find)))

        #expect(await model.delete(id))
        await model.readDocuments(with: Self.documents)
        #expect(!model.finds.contains { $0.value == "WAC2412345678" })
    }

    /// VT64: what its documents said goes with a removed ID, sealed, so Refresh no longer counts or
    /// opens the document, now or after a relaunch.
    @Test func aRemovedIDTakesWhatItsDocumentsSaidWithIt() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = rig.model()
        await model.readDocuments(with: Self.documents)
        let find = try #require(model.finds.first { $0.title == "Passport" })
        let id = try #require(model.confirm(find.id, as: VaultModel.Draft(find)))
        try #require(!model.finds.contains { $0.facts.sources.contains { $0.path == "/docs/passport.pdf" } },
                     "only the passport comes from its page")
        #expect(model.refreshSources.contains("/docs/passport.pdf"))
        let key = VaultReading.normalized(find.value)
        #expect(model.sealedReading.copies[key] != nil && model.sealedReading.mentions[key] != nil,
                "confirmed, its documents are held under its number")

        #expect(await model.delete(id))
        #expect(!model.refreshSources.contains("/docs/passport.pdf"))
        #expect(model.refreshSources.contains("/docs/notice.pdf"), "the waiting IDs keep theirs")

        let reopened = rig.model()
        await reopened.opened()
        #expect(reopened.refreshSources.contains("/docs/notice.pdf"), "the reading file was opened again")
        #expect(!reopened.refreshSources.contains("/docs/passport.pdf"), "the reading file was sealed without it")
        #expect(reopened.sealedReading.copies[key] == nil && reopened.sealedReading.mentions[key] == nil,
                "nothing is kept under the removed number")
    }

    @Test func aTypedNumberRemovedIsStillOfferedWhenReadLater() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = rig.model()
        await model.opened()
        let id = try #require(model.add(VaultModel.Draft(title: "Receipt", value: "WAC2412345678")))
        #expect(await model.delete(id))
        await model.readDocuments(with: Self.documents)
        #expect(model.finds.contains { $0.value == "WAC2412345678" },
                "typing a number in is not reading it, so removing it says nothing about documents")
    }

    /// VT64: a typed number's documents are read again once it is removed, so it is offered from
    /// them though none changed. Stamped, the documents are otherwise passed over as read.
    @Test func aTypedNumberRemovedIsOfferedFromDocumentsThatDidNotChange() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        var documents = Self.documents
        documents.stamps = ["/docs/passport.pdf": "1", "/docs/notice.pdf": "1", "/docs/letter.pdf": "1"]
        let model = rig.model()
        await model.opened()
        let id = try #require(model.add(VaultModel.Draft(title: "Receipt", value: "WAC2412345678")))
        await model.readDocuments(with: documents)
        #expect(!model.finds.contains { $0.value == "WAC2412345678" }, "saved, it is not offered")

        #expect(await model.delete(id))
        await model.readDocuments(with: documents)
        #expect(model.finds.contains { $0.value == "WAC2412345678" }, "its unchanged document was read again")
    }

    /// VT110: a Vault saved by a build before VT64, which removed the passport and left what its
    /// page said. Sealed with the format tests' key, so a test can write the Vault file itself.
    @MainActor static func removedByAnOlderBuild(_ rig: Rig) async throws -> (key: String, receipt: VaultEntry) {
        rig.keychain.itemData = VaultFormatTests.key.withUnsafeBytes { Data($0) }
        let model = rig.model()
        await model.readDocuments(with: Self.documents)
        let passport = try #require(model.finds.first { $0.title == "Passport" })
        let receipt = try #require(model.finds.first { $0.title == "USCIS receipt number" })
        // Saved as printed, with dashes: what it is held by is its number normalized.
        var draft = VaultModel.Draft(receipt)
        draft.value = "WAC-24-123-45678"
        let receiptID = try #require(model.confirm(receipt.id, as: draft))
        _ = try #require(model.confirm(passport.id, as: VaultModel.Draft(passport)))
        let kept = try #require(model.entry(id: receiptID))
        model.closed()
        return (VaultReading.normalized(passport.value), kept)
    }

    @Test func documentsOfAnIDRemovedBeforeAreLetGoAsTheVaultOpens() async throws {
        let rig = try Rig(v1: true); defer { rig.cleanUp() }
        let (key, receipt) = try await Self.removedByAnOlderBuild(rig)
        try rig.store.writeSavedOnDisk([receipt])

        let opened = rig.model()
        await opened.opened()
        #expect(opened.sealedReading.copies[key] == nil)
        #expect(!opened.refreshSources.contains("/docs/passport.pdf"))
        let receiptKey = VaultReading.normalized(receipt.value), waitingKey = VaultReading.normalized("123456789A1")
        #expect(opened.finds.contains { VaultReading.normalized($0.value) == waitingKey })
        #expect(opened.sealedReading.copies[receiptKey] != nil, "the saved receipt keeps what its document said")
        #expect(opened.sealedReading.copies[waitingKey] != nil, "so does the waiting ID")
        #expect(opened.sealedReading.mentions[key] != nil, "documents naming it stay")
        opened.closed()

        let sealed = try #require(rig.store.readingOnDisk())
        #expect(sealed.copies[key] == nil, "sealed as it closed")
        #expect(sealed.copies[receiptKey] != nil && sealed.copies[waitingKey] != nil)
    }

    @Test func documentsOfRemovedIDsStayWhileTheVaultCannotSayWhatItHolds() async throws {
        // Empty: set aside as unreadable, say, with a restore to come.
        let rig = try Rig(v1: true); defer { rig.cleanUp() }
        let (key, _) = try await Self.removedByAnOlderBuild(rig)
        try VaultFormatTests.sealed([], plus: []).write(to: rig.scratch.fileURL)
        let empty = rig.model()
        await empty.opened()
        #expect(empty.sealedReading.copies[key] != nil, "an empty Vault keeps them")
        empty.closed()

        // Holding a later build's record: its number cannot be read here.
        let later = try Rig(v1: true); defer { later.cleanUp() }
        let (laterKey, receipt) = try await Self.removedByAnOlderBuild(later)
        try VaultFormatTests.sealed([receipt], plus: [["category": "bankAccount"]]).write(to: later.scratch.fileURL)
        let model = later.model()
        await model.opened()
        #expect(model.newerRecords == 1)
        #expect(model.sealedReading.copies[laterKey] != nil, "kept beside a record this build cannot read")
        model.closed()

        // A later build's field on a record this build reads: it may hold a number too.
        let field = try Rig(v1: true); defer { field.cleanUp() }
        let (fieldKey, kept) = try await Self.removedByAnOlderBuild(field)
        try VaultFormatTests.sealed([kept], plus: [], laterOnFirst: ["formerNumber": "X1234567"]).write(to: field.scratch.fileURL)
        let withField = field.model()
        await withField.opened()
        #expect(withField.newerRecords == 0 && withField.entries.count == 1)
        #expect(withField.sealedReading.copies[fieldKey] != nil, "kept beside a later build's field")
    }

    /// VT109: a typed ID's number changed. Its documents printed the old one, so they are read
    /// again and offer it in To Confirm, as for a typed ID removed (owner's call).
    @Test func aTypedNumberChangedIsOfferedFromItsDocuments() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        var documents = Self.documents
        documents.stamps = ["/docs/passport.pdf": "1", "/docs/notice.pdf": "1", "/docs/letter.pdf": "1"]
        let model = rig.model()
        await model.opened()
        let id = try #require(model.add(VaultModel.Draft(title: "Receipt", value: "WAC2412345678")))
        await model.readDocuments(with: documents)
        #expect(!model.finds.contains { $0.value == "WAC2412345678" }, "saved, it is not offered")
        #expect(model.sealedReading.copies[VaultReading.normalized("WAC2412345678")] != nil, "its document was given to it")
        let openedBefore = documents.opened.all.count

        var draft = VaultModel.Draft(try #require(model.entry(id: id)))
        draft.value = "WAC2412345679"
        #expect(await model.update(id, to: draft))
        #expect(model.sealedReading.copies[VaultReading.normalized("WAC2412345678")] == nil)
        let sealed = try #require(rig.store.readingOnDisk())
        #expect(sealed.copies[VaultReading.normalized("WAC2412345678")] == nil && sealed.read["/docs/notice.pdf"] == nil,
                "sealed: gone, and its document no longer marked read")
        await model.readDocuments(with: documents)
        #expect(model.finds.contains { $0.value == "WAC2412345678" }, "its unchanged document was read again")
        #expect(Array(documents.opened.all.dropFirst(openedBefore)) == ["/docs/notice.pdf"], "only the document that printed it")
        #expect(model.entries.map(\.value) == ["WAC2412345679"])
    }

    @Test func aKeychainThatRefusesStillSetsAsideForThisRun() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = rig.model()
        await model.readDocuments(with: Self.documents)
        let find = try #require(model.finds.first { $0.title == "Passport" })
        rig.keychain.forcedCopyStatus = errSecInteractionNotAllowed
        model.setAside(find.id)
        rig.keychain.forcedCopyStatus = nil
        // Read once the Keychain answers again: read while it refused, the document never opened,
        // and nothing could be seen in it (the final review).
        #expect(rig.store.setAsideOnDisk(rig.defaults).isEmpty)
        await model.readDocuments(with: Self.documents)
        #expect(!model.finds.contains { $0.value == "L898902C3" })
    }

    @Test func lockingLetsTheFindsGoFromMemoryAndUnlockingBringsThemBack() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = rig.model()
        await model.readDocuments(with: Self.documents)
        #expect(model.finds.count == 3)
        model.systemLocked()
        #expect(model.finds.isEmpty)

        // Sealed, not in plain sight: no number is in the file's bytes.
        let bytes = try #require(FileManager.default.contents(atPath: rig.store.readingFileOnDisk.path))
        #expect(bytes.range(of: Data("L898902C3".utf8)) == nil)
        #expect(bytes.range(of: Data("passport.pdf".utf8)) == nil)

        // The next launch: the same file and Keychain, nothing read again.
        let next = rig.model()
        await next.opened()
        #expect(next.finds.map(\.value).sorted() == ["123456789A1", "L898902C3", "WAC2412345678"])
        #expect(try rig.store.savedOnDisk().isEmpty, "To Confirm was written into the Vault's own file")
    }

    @Test func onlyNewOrChangedFilesAreReadAgain() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        var documents = Self.documents
        documents.stamps = ["/docs/passport.pdf": "1", "/docs/notice.pdf": "1", "/docs/letter.pdf": "1"]
        let model = rig.model()
        await model.readDocuments(with: documents)
        #expect(documents.opened.all.count == 3)

        // Nothing changed: nothing opened, and what waits is still there.
        let unchanged = VaultFakeDocuments(pages: documents.pages, stamps: documents.stamps)
        await model.readDocuments(with: unchanged)
        #expect(unchanged.opened.all.isEmpty)
        #expect(model.lastReading == .init(documents: 3, opened: 0, newNumbers: 0))

        // One changed, across a relaunch: only it is opened.
        var changedStamps = documents.stamps
        changedStamps["/docs/letter.pdf"] = "2"
        let changed = VaultFakeDocuments(pages: documents.pages, stamps: changedStamps)
        let next = rig.model()
        await next.readDocuments(with: changed)
        #expect(changed.opened.all == ["/docs/letter.pdf"])

        // Read Everything Again opens them all; Forget in Settings does too.
        let again = VaultFakeDocuments(pages: documents.pages, stamps: changedStamps)
        await next.readDocuments(with: again, again: true)
        #expect(again.opened.all.count == 3)
        await rig.forgetSetAside()
        let afterForget = VaultFakeDocuments(pages: documents.pages, stamps: changedStamps)
        let third = rig.model()
        await third.readDocuments(with: afterForget)
        #expect(afterForget.opened.all.count == 3)
    }

    @Test func aCaseReadTwiceKeepsWhatEitherCopySaysAboutItsValidity() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        // The receipt notice names the case; only the later approval says when it ran out.
        let documents = VaultFakeDocuments(pages: [
            "/Case/1 Receipt Notice.pdf": ["Receipt Number WAC1912345678"],
            "/Case/2 Approval Notice.pdf": ["Receipt Number WAC1912345678",
                                            "Valid from 10/01/2016 to 08/25/2019"],
        ])
        let model = rig.model()
        await model.readDocuments(with: documents)
        let find = try #require(model.finds.first)
        #expect(model.finds.count == 1)
        #expect(find.validUntil == VaultReadingTests.day(2019, 8, 25))
        #expect(find.facts.sources.count == 2, "both notices are documents of the one case")
        #expect(model.rows.first?.standing.tab == .archive, "a case that ran out in 2019 is not current")
    }

    @Test func archiveIsItsOwnTabAndKeepsWhatIsAddedFromIt() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let documents = VaultFakeDocuments(pages: [
            "/I-94/Anna/Form I-94 - Anna - Apr 2026.pdf": ["I-94 Number 123456789A1"],
            "/I-94/Anna/Archive/Form I-94 - Anna - Jul 2024.pdf": ["I-94 Number 223456789A1"],
        ])
        VaultReadFolders.add("/I-94", in: rig.defaults)
        let model = rig.model()
        await model.readDocuments(with: documents)
        #expect(model.visibleRows.map(\.value) == ["123456789A1"])
        #expect(model.count(in: .archive) == 1)
        model.tab = .archive
        #expect(model.visibleRows.map(\.value) == ["223456789A1"])
        // A search looks in every tab.
        model.tab = .current
        model.query = "I-94"
        #expect(model.visibleRows.count == 2)
        model.query = ""

        let older = try #require(model.finds.first { $0.value == "223456789A1" })
        let id = try #require(model.confirm(older.id, as: VaultModel.Draft(older)))
        let saved = try #require(try rig.store.savedOnDisk().first { $0.id == id })
        #expect(saved.category == .i94)
        #expect(saved.facts?.primary?.path == "/I-94/Anna/Archive/Form I-94 - Anna - Jul 2024.pdf")
        #expect(model.rows.first { $0.id == id }?.standing.tab == .archive, "saved, it is still the older one")
    }

    @Test func aSavedPassportAndANewerReadOneAreWeighedTogether() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let old = VaultReadingTests.zone("P", number: "A1000001", born: "740812", expires: "240825")
        let new = VaultReadingTests.zone("P", number: "A1000002", born: "740812", expires: "320516")
        let model = rig.model()
        await model.readDocuments(with: VaultFakeDocuments(pages: ["/P/Anna/2014.pdf": old]))
        let first = try #require(model.finds.first)
        let savedID = try #require(model.confirm(first.id, as: VaultModel.Draft(first)))
        #expect(model.rows.first { $0.id == savedID }?.standing.tab == .current, "alone, the expired one is current")

        await model.readDocuments(with: VaultFakeDocuments(pages: ["/P/Anna/2014.pdf": old, "/P/Anna/2022.pdf": new]))
        let rows = model.rows
        #expect(rows.first { $0.id == savedID }?.standing.tab == .archive, "the newer passport read makes the saved one older")
        #expect(rows.first { $0.value == "A1000002" }?.standing.tab == .current)
    }

    @Test func aPassportGathersTheDocumentsThatNameIt() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let passport = VaultReadingTests.zone("P", number: "L8988901", born: "740812", expires: "320516")
        let i94 = ["Most Recent I-94", "Admission I-94 Record Number: 123456789A1", "Document Number: L8988901"]
        let model = rig.model()
        await model.readDocuments(with: VaultFakeDocuments(pages: ["/a/i94.pdf": i94, "/a/passport.pdf": passport]))
        let row = try #require(model.rows.first { $0.category == .passport })
        #expect(row.documents.map(\.path) == ["/a/passport.pdf", "/a/i94.pdf"], "its own page first, then what names it")
        #expect(row.documents.first?.role == "Passport photo page")
    }

    @Test func aNumberWithNoNameReadBorrowsItFromTheSameBirthDate() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let named = VaultReadingTests.zone("P", number: "A1000002", born: "740812", expires: "320516")
        let unnamed = VaultReadingTests.zone("P", number: "A1000001", born: "740812", expires: "220516")
        let model = rig.model()
        model.people = [Person(id: "anna", displayName: "Anna")]
        // The old passport's name line was not read: only its number line is on the page.
        await model.readDocuments(with: VaultFakeDocuments(pages: ["/p/new.pdf": named, "/p/old.pdf": [unnamed[1]]]))
        let old = try #require(model.rows.first { $0.value == "A1000001" })
        #expect(old.whose == "Anna")
        #expect(old.personID == "anna")
        #expect(old.standing.tab == .archive)
    }

    @Test func aNumberCanBeGivenToSomeoneElseOrTheHouseholdAndTheChoiceStays() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        // Two passports read with Anna's birth date: the older one is really a mistagged scan.
        let new = VaultReadingTests.zone("P", number: "A1000002", born: "740812", expires: "320516")
        let old = VaultReadingTests.zone("P", number: "A1000001", born: "740812", expires: "240516")
        let documents = VaultFakeDocuments(pages: ["/p/new.pdf": new, "/p/old.pdf": old])
        let model = rig.model()
        model.people = [Person(id: "anna", displayName: "Anna"), Person(id: "erik", displayName: "Erik")]
        await model.readDocuments(with: documents)
        let oldRow = try #require(model.rows.first { $0.value == "A1000001" })
        #expect(oldRow.standing.tab == .archive)
        #expect(oldRow.whose == "Anna")

        // Moved to the household: no longer weighed against Anna's, so it is current there.
        model.assign(oldRow.id, to: .household)
        var moved = try #require(model.rows.first { $0.value == "A1000001" })
        #expect(moved.whose == "Household")
        #expect(moved.isHousehold)
        #expect(moved.standing.tab == .current)
        model.personFilter = .household
        #expect(model.visibleRows.map(\.value) == ["A1000001"])
        model.personFilter = .everyone

        // Kept across a read of everything, and onto the saved entry.
        await model.readDocuments(with: documents, again: true)
        moved = try #require(model.rows.first { $0.value == "A1000001" })
        #expect(moved.assignment == .household)
        let find = try #require(model.finds.first { $0.value == "A1000001" })
        let id = try #require(model.confirm(find.id, as: VaultModel.Draft(find, people: model.people)))
        #expect(model.rows.first { $0.id == id }?.isHousehold == true)

        // Given to Erik instead.
        model.assign(id, to: .person("erik"))
        #expect(model.rows.first { $0.id == id }?.whose == "Erik")
        // And back to whoever the document names.
        model.assign(id, to: nil)
        #expect(model.rows.first { $0.id == id }?.whose == "Anna")
    }

    @Test func aFoldedCardIsPassedOverByTheArrowsAndRemembered() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = rig.model()
        await model.readDocuments(with: Self.documents)
        // A passport and an I-94 are current; the sample receipt, with no validity, is in Archive.
        #expect(model.cards.map(\.card) == [.builtIn(.passport), .builtIn(.i94)])
        model.selection = model.cards[0].rows[0].id
        // Folding the card the chosen row is in moves the choice to a row on screen.
        model.toggleFold(.builtIn(.passport))
        #expect(model.selectedRow?.category == .i94)
        model.moveSelection(by: -1)
        #expect(model.selectedRow?.category == .i94, "the folded passport card's row is skipped")

        // ⌥-click on an open card folds every card; Collapse All then reads Expand All.
        model.toggleFold(.builtIn(.i94), all: true)
        #expect(model.allFolded)
        model.toggleFoldAll()
        #expect(model.folded.isEmpty)

        // Kept for the next open.
        model.toggleFold(.builtIn(.uscisCase))
        #expect(rig.model().folded == ["uscisCase"], "stored by the kind's own name, as before custom kinds")
    }

    @Test func aChoiceToMarkOlderOutlivesTheNextRead() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = rig.model()
        await model.readDocuments(with: Self.documents)
        let find = try #require(model.finds.first { $0.category == .i94 })
        model.pin(find.id, .older)
        await model.readDocuments(with: Self.documents, again: true)
        #expect(model.rows.first { $0.value == find.value }?.standing.tab == .archive)
    }

    @Test func theHolderSuggestsWhoseItIsOnlyWhenOnePersonAnswers() {
        let find = VaultFind(title: "Passport", value: "L898902C3",
                             facts: VaultReadFacts(category: .passport, holder: "Anna Maria Eriksson",
                                                   sources: [VaultSource(path: "/a", role: "Document", rank: 1)]))
        let anna = Person(id: "anna", displayName: "Anna")
        let erik = Person(id: "erik", displayName: "Erik")
        #expect(VaultModel.Draft(find, people: [anna, erik]).personID == "anna")
        #expect(VaultModel.Draft(find, people: [erik]).personID == nil)
        #expect(VaultModel.Draft(find).personID == nil)
    }

    @Test func searchFindsAFindByNameButNeverByNumber() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = rig.model()
        await model.readDocuments(with: Self.documents)
        model.query = "passport"
        #expect(model.visibleRows.map(\.title) == ["Passport"])
        model.query = "02C3"
        #expect(model.visibleRows.isEmpty)
    }
}

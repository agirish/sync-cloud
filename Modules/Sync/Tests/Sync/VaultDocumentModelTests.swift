import Foundation
import Testing
@testable import Sync

/// The panel's model on the v7.2 document (VT6): what it loads, what one action writes, the
/// read-only cases, two copies of the app, and that with the migration off nothing changes for a
/// v1 Vault. Scratch folders, the fake Keychain and scratch defaults only; every number is made up.
@MainActor
@Suite struct VaultDocumentModelTests {
    typealias Rig = VaultModelTests.Rig
    static let key = VaultFormatTests.key

    /// A model whose store migrates, as the app's will once the gate opens.
    static func model(_ rig: Rig, otherCopy: Bool = false, migrating: Bool = true) -> VaultModel {
        let clock = rig.clock, box = rig.box
        let store = VaultStore(fileURL: rig.scratch.fileURL, keychain: rig.keychain, clock: { clock.now }, migrating: migrating,
                               anotherCopyRunning: { otherCopy })
        return VaultModel(store: store, authenticator: rig.auth, defaults: rig.defaults, clock: { clock.now },
                          copyToPasteboard: { box.copied.append($0) })
    }

    static func documentStore(_ rig: Rig) -> VaultStore {
        VaultStore(fileURL: rig.scratch.fileURL, keychain: rig.keychain, migrating: true, anotherCopyRunning: { false })
    }

    static func names(_ rig: Rig) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: rig.scratch.fileURL.deletingLastPathComponent().path)) ?? []).sorted()
    }

    /// The committed v1 files, the fixture key, and made-up moved keys.
    static func v1(_ rig: Rig) throws {
        let folder = rig.scratch.fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try VaultFormatTests.fixture("vault-format-6").write(to: rig.scratch.fileURL)
        try VaultFormatTests.fixture("vault-reading-format-2").write(to: folder.appendingPathComponent("vault-reading.sealed"))
        rig.keychain.itemData = key.withUnsafeBytes { Data($0) }
        rig.defaults.set(["ff00", "aa11"], forKey: VaultSetAside.key)
        rig.defaults.set(2, forKey: VaultSetAside.generationKey)
        rig.defaults.set(try JSONEncoder().encode([VaultCustomKind(id: "kind-1", name: "Memberships", group: "home")]),
                         forKey: VaultKinds.key)
    }

    static func document(_ rig: Rig) throws -> VaultDocument { try #require(try documentStore(rig).loadDocument()).document }

    // MARK: With the migration off

    @Test func withTheMigrationOffAV1VaultOpensAndSavesAsBefore() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        try Self.v1(rig)
        let model = Self.model(rig, migrating: false)
        await model.opened()
        #expect(model.contents == .loaded && !model.keepsDocument && model.readOnly == nil)
        // The committed reading file was sealed under older rules: what it read is let go at load.
        #expect(model.entries.count == 4 && model.finds.isEmpty && model.needsReadAgain)
        #expect(model.kinds.custom.map(\.id) == ["kind-1"])
        #expect(model.add(VaultModel.Draft(title: "Library card", value: "LIB0000001")) != nil)
        await model.readDocuments(with: VaultFakeDocuments(pages: ["/docs/notice.pdf": VaultToConfirmTests.noticePage]))
        let find = try #require(model.finds.first)
        #expect(model.confirm(find.id, as: model.confirmationDraft(find)) != nil)
        #expect(rig.store.fileFormat == .v1)
        #expect(try rig.store.savedOnDisk().count == 6)
        #expect(rig.store.readingOnDisk()?.finds.count == model.finds.count)
        #expect(rig.defaults.stringArray(forKey: VaultSetAside.key) == ["ff00", "aa11"])
        #expect(!Self.names(rig).contains { $0.contains("cache") || $0.contains("lock") || $0.contains("premigration") || $0.contains("migrated") })
        #expect(model.documentWrites == 0)
    }

    // MARK: Migrating and loading

    @Test func aMigratedVaultDrawsTheVeryRowsTheV1VaultDid() async throws {
        let legacyRig = try Rig(); defer { legacyRig.cleanUp() }
        try Self.v1(legacyRig)
        let legacy = Self.model(legacyRig, migrating: false)
        await legacy.opened()

        let rig = try Rig(); defer { rig.cleanUp() }
        try Self.v1(rig)
        let model = Self.model(rig)
        await model.opened()
        #expect(model.contents == .loaded && model.keepsDocument && model.readOnly == nil)
        #expect(model.rows == legacy.rows)
        #expect(model.entries == legacy.entries)
        #expect(model.finds == legacy.finds)
        #expect(model.kinds == legacy.kinds)
        #expect(Self.documentStore(rig).fileFormat == .document)
        #expect(!Self.documentStore(rig).hasReadingFile)
        for key in VaultMigration.movedKeys { #expect(rig.defaults.object(forKey: key) == nil) }
        #expect(model.setAsideCount == 2)

        // Opened again, it is the same Vault.
        let again = Self.model(rig)
        await again.opened()
        #expect(again.rows == legacy.rows)
    }

    @Test func aWaitingRecordWhoseNumberIsSavedLeavesToConfirmAsItLoads() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        rig.keychain.itemData = Self.key.withUnsafeBytes { Data($0) }
        let saved = VaultEntry(title: "Health plan member ID", value: "XX000000001", addedAt: VaultRig.t0, category: .health,
                               facts: VaultReadFacts(category: .health, sources: [VaultSource(path: "Health/Plan/Old card.pdf",
                                                                                               role: "Member card", rank: 30)]))
        let find = VaultRecordTests.fullFind()
        let document = VaultDocument(entries: [saved], state: VaultReadingState(finds: [find]), setAside: .init(), kinds: [],
                                     savedAt: VaultRig.t0)
        try Self.documentStore(rig).saveDocument(document, expecting: .absent)
        let model = Self.model(rig)
        await model.opened()
        #expect(model.finds.isEmpty)
        #expect(model.entries.map(\.id) == [saved.id])
        #expect(try Self.document(rig).records.map(\.state) == [.saved], "and the document no longer holds it")
        #expect(model.rows.first?.documents.map(\.path).contains("Health/Plan/Card.pdf") == true,
                "its documents are the saved one's")
    }

    @Test func aVaultBegunWithTheMigrationOnIsADocumentThatTakesTheMovedKeys() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        rig.defaults.set(try JSONEncoder().encode([VaultCustomKind(id: "kind-1", name: "Memberships", group: "home")]),
                         forKey: VaultKinds.key)
        let model = Self.model(rig)
        await model.opened()
        #expect(model.keepsDocument && model.kinds.custom.map(\.id) == ["kind-1"])
        #expect(model.add(VaultModel.Draft(title: "Library card", value: "LIB0000001")) != nil)
        #expect(Self.documentStore(rig).fileFormat == .document)
        #expect(try Self.document(rig).kinds.map(\.id) == ["kind-1"])
        #expect(rig.defaults.object(forKey: VaultKinds.key) == nil)
    }

    // MARK: Writing

    @Test func aConfirmIsOneWriteOfTheDocument() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = Self.model(rig)
        await model.opened()
        _ = model.add(VaultModel.Draft(title: "Library card", value: "LIB0000001"))
        await model.readDocuments(with: VaultFakeDocuments(pages: ["/docs/notice.pdf": VaultToConfirmTests.noticePage]))
        let find = try #require(model.finds.first { $0.title == "USCIS receipt number" })
        let before = model.documentWrites
        let id = try #require(model.confirm(find.id, as: model.confirmationDraft(find)))
        #expect(model.documentWrites == before + 1, "saved and out of To Confirm in one write")
        let document = try Self.document(rig)
        #expect(document.records.contains { $0.id == id && $0.state == .saved })
        #expect(!document.records.contains { $0.id == find.id })
        let again = Self.model(rig)
        await again.opened()
        #expect(again.entries.contains { $0.id == id } && !again.finds.contains { $0.value == find.value })

        // An add, an edit and a removal are one write each too.
        var writes = again.documentWrites
        let library = try #require(again.add(VaultModel.Draft(title: "Gym card", value: "GYM0000002")))
        #expect(again.documentWrites == writes + 1)
        writes = again.documentWrites
        var draft = VaultModel.Draft(try #require(again.entry(id: library)))
        draft.title = "Gym membership"
        #expect(await again.update(library, to: draft))
        #expect(again.documentWrites == writes + 1)
        writes = again.documentWrites
        #expect(await again.delete(library))
        #expect(again.documentWrites == writes + 1)
    }

    /// Corrected as it is confirmed: the misread number still leaves To Confirm in the very write
    /// that saves the right one.
    @Test func aConfirmCorrectedIsOneWriteToo() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = Self.model(rig)
        await model.opened()
        _ = model.add(VaultModel.Draft(title: "Library card", value: "LIB0000001"))
        await model.readDocuments(with: VaultFakeDocuments(pages: ["/docs/notice.pdf": VaultToConfirmTests.noticePage]))
        let find = try #require(model.finds.first { $0.title == "USCIS receipt number" })
        var draft = model.confirmationDraft(find)
        draft.value = "WAC2412345679"
        let before = model.documentWrites
        let id = try #require(model.confirm(find.id, as: draft))
        #expect(model.documentWrites == before + 1)
        let document = try Self.document(rig)
        #expect(document.records.contains { $0.id == id && $0.value == "WAC2412345679" })
        #expect(!document.records.contains { $0.id == find.id })
        await model.notesWritten()
    }

    @Test func readingProgressWritesTheCacheAndNotTheDocument() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = Self.model(rig)
        await model.opened()
        _ = model.add(VaultModel.Draft(title: "Library card", value: "LIB0000001"))
        let (documents, caches) = (model.documentWrites, model.cacheWrites)
        let before = try Data(contentsOf: rig.scratch.fileURL)
        await model.readDocuments(with: VaultFakeDocuments(pages: ["/docs/letter.pdf": ["Dear Pat", "Nothing to see here"]],
                                                           stamps: ["/docs/letter.pdf": "100 1"]))
        #expect(model.documentWrites == documents)
        #expect(model.cacheWrites > caches)
        #expect(try Data(contentsOf: rig.scratch.fileURL) == before)
        let cache = try #require(try Self.documentStore(rig).loadDocument()?.cache)
        #expect(cache.read.keys.contains("/docs/letter.pdf"))
    }

    @Test func setAsideNumbersAndKindsAreKeptInTheDocumentNotInUserDefaults() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = Self.model(rig)
        await model.opened()
        let pages = VaultFakeDocuments(pages: ["/docs/notice.pdf": VaultToConfirmTests.noticePage])
        await model.readDocuments(with: pages)
        let find = try #require(model.finds.first { $0.title == "USCIS receipt number" })
        model.setAside(find.id)
        #expect(rig.defaults.object(forKey: VaultSetAside.key) == nil)
        #expect(try Self.document(rig).setAside.fingerprints.count == 1)
        #expect(model.addKind(named: "Memberships") != nil)
        #expect(rig.defaults.object(forKey: VaultKinds.key) == nil)
        #expect(try Self.document(rig).kinds.map(\.name) == ["Memberships"])

        // Read again from the start in another copy: what was set aside is not offered.
        let again = Self.model(rig)
        await again.opened()
        await again.readDocuments(with: pages, again: true)
        #expect(!again.finds.contains { $0.value == find.value })
        #expect(again.kinds.custom.map(\.name) == ["Memberships"])
        #expect(again.setAsideCount == 1)

        // Removing a read ID sets its number aside in the same write.
        let other = try #require(again.finds.first)
        let saved = try #require(again.confirm(other.id, as: again.confirmationDraft(other)))
        let writes = again.documentWrites
        #expect(await again.delete(saved))
        #expect(again.documentWrites == writes + 1)
        #expect(try Self.document(rig).setAside.fingerprints.count == 2)

        // Forget lets them all go, in the document.
        #expect(again.forgetSetAside())
        #expect(try Self.document(rig).setAside.fingerprints.isEmpty)
        #expect(try Self.document(rig).setAside.generation == 1)
    }

    // MARK: Read-only

    @Test func aDocumentFromANewerSyncCloudOpensReadOnlyAndNothingIsWritten() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        rig.keychain.itemData = Self.key.withUnsafeBytes { Data($0) }
        let document = VaultDocument(entries: [VaultModelTests.passport], state: VaultReadingState(finds: [VaultRecordTests.fullFind()]),
                                     setAside: .init(), kinds: [], savedAt: VaultRig.t0)
        var object = try #require(JSONSerialization.jsonObject(with: VaultFile.jsonEncoder().encode(document)) as? [String: Any])
        object["format"] = VaultDocument.format + 1
        object["laterField"] = ["x": 1]
        try FileManager.default.createDirectory(at: rig.scratch.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sealed = try VaultFile.sealPlain(JSONSerialization.data(withJSONObject: object), marker: VaultDocument.marker, with: Self.key)
        try sealed.write(to: rig.scratch.fileURL)
        let names = Self.names(rig)
        // A color of a kind this build cannot see: the newer build's, kept in the shared defaults.
        var shared = VaultColors()
        shared.cards[VaultCardID.custom("later").key] = .tint(.clay)
        shared.save(to: rig.defaults)

        for model in [Self.model(rig), Self.model(rig, migrating: false)] {
            await model.opened()
            #expect(model.contents == .loaded && model.readOnly == .newerFormat && model.isReadOnly)
            #expect(model.notice == VaultModel.message(for: .newerFormat), "the panel says why")
            #expect(model.entries.map(\.id) == [VaultModelTests.passport.id] && model.finds.count == 1)
            model.notice = nil
            #expect(model.notice == VaultModel.message(for: .newerFormat), "cleared, it comes back while read-only")
            #expect(model.add(VaultModel.Draft(title: "Library card", value: "LIB0000001")) == nil)
            #expect(model.notice == VaultModel.message(for: .newerFormat), "a refused save says why")
            model.setAside(try #require(model.finds.first).id)
            #expect(model.finds.count == 1, "Not an ID is refused, not held until the next open")
            model.setColors(model.colors)
            #expect(VaultColors.load(from: rig.defaults).own(.custom("later")) == .tint(.clay), "nothing pruned")
            _ = model.addKind(named: "Memberships")
            #expect(model.kinds.custom.isEmpty, "a kind is kept in the document, which is not written")
            model.closed()
        }
        #expect(try Data(contentsOf: rig.scratch.fileURL) == sealed)
        #expect(Self.names(rig).filter { $0 != "vault.lock" } == names, "no cache, no set-aside file, no backup")
        #expect(rig.defaults.object(forKey: VaultSetAside.key) == nil)
    }

    @Test func aMigrationWhileAnotherCopyRunsOpensTheV1VaultReadOnly() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        try Self.v1(rig)
        let before = try Data(contentsOf: rig.scratch.fileURL)
        let model = Self.model(rig, otherCopy: true)
        await model.opened()
        #expect(model.contents == .loaded && model.readOnly == .anotherCopyRunning && !model.keepsDocument)
        #expect(model.entries.count == 4)
        #expect(model.add(VaultModel.Draft(title: "Library card", value: "LIB0000001")) == nil)
        #expect(model.notice == VaultModel.message(for: .anotherCopyRunning), "the panel says why")
        _ = model.addKind(named: "School")
        await model.readDocuments(with: VaultFakeDocuments(pages: ["/docs/notice.pdf": VaultToConfirmTests.noticePage]))
        let waiting = model.finds.count
        model.setAside(try #require(model.finds.first).id)
        #expect(model.finds.count == waiting, "Not an ID is refused, not held until the next open")
        #expect(!model.forgetSetAside(), "Settings' Forget writes nothing either")
        // People's typing and name roles too, which would show and be lost (the second review).
        #expect(!model.setEmail("anna@example.com", label: nil, for: "anna"))
        #expect(model.contacts.isEmpty)
        let roles = model.nameRoles
        model.setRole(.goesBy, of: "Anna E", for: "anna")
        #expect(model.nameRoles == roles, "a role held that is never saved")
        model.closed()
        await model.opened()
        #expect(model.notice == VaultModel.message(for: .anotherCopyRunning), "still says why after a close")
        model.closed()
        #expect(try Data(contentsOf: rig.scratch.fileURL) == before)
        #expect(rig.store.readingOnDisk()?.version == 17, "the reading file as it was, under its older rules")
        #expect(VaultKinds.load(from: rig.defaults).custom.map(\.name) == ["Memberships"], "no kind added")
        #expect(rig.defaults.stringArray(forKey: VaultSetAside.key) == ["ff00", "aa11"])
    }

    // MARK: Two copies

    @Test func aSavedRecordEditOverAnotherCopysIsRefusedAndTheRestIsMerged() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let first = Self.model(rig), second = Self.model(rig)
        await first.opened()
        _ = first.add(VaultModel.Draft(title: "Passport", value: "A1000001"))
        await second.opened()

        let library = try #require(first.add(VaultModel.Draft(title: "Library card", value: "LIB0000001")))
        #expect(second.add(VaultModel.Draft(title: "Gym card", value: "GYM0000002")) == nil)
        #expect(second.notice == VaultModel.message(for: .changedElsewhere))
        #expect(second.entries.contains { $0.id == library }, "it reads the other copy's saved IDs")
        #expect(second.add(VaultModel.Draft(title: "Gym card", value: "GYM0000002")) != nil)
        #expect(try Self.document(rig).savedIDs.count == 3)

        // The user's own data, changed in both: both kept.
        _ = first.addKind(named: "Memberships")
        _ = second.addKind(named: "School")
        #expect(first.readingMerges == 1 && second.readingMerges == 2, "each merged with the other's document")
        #expect(Set(try Self.document(rig).kinds.map(\.name)) == ["Memberships", "School"])
        #expect(Set(second.kinds.custom.map(\.name)) == ["Memberships", "School"])
    }

    @Test func anEditorOpenOnAnIDAnotherCopyChangedIsToldOnce() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let first = Self.model(rig), second = Self.model(rig)
        await first.opened()
        let id = try #require(first.add(VaultModel.Draft(title: "Passport", value: "A1000001")))
        await second.opened()
        let opened = try #require(second.entry(id: id))

        var draft = VaultModel.Draft(try #require(first.entry(id: id)))
        draft.title = "Passport (renewed)"
        #expect(await first.update(id, to: draft))
        var mine = VaultModel.Draft(opened)
        mine.note = "Kept in the safe"
        #expect(await second.update(id, to: mine, editedFrom: opened) == false)
        #expect(second.notice == VaultModel.editedElsewhere)
        #expect(await second.update(id, to: mine, editedFrom: opened), "saving again replaces it")
        #expect(try Self.document(rig).records.first { $0.id == id }?.note == "Kept in the safe")
    }

    /// The other copy only read documents: no saved ID moved, so a save here is written over the
    /// merge, not refused.
    @Test func aSaveAfterAnotherCopyOnlyReadIsWrittenOverTheMerge() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        try rig.seed([VaultModelTests.passport])
        let first = Self.model(rig), second = Self.model(rig)
        await first.opened()
        await second.opened()
        await second.readDocuments(with: VaultFakeDocuments(pages: ["/docs/notice.pdf": VaultToConfirmTests.noticePage]))
        let pages = VaultFakeDocuments(pages: ["/docs/notice.pdf": VaultToConfirmTests.noticePage])
        let found = second.finds.count
        #expect(found > 0)
        #expect(first.add(VaultModel.Draft(title: "Library card", value: "LIB0000001")) != nil,
                "refused, though the other copy changed no saved ID")
        #expect(first.notice == nil)
        #expect(try rig.store.savedOnDisk().map(\.value).sorted() == ["LIB0000001", VaultModelTests.passport.value].sorted())
        // As for a v1 Vault (VT111), the other's new waiting IDs are not merged in, but nothing
        // marks their document read without them: the next read finds them again.
        first.closed()
        second.closed()
        let third = Self.model(rig)
        await third.opened()
        await third.readDocuments(with: pages)
        #expect(third.finds.count == found, "the other copy's waiting IDs are lost behind a read mark")
    }


    /// A reading file alone that the migration refuses (a later build's field in it) opens as the
    /// v1 Vault it is: what it holds is shown, and no empty document is begun beside it.
    @Test func aReadingFileAloneThatIsNotMigratedOpensAsTheV1VaultItIs() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        var state = VaultReadingState(names: ["AB": "A B"])
        state.laterFields = Data(#"{"aLaterBuildsField":1}"#.utf8)
        try rig.store.saveReading(state)
        let model = Self.model(rig)
        await model.opened()
        #expect(model.contents == .loaded && !model.keepsDocument)
        #expect(model.sealedReading.names["AB"] == "A B", "what the reading file holds was not shown")
        #expect(model.add(VaultModel.Draft(title: "Library card", value: "LIB0000001")) != nil)
        #expect(rig.store.fileFormat == .v1, "an empty document was begun beside the reading file")
        #expect(rig.store.loadReading()?.names["AB"] == "A B")
    }


    /// Two copies with a cache on disk: what one read and the other never saw is taken in by the
    /// other's merge, never left behind a read mark its next seal keeps.
    @Test func aWaitingIDTheOtherCopyReadSurvivesThisCopysSeal() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        try rig.seed([VaultModelTests.passport])
        let warm = Self.model(rig)
        await warm.opened()
        await warm.readDocuments(with: VaultFakeDocuments(pages: ["/docs/letter.pdf": ["Nothing to see here"]]))
        warm.closed()
        let first = Self.model(rig), second = Self.model(rig)
        await first.opened()
        await second.opened()
        let notice = ["/docs/notice.pdf": VaultToConfirmTests.noticePage], stamps = ["/docs/notice.pdf": "1"]
        await first.readDocuments(with: VaultFakeDocuments(pages: notice, stamps: stamps))
        let found = Set(first.finds.map(\.value))
        #expect(!found.isEmpty)
        #expect(second.setEmail("anna@example.com", label: nil, for: "anna"))
        #expect(Set(second.finds.map(\.value)) == found, "the other copy's waiting IDs were not taken in")
        let third = Self.model(rig)
        await third.opened()
        #expect(Set(third.finds.map(\.value)) == found, "lost behind the other copy's read mark")
        let again = VaultFakeDocuments(pages: notice, stamps: stamps)
        await third.readDocuments(with: again)
        #expect(again.opened.all.isEmpty, "what the other copy read was read again: its read marks were not taken in")
    }

    /// A seal that changes only the cache, after another copy saved: the other's read marks and
    /// waiting IDs are merged in, not written over by this copy's cache (the final review).
    @Test func aCacheOnlySealAfterAnotherCopysSaveKeepsItsReadMarks() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        try rig.seed([VaultModelTests.passport])
        let warm = Self.model(rig)
        await warm.opened()
        await warm.readDocuments(with: VaultFakeDocuments(pages: ["/docs/letter.pdf": ["Nothing to see here"]]))
        warm.closed()
        let first = Self.model(rig), second = Self.model(rig)
        await first.opened()
        await second.opened()
        let notice = ["/docs/notice.pdf": VaultToConfirmTests.noticePage]
        let blank = ["/docs/blank.pdf": ["Nothing here either"]]
        await first.readDocuments(with: VaultFakeDocuments(pages: notice, stamps: ["/docs/notice.pdf": "1"]))
        let found = Set(first.finds.map(\.value))
        #expect(!found.isEmpty)
        await second.readDocuments(with: VaultFakeDocuments(pages: blank, stamps: ["/docs/blank.pdf": "1"]))
        #expect(Set(second.finds.map(\.value)) == found, "the other copy's waiting IDs were not taken in")
        first.closed()
        second.closed()
        let third = Self.model(rig)
        await third.opened()
        let again = VaultFakeDocuments(pages: notice.merging(blank) { a, _ in a },
                                       stamps: ["/docs/notice.pdf": "1", "/docs/blank.pdf": "1"])
        await third.readDocuments(with: again)
        #expect(again.opened.all.isEmpty, "a copy's read marks were written over by the other's cache")
        #expect(Set(third.finds.map(\.value)) == found)
    }

    /// Two copies whose seals each change only the cache: the second's merges the first's read
    /// marks rather than writing over them (the second review).
    @Test func aCacheOnlySealAfterAnotherCopysCacheOnlySealKeepsItsReadMarks() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        try rig.seed([VaultModelTests.passport])
        let warm = Self.model(rig)
        await warm.opened()
        await warm.readDocuments(with: VaultFakeDocuments(pages: ["/docs/letter.pdf": ["Nothing to see here"]]))
        warm.closed()
        let first = Self.model(rig), second = Self.model(rig)
        await first.opened()
        await second.opened()
        let one = ["/docs/one.pdf": ["Nothing on this one"]], two = ["/docs/two.pdf": ["Nor on this one"]]
        await first.readDocuments(with: VaultFakeDocuments(pages: one, stamps: ["/docs/one.pdf": "1"]))
        await second.readDocuments(with: VaultFakeDocuments(pages: two, stamps: ["/docs/two.pdf": "1"]))
        first.closed()
        second.closed()
        let third = Self.model(rig)
        await third.opened()
        let again = VaultFakeDocuments(pages: one.merging(two) { a, _ in a }, stamps: ["/docs/one.pdf": "1", "/docs/two.pdf": "1"])
        await third.readDocuments(with: again)
        #expect(again.opened.all.isEmpty, "a copy's read marks were written over by the other's cache")
    }

    /// A Forget made in one copy stands when the other, still holding what it read before, seals.
    @Test func aForgetInTheOtherCopyIsNotUndoneByThisCopysSeal() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        try rig.seed([VaultModelTests.mortgage])
        var pages = VaultToConfirmTests.documents
        pages.stamps = ["/docs/passport.pdf": "1", "/docs/notice.pdf": "1", "/docs/letter.pdf": "1"]
        let first = Self.model(rig)
        await first.opened()
        await first.readDocuments(with: pages)
        let passport = try #require(first.finds.first { $0.title == "Passport" })
        first.setAside(passport.id)
        let second = Self.model(rig)
        await second.opened()
        #expect(first.forgetSetAside())
        #expect(second.setEmail("anna@example.com", label: nil, for: "anna"))
        first.closed()
        second.closed()
        let third = Self.model(rig)
        await third.opened()
        await third.readDocuments(with: VaultFakeDocuments(pages: pages.pages, stamps: pages.stamps))
        #expect(third.finds.contains { $0.value == passport.value }, "the Forget was undone by the other copy's seal")
    }

    /// A Vault begun here with moved keys this build cannot read: they stay where they are.
    @Test func movedKeysThatDoNotReadAreKeptByAVaultBegunHere() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        rig.defaults.set("not a list of kinds", forKey: VaultKinds.key)
        let model = Self.model(rig)
        await model.opened()
        #expect(model.contents == .loaded && model.keepsDocument)
        #expect(model.add(VaultModel.Draft(title: "Library card", value: "LIB0000001")) != nil)
        #expect(rig.store.fileFormat == .document)
        #expect(rig.defaults.object(forKey: VaultKinds.key) as? String == "not a list of kinds", "a key not taken in was removed")
    }

    /// Kinds both copies changed merge kind by kind: never two with one id.
    @Test func kindsMergeByID() {
        let a = VaultCustomKind(id: "k1", name: "School", group: "home")
        var ours = a; ours.name = "Kids’ School"
        var theirs = a; theirs.group = "money"
        let gone = VaultCustomKind(id: "k2", name: "Gym", group: "home")
        let added = VaultCustomKind(id: "k3", name: "Clubs", group: "home")
        let merged = VaultModel.mergedKinds([a, gone], [ours, gone, added], [theirs])
        #expect(merged.map(\.id) == ["k1", "k3"])
        #expect(merged.first?.name == "Kids’ School")
        // Removed by one and renamed by the other, it goes, whichever copy merges (the final review).
        var renamed = gone; renamed.name = "Fitness"
        #expect(VaultModel.mergedKinds([a, gone], [a, renamed], [a]).map(\.id) == ["k1"])
        #expect(VaultModel.mergedKinds([a, gone], [a], [a, renamed]).map(\.id) == ["k1"])
    }

}

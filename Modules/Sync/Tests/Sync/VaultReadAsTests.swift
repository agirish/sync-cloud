import Foundation
import Testing
@testable import Sync

/// A read ID corrected by hand keeps a note of what its document reads for it (``VaultReadAs``),
/// known by the document's bytes, in place of setting the misreading aside everywhere.
/// Every number is made up.
@MainActor
@Suite struct VaultReadAsTests {
    typealias Rig = VaultModelTests.Rig

    static let card = "/Documents/Identity/License/Anna/License.pdf"
    static let filed = "/Documents/Identity/License/Anna/2030/License.pdf"
    static let relative = "/Documents/Identity/License/Shweta/License.pdf"
    static let shwetaPage = ["California USA DRIVER LICENSE", "DL D1234567", "EXP 01/02/2031", "LN DANI", "FN SHWETA"]

    static func documents(_ pages: [String: [String]]) -> VaultFakeDocuments {
        var documents = VaultFakeDocuments(pages: pages)
        documents.knowsContents = true
        return documents
    }

    /// Anna's license read as D1234567 and added as D1234568, its note written.
    static func corrected(_ rig: Rig) async throws -> (model: VaultModel, id: UUID) {
        let model = rig.model()
        let documents = Self.documents([card: VaultFixtures.licensePage])
        model.fileContents = { await Self.documents([card: VaultFixtures.licensePage]).contentKey(of: $0) }
        await model.readDocuments(with: documents)
        let find = try #require(model.finds.first)
        var draft = VaultModel.Draft(find)
        draft.value = "D1234568"
        let id = try #require(model.confirm(find.id, as: draft))
        await model.notesWritten()
        return (model, id)
    }

    @Test func addingACorrectedIDNotesWhatItsCardReadsAndSetsNothingAside() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let (model, id) = try await Self.corrected(rig)
        let entry = try #require(model.entries.first { $0.id == id })
        #expect(entry.readAs == [VaultReadAs(contents: try #require(VaultFakeDocuments.contents(of: VaultFixtures.licensePage)),
                                             reads: "D1234567")])
        #expect(model.readings(of: id) == ["D1234567"])
        #expect(VaultSetAside.fingerprints(in: rig.defaults).isEmpty, "the misreading was set aside everywhere")
        // The card's own readings went with the ID: it still lists the card it came from.
        #expect(model.rows.first { $0.id == id }?.documents.map(\.path) == [Self.card])
        // Sealed with the ID: the next launch has it.
        let next = rig.model()
        await next.opened()
        #expect(next.readings(of: id) == ["D1234567"])
    }

    @Test func theNoteFollowsTheCardWhenItIsFiledElsewhere() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let (model, id) = try await Self.corrected(rig)
        // SyncCloud files the card into a year folder: the same bytes at another path.
        await model.readDocuments(with: Self.documents([Self.filed: VaultFixtures.licensePage]))
        #expect(model.finds.isEmpty, "the misreading came back To Confirm from the moved card")
        #expect(model.rows.first { $0.id == id }?.documents.map(\.path).contains(Self.filed) == true)
    }

    @Test func aRelativesCardPrintingTheMisreadingIsStillOffered() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let (model, _) = try await Self.corrected(rig)
        // Another card, other bytes, that really does print D1234567: it is someone's ID.
        await model.readDocuments(with: Self.documents([Self.card: VaultFixtures.licensePage,
                                                        Self.relative: Self.shwetaPage]))
        #expect(model.finds.map(\.value) == ["D1234567"])
        #expect(model.finds.first?.facts.sources.map(\.path) == [Self.relative])
    }

    @Test func aChangedCardIsNoLongerTheCardTheNoteKnows() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let (model, _) = try await Self.corrected(rig)
        // A new scan saved over it: other bytes, so its reading is offered once more.
        let rescanned = VaultFixtures.front(expiring: "05/16/2030")
        await model.readDocuments(with: Self.documents([Self.card: rescanned]), again: true)
        #expect(model.finds.map(\.value) == ["D1234567"])
    }

    @Test func forgetDropsTheNoteAndTheNextReadOffersTheReadingAgain() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let (model, id) = try await Self.corrected(rig)
        #expect(await model.forgetReadings(of: id))
        #expect(model.readings(of: id).isEmpty)
        #expect(model.entries.first { $0.id == id }?.readAs == nil)
        await model.readDocuments(with: Self.documents([Self.card: VaultFixtures.licensePage]), again: true)
        #expect(model.finds.map(\.value) == ["D1234567"])
    }

    @Test func correctingTheIDAgainKeepsTheOneNoteOfWhatTheCardReads() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let (model, id) = try await Self.corrected(rig)
        var draft = VaultModel.Draft(try #require(model.entries.first { $0.id == id }))
        draft.value = "D1234569"
        #expect(await model.update(id, to: draft))
        await model.notesWritten()
        // The card reads D1234567, not D1234568: the note it has stands, now for D1234569.
        #expect(model.entries.first { $0.id == id }?.readAs?.map(\.reads) == ["D1234567"])
        await model.readDocuments(with: Self.documents([Self.filed: VaultFixtures.licensePage]))
        #expect(model.finds.isEmpty)
        #expect(model.rows.first { $0.id == id }?.documents.map(\.path).contains(Self.filed) == true)
    }

    @Test func aCardThatCannotBeReadForItsBytesLeavesNoNote() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = rig.model()
        await model.readDocuments(with: Self.documents([Self.card: VaultFixtures.licensePage]))
        model.fileContents = { _ in nil }
        let find = try #require(model.finds.first)
        var draft = VaultModel.Draft(find)
        draft.value = "D1234568"
        let id = try #require(model.confirm(find.id, as: draft))
        await model.notesWritten()
        #expect(model.entries.first { $0.id == id }?.readAs == nil)
        #expect(VaultSetAside.fingerprints(in: rig.defaults).isEmpty)
    }

    @Test func aReadingIsGivenTheNotedNumberOnlyWhereTheNoteSaysSo() {
        let source = VaultSource(path: "/a.pdf", role: "Card", rank: 30)
        let find = VaultFind(title: "Member ID", value: "WZ88319122", note: "",
                             facts: VaultReadFacts(category: .health, details: [], sources: [source]))
        let other = VaultFind(title: "Member ID", value: "XX1", note: "",
                              facts: VaultReadFacts(category: .health, details: [], sources: [source]))
        let read = VaultModel.reading((finds: [find, other], mentions: [VaultMention(value: "wz8831-9122", category: .health, source: source)]),
                                      instead: ["WZ88319122": "W288319122"])
        #expect(read.finds.map(\.value) == ["W288319122", "XX1"])
        #expect(read.mentions.map(\.value) == ["W288319122"])
    }
}

import Foundation
import Testing
@testable import Sync

/// Two copies of SyncCloud on one Vault, and the reading file (VT111): a seal over one the other
/// copy sealed since merges what the user typed in each (contacts, names, roles, lessons,
/// choices) and seals again, so neither copy's typing is lost.
@MainActor
@Suite struct VaultTwoCopiesReadingTests {
    typealias Rig = VaultModelTests.Rig

    static func copies(_ rig: Rig) async throws -> (VaultModel, VaultModel) {
        try rig.seed([VaultModelTests.passport])
        let people = [Person(id: "anna", displayName: "Anna"), Person(id: "erik", displayName: "Erik")]
        let first = rig.model(), second = rig.model()
        for model in [first, second] {
            model.people = people
            await model.opened()
        }
        return (first, second)
    }

    static func emails(_ rig: Rig, _ person: String) -> [String]? {
        rig.store.loadReading()?.contacts?[person]?.emails.map(\.value)
    }

    @Test func eachCopysTypingIsKeptWhenBothSeal() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let (first, second) = try await Self.copies(rig)
        #expect(first.setEmail("anna@example.com", label: nil, for: "anna"))
        #expect(second.setEmail("erik@example.com", label: nil, for: "erik"))
        #expect(second.readingMerges == 1)

        #expect(Self.emails(rig, "anna") == ["anna@example.com"], "the second's seal kept the first's typing")
        #expect(Self.emails(rig, "erik") == ["erik@example.com"])
        #expect(second.contacts["anna"]?.emails.map(\.value) == ["anna@example.com"], "and the second shows it")

        // The first, behind now, merges in turn.
        #expect(first.setEmail("anna.b@example.com", label: nil, for: "anna"))
        #expect(Self.emails(rig, "anna") == ["anna@example.com", "anna.b@example.com"])
        #expect(Self.emails(rig, "erik") == ["erik@example.com"])
    }

    @Test func whatTheOtherRemovedIsNotPutBack() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        try rig.seed([VaultModelTests.passport])
        let people = [Person(id: "anna", displayName: "Anna"), Person(id: "erik", displayName: "Erik")]
        let first = rig.model()
        first.people = people
        await first.opened()
        #expect(first.setEmail("anna@example.com", label: nil, for: "anna"))
        let second = rig.model()
        second.people = people
        await second.opened()
        #expect(second.contacts["anna"] != nil)

        first.removeEmail(at: 0, for: "anna")
        #expect(second.setEmail("erik@example.com", label: nil, for: "erik"))
        #expect(Self.emails(rig, "anna") == nil, "the second never changed it, so the first's removal stands")
        #expect(Self.emails(rig, "erik") == ["erik@example.com"])
    }

    @Test func aNameCorrectionAndAContactMadeInTwoCopiesBothStand() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let (first, second) = try await Self.copies(rig)
        #expect(first.setEmail("anna@example.com", label: nil, for: "anna"))
        second.setRole(.legal, of: "Anna Larsen", for: "anna")
        let reading = try #require(rig.store.loadReading())
        #expect(reading.contacts?["anna"] != nil)
        #expect(reading.nameRoles?["anna"]?.legal != nil, "the second's role is sealed beside the first's contact")
    }

    /// Both changed one person's contacts: each copy's phone and email are kept.
    @Test func bothCopiesTypingForOnePersonAreKept() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let (first, second) = try await Self.copies(rig)
        #expect(first.setPhone("+1 415 555 0101", label: nil, for: "anna"))
        #expect(second.setEmail("anna@example.com", label: nil, for: "anna"))
        let anna = try #require(rig.store.loadReading()?.contacts?["anna"])
        #expect(anna.phones.count == 1 && anna.emails.map(\.value) == ["anna@example.com"])
    }

    /// A choice the other copy made about a waiting ID stands; one it took out of To Confirm goes.
    @Test func waitingIDsFollowWhatTheOtherCopyDidToThem() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let (first, second) = try await Self.copies(rig)
        let pages = VaultFakeDocuments(pages: ["/docs/notice.pdf": VaultToConfirmTests.noticePage])
        await first.readDocuments(with: pages)
        first.closed()
        await first.opened()
        second.closed()
        await second.opened()
        let receipt = try #require(first.finds.first { $0.title == "USCIS receipt number" })
        let i94 = try #require(first.finds.first { $0.value == "123456789A1" })
        first.pin(receipt.id, .older)
        first.setAside(i94.id)

        #expect(second.setEmail("erik@example.com", label: nil, for: "erik"))
        #expect(second.finds.first { $0.value == receipt.value }?.choices.pin == .older, "the first's choice stands")
        #expect(!second.finds.contains { $0.value == "123456789A1" }, "set aside by the first, it waits no more")
        let sealed = try #require(rig.store.loadReading())
        #expect(sealed.finds.first { $0.value == receipt.value }?.choices.pin == .older)
        #expect(!sealed.finds.contains { $0.value == "123456789A1" })
    }

    /// The file gone (set aside by the other copy, or for a key this one made): nothing typed here
    /// is let go for it.
    @Test func aReadingFileGoneLeavesWhatWasTypedHere() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let (first, _) = try await Self.copies(rig)
        #expect(first.setEmail("anna@example.com", label: nil, for: "anna"))
        try FileManager.default.removeItem(at: rig.store.readingURL)
        #expect(first.setEmail("erik@example.com", label: nil, for: "erik"))
        #expect(Self.emails(rig, "anna") == ["anna@example.com"])
        #expect(Self.emails(rig, "erik") == ["erik@example.com"])
    }

    /// One copy alone seals as before: what it expects is what it last wrote.
    @Test func oneCopySealsWithoutMerging() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let (first, _) = try await Self.copies(rig)
        for index in 0..<3 { #expect(first.setEmail("a\(index)@example.com", label: nil, for: "anna")) }
        #expect(Self.emails(rig, "anna")?.count == 3)
        #expect(first.readingMerges == 0)
    }
}

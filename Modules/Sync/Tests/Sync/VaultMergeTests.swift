import Foundation
import Testing
@testable import Sync

/// Merge…: a waiting ID that is another reading of a saved one. Every number is made up.
@MainActor
@Suite struct VaultMergeTests {
    typealias Rig = VaultModelTests.Rig

    static let root = "/Users/anna/Documents/Health"
    static let card = root + "/Dental/ID Cards/Delta Dental card.pdf"
    static let eob = root + "/Dental/EOB/EOB Mar 2026.pdf"
    static func page(_ id: String, name: String = "ANNA ERIKSSON") -> [String] {
        ["Delta Dental", "Member Name: \(name)", "Member ID: \(id)", "Group Number: 0012345"]
    }

    /// Anna's card saved as 1102462401, and an EOB read as `reading`, waiting.
    static func rig(_ rig: Rig, reading: String = "1102463901", name: String = "ANNA ERIKSSON")
        async throws -> (model: VaultModel, saved: UUID, waiting: UUID) {
        let model = rig.model()
        VaultReadFolders.add("/Users/anna/Documents", in: rig.defaults)
        let first = VaultReadAsTests.documents([card: page("1102462401")])
        model.fileContents = { [first] in await first.contentKey(of: $0) }
        await model.readDocuments(with: first)
        let find = try #require(model.finds.first)
        var draft = VaultModel.Draft(find)
        draft.personID = "anna"
        let saved = try #require(model.confirm(find.id, as: draft))
        let both = VaultReadAsTests.documents([card: page("1102462401"), eob: page(reading, name: name)])
        model.fileContents = { [both] in await both.contentKey(of: $0) }
        await model.readDocuments(with: both)
        let waiting = try #require(model.finds.first { VaultReading.normalized($0.value) == reading })
        model.assign(waiting.id, to: .person("anna"))
        return (model, saved, waiting.id)
    }

    @Test func theEditDistanceCountsAddedDroppedAndChangedCharacters() {
        #expect(VaultModel.editDistance("1102462401", "1102463901") == 2)
        #expect(VaultModel.editDistance("ABC", "ABCD") == 1)
        #expect(VaultModel.editDistance("", "AB") == 2)
        #expect(VaultModel.editDistance("SAME", "SAME") == 0)
    }

    @Test func aReadingTwoCharactersOffTheSamePersonsSavedIDIsOfferedMerge() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let (model, saved, waiting) = try await Self.rig(rig)
        #expect(model.mergeCandidates(for: waiting) == [VaultModel.MergeCandidate(id: saved, differ: 2)])
        #expect(model.mergeSuggestion(for: waiting)?.id == saved)
    }

    @Test func mergeHoldsBackForAFamilysIDsAndForAnotherName() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        // Only the last two characters differ: a dependent's ID on the same plan.
        let (family, _, sibling) = try await Self.rig(rig, reading: "1102462499")
        #expect(!family.mergeCandidates(for: sibling).isEmpty)
        #expect(family.mergeSuggestion(for: sibling) == nil)

        let other = try Rig(); defer { other.cleanUp() }
        let (named, _, shweta) = try await Self.rig(other, name: "SHWETA DANI")
        #expect(named.mergeSuggestion(for: shweta) == nil, "the cards print different names")
    }

    @Test func anotherPersonsSavedIDIsNoCandidate() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let (model, _, waiting) = try await Self.rig(rig)
        model.assign(waiting, to: .person("erik"))
        #expect(model.mergeCandidates(for: waiting).isEmpty)
    }

    @Test func mergingKeepsTheSavedNumberAndRemembersTheReading() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let (model, saved, waiting) = try await Self.rig(rig)
        #expect(model.merge(waiting, into: saved, keepingReading: false))
        await model.notesWritten()
        #expect(model.finds.isEmpty)
        let entry = try #require(model.entries.first { $0.id == saved })
        #expect(entry.value == "1102462401")
        #expect(entry.readAs?.map(\.reads) == ["1102463901"])
        #expect(entry.savedFrom == Self.card)
        #expect(model.rows.first { $0.id == saved }?.documents.first?.path == Self.card, "the kept ID's Read from file changed")
        #expect(model.rows.first { $0.id == saved }?.documents.map(\.path).contains(Self.eob) == true)
        #expect(model.lastCorrection == VaultModel.Correction(id: saved, file: "EOB Mar 2026.pdf", changed: nil, merged: true))
        #expect(VaultSetAside.fingerprints(in: rig.defaults).isEmpty)
        // The EOB, read again, gives its dates to the saved ID.
        let both = VaultReadAsTests.documents([Self.card: Self.page("1102462401"), Self.eob: Self.page("1102463901")])
        await model.readDocuments(with: both, again: true)
        #expect(model.finds.isEmpty)
    }

    @Test func mergingKeepingTheReadingChangesTheSavedNumberAndNotesItsOwnCard() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let (model, saved, waiting) = try await Self.rig(rig)
        #expect(model.merge(waiting, into: saved, keepingReading: true))
        await model.notesWritten()
        let entry = try #require(model.entries.first { $0.id == saved })
        #expect(entry.value == "1102463901")
        #expect(entry.readAs?.map(\.reads) == ["1102462401"])
        #expect(entry.savedFrom == Self.card)
        #expect(model.rows.first { $0.id == saved }?.documents.first?.path == Self.card, "the kept ID's Read from file changed")
        let both = VaultReadAsTests.documents([Self.card: Self.page("1102462401"), Self.eob: Self.page("1102463901")])
        await model.readDocuments(with: both, again: true)
        #expect(model.finds.isEmpty, "the saved ID's own card offered its old number again")
    }

    @Test func undoingAMergePutsTheReadingBackToConfirmAndTheSavedIDAsItWas() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let (model, saved, waiting) = try await Self.rig(rig)
        let before = try #require(model.entries.first { $0.id == saved })
        #expect(model.merge(waiting, into: saved, keepingReading: true))
        await model.notesWritten()
        #expect(model.undoCorrection())
        #expect(model.entries.first { $0.id == saved } == before)
        #expect(model.finds.map(\.id) == [waiting])
        #expect(model.rows.first { $0.id == waiting }?.documents.map(\.path) == [Self.eob])
    }
}

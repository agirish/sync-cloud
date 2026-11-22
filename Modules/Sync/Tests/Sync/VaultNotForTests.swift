import Foundation
import Testing
@testable import Sync

/// Not for This ID: a file that names a saved ID but is not for it. Every number is made up.
@MainActor
@Suite struct VaultNotForTests {
    typealias Rig = VaultModelTests.Rig

    static let card = VaultMergeTests.card
    static let claim = VaultMergeTests.root + "/Dental/Claims/Claim 2024-118.pdf"
    static let filed = VaultMergeTests.root + "/Dental/Claims/2024/Claim 2024-118.pdf"
    static let claimPage = ["Delta Dental", "Claim for ANNA ERIKSSON", "Member ID: 1102462401", "Policy Number: P77881234"]

    static func documents(_ pages: [String: [String]]) -> VaultFakeDocuments { VaultReadAsTests.documents(pages) }

    /// Anna's dental ID saved from her card, and a claim that names it.
    static func rig(_ rig: Rig) async throws -> (model: VaultModel, id: UUID, readFrom: String, other: String) {
        let model = rig.model()
        VaultReadFolders.add("/Users/anna/Documents", in: rig.defaults)
        let both = documents([card: VaultMergeTests.page("1102462401"), claim: claimPage])
        model.fileContents = { [both] in await both.contentKey(of: $0) }
        await model.readDocuments(with: both)
        let find = try #require(model.finds.first { $0.value == "1102462401" })
        let id = try #require(model.confirm(find.id, as: VaultModel.Draft(find)))
        let paths = try #require(model.rows.first { $0.id == id }?.documents.map(\.path))
        #expect(Set(paths) == [card, claim])
        return (model, id, paths[0], paths[1])
    }

    @Test func aFileTakenOffStaysOffWhenReadAgainAndWhenItMoves() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let (model, id, readFrom, other) = try await Self.rig(rig)
        #expect(await model.notForThisID(id, path: other))
        #expect(model.rows.first { $0.id == id }?.documents.map(\.path) == [readFrom])
        #expect(model.entries.first { $0.id == id }?.notOn?.count == 1)

        let pages = [Self.card: VaultMergeTests.page("1102462401"), Self.claim: Self.claimPage]
        await model.readDocuments(with: Self.documents(pages))
        #expect(model.rows.first { $0.id == id }?.documents.map(\.path) == [readFrom], "a read put the file back")

        // Filed into a year folder: the same bytes elsewhere.
        var moved = pages
        moved[other] = nil
        moved[other == Self.claim ? Self.filed : Self.card] = other == Self.claim ? Self.claimPage : VaultMergeTests.page("1102462401")
        await model.readDocuments(with: Self.documents(moved))
        #expect(!(model.rows.first { $0.id == id }?.documents.map(\.path).contains(other == Self.claim ? Self.filed : other) ?? true))
        // Its own ID still comes up.
        #expect(model.finds.contains { $0.value == "P77881234" } || model.entries.contains { $0.value == "P77881234" })
        #expect(model.finds.allSatisfy { $0.value != "1102462401" })
    }

    @Test func theFileAnIDIsReadFromCannotBeTakenOff() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let (model, id, readFrom, _) = try await Self.rig(rig)
        #expect(!(await model.notForThisID(id, path: readFrom)))
        #expect(!(await model.notForThisID(id, path: "/elsewhere.pdf")), "a file not listed under it")
        #expect(model.entries.first { $0.id == id }?.notOn == nil)
    }

    @Test func aFileThatCannotBeReadForItsBytesStays() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let (model, id, _, other) = try await Self.rig(rig)
        model.fileContents = { _ in nil }
        #expect(!(await model.notForThisID(id, path: other)))
        #expect(model.rows.first { $0.id == id }?.documents.map(\.path).contains(other) == true)
        #expect(model.notice != nil)
    }
}

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

    /// A reader that runs `before` as it opens the first file other than `except`.
    final class Hooked: VaultDocumentReading, @unchecked Sendable {
        let inner: VaultFakeDocuments
        let except: String
        let before: @MainActor () async -> Void
        private(set) var opened: [String] = []
        private var hooked = false
        init(_ inner: VaultFakeDocuments, except: String, before: @escaping @MainActor () async -> Void) {
            self.inner = inner
            self.except = except
            self.before = before
        }
        /// `except` last, so it is opened after the hook has run.
        func files() async -> [URL] {
            let all = await inner.files()
            return all.filter { $0.path != except } + all.filter { $0.path == except }
        }
        func pages(in file: URL) async -> [[String]] {
            if !hooked, file.path != except {
                hooked = true
                await before()
            }
            opened.append(file.path)
            return await inner.pages(in: file)
        }
        func stamp(of file: URL) -> String? { inner.stamp(of: file) }
        func size(of file: URL) -> Int? { inner.size(of: file) }
        func contentKey(of file: URL) async -> String? { await inner.contentKey(of: file) }
    }

    /// Not for This ID chosen while a read runs holds for the files it has yet to open: the read
    /// does not put the file back on the ID (the 2026-11-23 review).
    @Test func aFileTakenOffDuringAReadStaysOffForTheRestOfIt() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let (model, id, readFrom, other) = try await Self.rig(rig)
        let pages = [Self.card: VaultMergeTests.page("1102462401"), Self.claim: Self.claimPage]
        let reader = Hooked(Self.documents(pages), except: other) {
            #expect(await model.notForThisID(id, path: other))
        }
        await model.readDocuments(with: reader, again: true)
        #expect(reader.opened.last == other, "the file taken off was not opened after the choice: \(reader.opened)")
        #expect(model.rows.first { $0.id == id }?.documents.map(\.path) == [readFrom], "the read put the file back")
    }

    @Test func aFileACorrectionNotedOffersWhatItReadsOnceTakenOff() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = rig.model()
        VaultReadFolders.add("/Users/anna/Documents", in: rig.defaults)
        // Anna's card misread as Erik's real ID, which his claim prints: one waiting ID, two files.
        let erik = VaultMergeTests.root + "/Dental/Claims/Claim Erik 2024.pdf"
        let pages = [Self.card: VaultMergeTests.page("1102462409"),
                     erik: ["Delta Dental", "Claim", "Member ID: 1102462409", "Policy Number: P77881234"]]
        let documents = Self.documents(pages)
        model.fileContents = { [documents] in await documents.contentKey(of: $0) }
        await model.readDocuments(with: documents)
        let find = try #require(model.finds.first { $0.value == "1102462409" })
        var draft = VaultModel.Draft(find)
        draft.value = "1102462401"
        let id = try #require(model.confirm(find.id, as: draft))
        await model.notesWritten()
        #expect(model.entries.first { $0.id == id }?.readAs?.count == 2, "both files were noted")
        #expect(await model.notForThisID(id, path: erik))
        #expect(model.entries.first { $0.id == id }?.readAs?.count == 1, "the claim's note stayed")
        await model.readDocuments(with: documents)
        #expect(model.finds.contains { $0.value == "1102462409" }, "what the claim reads never came up")
        #expect(model.rows.first { $0.id == id }?.documents.map(\.path) == [Self.card])
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

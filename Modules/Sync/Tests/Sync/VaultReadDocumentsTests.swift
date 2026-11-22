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

    /// Stop keeps what was read: sealed at once, not at the next 25th file, so a quit with the
    /// lock off loses none of it (VT68).
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
        let documents = VaultFakeDocuments(pages: ["/r/a.pdf": VaultFixtures.licensePage])
        await model.readDocuments(with: documents)
        let find = try #require(model.finds.first)
        var draft = VaultModel.Draft(find)
        draft.value = "D1234568"
        _ = model.confirm(find.id, as: draft)

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
        let documents = VaultFakeDocuments(pages: ["/r/A.pdf": front])
        await model.readDocuments(with: documents)
        let find = try #require(model.finds.first)
        let id = try #require(model.confirm(find.id, as: VaultModel.Draft(title: "License", value: find.value,
                                                                           category: .driversLicense)))
        let changed = await model.update(id, to: VaultModel.Draft(title: "License", value: "D7654321",
                                                                    category: .driversLicense))
        #expect(changed)
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
}

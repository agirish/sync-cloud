import Foundation
import Testing
@testable import Sync

/// The third adversarial review of the Vault's model: each test is a finding's own scenario,
/// which went wrong before its fix.
@MainActor
@Suite struct VaultReview3ModelTests {
    typealias Rig = VaultModelTests.Rig
    typealias InterruptingProof = VaultReviewModelTests.InterruptingProof

    static func model(_ rig: Rig, proof: InterruptingProof, copied: Rig.Box) -> VaultModel {
        let clock = rig.clock
        return VaultModel(store: rig.store, authenticator: proof, defaults: rig.defaults,
                          clock: { clock.now }, copyToPasteboard: { copied.copied.append($0) })
    }

    // MARK: A proof answered after access ended

    @Test func aProofAnsweredAfterThePanelClosedLeavesTheVaultLocked() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        // Closing does not lock under this setting, so only the late answer could open it.
        rig.defaults.set(VaultLockSettings.Relock.afterTenMinutes.rawValue, forKey: VaultLockSettings.relockKey)
        try rig.seed([VaultModelTests.passport])
        let proof = InterruptingProof()
        let model = Self.model(rig, proof: proof, copied: rig.box)
        proof.during = { model.closed() }
        await model.opened()
        #expect(!model.isOpen, "an answer given after the panel closed opened the Vault")
    }

    @Test func aProofAnsweredAfterLockNowCopiesNothing() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        rig.defaults.set(VaultLockSettings.Ask.everyNumber.rawValue, forKey: VaultLockSettings.askKey)
        try rig.seed([VaultModelTests.passport])
        let proof = InterruptingProof()
        let model = Self.model(rig, proof: proof, copied: rig.box)
        await model.opened()
        proof.during = { model.lockNow() }
        let copied = await model.copy(VaultModelTests.passport.id)
        #expect(!copied)
        #expect(rig.copied.isEmpty)
    }

    // MARK: Twins

    @Test func twinsShareABirthDateAndNothingElse() {
        let born = VaultReadingTests.day(2015, 3, 1)
        let s = VaultStandingsTests.self
        let liv = s.input("C1", .passport, born: born, holder: "Liv Eriksson", issuer: "SWE",
                          dated: s.day(2030, 9, 23), until: s.day(2030, 9, 23))
        let nils = s.input("C2", .passport, born: born, holder: "Nils Eriksson", issuer: "SWE",
                           dated: s.day(2029, 4, 2), until: s.day(2029, 4, 2))
        let nilsI94 = s.input("I1", .i94, born: born, holder: "Nils Eriksson", dated: s.day(2024, 6, 1), until: s.day(2027, 6, 1))
        // Read with no name: it could be either twin's, so it replaces neither one's.
        let unnamed = s.input("I2", .i94, born: born, dated: s.day(2025, 6, 1), until: s.day(2028, 6, 1))
        #expect(s.tabs([liv, nils, nilsI94, unnamed]) == [.current, .current, .current, .current])
    }

    // MARK: Showing what was just added

    @Test func aNumberAddedForSomeoneTheFilterHidesIsShown() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = rig.model()
        await model.opened()
        model.personFilter = .person("anna")
        let id = try #require(model.add(VaultModel.Draft(title: "Loan", value: "1234567890", personID: "bob",
                                                         category: .loans)))
        #expect(model.personFilter == .everyone)
        #expect(model.visibleRows.contains { $0.id == id })
        #expect(model.selection == id)
    }

    // MARK: A read number corrected by hand

    @Test func aReadNumberCorrectedByHandIsNotOfferedAgain() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = rig.model()
        await model.opened()
        let front = VaultReviewModelTests.front(expiring: "05/16/2030")
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

    // MARK: A folder the walk could not open

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
        let front = VaultReviewModelTests.front(expiring: "05/16/2030")
        await model.readDocuments(with: VaultFakeDocuments(pages: ["/r/Sub/A.pdf": front, "/r/B.pdf": ["nothing here"]]))
        #expect(model.finds.count == 1)
        // The subfolder cannot be opened this time; the rest of /r can.
        await model.readDocuments(with: WalkWithAGap(pages: ["/r/B.pdf": ["nothing here"]], unreachable: ["/r/Sub"]))
        #expect(model.finds.count == 1, "a folder that could not be opened was taken for deleted")
    }
}

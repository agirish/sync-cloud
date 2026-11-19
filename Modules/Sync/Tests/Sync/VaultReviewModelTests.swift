import Foundation
import Testing
@testable import Sync

/// What the review of the whole Vault on 2026-11-19 found in the model, each pinned down:
/// a proof that outlives the panel, what a merged number keeps, a read that sees no files, who a
/// number belongs to, and a change of rules.
@MainActor
@Suite struct VaultReviewModelTests {
    typealias Rig = VaultModelTests.Rig

    /// A proof that, while it is asked, lets something else happen: the panel closing, say.
    final class InterruptingProof: VaultAuthenticating, @unchecked Sendable {
        var during: (@MainActor () -> Void)?
        func prove(reason: String) async -> VaultProof {
            await during?()
            return .allowed
        }
    }

    static func everyNumber(_ rig: Rig) {
        rig.defaults.set(VaultLockSettings.Ask.everyNumber.rawValue, forKey: VaultLockSettings.askKey)
        rig.defaults.set(VaultLockSettings.Relock.whenClosed.rawValue, forKey: VaultLockSettings.relockKey)
    }

    static func model(_ rig: Rig, proof: InterruptingProof) -> VaultModel {
        let clock = rig.clock
        return VaultModel(store: rig.store, authenticator: proof, defaults: rig.defaults,
                          clock: { clock.now }, copyToPasteboard: { _ in })
    }

    // MARK: A proof that outlives the panel

    @Test func removingWhileThePanelClosesUnderTheProofNeverEmptiesTheVault() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        Self.everyNumber(rig)
        try rig.seed([VaultModelTests.mortgage, VaultModelTests.passport])
        let proof = InterruptingProof()
        let model = Self.model(rig, proof: proof)
        await model.opened()
        proof.during = { model.closed() }

        let removed = await model.delete(VaultModelTests.mortgage.id)

        #expect(!removed)
        #expect(try rig.store.load().count == 2, "the Vault on disk lost what it held")
    }

    @Test func changingWhileThePanelClosesUnderTheProofChangesNothing() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        Self.everyNumber(rig)
        try rig.seed([VaultModelTests.mortgage])
        let proof = InterruptingProof()
        let model = Self.model(rig, proof: proof)
        await model.opened()
        proof.during = { model.closed() }

        let changed = await model.update(VaultModelTests.mortgage.id,
                                         to: VaultModel.Draft(title: "Loan", value: "1111222233"))

        #expect(!changed)
        #expect(try rig.store.load().map(\.value) == ["0482917365"])
    }

    // MARK: What a merged number keeps

    static let licenseFront = ["California USA DRIVER LICENSE", "DL D1234567", "LN ERIKSSON", "FN ANNA"]

    static func front(expiring: String) -> [String] { licenseFront + ["EXP " + expiring] }

    @Test func aMisreadCopyTakesItsDatesWithItWhenItGoes() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = rig.model()
        // One scan misread the year as 2035; the other reads 2030.
        await model.readDocuments(with: VaultFakeDocuments(pages: ["/r/A.pdf": Self.front(expiring: "05/16/2035"),
                                                                    "/r/B.pdf": Self.front(expiring: "05/16/2030")]))
        #expect(model.finds.first?.validUntil == VaultIDReadingTests.day(2035, 5, 16))

        await model.readDocuments(with: VaultFakeDocuments(pages: ["/r/B.pdf": Self.front(expiring: "05/16/2030")]))

        let find = try #require(model.finds.first)
        #expect(find.validUntil == VaultIDReadingTests.day(2030, 5, 16))
        #expect(find.facts.sources.map(\.path) == ["/r/B.pdf"])
        #expect(!find.note.contains("2035"))
    }

    @Test func aReadThatSeesNoFilesKeepsWhatWasRead() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        VaultReadFolders.add("/r", in: rig.defaults)
        let model = rig.model()
        await model.readDocuments(with: VaultFakeDocuments(pages: ["/r/A.pdf": Self.front(expiring: "05/16/2030")]))
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
        await model.readDocuments(with: VaultFakeDocuments(pages: ["/r/A.pdf": Self.front(expiring: "05/16/2030"),
                                                                    "/r/note.pdf": ["Nothing here"]]))
        #expect(model.finds.count == 1)
        await model.readDocuments(with: VaultFakeDocuments(pages: ["/r/note.pdf": ["Nothing here"]]))
        #expect(model.finds.isEmpty)
    }

    @Test func aSavedNumberTakesItsRenewedCardsDates() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = rig.model()
        await model.readDocuments(with: VaultFakeDocuments(pages: ["/r/old.pdf": Self.front(expiring: "05/16/2025")]))
        let find = try #require(model.finds.first)
        _ = model.confirm(find.id, as: VaultModel.Draft(find))

        // The card is renewed under the same number.
        await model.readDocuments(with: VaultFakeDocuments(pages: ["/r/old.pdf": Self.front(expiring: "05/16/2025"),
                                                                    "/r/new.pdf": Self.front(expiring: "05/16/2030")]))

        let row = try #require(model.rows.first { $0.isSaved })
        #expect(row.facts?.validUntil == VaultIDReadingTests.day(2030, 5, 16))
        #expect(row.standing.expired == false)
        #expect(model.finds.isEmpty, "the saved number was offered again")
    }

    @Test func typingInANumberAlreadyWaitingShowsItOnce() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = rig.model()
        await model.readDocuments(with: VaultFakeDocuments(pages: ["/r/A.pdf": Self.front(expiring: "05/16/2030")]))
        #expect(model.finds.count == 1)

        _ = model.add(VaultModel.Draft(title: "License", value: "D1234567"))

        #expect(model.finds.isEmpty)
        #expect(model.rows.filter { VaultReading.normalized($0.value) == "D1234567" }.count == 1)
    }

    // MARK: Who a number belongs to

    @Test func oneNamesDocumentsAreWeighedTogetherWithAndWithoutABirthDate() {
        let anna = VaultIDReadingTests.day(1974, 8, 12)
        func i94(_ value: String, born: Date?, entered: Date) -> VaultStandingInput {
            VaultStandingInput(id: UUID(), value: value, category: .i94,
                               facts: VaultReadFacts(category: .i94, holder: "Anna Eriksson", born: born, dated: entered,
                                                     sources: [VaultSource(path: "/r/\(value).pdf", role: "I-94", rank: 30)]),
                               pin: nil)
        }
        let printout = i94("11111111111", born: anna, entered: VaultIDReadingTests.day(2024, 4, 1))
        let tearOff = i94("22222222222", born: nil, entered: VaultIDReadingTests.day(2026, 1, 9))
        let out = VaultStandings.compute([printout, tearOff], now: VaultStandingsTests.today)
        #expect(out[tearOff.id]?.tab == .current)
        #expect(out[printout.id]?.tab == .archive)
    }

    @Test func twoPeopleWithOneNameAreNeverJoined() {
        func ssn(_ value: String, form: String, born: Date) -> VaultStandingInput {
            VaultStandingInput(id: UUID(), value: value, category: .ssn,
                               facts: VaultReadFacts(category: .ssn, holder: "Anna Eriksson", born: born, form: form,
                                                     sources: [VaultSource(path: "/r/\(value).pdf", role: "card", rank: 40)]),
                               pin: nil)
        }
        let mother = ssn("123456789", form: "SSN", born: VaultIDReadingTests.day(1950, 1, 1))
        let daughter = ssn("912701234", form: "ITIN", born: VaultIDReadingTests.day(1990, 1, 1))
        let out = VaultStandings.compute([mother, daughter], now: VaultStandingsTests.today)
        #expect(out[daughter.id]?.tab == .current, "an ITIN gave way to someone else's SSN")
    }

    @Test func aNumberTheUserMovedStaysWhereTheyPutIt() {
        let anna = VaultIDReadingTests.day(1974, 8, 12)
        let read = VaultStandingInput(id: UUID(), value: "X1", category: .passport,
                                      facts: VaultReadFacts(category: .passport, holder: "Anna Eriksson", born: anna,
                                                            issuer: "SWE", dated: VaultIDReadingTests.day(2032, 1, 1),
                                                            sources: [VaultSource(path: "/r/a.pdf", role: "p", rank: 40)]),
                                      pin: nil)
        var moved = read
        moved.id = UUID()
        moved.value = "X2"
        moved.facts?.dated = VaultIDReadingTests.day(2030, 1, 1)
        moved.assignment = .household
        moved.isChosen = true
        let out = VaultStandings.compute([read, moved], now: VaultStandingsTests.today)
        #expect(out[read.id]?.tab == .current)
        #expect(out[moved.id]?.tab == .current, "a number moved to the household was weighed against Anna's")
    }

    @Test func aDatedCopySpeaksOverAnUndatedOneOfTheSameKind() {
        func facts(_ until: Date?) -> VaultReadFacts {
            VaultReadFacts(category: .driversLicense, validUntil: until,
                           sources: [VaultSource(path: "/r/x.pdf", role: "card", rank: 40)])
        }
        #expect(VaultModel.supersedes(facts(VaultIDReadingTests.day(2030, 1, 1)), facts(nil)))
        #expect(!VaultModel.supersedes(facts(nil), facts(VaultIDReadingTests.day(2030, 1, 1))))
    }

    // MARK: A change of rules, and Forget

    @Test func aChangeOfRulesKeepsTheChoicesMadeAndSaysSo() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let documents = VaultFakeDocuments(pages: ["/r/A.pdf": Self.front(expiring: "05/16/2030")])
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
        #expect(model.notice?.contains("Read Documents") == true)

        await model.readDocuments(with: documents)
        let find = try #require(model.finds.first)
        #expect(find.assignment == .household)
        #expect(find.pin == .older)
    }

    @Test func forgetWhileTheVaultStaysLoadedReadsEveryFileAgain() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let documents = VaultFakeDocuments(pages: ["/r/A.pdf": Self.front(expiring: "05/16/2030")],
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
}

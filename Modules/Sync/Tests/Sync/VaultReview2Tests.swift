import Foundation
import Testing
@testable import Sync

/// What the second review of the whole Vault, on 2026-11-19, found: each pinned down. Every
/// number here is made up.
@MainActor
@Suite struct VaultReview2Tests {
    typealias Rig = VaultModelTests.Rig
    static func read(_ lines: [String]) -> [VaultFind] { VaultIDReadingTests.read(lines) }
    static func day(_ y: Int, _ m: Int, _ d: Int) -> Date { VaultIDReadingTests.day(y, m, d) }

    // MARK: Readers

    @Test func aReceiptAndItsApprovalInOneFileReadAsTheApproval() throws {
        let receipt = ["I-797C Receipt Notice", "Receipt Number WAC2690123456", "Form I-129",
                       "Beneficiary ERIKSSON, ANNA", "Received Date 01/05/2026"]
        let approval = ["I-797A Approval Notice", "Receipt Number WAC2690123456", "Form I-129",
                        "Notice Date 07/10/2026", "Valid from 10/01/2026 to 09/30/2029"]
        let find = try #require(VaultReading.read(pages: [receipt, approval], from: "/n.pdf").finds.first)
        #expect(find.facts.primary?.role == "I-797A approval")
        #expect(!find.facts.pending)
        #expect(find.validUntil == Self.day(2029, 9, 30))
        #expect(find.holder == "Anna Eriksson", "the receipt's name was not kept")
    }

    @Test func aBankPagesNoticeWordsAreNoUSCISCue() {
        #expect(Self.read(["Privacy notice", "Branch: LIN 4155551234"]).isEmpty)
        #expect(Self.read(["In case of emergency", "MEI LIN 4155551234"]).isEmpty)
    }

    @Test func aDottedLabelCountsAsAColumn() {
        let page = ["UNION OF INDIA DRIVING LICENSE", "License No. : KA05 20090001234", "Name : ANNA ERIKSSON",
                    "D.O.I.   Valid upto", "01-02-2010   31-01-2030"]
        #expect(Self.read(page).first?.validUntil == Self.day(2030, 1, 31))
    }

    @Test func aLicenseFrontsNextFieldNumberDoesNotHideIt() {
        let page = ["California USA DRIVER LICENSE", "4d DL D1234567 4b EXP 08/31/2029"]
        #expect(Self.read(page).map(\.value) == ["D1234567"])
    }

    @Test func anOlderPANCardWithoutItsLabelsIsStillACard() {
        let card = ["INCOME TAX DEPARTMENT", "GOVT. OF INDIA", "Permanent Account Number", "ABCPE1234F",
                    "ANNA ERIKSSON", "ERIK ERIKSSON", "12/08/1974"]
        let find = Self.read(card).first
        #expect(find?.facts.primary?.rank == VaultReading.IDRank.card)
        #expect(find?.holder == "Anna Eriksson")
    }

    @Test func aNameTwoPeopleShareIsNoKeyForAnUndatedDocument() {
        func i94(_ value: String, born: Date?, entered: Date) -> VaultStandingInput {
            VaultStandingInput(id: UUID(), value: value, category: .i94,
                               facts: VaultReadFacts(category: .i94, holder: "Anna Eriksson", born: born, dated: entered,
                                                     sources: [VaultSource(path: "/r/\(value).pdf", role: "I-94", rank: 30)]),
                               pin: nil)
        }
        let mother = i94("11111111111", born: Self.day(1960, 1, 1), entered: Self.day(2024, 1, 1))
        let daughter = i94("22222222222", born: Self.day(1990, 1, 1), entered: Self.day(2024, 2, 1))
        let undated = i94("33333333333", born: nil, entered: Self.day(2025, 1, 1))
        for order in [[mother, daughter, undated], [daughter, mother, undated]] {
            let out = VaultStandings.compute(order, now: VaultStandingsTests.today)
            #expect(out[mother.id]?.tab == .current, "one person's only I-94 was archived")
            #expect(out[daughter.id]?.tab == .current, "one person's only I-94 was archived")
        }
    }

    // MARK: Model

    nonisolated static let license = ["California USA DRIVER LICENSE", "DL D1234567", "EXP 05/16/2030", "LN ERIKSSON", "FN ANNA"]

    @Test func typingInAWaitingNumberKeepsWhatWasReadAndChosen() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = rig.model()
        await model.readDocuments(with: VaultFakeDocuments(pages: ["/r/a.pdf": Self.license]))
        let find = try #require(model.finds.first)
        model.assign(find.id, to: .household)
        model.setGeo(find.id, to: .india)

        _ = model.add(VaultModel.Draft(title: "License", value: "D1234567"))

        let entry = try #require(model.entries.first)
        #expect(entry.facts?.validUntil == Self.day(2030, 5, 16), "what was read for it was let go")
        #expect(entry.assignment == .household)
        #expect(entry.geo == .india)
        #expect(model.rows.first?.documents.map(\.path) == ["/r/a.pdf"])
    }

    @Test func confirmingKeepsUsedIn() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = rig.model()
        await model.readDocuments(with: VaultFakeDocuments(pages: ["/r/a.pdf": Self.license]))
        let find = try #require(model.finds.first)
        model.setGeo(find.id, to: .india)
        let updated = try #require(model.finds.first)
        _ = model.confirm(updated.id, as: VaultModel.Draft(updated))
        #expect(model.entries.first?.geo == .india)
    }

    @Test func aNumberAddedUnderAFilterThatHidesItIsShown() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = rig.model()
        model.kindFilter = "health"
        let id = try #require(model.add(VaultModel.Draft(title: "Loan", value: "4410552233", category: .loans)))
        #expect(model.visibleRows.contains { $0.id == id })
        #expect(model.kindFilter == nil)
    }

    @Test func aCorrectedMisreadIsNotOfferedAgain() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = rig.model()
        let documents = VaultFakeDocuments(pages: ["/r/a.pdf": Self.license])
        await model.readDocuments(with: documents)
        let find = try #require(model.finds.first)
        var draft = VaultModel.Draft(find)
        draft.value = "D1234568"
        _ = model.confirm(find.id, as: draft)

        await model.readDocuments(with: documents, again: true)
        #expect(model.finds.isEmpty, "the misread came back")
    }

    /// A file that gives nothing back at all (locked, gone for a moment).
    struct FlakyDocuments: VaultDocumentReading {
        let gone: Bool
        func files() async -> [URL] { [URL(fileURLWithPath: "/r/a.pdf")] }
        func pages(in file: URL) async -> [[String]] { gone ? [] : [VaultReview2Tests.license] }
        func stamp(of file: URL) -> String? { "1" }
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

    @Test func emptyingTheChosenGroupGoesBackToAllKinds() throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = rig.model()
        model.kindFilter = "health"
        var groups = model.groups
        groups.groupOf[.health] = "home"
        model.setGroups(groups)
        #expect(model.kindFilter == nil)
    }

    @Test func kindsOnlyTheOtherCountryHasAreCountedForTheLineUnderTheCards() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = rig.model()
        await model.readDocuments(with: VaultFakeDocuments(pages: ["/r/us.pdf": Self.license,
                                                                    "/r/pan.pdf": VaultIDReadingTests.panCard]))
        model.geoFilter = .us
        let elsewhere = try #require(model.elsewhereKinds)
        #expect(elsewhere.filter == .india && elsewhere.count == 1)
    }

    // MARK: The lock's seal

    @Test func aSealFromBeforeTheLockWentBackOnMatchesNothing() throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        try rig.seed([VaultModelTests.mortgage])
        rig.defaults.set(false, forKey: VaultLockSettings.requiresAuthenticationKey)
        VaultLockSwitch.sealOff(in: rig.defaults, store: rig.store)
        let old = try #require(rig.defaults.string(forKey: VaultLockSwitch.sealKey))
        #expect(!VaultLockSettings(defaults: rig.defaults, store: rig.store).requiresAuthentication)

        // On again, then the old seal written back as from a backup.
        VaultLockSwitch.unseal(in: rig.defaults, store: rig.store)
        rig.defaults.set(old, forKey: VaultLockSwitch.sealKey)
        #expect(VaultLockSettings(defaults: rig.defaults, store: rig.store).requiresAuthentication)

        // Off again: a new seal, not the old one.
        VaultLockSwitch.sealOff(in: rig.defaults, store: rig.store)
        #expect(rig.defaults.string(forKey: VaultLockSwitch.sealKey) != old)
    }
}

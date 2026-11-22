import Foundation
import Testing
@testable import Sync

/// One card read for the editor (``VaultReading/cardValues(on:)``), kept for its size and date,
/// and one proof that shows several IDs. Every number is made up.
@MainActor
@Suite struct VaultCardReadingTests {
    typealias Rig = VaultModelTests.Rig

    static func values(_ lines: [String]) -> [VaultCardValue] { VaultReading.cardValues(on: [lines]) }
    static func pair(_ label: String, _ value: String) -> VaultCardValue { VaultCardValue(label: label, value: value) }

    // MARK: What a card prints

    @Test func aDependentsCardGivesBothIDsAndNoGroupDatePhoneOrAmount() {
        let card = ["Aetna", "Member Name: SHWETA DANI", "Member ID: W288319122", "Subscriber ID: W288319115",
                    "Group Number: 0012345", "RxBIN 610014 RxPCN ADV RxGRP RX1234", "Effective 01/01/2025",
                    "Customer Service 1-800-555-0142", "Copay $25 ER $250"]
        #expect(Self.values(card) == [Self.pair("Member ID", "W288319122"), Self.pair("Subscriber ID", "W288319115"),
                                      Self.pair("RxBIN", "610014"), Self.pair("RxPCN", "ADV")])
    }

    @Test func aLabelOverItsValueNamesIt() {
        #expect(Self.values(["Subscriber ID", "W288319115"]) == [Self.pair("Subscriber ID", "W288319115")])
        #expect(Self.values(["Member #:", "XZB123456789"]) == [Self.pair("Member", "XZB123456789")])
        // A plan's name over a number is no label.
        #expect(Self.values(["Delta Dental", "12345678 PPO"]).isEmpty)
    }

    @Test func aNameAfterItsColonIsNotPartOfTheNextLabel() {
        #expect(Self.values(["Member Name: ANNA ERIKSSON Member ID: XZB123456789"])
                == [Self.pair("Member ID", "XZB123456789")])
        #expect(Self.values(["ANNA ERIKSSON Member ID XZB123456789"]) == [Self.pair("Member ID", "XZB123456789")])
    }

    @Test func twoColumnsReadAsOneLineGiveEachValueItsOwnLabel() {
        #expect(Self.values(["Member ID W28831 Plan Code 4412A"])
                == [Self.pair("Member ID", "W28831"), Self.pair("Plan Code", "4412A")])
        #expect(Self.values(["Member ID W28831 Group 0012345"]) == [Self.pair("Member ID", "W28831")])
    }

    @Test func groupsOfDigitsASpaceApartAreOneNumber() {
        #expect(Self.values(["Account Number 1234 5678 9012"]) == [Self.pair("Account Number", "1234 5678 9012")])
        #expect(Self.values(["Account Number 1234 5678 01/02/2030"]) == [Self.pair("Account Number", "1234 5678")])
    }

    @Test func aShortOrLetterOnlyValueAndAnUnlabelledNumberAreLeftOut() {
        #expect(Self.values(["Plan A12", "Plan ADV", "W288319115"]).isEmpty)
        // A plan's processor code is letters alone, and is read beside its own label only.
        #expect(Self.values(["RxPCN ADV"]) == [Self.pair("RxPCN", "ADV")])
        #expect(Self.values(["RxPCN A"]).isEmpty)
        // The same value twice is listed once, by its first label.
        #expect(Self.values(["Member ID W288319122", "ID W288319122"]) == [Self.pair("Member ID", "W288319122")])
    }

    @Test func anUnknownLabelKeepsItsLastTwoWords() {
        #expect(Self.values(["Your Benefit Ref Code Q4417"]) == [Self.pair("Ref Code", "Q4417")])
        #expect(Self.values(["Your Unknown Field Q4417"]) == [Self.pair("Unknown Field", "Q4417")])
    }

    // MARK: Read once, kept for its size and date

    static let path = "/Documents/Health/Aetna/card.pdf"
    static let card = ["Aetna", "Member ID: W288319122", "Subscriber ID: W288319115"]

    @Test func aCardIsReadOnceAndAgainOnlyOnceItChanges() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = rig.model()
        await model.opened()
        let shelf = VaultShelf([Self.path: Self.card])
        let first = await model.readCard(Self.path, with: shelf)
        #expect(first == .read([Self.pair("Member ID", "W288319122"), Self.pair("Subscriber ID", "W288319115")]))
        #expect(await model.readCard(Self.path, with: shelf) == first)
        #expect(shelf.opened == [Self.path], "an unchanged card was read again")

        shelf.write(Self.path, ["Member ID: W288319122"])
        #expect(await model.readCard(Self.path, with: shelf) == .read([Self.pair("Member ID", "W288319122")]))
        #expect(shelf.opened.count == 2)
    }

    @Test func aMovedCardIsNotFoundAndAnEmptyOneUnreadable() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = rig.model()
        await model.opened()
        let shelf = VaultShelf([Self.path: []])
        #expect(await model.readCard(Self.path, with: shelf) == .unreadable)
        shelf.remove(Self.path)
        #expect(await model.readCard(Self.path, with: shelf) == .notFound)
    }

    @Test func lockingLetsWhatWasReadGo() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = rig.model()
        await model.opened()
        let shelf = VaultShelf([Self.path: Self.card])
        _ = await model.readCard(Self.path, with: shelf)
        model.lockNow()
        await model.opened()
        _ = await model.readCard(Self.path, with: shelf)
        #expect(shelf.opened.count == 2, "values read before the lock were kept through it")
    }

    // MARK: One proof for several IDs

    @Test func oneProofShowsEveryIDTheEditorDrawsAndTheyHideTogether() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        rig.defaults.set(VaultLockSettings.Ask.everyNumber.rawValue, forKey: VaultLockSettings.askKey)
        try rig.seed([VaultModelTests.passport, VaultModelTests.memberID, VaultModelTests.mortgage])
        let model = rig.model()
        await model.opened()
        let ids = [VaultModelTests.passport.id, VaultModelTests.memberID.id]
        #expect(await model.showTogether(ids, reason: "correct Health plan member ID"))
        #expect(rig.auth.reasons == ["correct Health plan member ID"], "one proof, not one per ID")
        #expect(model.canShow(VaultModelTests.passport) && model.canShow(VaultModelTests.memberID))
        #expect(!model.canShow(VaultModelTests.mortgage))
        // Shown already: no second ask.
        #expect(await model.showTogether(ids, reason: "again"))
        #expect(rig.auth.reasons.count == 1)
        rig.clock.advance(VaultLock.showFor)
        model.tick()
        #expect(!model.canShow(VaultModelTests.passport) && !model.canShow(VaultModelTests.memberID))
    }

    @Test func aRefusedProofShowsNoneOfThem() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        rig.defaults.set(VaultLockSettings.Ask.everyNumber.rawValue, forKey: VaultLockSettings.askKey)
        try rig.seed([VaultModelTests.passport, VaultModelTests.memberID])
        let model = rig.model()
        await model.opened()
        rig.auth.answer = .cancelled
        #expect(!(await model.showTogether([VaultModelTests.passport.id, VaultModelTests.memberID.id], reason: "correct")))
        #expect(!model.canShow(VaultModelTests.passport) && !model.canShow(VaultModelTests.memberID))
    }

    @Test func theLockHoldsASetAndAnotherProofReplacesIt() {
        let a = UUID(), b = UUID(), c = UUID()
        var lock = VaultLock(settings: VaultLockSettings(ask: .everyNumber))
        let t0 = VaultLockTests.t0
        lock.proved(for: [a, b], at: t0)
        #expect(lock.canShow(a, at: t0) && lock.canShow(b, at: t0) && !lock.canShow(c, at: t0))
        #expect(lock.shownIDs(at: t0) == [a, b])
        #expect(lock.shownID(at: t0) == nil, "two shown are not one")
        lock.keepShown(at: t0.addingTimeInterval(20))
        #expect(lock.canShow(b, at: t0.addingTimeInterval(45)))
        lock.proved(for: c, at: t0.addingTimeInterval(46))
        #expect(!lock.canShow(a, at: t0.addingTimeInterval(46)) && lock.shownID(at: t0.addingTimeInterval(46)) == c)
    }
}

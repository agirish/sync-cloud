import Foundation
import Testing
@testable import Sync

/// Locked means locked: under "As soon as Vault opens", a locked panel has read nothing and
/// shows nothing. Every number is made up.
@MainActor
@Suite struct VaultSealedShutTests {
    typealias Rig = VaultModelTests.Rig
    static let mortgage = VaultModelTests.mortgage
    static let social = VaultEntry(title: "Social Security number", value: "123-45-6789", personID: "anna",
                                   addedAt: VaultLockTests.t0, category: .ssn)

    @Test func aSealedVaultIsReadOnlyAfterTheProof() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        try rig.seed([Self.mortgage])
        rig.auth.answer = .cancelled
        let model = rig.model()
        await model.opened()
        #expect(rig.auth.reasons == ["unlock your Vault"], "asked at once, before anything is read")
        #expect(model.contents == .notLoaded && model.rows.isEmpty)

        rig.auth.answer = .allowed
        #expect(await model.unlock())
        #expect(model.contents == .loaded && model.entries == [Self.mortgage])
        #expect(!model.isSealedShut)
        rig.auth.answer = .cancelled
        #expect(await model.unlock(), "already open: nothing to ask")
        #expect(rig.auth.reasons.count == 2)
    }

    @Test func lockNowAndTheIdleLimitLetTheNumbersGoWhileThePanelIsUp() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        try rig.seed([Self.mortgage])
        let model = rig.model()
        await model.opened()
        #expect(model.entries.count == 1)

        model.lockNow()
        #expect(model.isSealedShut)
        #expect(model.contents == .notLoaded && model.entries.isEmpty, "Lock Now is not a mask over a loaded list")

        #expect(await model.unlock())
        #expect(model.entries.count == 1)
        rig.clock.advance(61)   // the default: one idle minute
        model.tick()
        #expect(model.isSealedShut && model.entries.isEmpty, "and neither is the idle limit")
    }

    @Test func withNothingSealedThereIsNoLockToDrawAndWhatIsAddedShowsUntilThePanelCloses() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = rig.model()
        await model.opened()
        #expect(rig.auth.reasons.isEmpty && !model.isSealedShut, "an empty Vault guards nothing")
        let id = try #require(model.add(VaultModel.Draft(title: "Mortgage loan number", value: "0482917365", category: .loans)))
        rig.clock.advance(5); model.tick()
        #expect(model.rows.map(\.id) == [id], "typed in this sitting: its row stays, a name and an ending")
        #expect(model.masked(try #require(model.rows.first)) == "••••••7365")

        model.closed()
        rig.auth.answer = .cancelled
        await model.opened()
        #expect(model.isSealedShut && model.rows.isEmpty, "from the next open it is behind the lock")
    }

    @Test func anIDTypedInWhileLockedIsSavedAndNotShown() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        try rig.seed([Self.mortgage])
        rig.auth.answer = .cancelled
        let model = rig.model()
        await model.opened()
        #expect(model.add(VaultModel.Draft(title: "Passport", value: "A38291647", category: .passport)) != nil)
        model.tick()
        #expect(model.isSealedShut && model.entries.isEmpty, "saved, and let go again with the lock still shut")
        #expect(try rig.store.load().map(\.value) == ["0482917365", "A38291647"])
    }

    @Test func documentsReadWhileLockedAreSealedAndWaitForTheProof() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        try rig.seed([Self.mortgage])
        rig.auth.answer = .cancelled
        let model = rig.model()
        await model.opened()
        await model.readDocuments(with: VaultToConfirmTests.documents)
        #expect(model.finds.isEmpty && model.entries.isEmpty, "nothing read is held behind a shut lock")
        rig.auth.answer = .allowed
        #expect(await model.unlock())
        #expect(model.finds.count == 3, "it was sealed as it was read: \(model.finds.map(\.title))")
    }

    @Test func refreshDoesNotRunByItselfBehindTheLock() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        try rig.seed([Self.mortgage])
        rig.auth.answer = .cancelled
        let model = rig.model()
        await model.opened()
        model.refreshIfWanted(with: VaultToConfirmTests.documents)
        #expect(model.readingTask == nil, "a locked panel has read nothing to refresh")
    }

    @Test func forEveryIDStillListsNamesAndKeepsBackAnEndingThatIsItselfASecret() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        rig.defaults.set(VaultLockSettings.Ask.everyNumber.rawValue, forKey: VaultLockSettings.askKey)
        try rig.seed([Self.mortgage, Self.social])
        let model = rig.model()
        await model.opened()
        #expect(rig.auth.reasons.isEmpty && !model.isSealedShut, "there is no unlocking of the whole in this mode")
        let loan = try #require(model.rows.first { $0.id == Self.mortgage.id })
        let ssn = try #require(model.rows.first { $0.id == Self.social.id })
        #expect(model.masked(loan) == "••••••7365")
        #expect(model.masked(ssn) == "•••-••-••••", "a Social Security number's last four are what a bank asks for")

        #expect(await model.show(Self.social.id))
        #expect(model.masked(ssn) == "•••-••-6789", "once it may be shown, its row draws its ending like any other")
    }

    @Test func aVaultWhoseKeyIsNotHereIsSaidSoWithoutAsking() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        try rig.seed([Self.mortgage])
        rig.keychain.itemData = nil
        let model = rig.model()
        await model.opened()
        #expect(rig.auth.reasons.isEmpty, "no proof opens it, so none is asked for")
        #expect(model.contents == .unreadable(.keyMissing))
    }
}

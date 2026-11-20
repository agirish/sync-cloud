import Foundation
import Testing
@testable import Sync

/// When the Vault's numbers may be shown (``VaultLock``).
@Suite struct VaultLockTests {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    static func after(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }
    static let a = UUID(), b = UUID()

    static func lock(_ ask: VaultLockSettings.Ask = .whenOpened,
                     _ relock: VaultLockSettings.Relock = .afterTwoMinutes,
                     requires: Bool = true) -> VaultLock {
        VaultLock(settings: VaultLockSettings(requiresAuthentication: requires, ask: ask, relock: relock))
    }

    @Test func itStartsLockedAndAProofOpensEverything() {
        var lock = Self.lock()
        #expect(!lock.isOpen(at: Self.t0))
        #expect(!lock.canShow(Self.a, at: Self.t0))
        #expect(lock.needsProof(for: nil, at: Self.t0))
        #expect(lock.needsProof(for: Self.a, at: Self.t0))

        lock.proved(at: Self.t0)
        #expect(lock.isOpen(at: Self.t0))
        #expect(lock.canShow(Self.a, at: Self.t0) && lock.canShow(Self.b, at: Self.t0))
        #expect(!lock.needsProof(for: Self.a, at: Self.t0))
    }

    @Test func twoIdleMinutesLockItAndUseRestartsTheCount() {
        var lock = Self.lock(.whenOpened, .afterTwoMinutes)
        lock.proved(at: Self.t0)
        #expect(lock.secondsLeft(at: Self.t0) == 120)
        #expect(lock.secondsLeft(at: Self.after(90.4)) == 30)
        #expect(lock.isOpen(at: Self.after(119)))
        #expect(!lock.isOpen(at: Self.after(120)))

        lock.used(at: Self.after(100))
        #expect(lock.isOpen(at: Self.after(200)))
        #expect(!lock.isOpen(at: Self.after(220)))
        #expect(lock.secondsLeft(at: Self.after(220)) == nil)
    }

    @Test func usingALockedVaultDoesNotOpenIt() {
        var lock = Self.lock()
        lock.used(at: Self.t0)
        #expect(!lock.isOpen(at: Self.t0))

        lock.proved(at: Self.t0)
        lock.used(at: Self.after(500))   // long after it ran out
        #expect(!lock.isOpen(at: Self.after(500)))
    }

    @Test func closingLocksUnlessTheSettingKeepsItForTenMinutes() {
        for relock in [VaultLockSettings.Relock.whenClosed, .afterTwoMinutes] {
            var lock = Self.lock(.whenOpened, relock)
            lock.proved(at: Self.t0)
            lock.closed()
            #expect(!lock.isOpen(at: Self.after(1)), "\(relock)")
        }
        var kept = Self.lock(.whenOpened, .afterTenMinutes)
        kept.proved(at: Self.t0)
        kept.closed()
        #expect(kept.isOpen(at: Self.after(599)))
        #expect(!kept.isOpen(at: Self.after(600)))
    }

    @Test func untilClosedHasNoTimer() {
        var lock = Self.lock(.whenOpened, .whenClosed)
        lock.proved(at: Self.t0)
        #expect(lock.isOpen(at: Self.after(86_400)))
        #expect(lock.secondsLeft(at: Self.after(10)) == nil)
    }

    @Test func everyNumberShowsOnlyTheOneProvedForAndOnlyForThirtySeconds() {
        var lock = Self.lock(.everyNumber)
        lock.proved(at: Self.t0)   // a proof for nothing in particular opens nothing
        #expect(!lock.isOpen(at: Self.t0))

        lock.proved(for: Self.a, at: Self.t0)
        #expect(!lock.isOpen(at: Self.t0))
        #expect(lock.canShow(Self.a, at: Self.after(29)))
        #expect(!lock.needsProof(for: Self.a, at: Self.after(29)))
        #expect(!lock.canShow(Self.b, at: Self.after(1)))
        #expect(lock.needsProof(for: Self.b, at: Self.after(1)))
        #expect(!lock.canShow(Self.a, at: Self.after(30)))

        lock.proved(for: Self.b, at: Self.after(5))
        #expect(!lock.canShow(Self.a, at: Self.after(6)), "proving the next number hides the last")
    }

    @Test func lockNowAndClosingHideAShownNumber() {
        var lock = Self.lock(.everyNumber)
        lock.proved(for: Self.a, at: Self.t0)
        lock.closed()
        #expect(!lock.canShow(Self.a, at: Self.after(1)))

        var open = Self.lock()
        open.proved(at: Self.t0)
        open.lock()
        #expect(!open.isOpen(at: Self.after(1)))
    }

    @Test func withTheLockOffEverythingShowsAndNothingAsks() {
        var lock = Self.lock(requires: false)
        #expect(lock.isOpen(at: Self.t0))
        #expect(!lock.needsProof(for: nil, at: Self.t0))
        #expect(!lock.needsProof(for: Self.a, at: Self.t0))
        #expect(lock.secondsLeft(at: Self.t0) == nil)
        lock.closed()
        #expect(lock.isOpen(at: Self.after(1)))
    }

    @Test func anExpiredProofCannotBeRevivedByALooserSetting() {
        var lock = Self.lock(.whenOpened, .afterTwoMinutes)
        lock.proved(at: Self.t0)
        lock.expire(at: Self.after(300))
        lock.settings.relock = .afterTenMinutes
        #expect(!lock.isOpen(at: Self.after(301)))
    }

    @Test func aDamagedPreferenceReadsAsLocked() throws {
        let suite = "vault-lock-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(VaultLockSettings(defaults: defaults) == VaultLockSettings())
        #expect(VaultLockSettings().requiresAuthentication)

        defaults.set("nonsense", forKey: VaultLockSettings.askKey)
        defaults.set("nonsense", forKey: VaultLockSettings.relockKey)
        defaults.set("yes please", forKey: VaultLockSettings.requiresAuthenticationKey)
        #expect(VaultLockSettings(defaults: defaults) == VaultLockSettings())

        defaults.set(false, forKey: VaultLockSettings.requiresAuthenticationKey)
        defaults.set(VaultLockSettings.Ask.everyNumber.rawValue, forKey: VaultLockSettings.askKey)
        defaults.set(VaultLockSettings.Relock.whenClosed.rawValue, forKey: VaultLockSettings.relockKey)
        #expect(VaultLockSettings(defaults: defaults)
                == VaultLockSettings(requiresAuthentication: false, ask: .everyNumber, relock: .whenClosed))
    }
}

/// Turning the lock off (``VaultLockSwitch``).
@Suite struct VaultLockSwitchTests {
    @Test func theLockComesOffOnlyAfterAProofOrWhereNoneCanBeAsked() async {
        let auth = VaultFakeAuthenticator()
        #expect(await VaultLockSwitch.mayTurnOff(using: auth))
        #expect(auth.reasons == ["turn off the Vault’s lock"])
        auth.answer = .cancelled
        #expect(await VaultLockSwitch.mayTurnOff(using: auth) == false)
        auth.answer = .failed("no")
        #expect(await VaultLockSwitch.mayTurnOff(using: auth) == false)
        auth.answer = .unavailable("no password")
        #expect(await VaultLockSwitch.mayTurnOff(using: auth))
    }
}

/// A stand-in for Touch ID that answers what the test tells it to and counts the asks.
final class VaultFakeAuthenticator: VaultAuthenticating, @unchecked Sendable {
    var answer: VaultProof = .allowed
    private(set) var reasons: [String] = []
    func prove(reason: String) async -> VaultProof {
        reasons.append(reason)
        return answer
    }
}

/// The panel's rules (``VaultModel``).
@MainActor
@Suite struct VaultModelTests {
    /// A clock the test moves.
    final class Clock: @unchecked Sendable {
        var now = VaultLockTests.t0
        func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    }

    struct Rig {
        let scratch: VaultScratch
        let keychain = VaultFakeKeychain()
        let auth = VaultFakeAuthenticator()
        let clock = Clock()
        let defaults: UserDefaults
        let suite: String
        var copied: [String] { box.copied }
        final class Box: @unchecked Sendable { var copied: [String] = [] }
        let box = Box()

        init() throws {
            scratch = try VaultScratch()
            suite = "vault-model-tests-\(UUID().uuidString)"
            defaults = try #require(UserDefaults(suiteName: suite))
        }

        var store: VaultStore { VaultStore(fileURL: scratch.fileURL, keychain: keychain) }

        @MainActor func model() -> VaultModel {
            let clock = clock, box = box
            return VaultModel(store: store, authenticator: auth, defaults: defaults,
                              clock: { clock.now }, copyToPasteboard: { box.copied.append($0) })
        }

        func seed(_ entries: [VaultEntry]) throws { try store.save(entries) }
        func cleanUp() { scratch.remove(); defaults.removePersistentDomain(forName: suite) }
    }

    static let mortgage = VaultEntry(title: "Mortgage loan number", value: "0482917365", note: "Home loan servicer",
                                     kind: .home, addedAt: VaultLockTests.t0)
    static let passport = VaultEntry(title: "Passport", value: "A38291647", personID: "abhishek",
                                     kind: .identity, addedAt: VaultLockTests.t0)
    static let memberID = VaultEntry(title: "Health plan member ID", value: "XEH482917365", personID: "shweta",
                                     note: "PPO family plan", kind: .health, addedAt: VaultLockTests.t0)

    @Test func openingAsksOnceAndThenShowsNumbersInFull() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        try rig.seed([Self.mortgage, Self.passport])
        let model = rig.model()

        await model.opened()

        #expect(rig.auth.reasons == ["unlock your Vault"])
        #expect(model.isOpen)
        #expect(model.drawn(Self.mortgage) == "0482917365")
        #expect(model.selection == Self.passport.id, "the first row in list order is chosen")
    }

    @Test func aCancelledProofLeavesNamesAndEndingsOnly() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        try rig.seed([Self.mortgage])
        rig.auth.answer = .cancelled
        let model = rig.model()

        await model.opened()

        #expect(!model.isOpen)
        #expect(model.entries.map(\.title) == ["Mortgage loan number"])
        #expect(model.drawn(Self.mortgage) == "••••••7365")
        #expect(model.notice == nil, "cancelling is not an error")
        #expect(await model.copy(Self.mortgage.id) == false)
        #expect(rig.copied.isEmpty)
    }

    @Test func anEmptyVaultOpensWithoutAsking() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = rig.model()
        await model.opened()
        #expect(rig.auth.reasons.isEmpty)
        #expect(model.contents == .loaded)
        #expect(rig.keychain.adds == 0)
    }

    @Test func copyPutsTheFullNumberOnThePasteboardOnlyWhenAllowed() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        try rig.seed([Self.mortgage])
        let model = rig.model()
        await model.opened()

        #expect(await model.copy(Self.mortgage.id))
        #expect(rig.copied == ["0482917365"])
        #expect(rig.auth.reasons.count == 1, "an open Vault does not ask again to copy")
    }

    @Test func everyNumberAsksPerNumberAndHidesItAgain() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        rig.defaults.set(VaultLockSettings.Ask.everyNumber.rawValue, forKey: VaultLockSettings.askKey)
        try rig.seed([Self.mortgage, Self.passport])
        let model = rig.model()

        await model.opened()
        #expect(rig.auth.reasons.isEmpty, "nothing is asked as it opens")
        #expect(!model.canShow(Self.mortgage))

        #expect(await model.show(Self.mortgage.id))
        #expect(rig.auth.reasons == ["show Mortgage loan number"])
        #expect(model.canShow(Self.mortgage) && !model.canShow(Self.passport))

        #expect(await model.copy(Self.mortgage.id))
        #expect(rig.auth.reasons.count == 1, "the proof for a number covers copying it while it is up")

        rig.clock.advance(31)
        model.tick()
        #expect(!model.canShow(Self.mortgage))
        #expect(await model.copy(Self.passport.id))
        #expect(rig.auth.reasons.last == "copy Passport")
    }

    @Test func idleTimeLocksAndTheCountdownIsPublished() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        rig.defaults.set(VaultLockSettings.Relock.afterTwoMinutes.rawValue, forKey: VaultLockSettings.relockKey)
        try rig.seed([Self.mortgage])
        let model = rig.model()
        await model.opened()
        #expect(model.secondsLeft == 120)

        rig.clock.advance(119); model.tick()
        #expect(model.isOpen && model.secondsLeft == 1)
        rig.clock.advance(1); model.tick()
        #expect(!model.isOpen)
        #expect(model.drawn(Self.mortgage) == "••••••7365")
    }

    @Test func closingLocksAndLetsTheNumbersGo() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        try rig.seed([Self.mortgage])
        let model = rig.model()
        await model.opened()
        model.query = "mort"
        model.closed()

        #expect(model.entries.isEmpty, "a closed, locked Vault holds no numbers in memory")
        #expect(model.contents == .notLoaded)
        #expect(model.query.isEmpty)

        await model.opened()
        #expect(rig.auth.reasons.count == 2, "reopening asks again")
        #expect(model.entries == [Self.mortgage])
    }

    @Test func theMacLockingForgetsEverythingWhateverTheSetting() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        rig.defaults.set(VaultLockSettings.Relock.afterTenMinutes.rawValue, forKey: VaultLockSettings.relockKey)
        try rig.seed([Self.mortgage])
        let model = rig.model()
        await model.opened()

        model.systemLocked()
        #expect(!model.isOpen && model.entries.isEmpty)
    }

    @Test func searchMatchesNamesAndNotesButNeverTheNumber() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        try rig.seed([Self.mortgage, Self.passport, Self.memberID])
        let model = rig.model()
        await model.opened()

        model.query = "ppo"
        #expect(model.visibleRows.map(\.title) == ["Health plan member ID"])
        model.query = "  LOAN "
        #expect(model.visibleRows.map(\.title) == ["Mortgage loan number"])
        model.query = "health"
        #expect(model.visibleRows.map(\.title) == ["Health plan member ID"])
        model.query = "7365"
        #expect(model.visibleRows.isEmpty, "a search on digits would confirm a guess at a number")
        #expect(model.selection == nil)
    }

    @Test func thePersonFilterAndItsCounts() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        try rig.seed([Self.mortgage, Self.passport, Self.memberID])
        let model = rig.model()
        await model.opened()

        #expect(model.count(person: .everyone) == 3)
        #expect(model.count(person: .household) == 1)
        #expect(model.count(person: .person("shweta")) == 1)
        model.personFilter = .person("shweta")
        #expect(model.visibleRows.map(\.id) == [Self.memberID.id])
        #expect(model.selection == Self.memberID.id)
        model.personFilter = .household
        #expect(model.visibleRows.map(\.id) == [Self.mortgage.id])
    }

    @Test func theListIsOrderedByKindThenNameAndArrowsStopAtItsEnds() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        try rig.seed([Self.mortgage, Self.memberID, Self.passport])
        let model = rig.model()
        await model.opened()

        #expect(model.visibleRows.map(\.title) == ["Passport", "Health plan member ID", "Mortgage loan number"])
        model.moveSelection(by: -1)
        #expect(model.selection == Self.passport.id)
        model.moveSelection(by: 1); model.moveSelection(by: 1); model.moveSelection(by: 1)
        #expect(model.selection == Self.mortgage.id)
    }

    @Test func addingNeedsNoProofAndIsOnDiskBeforeItIsShown() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        rig.auth.answer = .cancelled
        let model = rig.model()
        await model.opened()

        let id = model.add(.init(title: "  T-Mobile account number ", value: " 948271635 ", note: "", kind: .phone))
        #expect(id != nil)
        #expect(rig.auth.reasons.isEmpty)
        #expect(model.entries.map(\.title) == ["T-Mobile account number"])
        #expect(try rig.store.load().map(\.value) == ["948271635"])
        #expect(model.selection == id)

        #expect(model.add(.init(title: "No number", value: "  ")) == nil)
        #expect(model.entries.count == 1)
    }

    @Test func aRefusedSaveKeepsTheListAsItWasAndSaysSo() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        rig.keychain.forcedAddStatus = errSecAuthFailed
        let model = rig.model()
        await model.opened()

        #expect(model.add(.init(title: "Passport", value: "A38291647")) == nil)
        #expect(model.entries.isEmpty)
        #expect(model.notice?.contains("nothing was saved") == true)
    }

    @Test func changingAndRemovingAskFirstWhenTheNumberIsHidden() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        try rig.seed([Self.mortgage, Self.passport])
        rig.auth.answer = .cancelled
        let model = rig.model()
        await model.opened()

        var draft = VaultModel.Draft(Self.mortgage)
        draft.value = "1111111111"
        #expect(await model.update(Self.mortgage.id, to: draft) == false)
        #expect(await model.delete(Self.passport.id) == false)
        #expect(try rig.store.load() == [Self.mortgage, Self.passport])

        rig.auth.answer = .allowed
        #expect(await model.update(Self.mortgage.id, to: draft))
        #expect(rig.auth.reasons.last == "change Mortgage loan number")
        rig.clock.advance(200); model.tick()   // locked again
        #expect(await model.delete(Self.passport.id))
        #expect(rig.auth.reasons.last == "remove Passport")
        #expect(try rig.store.load().map(\.value) == ["1111111111"])
    }

    @Test func aVaultThisMacCannotOpenIsShownAsThatAndLeftAlone() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        try rig.seed([Self.mortgage])
        rig.keychain.itemData = nil
        let model = rig.model()

        await model.opened()

        #expect(model.contents == .unreadable(.keyMissing))
        #expect(rig.auth.reasons.isEmpty)
        #expect(model.add(.init(title: "New", value: "1234567")) == nil)
        #expect(rig.store.hasFile)
    }

    @Test func aSettingChangedWhileItIsOpenLocksIt() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        try rig.seed([Self.mortgage])
        let model = rig.model()
        await model.opened()
        #expect(model.isOpen)

        rig.defaults.set(VaultLockSettings.Ask.everyNumber.rawValue, forKey: VaultLockSettings.askKey)
        model.settingsChanged()
        #expect(!model.isOpen)
        #expect(model.lock.settings.ask == .everyNumber)
    }

    @Test func aLockTurnedOffFromTerminalStaysOn() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        try rig.seed([Self.mortgage])
        // `defaults write … vaultRequiresAuthentication -bool NO`, with no proof and no seal.
        rig.defaults.set(false, forKey: VaultLockSettings.requiresAuthenticationKey)
        let model = rig.model()

        await model.opened()

        #expect(model.lock.settings.requiresAuthentication)
        #expect(rig.auth.reasons == ["unlock your Vault"])
        // A seal copied from another Mac, or made with another key, is no seal either.
        rig.defaults.set(String(repeating: "0", count: 64), forKey: VaultLockSwitch.sealKey)
        #expect(VaultLockSettings(defaults: rig.defaults, store: rig.store).requiresAuthentication)
    }

    @Test func withTheLockOffNothingAsksAndNumbersStayAcrossClosing() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        try rig.seed([Self.mortgage])
        // As Settings turns it off, after a proof: the setting, sealed with the Vault's key.
        VaultLockSwitch.sealOff(in: rig.defaults, store: rig.store)
        rig.defaults.set(false, forKey: VaultLockSettings.requiresAuthenticationKey)
        let model = rig.model()

        await model.opened()
        #expect(model.isOpen && rig.auth.reasons.isEmpty)
        #expect(await model.copy(Self.mortgage.id))
        model.closed()
        #expect(model.entries == [Self.mortgage])
    }

    @Test func aMacThatCannotAskSaysWhy() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        try rig.seed([Self.mortgage])
        rig.auth.answer = .unavailable("Set a login password to lock the Vault.")
        let model = rig.model()
        await model.opened()
        #expect(!model.isOpen)
        #expect(model.notice == "Set a login password to lock the Vault.")
    }
}

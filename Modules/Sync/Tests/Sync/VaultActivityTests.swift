import Foundation
import Testing
@testable import Sync

/// The activity list: what was done and to which ID by name, sealed, and never a number.
@MainActor
@Suite struct VaultActivityTests {
    typealias Rig = VaultModelTests.Rig
    static let mortgage = VaultModelTests.mortgage
    static let passport = VaultModelTests.passport

    static func rig() throws -> (rig: Rig, activity: VaultActivityStore, model: VaultModel) {
        let rig = try Rig()
        let activity = VaultActivityStore.beside(rig.store, keychain: rig.keychain)
        let clock = rig.clock, box = rig.box
        let model = VaultModel(store: rig.store, authenticator: rig.auth, defaults: rig.defaults, clock: { clock.now },
                               activity: activity, copyToPasteboard: { box.copied.append($0) })
        return (rig, activity, model)
    }

    @Test func whatIsDoneIsListedNewestFirstByNameAndOwner() async throws {
        let (rig, activity, model) = try Self.rig(); defer { rig.cleanUp() }
        try rig.seed([Self.mortgage, Self.passport])
        model.people = [Person(id: "abhishek", displayName: "Anna")]
        await model.opened()
        rig.clock.advance(1)
        #expect(await model.copy(Self.passport.id))
        rig.clock.advance(1)
        var draft = VaultModel.Draft(Self.mortgage)
        draft.note = "Refinanced"
        #expect(await model.update(Self.mortgage.id, to: draft))
        rig.clock.advance(1)
        #expect(await model.delete(Self.passport.id))

        #expect(activity.load().map(\.line) == ["Removed Passport · Anna", "Edited Mortgage loan number · Household",
                                                "Copied Passport · Anna", "Unlocked"])
    }

    @Test func aRefusedProofIsListedThoughNothingOpened() async throws {
        let (rig, activity, model) = try Self.rig(); defer { rig.cleanUp() }
        try rig.seed([Self.mortgage])
        rig.auth.answer = .cancelled
        await model.opened()
        #expect(model.isSealedShut)
        #expect(activity.load().map(\.line) == ["Proof refused: unlock your Vault"])
    }

    @Test func theListIsSealedAndHoldsNoNumberEvenFromATitleTypedWithOne() async throws {
        let (rig, activity, model) = try Self.rig(); defer { rig.cleanUp() }
        await model.opened()
        let id = try #require(model.add(VaultModel.Draft(title: "Chase card 4417 9921 0038 5512", value: "4417 9921 0038 5512", category: .other)))
        #expect(await model.copy(id))
        let events = activity.load()
        #expect(events.count == 2, "\(events.map(\.line))")
        for event in events {
            #expect(!event.what.contains("4417") && !event.what.contains("9921"), "a number typed into a title is cut to its ending: \(event.what)")
        }
        let sealed = try Data(contentsOf: activity.fileURL)
        let text = String(decoding: sealed, as: UTF8.self)
        #expect(sealed.prefix(8) == Data("SCVACTV1".utf8))
        #expect(!text.contains("Chase") && !text.contains("Copied"), "which IDs were used is private too")
    }

    @Test func turnedOffNothingIsListed() async throws {
        let (rig, activity, model) = try Self.rig(); defer { rig.cleanUp() }
        rig.defaults.set(false, forKey: VaultActivitySettings.keepsKey)
        try rig.seed([Self.mortgage])
        await model.opened()
        #expect(await model.copy(Self.mortgage.id))
        #expect(activity.load().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: activity.fileURL.path))
    }

    @Test func theListIsBoundedInCountAndAge() throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        try rig.seed([Self.mortgage])   // makes the key the list is sealed with
        let activity = VaultActivityStore.beside(rig.store, keychain: rig.keychain)
        let now = VaultLockTests.t0
        let old = VaultActivityEvent(at: now.addingTimeInterval(-91 * 86_400), kind: .copied, what: "Old")
        let many = (0..<(VaultActivityStore.limit + 20)).map { VaultActivityEvent(at: now.addingTimeInterval(Double(-$0)), kind: .copied, what: "\($0)") }
        activity.append([old] + many, now: now)
        let kept = activity.load()
        #expect(kept.count == VaultActivityStore.limit)
        #expect(kept.first?.what == "0" && !kept.contains { $0.what == "Old" }, "the newest, and nothing past ninety days")
        // Each bound alone (VT95): under the count, one past ninety days goes and one within stays.
        activity.clear()
        activity.append([VaultActivityEvent(at: now.addingTimeInterval(-91 * 86_400), kind: .copied, what: "Past"),
                         VaultActivityEvent(at: now.addingTimeInterval(-86_400), kind: .copied, what: "Within")], now: now)
        #expect(activity.load().map(\.what) == ["Within"], "the age bound held only because the count did")
        // And on what was stored: ninety-one days on, "Within" is past it.
        let later = now.addingTimeInterval(91 * 86_400)
        activity.append([VaultActivityEvent(at: later, kind: .unlocked)], now: later)
        #expect(activity.load().map(\.what) == [""], "a stored event outlived ninety days")
        activity.clear()
        #expect(activity.load().isEmpty)
    }

    @Test func aVaultWithNoKeyKeepsNoListAndMakesNoKey() throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let activity = VaultActivityStore.beside(rig.store, keychain: rig.keychain)
        activity.append([VaultActivityEvent(at: VaultLockTests.t0, kind: .unlocked)], now: VaultLockTests.t0)
        #expect(rig.keychain.itemData == nil, "listing activity never makes the Vault's key")
        #expect(activity.load().isEmpty)
    }

    @Test func aKindALaterBuildWroteIsKeptAndListedByItsWords() throws {
        let json = #"[{"id":"00000000-0000-0000-0000-000000000001","at":"2026-11-20T10:00:00Z","kind":"teleported","what":"Moved somewhere new"}]"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let events = try decoder.decode([VaultActivityEvent].self, from: Data(json.utf8))
        #expect(events.first?.kind == .other && events.first?.line == "Moved somewhere new")
    }
}

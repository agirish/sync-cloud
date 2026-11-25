import Foundation
import Testing
@testable import Sync

/// The lock as one table (VT29): every Ask × Relock setting, each event the Vault meets (open, use,
/// idle past the limit, close, reopen, sleep, Lock Now, a proof answered after a lock), and what
/// it leaves: whether the Vault is open, whether its numbers are in memory, and how many proofs
/// were asked. Each row starts from a fresh Vault holding one made-up ID, or (VT60) from an empty
/// one the ID is typed into.
@MainActor
@Suite struct VaultLockTableTests {
    enum Event: CaseIterable { case open, use, idle, close, reopen, sleep, lockNow, proofAfterLock }

    struct Outcome: Equatable, CustomStringConvertible {
        var open: Bool
        var loaded: Bool
        var proofs: Int
        var description: String { "open \(open), loaded \(loaded), \(proofs) proof(s)" }
    }

    /// What the settings say each event leaves, from their own rules: only "As soon as Vault
    /// opens" opens the whole Vault, and asks as it opens; "For every number" loads the list and
    /// asks per number, never at opening; idle locks after the limit, closing locks unless "even
    /// if closed", and sleep and Lock Now lock whatever the setting. A locked Vault under "As
    /// soon as Vault opens" lets its numbers go; under "For every number" Lock Now leaves the list.
    /// Each setting's idle limit and whether closing locks, as Settings ▸ Vault words them: written
    /// out here, not read from the settings, so a rule changed there shows as a red row.
    static let rules: [VaultLockSettings.Relock: (limit: TimeInterval?, locksOnClose: Bool)] = [
        .whenClosed: (nil, true), .afterOneMinute: (60, true), .afterTwoMinutes: (120, true),
        .afterFiveMinutes: (300, true), .afterTenMinutes: (600, false),
    ]

    static func expected(_ ask: VaultLockSettings.Ask, _ relock: VaultLockSettings.Relock, _ event: Event) -> Outcome {
        let rule = rules[relock]!
        let whole = ask == .whenOpened
        let asked = whole ? 1 : 0
        switch event {
        case .open, .use:
            return Outcome(open: whole, loaded: true, proofs: asked)
        case .idle:
            let stays = whole && rule.limit == nil
            return Outcome(open: stays, loaded: !whole || stays, proofs: asked)
        case .close:
            let stays = whole && !rule.locksOnClose
            return Outcome(open: stays, loaded: stays, proofs: asked)
        case .reopen:
            return Outcome(open: whole, loaded: true, proofs: whole ? (rule.locksOnClose ? 2 : 1) : 0)
        case .sleep:
            return Outcome(open: false, loaded: false, proofs: asked)
        case .lockNow:
            return Outcome(open: false, loaded: !whole, proofs: asked)
        case .proofAfterLock:
            // The proof asked as it opens, or for one number, is answered after the Mac locked:
            // nothing opens, nothing is shown, and the numbers are let go.
            return Outcome(open: false, loaded: false, proofs: 1)
        }
    }

    /// A sitting that starts with nothing sealed (VT60), where the passport is typed in after the
    /// Vault opens. It opens without asking, as there is nothing to guard, and the typed ID stays
    /// in memory while the panel is up: idle and Lock Now leave it, since the lock hides
    /// everything only when something was sealed as the panel opened. Closing, sleep and a late
    /// proof let it go whatever the setting, "even if closed" too; reopening finds it sealed, so
    /// the Vault asks as its setting says.
    static func expectedFromEmpty(_ ask: VaultLockSettings.Ask, _ event: Event) -> Outcome {
        let whole = ask == .whenOpened
        switch event {
        case .open, .use, .idle, .lockNow:
            return Outcome(open: false, loaded: true, proofs: 0)
        case .close, .sleep:
            return Outcome(open: false, loaded: false, proofs: 0)
        case .reopen:
            return Outcome(open: whole, loaded: true, proofs: whole ? 1 : 0)
        case .proofAfterLock:
            return Outcome(open: false, loaded: false, proofs: 1)
        }
    }

    /// Answers yes, but locks the Vault while it is asked, as sleep can.
    final class LocksWhileAsked: VaultAuthenticating, @unchecked Sendable {
        weak var model: VaultModel?
        private(set) var asked = 0
        func prove(reason: String) async -> VaultProof {
            asked += 1
            await MainActor.run { model?.systemLocked() }
            return .allowed
        }
    }

    func outcome(_ ask: VaultLockSettings.Ask, _ relock: VaultLockSettings.Relock, _ event: Event,
                 fromEmpty: Bool = false) async throws -> Outcome {
        let rig = try VaultRig(); defer { rig.cleanUp() }
        rig.defaults.set(ask.rawValue, forKey: VaultLockSettings.askKey)
        rig.defaults.set(relock.rawValue, forKey: VaultLockSettings.relockKey)
        let passport = VaultEntry(title: "Passport", value: "Z0000009", personID: "anna", addedAt: VaultRig.t0)
        if !fromEmpty { try rig.seed([passport]) }
        /// Opened, and from empty the passport typed in: its id.
        func open(_ model: VaultModel) async throws -> UUID {
            await model.opened()
            guard fromEmpty else { return passport.id }
            return try #require(model.add(VaultModel.Draft(passport)))
        }
        if event == .proofAfterLock {
            let auth = LocksWhileAsked()
            let model = VaultModel(store: rig.store, authenticator: auth, defaults: rig.defaults,
                                   clock: { [clock = rig.clock] in clock.now }, copyToPasteboard: { _ in })
            auth.model = model
            let id = try await open(model)
            // Under "For every number", or from empty (nothing is asked as it opens), the proof is
            // the number's own: asked as it is shown.
            if model.contents == .loaded { #expect(await model.show(id) == false) }
            return Outcome(open: model.isOpen, loaded: model.contents == .loaded, proofs: auth.asked)
        }
        let model = rig.model()
        _ = try await open(model)
        let limit = Self.rules[relock]!.limit ?? 3600
        switch event {
        case .open, .proofAfterLock: break
        case .use:
            // Used just before the limit: the count starts again, so as long again is still open.
            rig.clock.advance(limit * 0.9); model.panelActivity(); model.tick()
            rig.clock.advance(limit * 0.9); model.tick()
        case .idle:
            rig.clock.advance(limit + 1); model.tick()
        case .close:
            model.closed()
        case .reopen:
            model.closed()
            rig.clock.advance(5)
            await model.opened()
        case .sleep:
            model.systemLocked()
        case .lockNow:
            model.lockNow()
        }
        return Outcome(open: model.isOpen, loaded: model.contents == .loaded, proofs: rig.auth.reasons.count)
    }

    @Test func everySettingMeetsEveryEventAsItsRulesSay() async throws {
        var rows = 0
        for ask in VaultLockSettings.Ask.allCases {
            for relock in VaultLockSettings.Relock.allCases {
                for event in Event.allCases {
                    let got = try await outcome(ask, relock, event)
                    #expect(got == Self.expected(ask, relock, event), "\(ask) · \(relock) · \(event): \(got)")
                    rows += 1
                }
            }
        }
        #expect(rows == 2 * 5 * 8)
    }

    @Test func aSittingThatStartsWithNothingSealedMeetsEveryEventAsItsRulesSay() async throws {
        var rows = 0
        for ask in VaultLockSettings.Ask.allCases {
            for relock in VaultLockSettings.Relock.allCases {
                for event in Event.allCases {
                    let got = try await outcome(ask, relock, event, fromEmpty: true)
                    #expect(got == Self.expectedFromEmpty(ask, event), "from empty · \(ask) · \(relock) · \(event): \(got)")
                    rows += 1
                }
            }
        }
        #expect(rows == 2 * 5 * 8)
    }
}

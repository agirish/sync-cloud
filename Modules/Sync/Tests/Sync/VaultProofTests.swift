import Foundation
import Testing
@testable import Sync

/// The proof and the lock: what a late answer, a lock or a close leaves open.
@MainActor
@Suite struct VaultProofTests {
    typealias Rig = VaultModelTests.Rig
    typealias InterruptingProof = VaultFixtures.InterruptingProof

    @Test func removingWhileThePanelClosesUnderTheProofNeverEmptiesTheVault() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        VaultFixtures.everyNumber(rig)
        try rig.seed([VaultModelTests.mortgage, VaultModelTests.passport])
        let proof = InterruptingProof()
        let model = VaultFixtures.model(rig, proof: proof)
        await model.opened()
        proof.during = { model.closed() }

        let removed = await model.delete(VaultModelTests.mortgage.id)

        #expect(!removed)
        #expect(try rig.store.load().count == 2, "the Vault on disk lost what it held")
    }

    @Test func changingWhileThePanelClosesUnderTheProofChangesNothing() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        VaultFixtures.everyNumber(rig)
        try rig.seed([VaultModelTests.mortgage])
        let proof = InterruptingProof()
        let model = VaultFixtures.model(rig, proof: proof)
        await model.opened()
        proof.during = { model.closed() }

        let changed = await model.update(VaultModelTests.mortgage.id,
                                         to: VaultModel.Draft(title: "Loan", value: "1111222233"))

        #expect(!changed)
        #expect(try rig.store.load().map(\.value) == ["0482917365"])
    }

    @Test func aProofAnsweredAfterThePanelClosedLeavesTheVaultLocked() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        // Closing does not lock under this setting, so only the late answer could open it.
        rig.defaults.set(VaultLockSettings.Relock.afterTenMinutes.rawValue, forKey: VaultLockSettings.relockKey)
        try rig.seed([VaultModelTests.passport])
        let proof = InterruptingProof()
        let model = VaultFixtures.model(rig, proof: proof, copied: rig.box)
        proof.during = { model.closed() }
        await model.opened()
        #expect(!model.isOpen, "an answer given after the panel closed opened the Vault")
    }

    @Test func aProofAnsweredAfterLockNowCopiesNothing() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        rig.defaults.set(VaultLockSettings.Ask.everyNumber.rawValue, forKey: VaultLockSettings.askKey)
        try rig.seed([VaultModelTests.passport])
        let proof = InterruptingProof()
        let model = VaultFixtures.model(rig, proof: proof, copied: rig.box)
        await model.opened()
        proof.during = { model.lockNow() }
        let copied = await model.copy(VaultModelTests.passport.id)
        #expect(!copied)
        #expect(rig.copied.isEmpty)
    }

    @Test func typingInTheEditorKeepsTheNumberShownPastItsThirtySeconds() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        rig.defaults.set(VaultLockSettings.Ask.everyNumber.rawValue, forKey: VaultLockSettings.askKey)
        try rig.seed([VaultModelTests.passport])
        let model = rig.model()
        await model.opened()
        #expect(await model.show(VaultModelTests.passport.id))
        rig.clock.advance(25)
        model.noteActivity()
        rig.clock.advance(20)
        model.tick()
        #expect(model.canShow(VaultModelTests.passport), "the editor's number was taken away mid-edit")
        rig.clock.advance(31)
        model.tick()
        #expect(!model.canShow(VaultModelTests.passport), "left alone, it hides again")
    }
}

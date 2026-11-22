import AppKit
import SwiftUI
import Sync
import Testing
@testable import SyncCloud

/// Locked means locked, as the panel draws it. Every ID is made up.
@MainActor
@Suite struct VaultSealedShutPanelTests {
    @Test func aLockedPanelDrawsItsLockAndNoCardRowOrEnding() async throws {
        let rig = try await VaultPanelRenderTests.rig(); defer { rig.cleanUp() }
        let open = try VaultPanelRenderTests.render(rig.model, defaults: rig.defaults, name: "sealed-open")
        #expect(try pixels(near: VaultPanelRenderTests.wash(.blue), in: open) > 1500, "open: the cards are drawn")

        // Closed and opened again with the proof refused: what was sealed is behind the lock.
        rig.model.closed()
        rig.proof.answer = .cancelled
        await rig.model.opened()
        #expect(rig.model.isSealedShut && rig.model.rows.isEmpty)
        let locked = try VaultPanelRenderTests.render(rig.model, defaults: rig.defaults, name: "sealed-locked")
        for tint in [VaultTint.blue, .violet, .rose, .green] {
            #expect(try pixels(near: VaultPanelRenderTests.wash(tint), in: locked) < 50, "locked: no \(tint) card is drawn")
        }
        #expect(differingPixels(open, locked) > 100_000, "another screen altogether")
        // Unlocking from here is the model's (VaultSealedShutTests in Sync): a hosted panel that goes
        // away closes its Vault, which would race a proof asked for here.
    }

    @Test func aRowOfAKindWhoseEndingIsASecretIsSpokenWithoutIt() {
        #expect(VaultMask.spoken("123-45-6789", shown: false, hidesEnding: true) == "")
        #expect(VaultMask.spoken("123-45-6789", shown: false) == "ending 6 7 8 9")
        #expect(VaultMask.spoken("123-45-6789", shown: true, hidesEnding: true) == "1 2 3 4 5 6 7 8 9")
    }
}

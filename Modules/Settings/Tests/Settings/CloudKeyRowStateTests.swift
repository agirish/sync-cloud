import Testing
import Foundation
import Security
@testable import Settings

/// Pins the Anthropic key row's four states and what each one offers.
///
/// The old row had three controls and no states: one `SecureField` whose placeholder flipped to
/// "•••• key saved", with Save / Test / Clear. Replacing a key worked — type a new one, press
/// Save — but nothing said so, and `Clear` (which deletes) was the only labelled way out. The
/// states are the fix, so they are what is worth asserting.
@Suite struct CloudKeyRowStateTests {

    @Test func noStoredKeyIsTheEntryField() {
        let state = CloudKeyRowState.resolve(hasStoredKey: false, isRevealed: false, isReplacing: false)

        #expect(state == .empty)
        #expect(state.isEntry)
        #expect(!state.offersRemove, "there is nothing to remove")
        #expect(!state.offersCopy)
    }

    @Test func aStoredKeyRestsMasked() {
        let state = CloudKeyRowState.resolve(hasStoredKey: true, isRevealed: false, isReplacing: false)

        #expect(state == .stored)
        #expect(!state.isEntry)
        #expect(!state.showsSecret, "the resting state must never put the key on screen")
        #expect(state.offersRemove)
        #expect(!state.offersCopy, "nothing to copy while the key is hidden")
    }

    @Test func revealingShowsTheSecretAndOffersCopy() {
        let state = CloudKeyRowState.resolve(hasStoredKey: true, isRevealed: true, isReplacing: false)

        #expect(state == .revealed)
        #expect(state.showsSecret)
        #expect(state.offersCopy)
        #expect(state.offersRemove)
    }

    /// The whole point of Replace…: it is a mode, entered on purpose, with a way back out —
    /// not an unlabelled side-effect of typing into a field that looked empty.
    @Test func replacingIsTheEntryFieldEvenThoughAKeyIsStored() {
        let state = CloudKeyRowState.resolve(hasStoredKey: true, isRevealed: false, isReplacing: true)

        #expect(state == .replacing)
        #expect(state.isEntry)
        #expect(!state.offersRemove, "Cancel is the way out of entry, not Remove")
    }

    /// Replacing wins over a revealed key. Reveal then Replace… must not leave the old secret on
    /// screen underneath the field the user is about to type the new one into.
    @Test func replacingWinsOverAReveal() {
        let state = CloudKeyRowState.resolve(hasStoredKey: true, isRevealed: true, isReplacing: true)

        #expect(state == .replacing)
        #expect(!state.showsSecret)
    }

    /// A stale `isRevealed` cannot resurrect a key that is no longer stored — Remove clears both
    /// flags, but the resolution must not depend on that having happened in the right order.
    @Test func revealCannotOutliveTheStoredKey() {
        let state = CloudKeyRowState.resolve(hasStoredKey: false, isRevealed: true, isReplacing: false)

        #expect(state == .empty)
        #expect(!state.showsSecret)
    }

    /// **A refused Save keeps the typed key in the field (FR58)** — the field was cleared whatever
    /// the status, so the only copy of the new key went with the refusal. Replacing stays in entry
    /// mode, or the stored key's row would hide the field. A landed Save still clears it.
    @Test func aRefusedSaveKeepsTheTypedKeyAndTheField() throws {
        let refused = CloudKeyRow.afterSave(typed: "sk-ant-new", status: errSecInteractionNotAllowed,
                                            stored: true, wasReplacing: true)
        #expect(refused.field == "sk-ant-new", "a refused Save cleared the typed key")
        #expect(refused.isReplacing, "a refused replace left entry mode and hid the field")
        #expect(refused.failure?.contains("refused to store the key") == true)

        // `errSecSuccess` with no item to show for it is a refusal too.
        let unconfirmed = CloudKeyRow.afterSave(typed: "sk-ant-new", status: errSecSuccess,
                                                stored: false, wasReplacing: false)
        #expect(unconfirmed.field == "sk-ant-new")
        #expect(unconfirmed.failure != nil)

        let landed = CloudKeyRow.afterSave(typed: "sk-ant-new", status: errSecSuccess,
                                           stored: true, wasReplacing: true)
        #expect(landed.field == "")
        #expect(!landed.isReplacing)
        #expect(landed.failure == nil)

        // The half that connects the shipping Save to the rule: a Button's action is unreachable.
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Settings/CloudKeyRow.swift"), encoding: .utf8)
        #expect(source.contains("let after = Self.afterSave(typed: apiKeyField"),
                "Save no longer decides what to show through `afterSave`")
        #expect(source.contains("apiKeyField = after.field"), "Save no longer keeps the field by `afterSave`")
    }
}

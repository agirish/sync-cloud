import Foundation
import Testing
@testable import Settings

/// Removing the API key asks first: Remove deletes the Keychain item, which nothing in SyncCloud
/// can read back. Pinned on the static gate, since a button's closure can't be reached from a
/// test; the last test holds the button to its gate.
@MainActor
@Suite struct IrreversibleClearsAskFirstTests {

    @Test func decliningRemoveKeepsTheKey() {
        var asked = 0
        var removed = 0
        let done = CloudKeyRow.removeIfConfirmed(confirm: { asked += 1; return false },
                                                 remove: { removed += 1 })
        #expect(!done)
        #expect(asked == 1, "Remove did not ask")
        #expect(removed == 0, "a declined Remove deleted the key")
    }

    @Test func confirmingRemoveDeletesAfterAsking() {
        var order: [String] = []
        let done = CloudKeyRow.removeIfConfirmed(confirm: { order.append("ask"); return true },
                                                 remove: { order.append("remove") })
        #expect(done)
        #expect(order == ["ask", "remove"], "the key went before the question: \(order)")
    }

    /// The question names what is lost, and the button says the verb.
    @Test func theRemovePromptSaysWhatIsLost() {
        let prompt = CloudKeyRow.removePrompt
        #expect(prompt.informativeText.contains("Keychain"))
        #expect(prompt.informativeText.contains("can’t be undone"))
        #expect(prompt.confirmTitle == "Remove Key")
    }

    /// Each button goes through its gate. Scanned, not driven, because a SwiftUI `Button`'s action
    /// can't be reached from a test; this connects the shipping button to the decisions above.
    @Test func everyIrreversibleClearGoesThroughItsGate() throws {
        let keyRow = try repoSource("Modules/Settings/Sources/Settings/CloudKeyRow.swift")
        #expect(keyRow.contains("Self.removeIfConfirmed(confirm: confirmRemoveKey, remove: removeKey)"),
                "Remove no longer asks through `removeIfConfirmed`")
        #expect(!keyRow.contains("Button(\"Remove\", action: removeKey)"),
                "Remove deletes the key on one click again")
    }
}

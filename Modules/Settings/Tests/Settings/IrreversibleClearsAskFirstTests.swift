import Foundation
import Testing
@testable import Settings

/// Removing the API key, and both spend Clears, ask first.
///
/// **Each one acted on a single click.** Remove deleted the Keychain item, which nothing in
/// SyncCloud can read back; Clear (Settings ▸ Intelligence) and Clear History (the Organize lens's
/// spend sheet) reset what both budget caps count against, the $5 backstop included. Sync History's
/// Clear History was the only one of the kind that asked.
///
/// The decisions are pinned on the static gates — a button's closure cannot be reached from a test
/// — and the last test holds each button to its gate, so a revert cannot leave the gates tested
/// and unused.
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

    /// **Each button goes through its gate.** Scanned rather than driven: a SwiftUI `Button`'s
    /// action cannot be reached from a test, and this is the half that connects the shipping
    /// button to the decision tested above.
    @Test func everyIrreversibleClearGoesThroughItsGate() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        func source(_ path: String) throws -> String {
            let text = try #require(
                try? String(contentsOf: repo.appendingPathComponent(path), encoding: .utf8),
                "cannot read \(path) — the checks below would be vacuous")
            try #require(text.count > 1_000, "\(path) is implausibly short")
            return text
        }

        let keyRow = try source("Modules/Settings/Sources/Settings/CloudKeyRow.swift")
        #expect(keyRow.contains("Self.removeIfConfirmed(confirm: confirmRemoveKey, remove: removeKey)"),
                "Remove no longer asks through `removeIfConfirmed`")
        #expect(!keyRow.contains("Button(\"Remove\", action: removeKey)"),
                "Remove deletes the key on one click again")

        // Both spend Clears, and no unasked clear anywhere else in the app.
        let settings = try source("Modules/Settings/Sources/Settings/SettingsView.swift")
        let lensSheet = try source("Modules/FileExplorer/Sources/FileExplorer/FilingSpendHistoryView.swift")
        #expect(settings.contains("FilingSpendStore.clearIfConfirmed("),
                "Settings ▸ Intelligence's Clear no longer asks")
        #expect(lensSheet.contains("FilingSpendStore.clearIfConfirmed"),
                "the Organize lens's Clear History no longer asks")
        for (name, text) in [("SettingsView.swift", settings), ("FilingSpendHistoryView.swift", lensSheet)] {
            #expect(!text.contains("FilingSpendStore.clear()"),
                    "\(name) clears the spend without asking")
        }
    }
}

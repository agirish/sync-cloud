import Testing
import Foundation
@testable import SyncCloud

/// `AskClaudeSpend.didChange` is posted wherever a cost is recorded, and Organize's Refine records
/// its costs off the main thread. Every view that listens hops to the main run loop before it
/// writes its state.
@Suite struct SpendNotificationWiringTests {

    @Test func everySpendListenerHopsToTheMainThread() throws {
        let sources = [
            try macAppFile("AskClaude/AskClaudePanel.swift"),
            try repoFile("Modules/Settings/Sources/Settings/SettingsView.swift"),
        ]
        var listeners = 0
        for source in sources {
            let code = sourceCodeOnly(source)
            var rest = Substring(code)
            while let found = rest.range(of: "publisher(for: AskClaudeSpend.didChange)") {
                listeners += 1
                let after = rest[found.upperBound...].prefix(60).trimmingCharacters(in: .whitespacesAndNewlines)
                #expect(after.hasPrefix(".receive(on: RunLoop.main)") || after.hasPrefix(".receive(on: DispatchQueue.main)"),
                        "a spend listener writes its state on the posting thread: \(after)")
                rest = rest[found.upperBound...]
            }
        }
        #expect(listeners == 2, "the scan found \(listeners) listeners; a new or renamed one needs adding here")
    }
}

/// A button under Claude's question and a card's Next answer Claude: their words go to Claude and
/// are never tried as a command on this Mac, where "Into Documents" could become a go-to.
@Suite struct AnswerButtonsGoToClaudeTests {
    @Test func aButtonsWordsSkipTheOnDeviceLane() throws {
        let code = sourceCodeOnly(try macAppFile("ContentView+AskClaude.swift"))
        for anchor in ["onChoice:", "case .next:"] {
            let start = try #require(code.range(of: anchor), "no \(anchor) in the panel's wiring")
            let body = code[start.upperBound...].prefix(400)
            let send = try #require(body.range(of: "askClaudeSend("), "\(anchor) no longer sends")
            let call = body[send.lowerBound...].prefix { $0 != "\n" }
            #expect(call.contains("typed: false") && !call.contains("onDevice: true"), "\(anchor): \(call)")
        }
    }
}

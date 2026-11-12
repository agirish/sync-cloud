import AppKit
import Foundation
import SwiftUI
import Sync
import Testing
@testable import SyncCloud

/// The chip above Ask Claude's box (TE309), in the panel: shown from local facts, sent only on a
/// click, as a starter is, and remembered in the chat's own defaults.
@MainActor
@Suite(.serialized) struct AskClaudeSuggestionChipTests {

    final class Sent { var questions: [String] = [] }

    private let question = "Sum up Compare’s 7 differences by kind and folder"

    private func rig(_ chat: AskClaudeChat, _ sent: Sent) -> AskClaudePanelRig {
        let sources = AskClaudeSuggestionSources(
            workspace: "Compare", comparison: .init(count: 7, scannedAt: Date().addingTimeInterval(-60), hidden: false))
        return AskClaudePanelRig(chat: chat, onAsk: { sent.questions.append($0) }, topLeading: true, parked: true,
                                 suggestions: sources)
    }

    /// Clicks up the left of the column from just above the text box, where the chip sits, until
    /// something is sent. Never below the box: the model menu there opens a pop-up on screen.
    private func clickAboveTheBox(_ rig: AskClaudePanelRig, sent: () -> Bool) async -> Bool {
        // Buried under every window, so nothing it opens can show over his; ordered in, never
        // made key: a key test window takes key from other suites' panels.
        rig.window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.minimumWindow)))
        rig.window.orderFrontRegardless()
        defer { rig.window.orderOut(nil) }
        for _ in 0..<10 { try? await Task.sleep(for: .milliseconds(10)); rig.host.layoutSubtreeIfNeeded() }
        guard let field = rig.field else { return false }
        let top = field.convert(field.bounds, to: nil).maxY
        for y in stride(from: top + 8, through: top + 60, by: 3) {
            let point = NSPoint(x: 40, y: y)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                     timestamp: ProcessInfo.processInfo.systemUptime,
                                                     windowNumber: rig.window.windowNumber, context: nil,
                                                     eventNumber: 0, clickCount: 1, pressure: 1) else { continue }
                rig.window.sendEvent(event)
            }
            try? await Task.sleep(for: .milliseconds(10))
            if sent() { return true }
        }
        return false
    }

    @Test func aFreshScansChipSendsItsQuestionOnlyWhenClickedAndThenStepsAside() async {
        let defaults = ScratchDefaults("AskClaudeSuggestionChipTests")
        let chat = AskClaudeChat(defaults: defaults, readKey: { nil })
        // A chat under way: an empty one shows the suggestion as its first starter instead.
        chat.addNote("Earlier in this chat")
        let sent = Sent()
        let rig = rig(chat, sent)
        for _ in 0..<10 { try? await Task.sleep(for: .milliseconds(10)); rig.host.layoutSubtreeIfNeeded() }
        #expect(sent.questions.isEmpty, "nothing is sent before a click")
        #expect(await clickAboveTheBox(rig) { !sent.questions.isEmpty })
        #expect(sent.questions == [question])
        #expect(chat.recallOlder(than: "") == question, "a click is remembered as a typed question is")
        let memory = AskClaudeSuggestions.Memory.load(defaults)
        #expect(memory.seen["compare"]?.putAwayAt == 7, "remembered in the chat's defaults, not his live ones")
        // Clicked, the same scan offers nothing more.
        sent.questions = []
        #expect(await clickAboveTheBox(rig) { !sent.questions.isEmpty } == false)
    }

    @Test func withSuggestionsOffThereIsNoChip() async {
        let defaults = ScratchDefaults("AskClaudeSuggestionChipTests")
        defaults.set(false, forKey: AskClaudeSuggestions.enabledKey)
        let chat = AskClaudeChat(defaults: defaults, readKey: { nil })
        chat.addNote("Earlier in this chat")
        let sent = Sent()
        let rig = rig(chat, sent)
        #expect(rig.field != nil, "the text box the clicks are placed from")
        #expect(await clickAboveTheBox(rig) { !sent.questions.isEmpty } == false)
    }

    /// In a new chat the chip stays away and its question leads the starters instead, remembered
    /// on a click as the chip's own is (TE347b, B-R8).
    @Test func aNewChatLeadsItsStartersWithTheSuggestion() async {
        let defaults = ScratchDefaults("AskClaudeSuggestionChipTests")
        let chat = AskClaudeChat(defaults: defaults, readKey: { nil })
        let sent = Sent()
        let rig = rig(chat, sent)
        #expect(await clickAboveTheBox(rig) { !sent.questions.isEmpty } == false, "no chip above the box")
        rig.window.orderFrontRegardless()
        defer { rig.window.orderOut(nil) }
        // Down the thread from under the header: the first thing that sends is the first starter.
        for y in stride(from: 60.0, through: 320.0, by: 3) where sent.questions.isEmpty {
            let point = NSPoint(x: 60, y: rig.host.bounds.height - y)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                     timestamp: ProcessInfo.processInfo.systemUptime,
                                                     windowNumber: rig.window.windowNumber, context: nil,
                                                     eventNumber: 0, clickCount: 1, pressure: 1) else { continue }
                rig.window.sendEvent(event)
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(sent.questions == [question])
        #expect(AskClaudeSuggestions.Memory.load(defaults).seen["compare"]?.putAwayAt == 7)
    }
}

import AppKit
import Foundation
import SwiftUI
import Sync
import Testing
@testable import SyncCloud

/// A question typed while Claude answers waits, one at a time, and goes when the answer ends (not
/// after a Stop or a problem), carrying its own text and chips.
@MainActor
@Suite struct AskClaudeQueueTests {

    private let screen = AskClaudeScreen(workspace: "Browse", source: "iCloud", folder: "", sort: "Name", rows: [],
                                         selection: [], toolsAvailable: true)
    private static let receipt = AskClaudeChat.Attachment(path: "/Docs/Receipt.pdf", name: "Receipt.pdf", isDirectory: false)
    private static let lease = AskClaudeChat.Attachment(path: "/Docs/Lease.pdf", name: "Lease.pdf", isDirectory: false)

    /// A chat whose answers wait for `gate`, and whose queued questions are asked as the window
    /// asks them, recorded in `sent`.
    private func chat(_ d: UserDefaults, gate: Gate, key: String? = "k", keyChanges: NotificationCenter = NotificationCenter())
        -> (AskClaudeChat, Box<[AskClaudeChat.Queued]>) {
        let chat = AskClaudeChat(defaults: d, makeEngine: { AskClaudeEngine(transport: GatedTransport(gate: gate), defaults: d) },
                                 readKey: { key }, keyChanges: keyChanges)
        let sent = Box<[AskClaudeChat.Queued]>([])
        chat.sendQueued = { [weak chat] waiting in
            sent.value.append(waiting)
            chat?.ask(waiting.text, screen: screen, tools: NoTools())
        }
        return (chat, sent)
    }

    @Test func aQuestionTypedWhileClaudeAnswersGoesWhenTheAnswerEnds() async {
        let gate = Gate()
        let (chat, sent) = chat(ScratchDefaults("AskClaudeQueueTests"), gate: gate)
        chat.ask("Find my latest I-797", screen: screen, tools: NoTools())
        chat.attach([Self.receipt])
        chat.queue("open it in Preview", spoken: false)
        // The chips go with it, and the box is clear for the next one.
        #expect(chat.queued == AskClaudeChat.Queued(text: "open it in Preview", attachments: [Self.receipt], spoken: false))
        #expect(chat.attachments.isEmpty)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(sent.value.isEmpty, "sent before the answer ended")
        gate.open = true
        await waitUntil("the queued question goes", timeout: 30) { !sent.value.isEmpty }
        await waitUntilIdle(chat)
        #expect(sent.value == [AskClaudeChat.Queued(text: "open it in Preview", attachments: [Self.receipt], spoken: false)])
        #expect(chat.queued == nil)
        #expect(chat.items.filter { if case .user = $0.kind { true } else { false } }.map(\.kind)
                == [.user("Find my latest I-797"), .user("open it in Preview")])
    }

    /// Only one question waits: a second Return joins it on its own line, with its chips.
    @Test func aSecondQuestionJoinsTheFirst() {
        let (chat, _) = chat(ScratchDefaults("AskClaudeQueueTests"), gate: Gate())
        chat.ask("one", screen: screen, tools: NoTools())
        chat.attach([Self.receipt])
        chat.queue("open it", spoken: true)
        chat.attach([Self.receipt, Self.lease])
        chat.queue("and tell me when it expires", spoken: false)
        #expect(chat.queued == AskClaudeChat.Queued(text: "open it\nand tell me when it expires",
                                                    attachments: [Self.receipt, Self.lease], spoken: false))
        chat.stop()
    }

    /// Stop ends the answer and the question stays, unsent, until they say: Send, Edit or Cancel.
    @Test func stopKeepsItUnsent() async {
        let (chat, sent) = chat(ScratchDefaults("AskClaudeQueueTests"), gate: Gate())
        chat.ask("one", screen: screen, tools: NoTools())
        chat.queue("two", spoken: false)
        chat.stop()
        await waitUntilIdle(chat)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(sent.value.isEmpty)
        #expect(chat.queued?.text == "two")
        chat.sendQueuedNow()
        #expect(sent.value.map(\.text) == ["two"])
        #expect(chat.queued == nil)
        chat.stop()
    }

    /// A problem keeps it too: with no key, the same problem would meet it.
    @Test func aProblemKeepsItUnsent() async {
        let (chat, sent) = chat(ScratchDefaults("AskClaudeQueueTests"), gate: Gate(), key: nil)
        chat.ask("one", screen: screen, tools: NoTools())
        chat.queue("two", spoken: false)
        await waitUntilIdle(chat)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(sent.value.isEmpty)
        #expect(chat.queued?.text == "two")
    }

    /// Edit gives the text back for the box and the chips back above it; Cancel drops both.
    @Test func editGivesItBackAndCancelDropsIt() {
        let (chat, _) = chat(ScratchDefaults("AskClaudeQueueTests"), gate: Gate())
        chat.ask("one", screen: screen, tools: NoTools())
        chat.attach([Self.receipt])
        chat.queue("two", spoken: false)
        #expect(chat.editQueued() == "two")
        #expect(chat.queued == nil)
        #expect(chat.attachments == [Self.receipt])
        chat.queue("three", spoken: false)
        chat.cancelQueued()
        #expect(chat.queued == nil && chat.attachments.isEmpty)
        // A question running holds a Send back until it ends.
        chat.queue("four", spoken: false)
        chat.sendQueuedNow()
        #expect(chat.queued?.text == "four")
        chat.stop()
    }

    /// New Chat while it waits: the answer goes, the question stays for them to send.
    @Test func newChatKeepsItUnsent() async {
        let (chat, sent) = chat(ScratchDefaults("AskClaudeQueueTests"), gate: Gate())
        chat.ask("one", screen: screen, tools: NoTools())
        chat.queue("two", spoken: false)
        chat.newChat()
        #expect(!chat.isRunning)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(sent.value.isEmpty)
        #expect(chat.queued?.text == "two")
    }

    /// A folder hidden while Claude answers starts a new chat at the queued question, which still
    /// goes whole: its words and chips are its own, not "what I asked before".
    @Test func aQueuedQuestionThatStartsANewChatCarriesItsOwnTextAndChips() async {
        let d = ScratchDefaults("AskClaudeQueueTests")
        let center = NotificationCenter()
        let gate = Gate()
        let (chat, sent) = chat(d, gate: gate, keyChanges: center)
        chat.ask("one", screen: screen, tools: NoTools())
        chat.attach([Self.receipt])
        chat.queue("is this the newest?", spoken: false)
        d.set(["/Private"], forKey: AskClaudePrivacy.hiddenFoldersKey)
        center.post(name: AskClaudePrivacy.didChange, object: nil)
        gate.open = true
        await waitUntil("the queued question goes", timeout: 30) { !sent.value.isEmpty }
        await waitUntilIdle(chat)
        #expect(sent.value.first?.attachments == [Self.receipt])
        #expect(chat.items.first?.kind == .note("Started a new chat: a folder was hidden, so nothing Claude saw of it stays."))
        #expect(chat.items.dropFirst().first?.kind == .user("is this the newest?"))
    }

    /// The box is open while Claude answers, and Return in it queues rather than sends.
    @Test func theBoxStaysOpenAndReturnQueues() async throws {
        let (chat, sent) = chat(ScratchDefaults("AskClaudeQueueTests"), gate: Gate())
        var asked: [String] = []
        chat.ask("one", screen: screen, tools: NoTools())
        let rig = AskClaudePanelRig(chat: chat, onAsk: { asked.append($0) }, parked: true)
        let window = rig.window
        window.orderFrontRegardless()
        window.makeKey()
        defer { window.orderOut(nil) }
        rig.host.layoutSubtreeIfNeeded()
        let box = try #require(rig.field)
        #expect(box.isEnabled && box.isEditable)
        #expect(window.makeFirstResponder(box))
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.insertText("open it", replacementRange: NSRange(location: 0, length: 0))
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        await waitUntil("Return queues it") { chat.queued != nil }
        #expect(chat.queued?.text == "open it")
        #expect(asked.isEmpty && sent.value.isEmpty)
        // Sent from the box in all but timing: Up brings it back.
        #expect(chat.recallOlder(than: "") == "open it")
        chat.stop()
        await waitUntilIdle(chat)
    }
}

private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var _open = false
    var open: Bool {
        get { lock.withLock { _open } }
        set { lock.withLock { _open = newValue } }
    }
}

private final class Box<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}

/// Holds each request until the gate opens, then answers it with one line; a stop cancels it.
private struct GatedTransport: AskClaudeTransport {
    let gate: Gate

    func send(_ request: URLRequest) async throws -> AskClaudeTransportResponse {
        while !gate.open { try await Task.sleep(for: .milliseconds(10)) }
        return SSE.response(SSE.text("ok", outputTokens: 5))
    }
}

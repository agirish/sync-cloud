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
            chat?.ask(waiting.text, screen: screen, tools: QueueNoTools())
        }
        return (chat, sent)
    }

    private func waitUntilIdle(_ chat: AskClaudeChat, sourceLocation: SourceLocation = #_sourceLocation) async {
        await waitUntil("the chat finishes its question", timeout: 30, sourceLocation: sourceLocation) { !chat.isRunning }
    }

    @Test func aQuestionTypedWhileClaudeAnswersGoesWhenTheAnswerEnds() async {
        let gate = Gate()
        let (chat, sent) = chat(ScratchDefaults("AskClaudeQueueTests"), gate: gate)
        chat.ask("Find my latest I-797", screen: screen, tools: QueueNoTools())
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
        chat.ask("one", screen: screen, tools: QueueNoTools())
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
        chat.ask("one", screen: screen, tools: QueueNoTools())
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
        chat.ask("one", screen: screen, tools: QueueNoTools())
        chat.queue("two", spoken: false)
        await waitUntilIdle(chat)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(sent.value.isEmpty)
        #expect(chat.queued?.text == "two")
    }

    /// Edit gives the text back for the box and the chips back above it; Cancel drops both.
    @Test func editGivesItBackAndCancelDropsIt() {
        let (chat, _) = chat(ScratchDefaults("AskClaudeQueueTests"), gate: Gate())
        chat.ask("one", screen: screen, tools: QueueNoTools())
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
        chat.ask("one", screen: screen, tools: QueueNoTools())
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
        chat.ask("one", screen: screen, tools: QueueNoTools())
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
        chat.ask("one", screen: screen, tools: QueueNoTools())
        let container = CGSize(width: 1000, height: 800)
        let host = NSHostingView(rootView: AskClaudePanel(chat: chat, place: AskClaudePanelHandleTests.place, accent: .blue,
                                                          accentFill: .blue, onAccent: .white, onAsk: { asked.append($0) },
                                                          onClose: {}, onOpenSettings: {}, container: container,
                                                          settingsBridge: .keySaved))
        host.frame = NSRect(origin: .zero, size: container)
        let window = AskClaudePanelWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
        window.orderFrontRegardless()
        window.makeKey()
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        func field(in view: NSView) -> NSTextField? { (view as? NSTextField) ?? view.subviews.lazy.compactMap(field).first }
        let box = try #require(field(in: host))
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
        let lines = [
            #"data: {"type":"message_start","message":{"model":"claude-sonnet-5-5","usage":{"input_tokens":300}}}"#,
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ok"}}"#,
            #"data: {"type":"content_block_stop","index":0}"#,
            #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":5}}"#,
            #"data: {"type":"message_stop"}"#,
        ]
        return AskClaudeTransportResponse(status: 200, retryAfter: nil, lines: AsyncThrowingStream { c in
            lines.forEach { c.yield($0) }
            c.finish()
        })
    }
}

@MainActor
private final class QueueNoTools: AskClaudeToolRunning {
    func run(_ call: AskClaudeToolCall, handles: inout AskClaudeHandles) async -> AskClaudeToolOutcome {
        AskClaudeToolOutcome(result: "", step: "")
    }
}

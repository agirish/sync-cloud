import AppKit
import Foundation
import Sync
import Testing
@testable import SyncCloud

/// Copy, Edit and Retry on a turn (TE296): what Copy puts on the pasteboard, and what taking
/// turns back leaves in the thread, in Claude's transcript and in what Claude is told.
@MainActor
@Suite struct AskClaudeTurnTests {

    private let screen = AskClaudeScreen(workspace: "Browse", source: "iCloud", folder: "", sort: "Name", rows: [],
                                         selection: [], toolsAvailable: true)

    private func chat(_ transport: TurnTransport, d: UserDefaults = ScratchDefaults("AskClaudeTurnTests")) -> AskClaudeChat {
        let chat = AskClaudeChat(defaults: d, makeEngine: { AskClaudeEngine(transport: transport, defaults: d) },
                                 readKey: { "k" }, keyChanges: NotificationCenter())
        chat.askAgain = { [weak chat] asked, shown, spoken in
            guard let chat else { return }
            chat.ask(asked.question, shown: asked.editable ? nil : shown, spoken: spoken, attached: asked.attachments,
                     editable: asked.editable, screen: screen, tools: TurnTools())
        }
        return chat
    }

    private func ask(_ chat: AskClaudeChat, _ question: String, tools: AskClaudeToolRunning? = nil,
                     sourceLocation: SourceLocation = #_sourceLocation) async {
        chat.ask(question, editable: true, screen: screen, tools: tools ?? TurnTools())
        await waitUntil("the chat finishes its question", timeout: 30, sourceLocation: sourceLocation) { !chat.isRunning }
    }

    private func questions(_ chat: AskClaudeChat) -> [String] {
        chat.items.compactMap { if case .user(let text) = $0.kind { text } else { nil } }
    }

    /// The text of each message the last request sent, user and assistant, in order.
    private func lastSent(_ transport: TurnTransport) throws -> [String] {
        let body = try JSONFragment.decode(Data(try #require(transport.bodies.last).utf8))
        return (body["messages"]?.arrayValue ?? []).map { message in
            (message["content"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }.last ?? ""
        }
    }

    @Test func copyPutsATableOnThePasteboardAsATable() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("AskClaudeTurnTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        AskClaudeAnswerCopy.write("Four, **biggest** first:\n\n| File | Size |\n|---|---:|\n| W-2.pdf | 212 KB |\n| 1099.pdf | 88 KB |\n\n- one\n- two",
                                  to: pasteboard)
        let plain = try #require(pasteboard.string(forType: .string))
        #expect(plain == "Four, biggest first:\n\nFile\tSize\nW-2.pdf\t212 KB\n1099.pdf\t88 KB\n\n• one\n• two")
        let html = try #require(pasteboard.string(forType: .html))
        #expect(html.contains("<b>biggest</b>"))
        #expect(html.contains("<th>File</th><th>Size</th>") && html.contains("<td>W-2.pdf</td><td>212 KB</td>"))
        // AppKit's RTF of a table is a text table: its rows begin \trowd.
        let rtf = String(decoding: try #require(pasteboard.data(forType: .rtf)), as: UTF8.self)
        #expect(rtf.contains("\\trowd") && rtf.contains("W-2.pdf"))
    }

    @Test func anAnswerIsEveryRoundsTextAndAQuestionIsItsOwnWords() async {
        let transport = TurnTransport([.tool, .text("Two files."), .text("The lease.")])
        let chat = chat(transport)
        chat.attach([AskClaudeChat.Attachment(path: "/Docs/Lease.pdf", name: "Lease.pdf", isDirectory: false)])
        chat.ask("Which are big?", shown: "Which are big?\nAbout Lease.pdf", attached: chat.takeAttachments(), editable: true,
                 screen: screen, tools: TurnTools())
        await waitUntil("answered", timeout: 30) { !chat.isRunning }
        let question = chat.items.first { if case .user = $0.kind { true } else { false } }!.id
        let receipt = chat.items.last!.id
        #expect(chat.question(question) == "Which are big?")
        #expect(chat.answer(inTurnOf: receipt) == "Looking.\n\nTwo files.")
        #expect(chat.question(receipt) == nil)
    }

    /// Edit, then send: the edited question and all after it go, and Claude's transcript is
    /// what it was before it, the whole screen sent again.
    @Test func sendingAnEditedQuestionTakesBackItAndWhatFollowed() async throws {
        let transport = TurnTransport([.text("A"), .text("B"), .text("C"), .text("D")])
        let chat = chat(transport)
        await ask(chat, "one")
        await ask(chat, "two")
        await ask(chat, "three")
        let two = try #require(chat.items.first { $0.kind == .user("two") }?.id)
        #expect(chat.canEdit(two))
        #expect(chat.beginEdit(two) == "two")
        #expect(chat.editing == two)
        chat.finishEdit()
        #expect(questions(chat) == ["one"])
        #expect(chat.editing == nil)
        await ask(chat, "two, again")
        #expect(questions(chat) == ["one", "two, again"])
        #expect(try lastSent(transport) == ["one", "A", "two, again"])
        // The system text names the one-line form too, so only the new question's blocks count.
        let body = try JSONFragment.decode(Data(try #require(transport.bodies.last).utf8))
        let blocks = body["messages"]?.arrayValue?.last?["content"]?.arrayValue?.compactMap { $0["text"]?.stringValue } ?? []
        #expect(blocks.count == 3 && !blocks.contains("<screen unchanged/>"), "the screen Claude last saw went with the turns")
    }

    /// Retry on the last answer: the question goes again in its place, with what it was about.
    @Test func retryAsksTheLastQuestionAgainInItsPlace() async throws {
        let transport = TurnTransport([.text("A"), .text("B"), .text("B again")])
        let chat = chat(transport)
        await ask(chat, "one")
        chat.ask("two", attached: [AskClaudeChat.Attachment(path: "/Docs/Lease.pdf", name: "Lease.pdf", isDirectory: false)],
                 editable: true, screen: screen, tools: TurnTools())
        await waitUntil("answered", timeout: 30) { !chat.isRunning }
        chat.retryLast()
        await waitUntil("answered again", timeout: 30) { !chat.isRunning && transport.bodies.count == 3 }
        #expect(questions(chat) == ["one", "two"])
        #expect(chat.items.last { if case .user = $0.kind { true } else { false } }?.asked?.attachments.map(\.name) == ["Lease.pdf"])
        #expect(try lastSent(transport) == ["one", "A", "two"])
        #expect(chat.items.contains { $0.kind == .assistant("B again") } && !chat.items.contains { $0.kind == .assistant("B") })
    }

    /// Decision IT: a card from the turns taken back that changed something stays, and Claude,
    /// which no longer sees it, is told again what was done on it and what it did itself there.
    @Test func aChangedCardStaysAndClaudeIsToldAgain() async throws {
        let transport = TurnTransport([.text("A"), .tool, .text("Dark now."), .tool, .text("Shown."), .text("ok")])
        let chat = chat(transport)
        await ask(chat, "one")
        chat.tellClaude("They applied your card “Rename 2 Files”: 2 renamed.")
        let card = AskClaudeSettingCard(rows: [.init(id: "appearance.theme", changedFrom: "light", byClaude: true)])
        await ask(chat, "go dark", tools: TurnTools(card: card))
        let offered = AskClaudeSettingCard(rows: [.init(id: "appearance.theme")])
        await ask(chat, "show me the theme", tools: TurnTools(card: offered))
        let goDark = try #require(chat.items.first { $0.kind == .user("go dark") }?.id)
        #expect(chat.rewind(from: goDark))
        // The card that changed the theme stays; the one only offered goes.
        let cards = chat.items.compactMap { if case .settings(let card) = $0.kind { card } else { nil } }
        #expect(cards == [card])
        #expect(questions(chat) == ["one"])
        #expect(chat.sinceLastAnswer == [
            AskClaudeChat.tookBack("go dark"),
            "They applied your card “Rename 2 Files”: 2 renamed.",
            "You changed Theme yourself in that part, and it stays changed.",
        ])
        await ask(chat, "now?")
        let sent = try lastSent(transport)
        #expect(sent.prefix(2) == ["one", "A"] && sent.count == 3)
        #expect(sent.last?.contains("2 renamed.") == true && sent.last?.contains("You changed Theme yourself") == true)
        #expect(sent.last?.hasSuffix("now?") == true)
        #expect(chat.sinceLastAnswer.isEmpty)
    }

    /// Nothing is taken back while a question runs, and a failed question that never reached
    /// Claude goes from the thread alone.
    @Test func aRunningChatRefusesAndAFailedQuestionGoesFromTheThreadAlone() async throws {
        let transport = TurnTransport([.text("A"), .status(500), .text("B")])
        let chat = chat(transport)
        await ask(chat, "one")
        await ask(chat, "two")
        let two = try #require(chat.items.first { $0.kind == .user("two") }?.id)
        #expect(chat.items.contains { if case .problem = $0.kind { true } else { false } })
        #expect(chat.items.first { $0.id == two }?.turn == nil, "never joined")
        #expect(chat.rewind(from: two))
        #expect(questions(chat) == ["one"])
        #expect(chat.sinceLastAnswer.isEmpty)
        chat.ask("three", editable: true, screen: screen, tools: TurnTools())
        let one = try #require(chat.items.first { $0.kind == .user("one") }?.id)
        #expect(!chat.canRewind(from: one) && !chat.rewind(from: one))
        await waitUntil("answered", timeout: 30) { !chat.isRunning }
        #expect(try lastSent(transport) == ["one", "A", "three"])
    }

    /// The marks survive a relaunch, and Edit is only for a question from the box.
    @Test func theMarksAreSavedAndOnlyABoxQuestionIsEditable() async throws {
        let d = ScratchDefaults("AskClaudeTurnTests")
        let store = FileManager.default.temporaryDirectory.appendingPathComponent("AskClaudeTurnTests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: store) }
        let transport = TurnTransport([.text("A"), .text("B")])
        let chat = AskClaudeChat(defaults: d, makeEngine: { AskClaudeEngine(transport: transport, defaults: d) }, readKey: { "k" },
                                 storeURL: store, keyChanges: NotificationCenter())
        chat.ask("one", editable: true, screen: screen, tools: TurnTools())
        await waitUntil("answered", timeout: 30) { !chat.isRunning }
        chat.ask("Here is page 1 of x, as data.", shown: "Sent page 1 of x", screen: screen, tools: TurnTools())
        await waitUntil("answered", timeout: 30) { !chat.isRunning }
        let reopened = AskClaudeChat(defaults: d, makeEngine: { AskClaudeEngine(transport: transport, defaults: d) }, readKey: { "k" },
                                     storeURL: store, keyChanges: NotificationCenter())
        let ids = reopened.items.filter { if case .user = $0.kind { true } else { false } }
        #expect(ids.map(\.turn) == [0, 1])
        #expect(reopened.canEdit(ids[0].id) && !reopened.canEdit(ids[1].id))
        #expect(reopened.canRewind(from: ids[1].id))
        #expect(reopened.question(ids[1].id) == "Sent page 1 of x")
    }
}

/// Plays one reply per request, in order, keeping each body. `.tool` is one list_folder call
/// with "Looking." before it.
private final class TurnTransport: AskClaudeTransport, @unchecked Sendable {
    enum Reply { case text(String), tool, status(Int) }
    private let lock = NSLock()
    private var replies: [Reply]
    private var _bodies: [String] = []
    var bodies: [String] { lock.withLock { _bodies } }

    init(_ replies: [Reply]) { self.replies = replies }

    func send(_ request: URLRequest) async throws -> AskClaudeTransportResponse {
        let reply = lock.withLock {
            _bodies.append(String(decoding: request.httpBody ?? Data(), as: UTF8.self))
            return replies.isEmpty ? Reply.status(500) : replies.removeFirst()
        }
        let start = #"data: {"type":"message_start","message":{"model":"claude-sonnet-5-5","usage":{"input_tokens":300}}}"#
        let lines: [String]
        switch reply {
        case .status(let status):
            return AskClaudeTransportResponse(status: status, retryAfter: nil, lines: AsyncThrowingStream { $0.finish() })
        case .text(let text):
            lines = [start,
                     #"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
                     #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"\#(text)"}}"#,
                     #"data: {"type":"content_block_stop","index":0}"#,
                     #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":5}}"#,
                     #"data: {"type":"message_stop"}"#]
        case .tool:
            lines = [start,
                     #"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
                     #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Looking."}}"#,
                     #"data: {"type":"content_block_stop","index":0}"#,
                     #"data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_t","name":"list_folder","input":{}}}"#,
                     #"data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"folder\":\"\"}"}}"#,
                     #"data: {"type":"content_block_stop","index":1}"#,
                     #"data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":20}}"#,
                     #"data: {"type":"message_stop"}"#]
        }
        return AskClaudeTransportResponse(status: 200, retryAfter: nil, lines: AsyncThrowingStream { c in
            lines.forEach { c.yield($0) }
            c.finish()
        })
    }
}

/// Answers every tool call, with a settings card when given one.
@MainActor
private final class TurnTools: AskClaudeToolRunning {
    let card: AskClaudeSettingCard?
    init(card: AskClaudeSettingCard? = nil) { self.card = card }
    func run(_ call: AskClaudeToolCall, handles: inout AskClaudeHandles) async -> AskClaudeToolOutcome {
        AskClaudeToolOutcome(result: "Done", step: "Looked", settings: card)
    }
}

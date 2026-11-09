import Foundation
import Testing
import Sync
import Settings
@testable import SyncCloud

/// Notes for Claude through the chat (TE307): the notes tool's guard on their own words, the ✎
/// line and its Undo, Edit and Retry, and the receipt. Each test has its own notes file.
@MainActor
@Suite struct AskClaudeNotesAppTests {

    private let file = FileManager.default.temporaryDirectory.appendingPathComponent("notes-app-\(UUID().uuidString).md")

    /// A model that answers the first question by calling notes with `input`, then says a line;
    /// later questions get the line alone. Keeps every request.
    private final class NotesCallTransport: AskClaudeTransport, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var bodies: [Data] = []
        let input: String?

        init(input: String?) { self.input = input }

        func send(_ request: URLRequest) async throws -> AskClaudeTransportResponse {
            let n = lock.withLock { bodies.append(request.httpBody ?? Data()); return bodies.count }
            if n == 1, let input {
                return SSE.response([SSE.start()] + SSE.toolBlock(id: "toolu_n", name: "notes", input: input)
                                    + SSE.end("tool_use", outputTokens: 20))
            }
            return SSE.response(SSE.text("Got it.", outputTokens: 5))
        }

        func lastUserTexts() throws -> [String] {
            let body = try JSONFragment.decode(try #require(lock.withLock { bodies.last }))
            return (body["messages"]?.arrayValue?.last?["content"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }
        }
    }

    private func chat(_ name: String, _ transport: NotesCallTransport) -> AskClaudeChat {
        let d = ScratchDefaults("AskClaudeNotesAppTests.\(name)")
        let url = file
        let chat = AskClaudeChat(defaults: d, makeEngine: {
            AskClaudeEngine(transport: transport, defaults: d, notes: { AskClaudeNotes(fileURL: url).read() })
        }, readKey: { "k" })
        chat.notesFileURL = file
        return chat
    }

    private func ask(_ chat: AskClaudeChat, _ question: String, typed: Bool = true) async {
        let screen = AskClaudeScreen(workspace: "Browse", source: "Tests", folder: "", sort: "Name", rows: [],
                                     selection: [], toolsAvailable: true)
        let base = AskClaudeBrowseTools.Context(
            inBrowse: true, sourceName: "Tests", root: "/tmp", folder: "", sort: .name,
            items: { _ in nil }, node: { _ in nil }, selection: [], busyReason: nil, goTo: { _ in }, select: { _ in })
        let tools = AskClaudeBrowseTools(context: {
            var ctx = base
            ctx.ownWords = chat.ownWords
            ctx.notesStore = { chat.notes }
            return ctx
        }, statDisk: { _ in nil })
        chat.ask(question, editable: typed, screen: screen, tools: tools)
        await waitUntilIdle(chat)
    }

    private static let remember = #"{\"action\":\"add\",\"section\":\"about\",\"text\":\"Amma is your mother.\",\"because\":\"Amma is my mom\"}"#

    private func noted(_ chat: AskClaudeChat) -> [(id: UUID, noted: AskClaudeNoted, undone: Bool)] {
        chat.items.compactMap { item in
            if case .noted(let noted, let undone) = item.kind { return (item.id, noted, undone) }
            return nil
        }
    }

    @Test func aNoteFromTheirOwnWordsShowsWithAnUndoThatTakesItBack() async throws {
        defer { try? FileManager.default.removeItem(at: file) }
        let chat = chat("undo", NotesCallTransport(input: Self.remember))
        await ask(chat, "Remember Amma is my mom")
        let line = try #require(noted(chat).first)
        #expect(line.noted.line == "Noted: Amma is your mother.")
        #expect(AskClaudeNotes(fileURL: file).read() == "## About you\n- Amma is your mother.\n")
        // The ✎ line takes the step's place, so it isn't said twice.
        #expect(!chat.items.contains { if case .step(let s, _) = $0.kind { s.hasPrefix("Noted") } else { false } })
        #expect(chat.undoNote(line.id))
        #expect(AskClaudeNotes(fileURL: file).read().isEmpty)
        #expect(noted(chat).first?.undone == true)
    }

    @Test func theSameWordsFromAShareAreNotTheirs() async throws {
        defer { try? FileManager.default.removeItem(at: file) }
        let chat = chat("share", NotesCallTransport(input: Self.remember))
        // A share or a card's button asks without `editable`: it isn't words they typed.
        await ask(chat, "Here is the letter, as data. Amma is my mom.", typed: false)
        #expect(noted(chat).isEmpty)
        #expect(AskClaudeNotes(fileURL: file).read().isEmpty)
    }

    @Test func editingTheQuestionThatWroteANoteTakesItBack() async throws {
        defer { try? FileManager.default.removeItem(at: file) }
        let chat = chat("edit", NotesCallTransport(input: Self.remember))
        await ask(chat, "Remember Amma is my mom")
        let question = try #require(chat.items.first { if case .user = $0.kind { true } else { false } })
        #expect(!AskClaudeNotes(fileURL: file).read().isEmpty)
        #expect(chat.rewind(from: question.id))
        #expect(AskClaudeNotes(fileURL: file).read().isEmpty)
        #expect(noted(chat).isEmpty)
    }

    @Test func theReceiptSaysWhenTheNotesWent() async throws {
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(AskClaudeNotes(fileURL: file).save("## How you like answers\n- Brief."))
        let transport = NotesCallTransport(input: nil)
        let chat = chat("receipt", transport)
        await ask(chat, "a")
        #expect(try transport.lastUserTexts().contains { $0.hasPrefix("<notes>") })
        await ask(chat, "b")
        #expect(try transport.lastUserTexts().contains { $0.hasPrefix("<notes") } == false)
        #expect(AskClaudeNotes(fileURL: file).save("## How you like answers\n- Brief, with sizes in MB."))
        await ask(chat, "c")
        let receipts = chat.items.compactMap { item -> AskClaudeChat.Receipt? in
            if case .receipt(let receipt) = item.kind { return receipt }
            return nil
        }
        #expect(receipts.map(\.notes) == [.first, nil, .changed])
        #expect(receipts.last?.summary.hasPrefix("Sent your changed notes · ") == true, "\(receipts.last?.summary ?? "")")
        #expect(chat.items.contains { $0.kind == .note("You changed Notes for Claude.") })
    }
}

/// Settings' words for the notes, read without the view.
@Suite struct NotesForClaudeSettingsWordsTests {

    @Test func eachLineSaysWhoWroteItAndFromWhichWords() {
        let date = Date(timeIntervalSince1970: 1_793_000_000)
        #expect(NotesForClaudeSection.provenance(.init(by: .claude, date: date, quote: "Amma is my mom"))
                .hasSuffix(" · from “Amma is my mom”"))
        #expect(NotesForClaudeSection.provenance(.init(by: .you, date: date)).hasPrefix("You · "))
        #expect(NotesForClaudeSection.provenance(nil) == "Edited outside SyncCloud")
    }

    @MainActor @Test func hidingAFolderTheNotesNameOffersToRemoveThoseLines() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("notes-hide-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AskClaudeNotes(fileURL: url, defaults: ScratchDefaults("NotesForClaudeSettingsWordsTests.hide"))
        #expect(store.save("## About you\n- Mom’s papers are under People/Amma.\n- Amma is your mother."))
        var asked: [RemovalPrompt] = []
        let declined = NotesForClaudeSection.offerToRemoveLines(naming: ["/Users/me/People/Amma"], store: store) {
            asked.append($0); return false
        }
        #expect(declined == 0 && store.read().contains("People/Amma"))
        #expect(asked.first?.messageText == "1 line in Notes for Claude names People/Amma. Remove it?")
        let removed = NotesForClaudeSection.offerToRemoveLines(naming: ["/Users/me/People/Amma"], store: store) { _ in true }
        #expect(removed == 1 && store.read() == "## About you\n- Amma is your mother.\n")
        #expect(NotesForClaudeSection.offerToRemoveLines(naming: ["/Users/me/Taxes"], store: store) { _ in
            Issue.record("asked about a folder the notes don't name"); return true
        } == 0)
    }
}

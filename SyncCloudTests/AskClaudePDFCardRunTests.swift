import AppKit
import Foundation
import PDFKit
import Testing
import FileExplorer
import Sync
@testable import SyncCloud

/// **A PDF card from Claude's call to Undo, end to end** (TE294): a scripted model calls `pdf`,
/// the app's own runner offers the card, the chat reads its file, the click runs the real PDF
/// tool, Claude is told what it made, and Undo — the card's button or Edit ▸ Undo — takes it back.
/// Only the model and the Trash are stand-ins: Undo moves into a folder of the test's own, so a
/// run never fills his Trash.
@MainActor
@Suite(.serialized) final class AskClaudePDFCardRunTests {
    let folder = NSTemporaryDirectory() + "ask-claude-pdf-run-" + UUID().uuidString
    var trashFolder: String { (folder as NSString).appendingPathComponent("Trash") }

    init() throws {
        try FileManager.default.createDirectory(atPath: trashFolder, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(atPath: folder) }

    private func realPDF(_ name: String, pages: Int) -> String {
        let path = (folder as NSString).appendingPathComponent(name)
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(URL(fileURLWithPath: path) as CFURL, mediaBox: &box, nil)!
        for _ in 0..<pages { context.beginPDFPage(nil); context.endPDFPage() }
        context.closePDF()
        return path
    }

    /// What the window would have done: the panes told of each write, by path and writer.
    final class Window {
        var rereads: [(path: String, writer: String)] = []
    }

    /// A chat whose model calls `pdf` with `input` for the screen's one file, then says a line.
    private func chat(_ name: String, calling input: String) -> AskClaudeChat {
        let d = ScratchDefaults("AskClaudePDFCardRunTests.\(name)")
        return AskClaudeChat(defaults: d, makeEngine: { AskClaudeEngine(transport: PDFCallTransport(input: input), defaults: d) },
                             readKey: { "k" })
    }

    private func cards(_ chat: AskClaudeChat, _ sync: FileSyncManager, _ window: Window) -> AskClaudePDFCards {
        var cards = AskClaudePDFCards(
            askClaudeChat: chat, panePDFTools: PanePDFTools(), paneSaveAsPDF: PaneSaveAsPDF(), editorPDF: EditorPDFDocument(),
            syncManager: sync, fontScale: { 1 }, hue: { .blue }, lockReason: { nil }, refuse: { false }, isHidden: { _ in false },
            reread: { window.rereads.append(($0, $1)) }, handOff: { _ in }, reveal: { _, _, _ in }, download: { _ in })
        let trash = trashFolder
        cards.trash = { url in
            try FileManager.default.moveItem(atPath: url.path, toPath: (trash as NSString).appendingPathComponent(url.lastPathComponent))
        }
        return cards
    }

    private func ask(_ chat: AskClaudeChat, _ question: String, about path: String) async {
        let row = AskClaudeScreen.Row(path: path, name: (path as NSString).lastPathComponent, isDirectory: false,
                                      kind: "PDF document", size: nil, modified: nil, tags: [])
        let screen = AskClaudeScreen(workspace: "Browse", source: "Tests", folder: "", sort: "Name", rows: [row],
                                     selection: [], toolsAvailable: true)
        let root = folder
        let ctx = AskClaudeBrowseTools.Context(
            inBrowse: true, sourceName: "Tests", root: root, folder: "", sort: .name,
            items: { _ in nil }, node: { _ in nil }, selection: [], busyReason: nil,
            goTo: { _ in }, select: { _ in })
        chat.ask(question, screen: screen, tools: AskClaudeBrowseTools(context: { ctx }, statDisk: { _ in nil }))
        await waitUntil("the chat finishes its question", timeout: 30) { !chat.isRunning }
    }

    private func onlyCard(_ chat: AskClaudeChat) throws -> (id: UUID, card: AskClaudePDFCard) {
        let found = chat.items.compactMap { item -> (UUID, AskClaudePDFCard)? in
            if case .pdf(let card) = item.kind { return (item.id, card) }
            return nil
        }
        #expect(found.count == 1, "cards: \(found.map(\.1.title))")
        return try #require(found.first)
    }

    private func pageCount(_ path: String) -> Int? { PDFDocument(url: URL(fileURLWithPath: path))?.pageCount }

    /// The window's undo stack as a test can drive it. The app's groups by event: a step joins a
    /// group the run loop closes, and a click comes in a later event. Here the main actor's tasks
    /// never turn that loop, so the group never closed; the test opens one before the click and
    /// closes it after the run, as the loop would. (Taken off while its group is still open, a
    /// step leaves an empty one named for it on the menu — the order no click can make.)
    private func undoStack() -> UndoManager {
        let undo = UndoManager()
        undo.groupsByEvent = false
        return undo
    }

    /// **Delete Pages, clicked and undone on the card**: the card reads the file, nothing is written
    /// before the click, the click writes a copy without page 1 next to the original and tells
    /// Claude its name, pages and mark, and the card's Undo moves it out and takes the Edit ▸ Undo
    /// step off with it.
    @Test func aDeleteCardWritesOnTheClickAndItsUndoTakesItBack() async throws {
        let statement = realPDF("Statement.pdf", pages: 3)
        let original = try Data(contentsOf: URL(fileURLWithPath: statement))
        let chat = chat("delete", calling: #"{\"action\":\"delete_pages\",\"handles\":[\"r1\"],\"pages\":\"1\"}"#)
        let sync = FileSyncManager()
        let undo = undoStack()
        sync.undoManager = undo
        let window = Window()
        let cards = cards(chat, sync, window)
        chat.pdfCardOffered = { cards.askClaudePDFRead($0) }

        await ask(chat, "delete the first page of the statement", about: statement)
        let (id, _) = try onlyCard(chat)
        await waitUntil("the card reads its file", timeout: 30) { chat.pdfCard(id)?.state == .offered }
        let offered = try #require(chat.pdfCard(id))
        #expect(offered.rows.first?.pageCount == 3)
        #expect(offered.rows.first?.stamp != nil)
        #expect(offered.pagesProblem == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder).sorted() == ["Statement.pdf", "Trash"],
                "something was written before the click")

        undo.beginUndoGrouping()
        cards.askClaudePDFRun(id, password: nil)
        await waitUntil("the run ends", timeout: 60) { chat.pdfCard(id).map { !$0.isOpen && $0.state != .running } ?? false }
        undo.endUndoGrouping()
        let done = try #require(chat.pdfCard(id))
        #expect(done.state == .done, "\(done.state): \(done.message ?? "")")
        let written = try #require(done.written.first?.path)
        #expect((written as NSString).deletingLastPathComponent == folder, "not next to the original: \(written)")
        #expect(pageCount(written) == 2)
        #expect(try Data(contentsOf: URL(fileURLWithPath: statement)) == original, "the original changed")
        #expect(window.rereads.contains { $0.path == written && $0.writer == "Ask Claude wrote" }, "\(window.rereads)")
        let told = try #require(chat.sinceLastAnswer.last)
        #expect(told.hasPrefix("They deleted pages 1 from “Statement.pdf”: “\((written as NSString).lastPathComponent)” \(AskClaudeChat.fileMark(written)), 2 pages, "),
                "\(told)")
        #expect(undo.canUndo)
        #expect(undo.undoActionName == "Delete Pages")
        #expect(cards.askClaudePDFOffersUndo(id))

        cards.askClaudePDFUndo(id, fromMenu: false)
        #expect(chat.pdfCard(id)?.state == .undone)
        #expect(!FileManager.default.fileExists(atPath: written))
        #expect(FileManager.default.fileExists(atPath: (trashFolder as NSString).appendingPathComponent((written as NSString).lastPathComponent)))
        #expect(FileManager.default.fileExists(atPath: statement), "Undo took the original")
        #expect(!undo.canUndo, "the card's Undo left its Edit ▸ Undo step behind")
        #expect(chat.sinceLastAnswer.last == "They undid your card “Delete Pages”: “\((written as NSString).lastPathComponent)” is in the Trash.")
        #expect(!cards.askClaudePDFOffersUndo(id))
    }

    /// **Extract, taken back by Edit ▸ Undo**: the menu's step does what the card's button does.
    @Test func editUndoTakesAnExtractCardBack() async throws {
        let statement = realPDF("Statement.pdf", pages: 5)
        let chat = chat("extract", calling: #"{\"action\":\"extract\",\"handles\":[\"r1\"],\"pages\":\"2-3\"}"#)
        let sync = FileSyncManager()
        let undo = undoStack()
        sync.undoManager = undo
        let cards = cards(chat, sync, Window())
        chat.pdfCardOffered = { cards.askClaudePDFRead($0) }

        await ask(chat, "take pages 2 and 3 out", about: statement)
        let (id, _) = try onlyCard(chat)
        await waitUntil("the card reads its file", timeout: 30) { chat.pdfCard(id)?.state == .offered }
        undo.beginUndoGrouping()
        cards.askClaudePDFRun(id, password: nil)
        await waitUntil("the run ends", timeout: 60) { chat.pdfCard(id)?.state == .done }
        undo.endUndoGrouping()
        let written = try #require(chat.pdfCard(id)?.written.first?.path)
        #expect(pageCount(written) == 2)
        #expect(undo.canUndo)
        #expect(undo.undoActionName == "Extract Pages")

        undo.undo()
        #expect(chat.pdfCard(id)?.state == .undone)
        #expect(!FileManager.default.fileExists(atPath: written))
        #expect(chat.sinceLastAnswer.last?.hasPrefix("They undid your card “Extract Pages”: ") == true)
    }

    /// **A file changed after the card read it is not run**: the click reads it again and says why.
    @Test func aFileChangedSinceTheCardReadItIsNotRun() async throws {
        let statement = realPDF("Statement.pdf", pages: 3)
        let chat = chat("changed", calling: #"{\"action\":\"delete_pages\",\"handles\":[\"r1\"],\"pages\":\"2\"}"#)
        let cards = cards(chat, FileSyncManager(), Window())
        chat.pdfCardOffered = { cards.askClaudePDFRead($0) }

        await ask(chat, "delete page 2", about: statement)
        let (id, _) = try onlyCard(chat)
        await waitUntil("the card reads its file", timeout: 30) { chat.pdfCard(id)?.state == .offered }
        _ = realPDF("Statement.pdf", pages: 4)
        cards.askClaudePDFRun(id, password: nil)
        #expect(chat.pdfCard(id)?.message == "A file changed since the card was made. Check it and click again.")
        #expect(chat.pdfCard(id)?.written.isEmpty == true)
        await waitUntil("the card reads the file again", timeout: 30) { chat.pdfCard(id)?.rows.first?.pageCount == 4 }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder).sorted() == ["Statement.pdf", "Trash"])
    }
}

/// A model that calls `pdf` once with `input`, then answers in a line.
private final class PDFCallTransport: AskClaudeTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    let input: String

    init(input: String) { self.input = input }

    func send(_ request: URLRequest) async throws -> AskClaudeTransportResponse {
        let first = lock.withLock { calls += 1; return calls == 1 }
        let start = #"data: {"type":"message_start","message":{"model":"claude-haiku-5-5","usage":{"input_tokens":300}}}"#
        let lines = first ? [
            start,
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_pdf","name":"pdf","input":{}}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"\#(input)"}}"#,
            #"data: {"type":"content_block_stop","index":0}"#,
            #"data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":20}}"#,
            #"data: {"type":"message_stop"}"#,
        ] : [
            start,
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"The card is ready."}}"#,
            #"data: {"type":"content_block_stop","index":0}"#,
            #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":10}}"#,
            #"data: {"type":"message_stop"}"#,
        ]
        return AskClaudeTransportResponse(status: 200, retryAfter: nil, lines: AsyncThrowingStream { c in
            lines.forEach { c.yield($0) }
            c.finish()
        })
    }
}

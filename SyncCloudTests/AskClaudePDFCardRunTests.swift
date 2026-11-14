import AppKit
import Foundation
import os
import PDFKit
import Testing
import Events
import FileExplorer
import Sync
@testable import SyncCloud

/// A PDF card from Claude's call to Undo, end to end: a scripted model calls `pdf`, the app's own
/// runner offers the card, the chat reads its file, the click runs the real PDF tool, Claude is
/// told what it made, and Undo (the card's button or Edit ▸ Undo) takes it back. Only the model
/// and the Trash are stand-ins: Undo moves into a folder of the test's own, so a run never fills
/// his Trash.
@MainActor
@Suite(.serialized) final class AskClaudePDFCardRunTests {
    let folder = NSTemporaryDirectory() + "ask-claude-pdf-run-" + UUID().uuidString
    var trashFolder: String { (folder as NSString).appendingPathComponent("Trash") }

    init() throws {
        try FileManager.default.createDirectory(atPath: trashFolder, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(atPath: folder) }

    /// What the window would have done: the panes told of each write, by path and writer.
    final class Window {
        var rereads: [(path: String, writer: String)] = []
    }

    /// A chat whose model calls `pdf` with `input` for the screen's one file, then says a line.
    private func chat(_ name: String, calling input: String) -> AskClaudeChat {
        chat(name, transport: PDFCallTransport(inputs: [input]))
    }

    private func chat(_ name: String, transport: PDFCallTransport, store: URL? = nil) -> AskClaudeChat {
        let d = ScratchDefaults("AskClaudePDFCardRunTests.\(name)")
        return AskClaudeChat(defaults: d, makeEngine: { AskClaudeEngine(transport: transport, defaults: d) },
                             readKey: { "k" }, storeURL: store)
    }

    private func cards(_ chat: AskClaudeChat, _ sync: FileSyncManager, _ window: Window) -> AskClaudePDFCards {
        var cards = AskClaudePDFCards(
            askClaudeChat: chat, panePDFTools: PanePDFTools(), paneSaveAsPDF: PaneSaveAsPDF(), editorPDF: EditorPDFDocument(defaults: ScratchDefaults("AskClaudePDFCardRunTests.pdf")),
            syncManager: sync, fontScale: { 1 }, hue: { .blue }, lockReason: { nil }, refuse: { false }, isHidden: { _ in false },
            reread: { window.rereads.append(($0, $1)) }, handOff: { _ in }, reveal: { _, _, _ in }, download: { _ in })
        let trash = trashFolder
        cards.trash = { url in
            try FileManager.default.moveItem(atPath: url.path, toPath: (trash as NSString).appendingPathComponent(url.lastPathComponent))
        }
        return cards
    }

    private func ask(_ chat: AskClaudeChat, _ question: String, about path: String, waiting: Bool = true) async {
        let row = AskClaudeScreen.Row(path: path, name: (path as NSString).lastPathComponent, isDirectory: false,
                                      kind: "PDF document", size: nil, modified: nil, tags: [])
        let screen = AskClaudeScreen(workspace: "Browse", source: "Tests", folder: "", sort: "Name", rows: [row],
                                     selection: [], toolsAvailable: true)
        let root = folder
        let ctx = AskClaudeBrowseTools.Context(
            inBrowse: true, sourceName: "Tests", root: root, folder: "",
            items: { _ in nil }, node: { _ in nil }, busyReason: nil,
            goTo: { _ in }, select: { _ in })
        chat.ask(question, screen: screen, tools: AskClaudeBrowseTools(context: { ctx }, statDisk: { _ in nil }))
        if waiting { await waitUntil("the chat finishes its question", timeout: 30) { !chat.isRunning } }
    }

    /// Asks `question` about `path` with `cards` reading what Claude offers, and returns the one
    /// card once it has read its file.
    private func offered(_ chat: AskClaudeChat, _ cards: AskClaudePDFCards, _ question: String, about path: String,
                         sourceLocation: SourceLocation = #_sourceLocation) async throws -> UUID {
        chat.pdfCardOffered = { cards.askClaudePDFRead($0) }
        await ask(chat, question, about: path)
        let (id, _) = try onlyCard(chat, sourceLocation: sourceLocation)
        await waitUntil("the card reads its file", timeout: 30, sourceLocation: sourceLocation) {
            chat.pdfCard(id)?.state == .offered
        }
        return id
    }

    private func onlyCard(_ chat: AskClaudeChat,
                          sourceLocation: SourceLocation = #_sourceLocation) throws -> (id: UUID, card: AskClaudePDFCard) {
        let found = allCards(chat)
        #expect(found.count == 1, "cards: \(found.map(\.1.title))", sourceLocation: sourceLocation)
        return try #require(found.first, sourceLocation: sourceLocation)
    }

    private func allCards(_ chat: AskClaudeChat) -> [(UUID, AskClaudePDFCard)] {
        chat.items.compactMap { item -> (UUID, AskClaudePDFCard)? in
            if case .pdf(let card) = item.kind { return (item.id, card) }
            return nil
        }
    }

    private func finished(_ chat: AskClaudeChat, _ id: UUID) -> Bool {
        chat.pdfCard(id).map { !$0.isOpen && $0.state != .running } ?? false
    }

    private func pageCount(_ path: String) -> Int? { PDFDocument(url: URL(fileURLWithPath: path))?.pageCount }

    /// The window's undo stack as a test can drive it. The app's groups by event: a step joins a
    /// group the run loop closes. The main actor's tasks never turn that loop here, so the test
    /// opens a group before the click and closes it after the run, as the loop would. (A step
    /// taken off while its group is open leaves an empty one named for it on the menu.)
    private func undoStack() -> UndoManager {
        let undo = UndoManager()
        undo.groupsByEvent = false
        return undo
    }

    /// Delete Pages, clicked and undone on the card: the card reads the file, nothing is written
    /// before the click, the click writes a copy without page 1 next to the original and tells
    /// Claude its name, pages and mark, and the card's Undo moves it out and takes the Edit ▸ Undo
    /// step off with it.
    @Test func aDeleteCardWritesOnTheClickAndItsUndoTakesItBack() async throws {
        let statement = blankPDF("Statement.pdf", pages: 3, in: folder)
        let original = try Data(contentsOf: URL(fileURLWithPath: statement))
        let chat = chat("delete", calling: #"{\"action\":\"delete_pages\",\"handles\":[\"r1\"],\"pages\":\"1\"}"#)
        let sync = FileSyncManager.scratch()
        let undo = undoStack()
        sync.undoManager = undo
        let window = Window()
        let cards = cards(chat, sync, window)

        let id = try await offered(chat, cards, "delete the first page of the statement", about: statement)
        let card = try #require(chat.pdfCard(id))
        #expect(card.rows.first?.pageCount == 3)
        #expect(card.rows.first?.stamp != nil)
        #expect(card.pagesProblem == nil)
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

    /// Extract, taken back by Edit ▸ Undo: the menu's step does what the card's button does.
    @Test func editUndoTakesAnExtractCardBack() async throws {
        let statement = blankPDF("Statement.pdf", pages: 5, in: folder)
        let chat = chat("extract", calling: #"{\"action\":\"extract\",\"handles\":[\"r1\"],\"pages\":\"2-3\"}"#)
        let sync = FileSyncManager.scratch()
        let undo = undoStack()
        sync.undoManager = undo
        let cards = cards(chat, sync, Window())

        let id = try await offered(chat, cards, "take pages 2 and 3 out", about: statement)
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

    /// A file changed after the card read it is not run: the click reads it again and says why.
    @Test func aFileChangedSinceTheCardReadItIsNotRun() async throws {
        let statement = blankPDF("Statement.pdf", pages: 3, in: folder)
        let chat = chat("changed", calling: #"{\"action\":\"delete_pages\",\"handles\":[\"r1\"],\"pages\":\"2\"}"#)
        let cards = cards(chat, FileSyncManager.scratch(), Window())

        let id = try await offered(chat, cards, "delete page 2", about: statement)
        _ = blankPDF("Statement.pdf", pages: 4, in: folder)
        cards.askClaudePDFRun(id, password: nil)
        #expect(chat.pdfCard(id)?.message == "A file changed since the card was made. Check it and click again.")
        #expect(chat.pdfCard(id)?.written.isEmpty == true)
        await waitUntil("the card reads the file again", timeout: 30) { chat.pdfCard(id)?.rows.first?.pageCount == 4 }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder).sorted() == ["Statement.pdf", "Trash"])
    }

    // MARK: Hand checks a test can make (MANUAL_CHECKS "Ask Claude's PDF cards")

    /// "Compress while a duplicate scan holds the PDF reader": while another job holds the PDF
    /// lane, the card says it is checking and its click runs nothing; let go, it fills in.
    @Test func aCardWaitsOutAHeldPDFReaderThenFillsIn() async throws {
        let scan = blankPDF("Scan.pdf", pages: 2, in: folder)
        let chat = chat("held", calling: #"{\"action\":\"compress\",\"handles\":[\"r1\"]}"#)
        let cards = cards(chat, FileSyncManager.scratch(), Window())
        chat.pdfCardOffered = { cards.askClaudePDFRead($0) }

        // The holder's turn first, as a long scan's would be.
        let release = DispatchSemaphore(value: 0)
        let held = OSAllocatedUnfairLock(initialState: false)
        let holder = Task.detached {
            await PDFKitSerialAccess.perform {
                held.withLock { $0 = true }
                _ = release.wait(timeout: .now() + 120)
            }
        }
        defer { release.signal() }
        await waitUntil("the holder gets the PDF lane", timeout: 60) { held.withLock { $0 } }

        await ask(chat, "make the scan smaller", about: scan)
        let (id, _) = try onlyCard(chat)
        // Held past the card's own 5 s wait for the lane: a duration held, not a pump.
        try await Task.sleep(for: .seconds(6))
        #expect(chat.pdfCard(id)?.state == .checking, "\(String(describing: chat.pdfCard(id)?.state))")
        #expect(chat.pdfCard(id)?.rows.first?.stamp == nil, "the card read the file through a held lane")
        cards.askClaudePDFRun(id, password: nil)
        #expect(chat.pdfCard(id)?.state == .checking, "a click ran a card that hadn't read its file")
        // And it was refused, not merely re-read: a refusal says nothing on the card.
        #expect(chat.pdfCard(id)?.message == nil, "\(String(describing: chat.pdfCard(id)?.message))")

        release.signal()
        await holder.value
        await waitUntil("the card fills in once the lane is free", timeout: 60) { chat.pdfCard(id)?.state == .offered }
        #expect(chat.pdfCard(id)?.rows.first?.pageCount == 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder).sorted() == ["Scan.pdf", "Trash"])
    }

    /// "Click while Claude is answering": the card waits, saying so, and runs nothing; once the
    /// answer is in, the same click runs it.
    @Test func aClickWhileClaudeAnswersWaits() async throws {
        let statement = blankPDF("Statement.pdf", pages: 3, in: folder)
        let transport = PDFCallTransport(inputs: [#"{\"action\":\"delete_pages\",\"handles\":[\"r1\"],\"pages\":\"1\"}"#], holding: 3)
        let chat = chat("answering", transport: transport)
        let cards = cards(chat, FileSyncManager.scratch(), Window())

        let id = try await offered(chat, cards, "delete the first page", about: statement)

        await ask(chat, "and how big is it?", about: statement, waiting: false)
        await waitUntil("Claude is answering") { chat.isRunning }
        #expect(AskClaudePDFCardView.waitReason(isRunning: chat.isRunning, bridge: cards.askClaudePDFWaitReason(id))
                == "Waits for Claude to finish.")
        cards.askClaudePDFRun(id, password: nil)
        #expect(chat.pdfCard(id)?.state == .offered, "it ran while Claude was answering")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder).sorted() == ["Statement.pdf", "Trash"])

        transport.release()
        await waitUntil("the answer lands", timeout: 30) { !chat.isRunning }
        #expect(AskClaudePDFCardView.waitReason(isRunning: chat.isRunning, bridge: cards.askClaudePDFWaitReason(id)) == nil)
        cards.askClaudePDFRun(id, password: nil)
        await waitUntil("the run ends", timeout: 60) { finished(chat, id) }
        #expect(chat.pdfCard(id)?.state == .done)
    }

    /// "Undo, on two cards": Edit ▸ Undo takes back the latest card and leaves the first; the
    /// first card's own Undo then takes back its own.
    @Test func twoCardsEachUndoTheirOwn() async throws {
        let a = blankPDF("A.pdf", pages: 3, in: folder), b = blankPDF("B.pdf", pages: 4, in: folder)
        // r2 is the first card's new file: its report line is minted a handle as the second
        // question is sent, before the screen's B.pdf, which is r3.
        let transport = PDFCallTransport(inputs: [#"{\"action\":\"delete_pages\",\"handles\":[\"r1\"],\"pages\":\"1\"}"#,
                                                  #"{\"action\":\"extract\",\"handles\":[\"r3\"],\"pages\":\"2-3\"}"#])
        let chat = chat("two", transport: transport)
        let sync = FileSyncManager.scratch()
        let undo = undoStack()
        sync.undoManager = undo
        let cards = cards(chat, sync, Window())
        chat.pdfCardOffered = { cards.askClaudePDFRead($0) }

        var made: [String] = []
        for (path, question) in [(a, "delete the first page of A"), (b, "take pages 2 and 3 out of B")] {
            await ask(chat, question, about: path)
            let id = try #require(allCards(chat).last?.0)
            #expect(chat.pdfCard(id)?.rows.first?.path == path)
            await waitUntil("the card reads its file", timeout: 30) { chat.pdfCard(id)?.state == .offered }
            undo.beginUndoGrouping()
            cards.askClaudePDFRun(id, password: nil)
            await waitUntil("the run ends", timeout: 60) { finished(chat, id) }
            undo.endUndoGrouping()
            made.append(try #require(chat.pdfCard(id)?.written.first?.path, "\(String(describing: chat.pdfCard(id)))"))
        }
        let ids = allCards(chat).map(\.0)
        try #require(ids.count == 2)
        #expect(undo.undoActionName == "Extract Pages")

        undo.undo()
        #expect(chat.pdfCard(ids[1])?.state == .undone)
        #expect(!FileManager.default.fileExists(atPath: made[1]))
        #expect(chat.pdfCard(ids[0])?.state == .done, "Edit ▸ Undo reached past the latest card")
        #expect(FileManager.default.fileExists(atPath: made[0]))
        #expect(undo.undoActionName == "Delete Pages")

        cards.askClaudePDFUndo(ids[0], fromMenu: false)
        #expect(chat.pdfCard(ids[0])?.state == .undone)
        #expect(!FileManager.default.fileExists(atPath: made[0]))
        #expect(!undo.canUndo)
        #expect(FileManager.default.fileExists(atPath: a) && FileManager.default.fileExists(atPath: b), "Undo took an original")
    }

    /// "Protect": the password typed on the card locks the new file and goes nowhere else: not
    /// the saved chat, not what Claude is told, not the log.
    @Test func aPasswordLocksTheCopyAndGoesNowhereElse() async throws {
        let notice = blankPDF("Notice.pdf", pages: 1, in: folder)
        let store = URL(fileURLWithPath: (folder as NSString).appendingPathComponent("chat.json"))
        let chat = chat("protect", transport: PDFCallTransport(inputs: [#"{\"action\":\"protect\",\"handles\":[\"r1\"]}"#]),
                        store: store)
        let cards = cards(chat, FileSyncManager.scratch(), Window())
        let log = LogCapture()
        let secret = "card-secret-\(UUID().uuidString)"

        let id = try await offered(chat, cards, "put a password on the notice", about: notice)
        cards.askClaudePDFRun(id, password: EditorPDFSecret(secret))
        await waitUntil("the run ends", timeout: 60) { finished(chat, id) }
        let written = try #require(chat.pdfCard(id)?.written.first?.path, "\(String(describing: chat.pdfCard(id)))")

        let copy = try #require(PDFDocument(url: URL(fileURLWithPath: written)))
        #expect(copy.isLocked, "the copy isn't locked")
        #expect(copy.unlock(withPassword: secret), "the copy doesn't open with the password typed")

        let marker = "protect window close \(UUID().uuidString)"
        Events.Logger.shared.debug(marker)
        let entries = await log.entries
        let heard = entries.contains { $0.message == marker }
        try #require(heard, "the capture never saw this test's own line, so the absence below would have examined nothing")
        #expect(!entries.contains { $0.message.contains(secret) }, "the password is in the log")
        // What Claude is told of the run is there to examine, or the absence below would hold of
        // an empty list.
        try #require(!chat.sinceLastAnswer.isEmpty, "Claude was told nothing of the run, so the absence below proves nothing")
        #expect(!chat.sinceLastAnswer.joined().contains(secret), "Claude would be told the password")
        let saved = try String(contentsOf: store, encoding: .utf8)
        #expect(saved.contains("Protect"), "the chat wasn't saved, so its absence proves nothing")
        #expect(!saved.contains(secret), "the password is in chat.json")
    }
}

/// A model that answers each question it is asked: the first ones by calling `pdf` with the next
/// of `inputs` and then saying a line, any after that with the line alone. Request `holding`
/// (counted from 1) waits until `release()`, so a test can click while Claude is answering.
private final class PDFCallTransport: AskClaudeTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var requests = 0
    private var released = false
    let inputs: [String]
    let holding: Int?

    init(inputs: [String], holding: Int? = nil) {
        self.inputs = inputs
        self.holding = holding
    }

    func release() { lock.withLock { released = true } }

    func send(_ request: URLRequest) async throws -> AskClaudeTransportResponse {
        let n = lock.withLock { requests += 1; return requests }
        if n == holding {
            while !lock.withLock({ released }) { try await Task.sleep(for: .milliseconds(10)) }
        }
        // Questions alternate a call and its line, as long as there are calls to make.
        let call = n % 2 == 1 ? inputs.dropFirst((n - 1) / 2).first : nil
        let start = SSE.start(model: "claude-haiku-5-5")
        return SSE.response(call.map { input in
            [start] + SSE.toolBlock(id: "toolu_pdf\(n)", name: "pdf", input: input) + SSE.end("tool_use", outputTokens: 20)
        } ?? SSE.text("The card is ready.", model: "claude-haiku-5-5", outputTokens: 10))
    }
}

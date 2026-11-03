import AppKit
import Foundation
import SwiftUI
import Testing
import Design
import FileExplorer
import Sync
@testable import SyncCloud

/// **Ask Claude's PDF cards, the app's half** (TE294 step 3): the runner's checks on Claude's call,
/// the card it offers, the handles a report line gets as it is sent, what a card restored after a
/// quit says, the lines Claude hears — and that the card fits the panel.
@MainActor
@Suite(.serialized) final class AskClaudePDFAppTests {
    let folder = NSTemporaryDirectory() + "ask-claude-pdf-" + UUID().uuidString

    init() throws {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(atPath: folder) }

    private func file(_ name: String, in sub: String? = nil) throws -> String {
        var base = folder
        if let sub {
            base = (folder as NSString).appendingPathComponent(sub)
            try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        }
        let path = (base as NSString).appendingPathComponent(name)
        try Data("%PDF-1.4\n".utf8).write(to: URL(fileURLWithPath: path))
        return path
    }

    private func context(hidden: [String] = []) -> AskClaudeBrowseTools.Context {
        var ctx = AskClaudeBrowseTools.Context(
            inBrowse: true, sourceName: "Tests", root: folder, folder: "", sort: .name,
            items: { _ in nil }, node: { _ in nil }, selection: [], busyReason: nil,
            goTo: { _ in }, select: { _ in })
        ctx.hidden = hidden
        return ctx
    }

    private func offer(_ input: [String: JSONFragment], paths: [String], hidden: [String] = []) -> AskClaudeToolOutcome {
        var handles = AskClaudeHandles()
        var named: [JSONFragment] = []
        for path in paths { named.append(.string(handles.handle(for: path))) }
        var input = input
        if input["handles"] == nil { input["handles"] = .array(named) }
        let ctx = context(hidden: hidden)
        let runner = AskClaudeBrowseTools(context: { ctx }, statDisk: { _ in nil })
        return runner.pdfCard(AskClaudeToolCall(id: "t", name: "pdf", input: .object(input)), ctx, handles)
    }

    // MARK: The runner

    /// **Each field Claude gets wrong is refused by name**, and nothing is offered.
    @Test func refusesACallFieldByField() throws {
        let one = try file("A.pdf"), two = try file("B.pdf"), doc = try file("Report.pages")
        func refusal(_ input: [String: JSONFragment], _ paths: [String], hidden: [String] = []) -> String {
            let outcome = offer(input, paths: paths, hidden: hidden)
            #expect(outcome.isError && outcome.pdf == nil, "offered a card for \(input)")
            return outcome.result
        }
        #expect(refusal(["action": .string("shrink")], [one]).contains("action must be one of"))
        #expect(refusal(["action": .string("compress"), "handles": .array([])], []).contains("handles needs"))
        #expect(refusal(["action": .string("compress"), "handles": .array([.string("r99")])], []).contains("r99 isn’t a handle"))
        #expect(refusal(["action": .string("combine")], [one]).contains("two or more"))
        #expect(refusal(["action": .string("extract"), "pages": .string("1")], [one, two]).contains("takes one handle"))
        #expect(refusal(["action": .string("reorder")], [one]).contains("pages needs"))
        #expect(refusal(["action": .string("compress"), "strength": .string("tiny")], [one]).contains("strength must be"))
        #expect(refusal(["action": .string("rotate"), "pages": .string("1")], [one, two]).contains("rotates one file’s pages"))
        #expect(refusal(["action": .string("split"), "split_at": .array([.integer(9), .integer(4)])], [one]).contains("must go up"))
        #expect(refusal(["action": .string("split"), "split_at": .array([.integer(1)])], [one]).contains("must go up"))
        #expect(refusal(["action": .string("save_as_pdf")], [doc]).contains("Pages, Keynote and Numbers"))
        #expect(refusal(["action": .string("compress")], [doc]).contains("isn’t a PDF"))
        #expect(refusal(["action": .string("compress")], [one], hidden: [folder]).contains("hid from you"))
        let many = try (0...AskClaudePDFCard.maxFiles).map { try file("F\($0).pdf") }
        #expect(refusal(["action": .string("compress")], many).contains("at most \(AskClaudePDFCard.maxFiles)"))
    }

    /// **The card it offers, and what Claude is told**: nothing has happened, never “done”, one
    /// short line that doesn't repeat the card; with no strength or size, Balanced. Protect tells Claude never to touch the password.
    @Test func offersACardAndSaysNothingHasHappened() throws {
        let one = try file("Scan.pdf")
        let outcome = offer(["action": .string("compress")], paths: [one])
        let card = try #require(outcome.pdf)
        #expect(!outcome.isError)
        #expect(card.state == .checking)
        #expect(card.options.strength == .balanced)
        #expect(card.rows.map(\.path) == [one])
        #expect(outcome.result.contains("Nothing has happened"))
        #expect(outcome.result.contains("Never say it’s done"))
        // The card says what the click makes and that the original stays: Claude hears that it
        // does, so its one line after the card needn't say it again.
        #expect(outcome.result.contains("The card itself shows"))
        #expect(outcome.result.contains("Reply in one short line"))
        #expect(outcome.result.contains("Never repeat what the card shows"))
        let protect = offer(["action": .string("protect")], paths: [one])
        #expect(protect.result.contains("Never ask for it"))
        #expect(protect.pdf?.options.mode == .lockToOpen)
        let combine = try #require(offer(["action": .string("combine")], paths: [one, try file("Other.pdf")]).pdf)
        #expect(combine.options.name == "Scan (combined).pdf")
    }

    // MARK: The tool, turned on (step 4)

    private func realPDF(_ name: String, pages: Int) -> String {
        let path = (folder as NSString).appendingPathComponent(name)
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(URL(fileURLWithPath: path) as CFURL, mediaBox: &box, nil)!
        for _ in 0..<pages { context.beginPDFPage(nil); context.endPDFPage() }
        context.closePDF()
        return path
    }

    private func run(_ input: [String: JSONFragment], paths: [String],
                     openForFill: @escaping (String) async -> AskClaudeBrowseTools.FillOutcome = { _ in .notNow })
    async -> AskClaudeToolOutcome {
        var handles = AskClaudeHandles()
        var input = input
        input["handles"] = .array(paths.map { .string(handles.handle(for: $0)) })
        var ctx = context()
        ctx.openForFill = openForFill
        let fixed = ctx
        let runner = AskClaudeBrowseTools(context: { fixed }, statDisk: { _ in nil })
        return await runner.run(AskClaudeToolCall(id: "t", name: "pdf", input: .object(input)), handles: &handles)
    }

    /// **The `pdf` name reaches the runner**: a card action offers a card, `info` reads the file.
    @Test func thePDFToolRunsThroughTheRunner() async throws {
        let statement = realPDF("Statement.pdf", pages: 8)
        let card = await run(["action": .string("extract"), "pages": .string("3-5")], paths: [statement])
        #expect(card.pdf?.action == .extract, "\(card.result)")
        let info = await run(["action": .string("info")], paths: [statement])
        #expect(!info.isError, "\(info.result)")
        #expect(info.result.hasPrefix("“Statement.pdf”: 8 pages, "), "\(info.result)")
        #expect(info.result.hasSuffix("no form fields."), "\(info.result)")
    }

    /// **fill opens the form and says so, in each way it can end** — moved to Edit when it opened.
    @Test func fillSaysHowOpeningTheFormWent() async throws {
        let form = realPDF("W-9.pdf", pages: 1)
        let opened = await run(["action": .string("fill")], paths: [form], openForFill: { _ in .opened(fields: 11) })
        #expect(opened.result.contains("Fill & Sign on. It has 11 form fields."), "\(opened.result)")
        #expect(opened.movedView == "Moved you to Edit")
        let slow = await run(["action": .string("fill")], paths: [form], openForFill: { _ in .openedWithoutFillSign })
        #expect(slow.result.contains("they click Fill & Sign"), "\(slow.result)")
        let waiting = await run(["action": .string("fill")], paths: [form], openForFill: { _ in .notNow })
        #expect(waiting.isError)
        let doc = try file("Letter.docx")
        let notPDF = await run(["action": .string("fill")], paths: [doc], openForFill: { _ in .opened(fields: 1) })
        #expect(notPDF.isError && notPDF.result.contains("isn’t a PDF"))
    }

    // MARK: Handles, minted as the line is sent

    /// **A file a line names gets its handle when the line is sent** — the same handle every time
    /// for the same file, and none for one now hidden from Claude.
    @Test func linesGetTheirHandlesAsTheyAreSent() {
        var handles = AskClaudeHandles()
        let earlier = handles.handle(for: "/d/Other.pdf")
        let lines = ["They compressed “A.pdf”: “A (compressed).pdf” \(AskClaudeChat.fileMark("/d/A (compressed).pdf")), 3 pages.",
                     "And again \(AskClaudeChat.fileMark("/d/A (compressed).pdf")).",
                     "Hidden: \(AskClaudeChat.fileMark("/secret/B.pdf"))."]
        let sent = AskClaudeChat.minted(lines, handles: &handles, isHidden: { $0.hasPrefix("/secret") })
        let handle = handles.handle(for: "/d/A (compressed).pdf")
        #expect(handle != earlier)
        #expect(sent[0] == "They compressed “A.pdf”: “A (compressed).pdf” (\(handle)), 3 pages.")
        #expect(sent[1] == "And again (\(handle)).")
        #expect(sent[2] == "Hidden: (in a folder hidden from you).")
        #expect(handles.path(for: handle) == "/d/A (compressed).pdf")
        #expect(!sent.joined().contains("⟦"), "a mark reached Claude")
    }

    /// **A card restored after a quit**: one that was running says SyncCloud quit while it ran;
    /// one still offered is read again before its button wakes.
    @Test func aRestoredCardSaysWhatBecameOfIt() {
        let base = AskClaudePDFCard(action: .compress, rows: [.init(path: "/d/A.pdf", name: "A.pdf", folderLabel: "d")])
        var running = base; running.state = .running
        var offered = base; offered.state = .offered
        func restored(_ card: AskClaudePDFCard) -> AskClaudePDFCard.State? {
            if case .pdf(let back) = AskClaudeChat.notWaiting(AskClaudeChat.Item(kind: .pdf(card))).kind { return back.state }
            return nil
        }
        #expect(restored(running) == .quitWhileRunning)
        #expect(restored(offered) == .checking)
        var done = base; done.state = .done
        #expect(restored(done) == .done)
    }

    // MARK: What Claude hears

    private func written(_ path: String, bytes: Int = 3_100_000, pages: Int? = 22) -> PDFWrittenFile {
        PDFWrittenFile(source: "/d/Scan.pdf", path: path, stamp: EditorFileStore.Stamp(modifiedAt: nil, size: bytes),
                       bytes: bytes, pageCount: pages)
    }

    /// **The lines, word for word**: each new file by name with its mark, its pages and size, and
    /// where; Compress says its pages are pictures; a hidden destination names nothing.
    @Test func reportsWhatTheClickMadeWordForWord() {
        let card = AskClaudePDFCard(action: .compress,
                                    rows: [.init(path: "/d/Scan.pdf", name: "Scan.pdf", folderLabel: "iCloud › Downloads",
                                                 bytes: 18_200_000)])
        let before = FileSyncManager.formatBytes(18_200_000)
        let mark = AskClaudeChat.fileMark("/d/Scan (compressed).pdf")
        let wrote = PDFRunResult(outcome: .wrote, written: [written("/d/Scan (compressed).pdf")], message: "Saved")
        let size = FileSyncManager.formatBytes(3_100_000)
        #expect(ContentView.askClaudePDFReport(card, wrote, isHidden: { _ in false })
                == "They compressed “Scan.pdf” (\(before)): “Scan (compressed).pdf” \(mark), 22 pages, \(size), next to it in iCloud › Downloads. Its pages are pictures now.")
        #expect(ContentView.askClaudePDFReport(card, wrote, isHidden: { _ in true })
                == "They compressed “Scan.pdf” (\(before)): a file in a folder hidden from you, next to it in iCloud › Downloads. Its pages are pictures now.")
        let missed = PDFRunResult(outcome: .wrote, written: [written("/d/Scan (compressed).pdf")],
                                  message: "Saved “Scan (compressed).pdf” — 18.2 MB → 6.4 MB. No setting reached 5 MB; this is the smallest it got")
        #expect(ContentView.askClaudePDFReport(card, missed, isHidden: { _ in false })
                .hasSuffix("Its pages are pictures now. It didn’t get under the size asked; this is the smallest it got."))
        var chosen = card
        chosen.folder = "/Elsewhere"
        #expect(ContentView.askClaudePDFReport(chosen, wrote, isHidden: { _ in false }).contains(", in the folder they chose."))
        let small = PDFRunResult(outcome: .nothingWritten, message: "“Scan.pdf” is already 3 MB, under the 5 MB target — nothing was written.")
        #expect(ContentView.askClaudePDFReport(card, small, isHidden: { _ in false })
                == "Your card “Compress” wrote nothing: “Scan.pdf” is already 3 MB, under the 5 MB target — nothing was written.")
        let failed = PDFRunResult(outcome: .failed, message: "“Scan.pdf” changed since it was chosen, so nothing was written.")
        #expect(ContentView.askClaudePDFReport(card, failed, isHidden: { _ in false })
                == "Your card “Compress” didn’t run: “Scan.pdf” changed since it was chosen, so nothing was written.")
        var protect = card
        protect.action = .protect
        let locked = PDFRunResult(outcome: .wrote, written: [written("/d/Scan (protected).pdf", pages: nil)], message: "Saved")
        let line = ContentView.askClaudePDFReport(protect, locked, isHidden: { _ in false })
        #expect(line.hasPrefix("They protected “Scan.pdf” with a password (locked to open): “Scan (protected).pdf”"), "\(line)")
    }

    /// A batch with some files left out says which, and why.
    @Test func aPartRunSaysWhatWasLeftOut() {
        let card = AskClaudePDFCard(action: .rotate, rows: [
            .init(path: "/d/A.pdf", name: "A.pdf", folderLabel: "d"), .init(path: "/d/B.pdf", name: "B.pdf", folderLabel: "d"),
        ])
        let part = PDFRunResult(outcome: .partlyWrote, written: [written("/d/A (rotated).pdf", bytes: 1000, pages: 1)],
                                skipped: [.init(path: "/d/B.pdf", reason: "locked with a password")], message: "Saved 1")
        let line = ContentView.askClaudePDFReport(card, part, isHidden: { _ in false })
        #expect(line.hasSuffix("Not done: “B.pdf” (locked with a password)."), "\(line)")
        #expect(line.contains("next to each original in d"), "\(line)")
        var spread = card
        spread.rows[1].folderLabel = "e"
        #expect(ContentView.askClaudePDFReport(spread, part, isHidden: { _ in false }).contains(": “A (rotated).pdf” ⟦/d/A (rotated).pdf⟧, 1 page, \(FileSyncManager.formatBytes(1000)), next to each original."),
                "\(ContentView.askClaudePDFReport(spread, part, isHidden: { _ in false }))")
    }

    /// **Undo's line names nothing in a hidden folder** — the caller gives it the names Claude may hear.
    @Test func undoSaysWhatWentToTheTrash() {
        #expect(ContentView.askClaudePDFUndoReport("Compress", trashed: ["“A (compressed).pdf”"], left: [])
                == "They undid your card “Compress”: “A (compressed).pdf” is in the Trash.")
        #expect(ContentView.askClaudePDFUndoReport("Split", trashed: ["“A (page 1).pdf”", "a file in a folder hidden from you"],
                                                   left: ["“A (pages 2–3).pdf” (changed since)"])
                == "They undid your card “Split”: “A (page 1).pdf”, a file in a folder hidden from you are in the Trash. Left where it was: “A (pages 2–3).pdf” (changed since).")
    }

    /// **A file named twice, and two sizes at once, are refused** — a file twice put two rows of
    /// one path on the card, and with Choose Folder… the run built a map of them and trapped.
    @Test func refusesAFileNamedTwiceAndTwoSizes() throws {
        let one = try file("A.pdf")
        var handles = AskClaudeHandles()
        let handle = handles.handle(for: one)
        let ctx = context()
        let runner = AskClaudeBrowseTools(context: { ctx }, statDisk: { _ in nil })
        let twice = runner.pdfCard(AskClaudeToolCall(id: "t", name: "pdf", input: .object([
            "action": .string("save_as_pdf"), "handles": .array([.string(handle), .string(handle.uppercased())])])), ctx, handles)
        #expect(twice.isError && twice.result.contains("given twice"), "\(twice.result)")
        let both = offer(["action": .string("compress"), "strength": .string("best"), "under_mb": .integer(5)], paths: [one])
        #expect(both.isError && both.result.contains("not both"), "\(both.result)")
        let blank = try #require(offer(["action": .string("rotate"), "pages": .string("  ")], paths: [one]).pdf)
        #expect(blank.options.pages == nil, "blank pages turned only “\(blank.options.pages ?? "")”")
    }

    /// **Extract and Delete with no pages named show the card, not a question**: its Pages field
    /// opens empty, Claude is told so, and the button waits until the field holds pages that can
    /// be. Reorder still asks: it needs every page, in order.
    @Test func extractOrDeleteWithoutPagesOffersAnEmptyField() throws {
        let one = try file("Statement.pdf")
        for action in ["extract", "delete_pages"] {
            for given: [String: JSONFragment] in [[:], ["pages": .string("  ")]] {
                let outcome = offer(given.merging(["action": .string(action)]) { _, new in new }, paths: [one])
                let card = try #require(outcome.pdf, "\(action) \(given): \(outcome.result)")
                #expect(!outcome.isError)
                #expect(card.options.pages == nil)
                #expect(outcome.result.contains("the card opens with its Pages field empty"), "\(outcome.result)")
                #expect(AskClaudePDFCardView.pagesBlank(card))
            }
        }
        let named = offer(["action": .string("extract"), "pages": .string("3-5")], paths: [one])
        #expect(!named.result.contains("Pages field empty"), "pages named, yet Claude heard none were")

        func waiting(_ action: AskClaudePDFCard.Action, _ pages: String?) -> String? {
            let card = AskClaudePDFCard(action: action, rows: [.init(path: one, name: "Statement.pdf", folderLabel: "d", pageCount: 8)],
                                        options: .init(pages: pages), state: .offered)
            return ContentView.askClaudePDFPagesProblem(card, pageCount: 8)
        }
        #expect(waiting(.extract, nil) == "Type the pages to keep, in the order you want them — e.g. 3-5, 1.")
        #expect(waiting(.deletePages, nil) == "Type the pages to leave out — e.g. 1, 4-6.")
        #expect(waiting(.extract, "3-5") == nil)
        #expect(waiting(.deletePages, "1") == nil)
        let empty = AskClaudePDFCard(action: .extract, rows: [.init(path: one, name: "Statement.pdf", folderLabel: "d", pageCount: 8)],
                                     state: .offered)
        #expect(ContentView.askClaudePDFTool(empty, password: nil) == nil, "an empty field made a tool to run")
        #expect(AskClaudePDFCardView.planned(empty, empty.rows[0]) == nil)
    }

    // MARK: The extras

    /// **Each row says the file it will make** — in the folder chosen, when there is one; Split names
    /// its first part and how many more; Combine's name is its own field.
    @Test func eachRowSaysTheFileItWillMake() {
        func card(_ action: AskClaudePDFCard.Action, _ options: AskClaudePDFCard.Options = .init(), folder: String? = nil)
        -> AskClaudePDFCard {
            AskClaudePDFCard(action: action, rows: [.init(path: "/d/Statement.pdf", name: "Statement.pdf", folderLabel: "d",
                                                          pageCount: 8)],
                             options: options, state: .offered, folder: folder)
        }
        func planned(_ c: AskClaudePDFCard) -> String? { AskClaudePDFCardView.planned(c, c.rows[0]) }
        #expect(planned(card(.compress)) == "Statement (compressed).pdf")
        #expect(planned(card(.extract, .init(pages: "3-5"))) == "Statement (pages 3–5).pdf")
        #expect(planned(card(.extract, .init(pages: "99"))) == nil, "pages it can't read plan nothing")
        #expect(planned(card(.split, .init(splitAt: [4]))) == "Statement (pages 1–3).pdf and 1 more")
        #expect(planned(card(.rotate, folder: "/Users/me/Out")) == "Statement (rotated).pdf in “Out”")
        #expect(planned(card(.combine)) == nil)
        var word = card(.saveAsPDF)
        word.rows[0].path = "/d/Lease.docx"
        #expect(planned(word) == "Lease.pdf")
    }

    /// **The row of pages each card draws** — Delete's taken-out pages struck through among their
    /// neighbours, Reorder's first pages in the new order (not page order, as it once was), the
    /// rest unmarked; seven places at most, so the row fits the card; nothing while the pages typed
    /// can't be read.
    @Test func eachCardDrawsItsPagesAsTheNewFileHasThem() {
        func strip(_ action: AskClaudePDFCard.Action, _ options: AskClaudePDFCard.Options, pages: Int = 12,
                   problem: String? = nil) -> [AskClaudePDFCardView.PageCell] {
            var card = AskClaudePDFCard(action: action, rows: [.init(path: "/d/S.pdf", name: "S.pdf", folderLabel: "d", pageCount: pages)],
                                        options: options, state: .offered)
            card.pagesProblem = problem
            return AskClaudePDFCardView.pageStrip(card)
        }
        typealias C = AskClaudePDFCardView.PageCell
        #expect(strip(.deletePages, .init(pages: "1")) == [C.page(0, struck: true), .page(1, struck: false)])
        #expect(strip(.deletePages, .init(pages: "5, 9")) == [C.page(3, struck: false), .page(4, struck: true), .page(5, struck: false), .gap,
                                                             .page(7, struck: false), .page(8, struck: true), .page(9, struck: false)])
        #expect(strip(.reorder, .init(pages: "3, 1, 2"), pages: 3) == [C.page(2, struck: false), .page(0, struck: false), .page(1, struck: false)])
        #expect(strip(.reorder, .init(pages: "8, 1, 2, 3, 4, 5, 6, 7"), pages: 8)
                == [C.page(7, struck: false), .page(0, struck: false), .page(1, struck: false), .page(2, struck: false),
                    .page(3, struck: false), .page(4, struck: false), .gap])
        #expect(strip(.extract, .init(pages: "3-5")) == [C.page(1, struck: false), .page(2, struck: false), .page(3, struck: false),
                                                        .page(4, struck: false), .page(5, struck: false)])
        #expect(strip(.extract, .init(pages: "1-12")).count == AskClaudePDFCardView.stripPlaces)
        #expect(strip(.split, .init(splitAt: [4]), pages: 8) == [C.page(2, struck: false), .page(3, struck: false), .page(4, struck: false)])
        #expect(strip(.deletePages, .init(pages: "99")) == [], "pages it can't read draw nothing")
        #expect(strip(.deletePages, .init(pages: "1"), problem: "No.") == [])
        #expect(strip(.rotate, .init()) == [], "Rotate on every page draws no row")
        #expect(AskClaudePDFCardView.stripPages([.gap, .page(4, struck: true), .page(0, struck: false)]) == [4, 0])
        #expect(AskClaudePDFCardView.pageLabel(4, struck: true, position: nil) == "Page 5, taken out")
        #expect(AskClaudePDFCardView.pageLabel(7, struck: false, position: 1) == "Page 8, placed 1")
    }

    /// **A run still going tells Claude how far it has got**, and says only that it runs when the
    /// window can't say.
    @Test func aRunStillGoingSaysHowFar() {
        #expect(AskClaudeChat.stillRunning("Compress · 20 files", progress: "File 7 of 20 · Mar.pdf")
                == "Your card “Compress · 20 files” is still running (File 7 of 20 · Mar.pdf); what it makes is reported when it ends.")
        #expect(AskClaudeChat.stillRunning("Split", progress: nil)
                == "Your card “Split” is still running; what it makes is reported when it ends.")
    }

    /// **With no Undo, the card says why and what to do** — gone after a quit or a new chat, or
    /// left alone because the file changed.
    @Test func withNoUndoTheCardSaysWhatToDo() {
        var card = AskClaudePDFCard(action: .compress, rows: [.init(path: "/d/A.pdf", name: "A.pdf", folderLabel: "d")], state: .done)
        card.written = [.init(path: "/d/A (compressed).pdf", stamp: AskClaudeFileStamp(modifiedAt: nil, size: 1, fileID: 1), bytes: 1)]
        #expect(AskClaudePDFCardView.noUndoNote(card, held: false)
                == "Undo isn’t kept once SyncCloud quits or the chat starts over. Move the new file to the Trash yourself if you don’t want it.")
        #expect(AskClaudePDFCardView.noUndoNote(card, held: true) == "Undo leaves the new file alone: it has changed since.")
        card.written.append(card.written[0])
        #expect(AskClaudePDFCardView.noUndoNote(card, held: false).hasSuffix("Move the new files to the Trash yourself if you don’t want them."))
    }

    // MARK: The card fits

    /// **Every action's card, offered and done, asks for no more than 240 pt** — the narrowest the
    /// panel leaves it. It sees a row too wide to wrap, not one squeezed: a card whose width fits.
    @Test(arguments: AskClaudePDFCard.Action.allCases)
    func everyCardFits240(_ action: AskClaudePDFCard.Action) {
        let rows: [AskClaudePDFCard.Row] = (action == .combine ? ["A long receipt name from a hotel.pdf", "Another.pdf"]
                                                               : ["Statement October 2026 with a long name.pdf"]).map {
            .init(path: "/Users/me/Library/Mobile Documents/com~apple~CloudDocs/Documents/Travel/2026/\($0)", name: $0,
                  folderLabel: "iCloud › Documents › Travel › 2026 › Sep", bytes: 18_200_000, pageCount: 22,
                  refusal: action == .protect ? "It already has a password. Remove it first." : nil)
        }
        for state in [AskClaudePDFCard.State.offered, .running, .done, .quitWhileRunning] {
            let card = AskClaudePDFCard(action: action, rows: rows,
                                        options: .init(strength: .balanced, underMB: action == .compress ? 4.5 : nil,
                                                       quarterTurns: 1, pages: "3-5, 1", splitAt: [4, 9], mode: .restrictEditing,
                                                       name: "A long receipt name from a hotel (combined).pdf"),
                                        state: state,
                                        losses: [PDFCardFactsReader.compressRedraw, PDFCardFactsReader.formFlattened],
                                        written: [.init(path: "/d/Statement (pages 3–5, 1).pdf",
                                                        stamp: AskClaudeFileStamp(modifiedAt: nil, size: 1, fileID: 1), bytes: 1)],
                                        message: "Saved “Statement October 2026 with a long name (pages 3–5, 1).pdf” — 18.2 MB → 3.1 MB")
            let view = AskClaudePDFCardView(itemID: UUID(), card: card,
                                            bridge: AskClaudePDFBridge(offersUndo: { _ in true }), accent: .blue, hue: .blue)
            let width = NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: 240, height: 3_000)).width
            #expect(width <= 240, "\(action) \(state) asks for \(width) pt")
        }
    }
}

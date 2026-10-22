import AppKit
import Design
import os
import PDFKit
import SwiftUI
import Sync
import Testing
@testable import FileExplorer

/// PDFs with chosen text, a line per string — so a phrase can be split across two lines the way a
/// typeset page splits it.
enum PDFTextFixtures {
    static func write(_ path: String, pages: [[String]]) {
        var box = CGRect(origin: .zero, size: PDFFixtures.letter)
        let context = CGContext(URL(fileURLWithPath: path) as CFURL, mediaBox: &box, nil)!
        for lines in pages {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            for (index, line) in lines.enumerated() {
                (line as NSString).draw(at: NSPoint(x: 72, y: box.height - 120 - CGFloat(index) * 30),
                                        withAttributes: [.font: NSFont.systemFont(ofSize: 18)])
            }
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
    }
}

/// **The matching rules, without a PDF.**
@Suite struct EditorPDFTextMatchTests {

    private func matched(_ query: String, in text: String) -> [String] {
        EditorPDFTextMatch.ranges(of: query, in: text).map { (text as NSString).substring(with: $0) }
    }

    /// **A phrase broken across a line still matches**, and the match covers the break — so its
    /// selection spans both lines on the page.
    @Test func aPhraseMatchesAcrossALineBreak() {
        #expect(matched("quarterly report", in: "See the quarterly\nreport below.") == ["quarterly\nreport"])
        #expect(matched("quarterly report", in: "the quarterly \r\n  report") == ["quarterly \r\n  report"])
        // Runs of spaces in the QUERY are one space too.
        #expect(matched("quarterly   report", in: "quarterly report") == ["quarterly report"])
    }

    @Test func matchingIsCaseAndDiacriticInsensitive() {
        #expect(matched("CAFÉ", in: "the cafe and the Café") == ["cafe", "Café"])
        #expect(matched("resume", in: "Résumé, RESUME") == ["Résumé", "RESUME"])
    }

    /// The `ﬁ` ligature a typeset PDF stores is found by a typed "fi".
    @Test func aLigatureMatchesItsLetters() {
        #expect(matched("final", in: "the \u{FB01}nal figure") == ["\u{FB01}nal"])
    }

    /// **A hyphen that ends a line is optional** (TE163): the word broken there is found whole,
    /// and so is a hyphenated compound — the match covers the hyphen and the break. A hyphen in
    /// the middle of a line stays a hyphen.
    @Test func aHyphenAtALineEndIsOptional() {
        #expect(matched("example", in: "an exam-\nple here") == ["exam-\nple"])
        #expect(matched("well-known", in: "a well-\r\n  known name") == ["well-\r\n  known"])
        #expect(matched("example", in: "an exam\u{00AD}\nple, an exam\u{2010}\nple") == ["exam\u{00AD}\nple", "exam\u{2010}\nple"])
        // Both a match with the hyphen and one without, at one place, are one match.
        #expect(matched("exam", in: "exam-\nple") == ["exam"])
        #expect(matched("e", in: "e-\ne") == ["e", "e"])
        // Not at a line end: the hyphen is a hyphen, and a space is a space.
        #expect(matched("example", in: "exam-ple, exam- ple").isEmpty)
        #expect(matched("exam ple", in: "exam-\nple").isEmpty)
        #expect(matched("well-known", in: "well-known") == ["well-known"])
        // ⌘E on a broken word puts the whole word in the field.
        #expect(EditorPDFTextMatch.oneLine("exam-\n ple") == "example")
        #expect(EditorPDFTextMatch.oneLine("a well- known - b") == "a well- known - b")
    }

    @Test func matchesDoNotOverlapAndANothingQueryFindsNothing() {
        #expect(matched("aa", in: "aaaa") == ["aa", "aa"])
        #expect(matched("  \n ", in: "a b").isEmpty)
        #expect(matched("x", in: "").isEmpty)
    }

    /// **From the page on screen, wrapping** — the order turns are asked for.
    @Test func pagesAreSearchedFromTheCurrentOneAndWrap() {
        #expect(EditorPDFFind.order(start: 3, count: 5) == [3, 4, 0, 1, 2])
        #expect(EditorPDFFind.order(start: 0, count: 3) == [0, 1, 2])
        #expect(EditorPDFFind.order(start: 9, count: 3) == [2, 0, 1], "a start past the end clamps")
        #expect(EditorPDFFind.order(start: 0, count: 0).isEmpty)
    }

    @Test func theCounterSaysWhereItIsAndWhetherItIsDone() {
        func caption(_ phase: EditorPDFFind.Phase, _ count: Int, _ current: Int?, waiting: Bool = false,
                     query: String = "tax") -> String {
            EditorPDFFind.caption(phase: phase, query: query, count: count, current: current, isWaiting: waiting)
        }
        #expect(caption(.searching, 9, 2) == "3 of 9 so far")
        #expect(caption(.done, 9, 2) == "3 of 9")
        #expect(caption(.searching, 0, nil) == "Searching…")
        #expect(caption(.done, 0, nil) == "Not found")
        #expect(caption(.searching, 9, 2, waiting: true) == "3 of 9 so far · Waiting for other PDF work…")
        #expect(caption(.done, 9, 2, waiting: true) == "3 of 9", "a finished search waits on nothing")
        #expect(caption(.noText, 0, nil) == "This PDF has no text to search")
        #expect(caption(.idle, 0, nil) == "")
        #expect(caption(.searching, 0, nil, query: "  ") == "")
    }
}

/// **Find inside an open PDF** — `EditorPDFFind`, searched a page per lane turn from a document of
/// its own. Serialized for `EditorPDFDocumentTests`' reason; the turns that must be held are held
/// on a lane of the test's own (`EditorPDFRailTests.HeldLane`), and the one test that holds the
/// process's lane does it from a detached task.
@MainActor
@Suite(.serialized) final class EditorPDFFindTests {

    let folder = NSTemporaryDirectory() + "editor-pdf-find-" + UUID().uuidString
    typealias HeldLane = EditorPDFRailTests.HeldLane

    init() throws {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(atPath: folder) }

    private func path(_ name: String) -> String { (folder as NSString).appendingPathComponent(name) }

    /// Waits until `done` holds — bounded in turns, a labeled failure rather than a hang.
    @discardableResult
    private func wait(_ label: String, turns: Int = 4000, until done: () -> Bool) async -> Bool {
        for _ in 0..<turns {
            if done() { return true }
            _ = await PDFKitSerialAccess.perform {}
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        Issue.record("timed out waiting for \(label)")
        return false
    }

    /// A five-page PDF with "needle" once on every page.
    private func needles(_ name: String = "needles.pdf", pages: Int = 5) -> String {
        let file = path(name)
        PDFTextFixtures.write(file, pages: (0..<pages).map { ["Page \($0 + 1) has a needle in it."] })
        return file
    }

    private func find(_ file: String, pages: Int, lane: EditorPDFLane = .pdfKit,
                      view: EditorPDFViewState = EditorPDFViewState()) -> EditorPDFFind {
        let find = EditorPDFFind(view: view, lane: lane)
        find.attach(path: file, pageCount: pages, hasText: true)
        return find
    }

    private func opened(_ file: String) async -> EditorPDFDocument {
        let pdf = EditorPDFDocument(isCloudOnly: { _ in false })
        pdf.open(path: file, log: { _ in })
        await wait("the PDF to open") { pdf.phase != .loading }
        return pdf
    }

    // MARK: The search

    /// **Turns start at the page on screen and wrap**, and the first match shown is that page's.
    @Test func theSearchStartsAtTheCurrentPageAndWraps() async {
        let view = EditorPDFViewState()
        view.currentPage = 3
        let find = find(needles(), pages: 5, view: view)
        find.show()
        find.search("needle")
        await wait("the search") { find.phase == .done }
        #expect(find.landed == [3, 4, 0, 1, 2])
        #expect(find.matches.map(\.pageIndex) == [0, 1, 2, 3, 4], "matches are not kept in document order")
        #expect(find.currentIndex.map { find.matches[$0].pageIndex } == 3,
                "the first match shown is not the current page's")
        #expect(view.pageRequest?.value == 3, "the first match's page was not asked for")
        #expect(view.revealRequest?.value.pageIndex == 3, "the first match was not scrolled into sight")
        #expect(find.caption == "4 of 5")
    }

    /// **⌘G and ⇧⌘G wrap**, and each step asks for its match's page.
    @Test func steppingWrapsBothWays() async {
        let view = EditorPDFViewState()
        let find = find(needles(), pages: 5, view: view)
        find.show()
        find.search("needle")
        await wait("the search") { find.phase == .done }
        #expect(find.currentIndex == 0)
        find.step(forward: false)
        #expect(find.currentIndex == 4)
        #expect(view.pageRequest?.value == 4)
        find.step(forward: true)
        #expect(find.currentIndex == 0)
        find.step(forward: true)
        #expect(find.currentIndex == 1)
        #expect(view.pageRequest?.value == 1)
    }

    /// **A phrase broken across two lines on a real page is found, as one match on two lines.**
    @Test func aPhraseBrokenAcrossLinesIsFoundOnThePage() async {
        let file = path("broken.pdf")
        PDFTextFixtures.write(file, pages: [["The annual", "statement is enclosed."]])
        let find = find(file, pages: 1)
        find.show()
        find.search("annual statement")
        await wait("the search") { find.phase == .done }
        #expect(find.matches.count == 1, "the phrase across the break was not found")
        #expect(find.matches.first?.rects.count == 2, "the match is not drawn on both lines")
    }

    /// **A changed query withdraws the turn already queued**: held behind the lane, the first
    /// search's page turn comes up after the second has started, and must skip without reading.
    @Test func aChangedQueryWithdrawsItsQueuedPages() async {
        let lane = HeldLane()
        defer { lane.release() }
        let find = find(needles(pages: 20), pages: 20, lane: lane.lane)
        find.show()
        lane.hold()
        find.search("needle")
        let stale = find.currentTicket
        await wait("the first turn to queue") { find.asking != nil }
        find.search("Page")
        let live = find.currentTicket
        lane.release()
        await wait("the second search") { find.phase == .done }
        #expect(stale.bodies.withLock { $0 } == 0, "a withdrawn search's page turn ran its body")
        #expect(find.skippedTurns == 0, "the stale turn landed on the live search")
        #expect(live.bodies.withLock { $0 } == 20)
        #expect(find.matches.count == 20)
        #expect(PDFKitSerialAccess.peakConcurrentParses <= 1)
    }

    /// **Esc and Done clear what was drawn.**
    @Test func hidingClearsTheHighlights() async {
        let find = find(needles(pages: 3), pages: 3)
        find.show()
        find.search("needle")
        await wait("the search") { find.phase == .done }
        #expect(find.highlights.pages.count == 3)
        #expect(find.highlights.current?.page == 0)
        find.hide()
        #expect(find.highlights == .none, "Esc left highlights drawn")
        #expect(find.matches.isEmpty && !find.isShown && find.phase == .idle)
        // Shown again, the kept query is searched again.
        find.show()
        await wait("the search again") { find.phase == .done }
        #expect(find.matches.count == 3)
    }

    /// **The card keeps its width while the count changes** — the capsule slides clear of the card,
    /// so a card as wide as its count moved a capsule docked beside it at every step of a search.
    @Test func theFindCardKeepsItsWidthAsTheCountChanges() async {
        let find = find(needles(pages: 3), pages: 3)
        func width() -> CGFloat { NSHostingView(rootView: EditorPDFFindBar(find: find, accent: .blue)).fittingSize.width }
        find.show()
        find.search("needle")
        let searching = find.caption, early = width()
        await wait("the search") { find.phase == .done }
        #expect(find.caption != searching, "the premise: the count changed, from \(searching)")
        #expect(width() == early, "the card is \(early)pt at “\(searching)” and \(width())pt at “\(find.caption)”")
        // And, count and all, it still fits the narrowest column at every text size.
        let room = EditorPDFHeaderWidthTests.column - 2 * EditorPDFFloating.inset
        for percent in FontSize.selectablePercents {
            let card = EditorPDFFindBar(find: find, accent: .blue).environment(\.appFontScale, FontSize(percent: percent).scale)
            let fitted = NSHostingController(rootView: card).sizeThatFits(in: CGSize(width: room, height: 200)).width
            #expect(fitted <= room, "at \(percent)% the find card is \(fitted)pt, over the \(room)pt the column has")
        }
    }

    /// **The highlights are the matches, by page, in their order** — kept as each page lands, from a
    /// search that started mid-file and wrapped, and gone with a new query. They used to be rebuilt
    /// from every match on every read of the reader's body.
    @Test func theHighlightsAreTheMatchesByPage() async {
        let file = path("twice.pdf")
        PDFTextFixtures.write(file, pages: (0..<6).map { ["Page \($0 + 1): a needle,", "and a second needle."] })
        let view = EditorPDFViewState()
        view.currentPage = 3
        let find = find(file, pages: 6, view: view)
        find.show()
        find.search("needle")
        await wait("the search") { find.phase == .done }
        var rebuilt: [Int: [[CGRect]]] = [:]
        for match in find.matches { rebuilt[match.pageIndex, default: []].append(match.rects) }
        #expect(find.matches.count == 12)
        #expect(find.highlights.pages == rebuilt)
        find.search("second")
        await wait("the new search") { find.phase == .done }
        #expect(find.highlights.pages.values.map(\.count) == Array(repeating: 1, count: 6))
        // A query on one page leaves no other page lit from the last one.
        find.search("Page 3")
        await wait("the one-page search") { find.phase == .done }
        #expect(find.matches.map(\.pageIndex) == [2])
        #expect(Array(find.highlights.pages.keys) == [2], "pages lit from an earlier query: \(find.highlights.pages.keys.sorted())")
    }

    /// **Hiding withdraws the turn already queued**, as a changed query does.
    @Test func hidingWithdrawsItsQueuedPages() async {
        let lane = HeldLane()
        defer { lane.release() }
        let find = find(needles(pages: 10), pages: 10, lane: lane.lane)
        find.show()
        lane.hold()
        find.search("needle")
        let stale = find.currentTicket
        await wait("the first turn to queue") { find.asking != nil }
        find.hide()
        lane.release()
        #expect(!stale.isWanted)
        // The lane is FIFO: a turn queued behind the stale one has run once this one has.
        await lane.lane.perform { () -> Int in 0 }
        #expect(stale.bodies.withLock { $0 } == 0, "a turn queued before Esc read its page")
        #expect(find.matches.isEmpty)
    }

    /// **A turn that waits on the lane says so** — and stops saying it once it runs.
    @Test func aTurnThatWaitsSaysSo() async {
        let lane = HeldLane()
        defer { lane.release() }
        let find = find(needles(pages: 3), pages: 3, lane: lane.lane)
        find.show()
        lane.hold()
        find.search("needle")
        // Bounded in turns, not a fixed sleep (`docs/flaky-tests.md`, "Fixed pumps and fixed sleeps"):
        // the turn is held, so it waits past the threshold however busy the machine is.
        await wait("the waiting line") { find.isWaiting }
        #expect(find.isWaiting, "a turn held behind other work does not say it is waiting")
        #expect(find.caption.contains(EditorPDFFind.waitingCaption))
        lane.release()
        await wait("the search") { find.phase == .done }
        #expect(!find.isWaiting)
    }

    /// **⌘E takes the reader's selection; nothing selected changes nothing.**
    @Test func useSelectionTakesTheSelectionAsTheQuery() async {
        let find = find(needles(pages: 2), pages: 2)
        #expect(!find.useSelection(nil))
        #expect(!find.useSelection("  \n"))
        #expect(!find.isShown, "an empty selection opened the bar")
        #expect(find.useSelection("  needle \n"))
        #expect(find.isShown && find.query == "needle")
        await wait("the search") { find.phase == .done }
        #expect(find.matches.count == 2)
    }

    // MARK: The lane and the reader's document

    /// **A page turn runs inside `PDFKitSerialAccess`**: with the process's lane held, nothing is
    /// read; released, the page is.
    @Test func aFindPageRunsThroughTheLane() async throws {
        let file = needles("lane.pdf", pages: 1)
        let source = EditorPDFFind.Source(path: file)
        let ticket = EditorPDFFind.Ticket()
        let (readWhileHeld, found) = await Task.detached { () -> (Int, Int) in
            let hold = LaneHold()
            guard await hold.waitUntilHeld() else { hold.release(); return (-1, 0) }
            let turn = Task.detached { await EditorPDFFind.searchPage(0, query: "needle", source: source, ticket: ticket) }
            try? await Task.sleep(for: .milliseconds(200))
            let read = ticket.bodies.withLock { $0 }
            hold.release()
            if case .page(_, let matches) = await turn.value { return (read, matches.count) }
            return (read, 0)
        }.value
        try #require(readWhileHeld >= 0, "the lane never came free to be held")
        #expect(readWhileHeld == 0, "a page was read while the lane was held — around it")
        #expect(found == 1)
        #expect(PDFKitSerialAccess.peakConcurrentParses <= 1)
    }

    /// **No text is ever read from the reader's document** — the search reads its own, and the
    /// reader's is never handed to it, opened or unlocked.
    @Test func theReadersDocumentIsNeverSearched() async throws {
        let pdf = await opened(needles("reader.pdf", pages: 3))
        let reader = try #require(pdf.document)
        pdf.find.show()
        pdf.find.search("needle")
        await wait("the search") { pdf.find.phase == .done }
        let read = try #require(pdf.find.currentSource).readDocuments.withLock { $0 }
        #expect(!read.isEmpty, "the search read nothing — this check would be vacuous")
        #expect(!read.contains(ObjectIdentifier(reader)), "the search read text from the reader's document")
        #expect(pdf.find.matches.count == 3)

        // Unlocked: the find's copy is made in the unlock's turn, and is not the reader's either.
        let locked = path("locked.pdf")
        PDFFixtures.writeLocked(locked, password: "pw", pages: 2)
        let secret = await opened(locked)
        #expect(secret.phase == .locked)
        secret.find.show()
        #expect(secret.find.phase == .idle && secret.find.currentSource == nil, "a locked PDF offers a search")
        #expect(await secret.unlock(password: "pw"))
        let unlockedReader = try #require(secret.document)
        let copy = try #require(secret.find.currentSource?.document, "the unlock handed the find no copy")
        #expect(copy !== unlockedReader, "the find was handed the reader's own document")
        secret.find.search("Page")
        await wait("the unlocked search") { secret.find.phase == .done }
        #expect(secret.find.matches.count == 2)
        let readUnlocked = try #require(secret.find.currentSource).readDocuments.withLock { $0 }
        #expect(!readUnlocked.contains(ObjectIdentifier(unlockedReader)))
    }

    /// **An image-only PDF says so and never queues a page.**
    @Test func anImageOnlyPDFHasNothingToSearch() async throws {
        let file = path("scan.pdf")
        PDFFixtures.write(file, pages: 4, text: false)
        let pdf = await opened(file)
        #expect(pdf.facts?.hasText == false, "the premise: the facts call it image only")
        pdf.find.show()
        pdf.find.search("anything")
        #expect(pdf.find.phase == .noText)
        #expect(pdf.find.caption == EditorPDFFind.noTextCaption)
        #expect(!pdf.find.isSearchable)
        _ = await PDFKitSerialAccess.perform {}
        #expect(pdf.find.asking == nil && pdf.find.searchedPages == 0)
        #expect(pdf.find.currentTicket.bodies.withLock { $0 } == 0, "an image-only PDF queued a page")
        #expect(try #require(pdf.find.currentSource).readDocuments.withLock { $0 }.isEmpty)
    }

    /// **A book whose first pages are scans is still searched** — a cover and plates in front of a
    /// text body. The facts asked only the first five pages for text, called it image only, and
    /// Find refused the whole book.
    @Test func aPDFWhoseFrontPagesAreScansIsStillSearched() async throws {
        let scans = path("plates.pdf"), body = needles("body.pdf", pages: 3), book = path("book.pdf")
        PDFFixtures.write(scans, pages: 6, text: false)
        let merged = try #require(PDFDocument(url: URL(fileURLWithPath: scans)))
        let text = try #require(PDFDocument(url: URL(fileURLWithPath: body)))
        for index in 0..<text.pageCount {
            merged.insert(try #require(text.page(at: index)), at: merged.pageCount)
        }
        #expect(merged.write(to: URL(fileURLWithPath: book)))
        let pdf = await opened(book)
        #expect(pdf.facts?.pageCount == 9)
        #expect(pdf.facts?.hasText == true, "a book with a text body was called image only")
        pdf.find.show()
        pdf.find.search("needle")
        await wait("the search to finish") { pdf.find.phase == .done }
        #expect(pdf.find.matches.count == 3)
    }

    /// **A PDF evicted while open is not downloaded by a search.** Esc lets the search's copy go and
    /// the next search reopens it from the path — on a dataless file `PDFDocument(url:)` would fetch
    /// it, in the lane. Its pages fail instead, and no document is opened.
    @Test func aSearchDoesNotDownloadAFileEvictedWhileOpen() async throws {
        let pdf = await opened(needles("evicted.pdf", pages: 6))
        pdf.find.isCloudOnly = { _ in true }
        pdf.find.attach(path: try #require(pdf.path), pageCount: 6, hasText: true)
        pdf.find.show()
        pdf.find.search("needle")
        await wait("the search to finish") { pdf.find.phase == .done }
        let source = try #require(pdf.find.currentSource)
        #expect(source.readDocuments.withLock { $0 }.isEmpty, "the search opened the evicted file")
        #expect(pdf.find.failedPages == 6 && pdf.find.matches.isEmpty)
    }

    /// **Closing the PDF withdraws the search and lets its document go**; the query is kept.
    @Test func closingWithdrawsTheSearchAndReleasesItsDocument() async throws {
        let pdf = await opened(needles("close.pdf", pages: 40))
        pdf.find.show()
        pdf.find.search("needle")
        await wait("a match") { !pdf.find.matches.isEmpty }
        let ticket = pdf.find.currentTicket
        pdf.close()
        #expect(!ticket.isWanted, "closing left the search's turns wanted")
        #expect(pdf.find.currentSource == nil, "closing kept the search's document")
        #expect(!pdf.find.isShown && pdf.find.matches.isEmpty && pdf.find.phase == .idle)
        #expect(pdf.find.query == "needle", "the query should be kept for the next ⌘F")
    }

    // MARK: Drawing

    /// **The highlights are drawn by an overlay on top of the pages, from geometry**: setting them
    /// installs it above PDFKit's own views and maps a page rect through `convert(_:from:)`.
    @Test func theOverlaySitsOnTopAndMapsPageRects() throws {
        let file = needles("overlay.pdf", pages: 2)
        let document = try #require(PDFDocument(url: URL(fileURLWithPath: file)))
        let reader = ReaderPDFView(frame: CGRect(x: 0, y: 0, width: 400, height: 500))
        reader.document = document
        reader.layoutDocumentView()
        let rect = CGRect(x: 72, y: 600, width: 100, height: 20)
        reader.highlights = EditorPDFHighlights(pages: [0: [[rect]]], current: .init(page: 0, ordinal: 0))
        reader.layout()
        let overlay = try #require(reader.subviews.last as? EditorPDFFindOverlay, "the overlay is not on top")
        let page = try #require(document.page(at: 0))
        let placed = try #require(overlay.place(rect, on: page))
        #expect(placed == overlay.convert(reader.convert(rect, from: page), from: reader))
        #expect(overlay.hitTest(NSPoint(x: placed.midX, y: placed.midY)) == nil, "the overlay takes clicks")
        reader.highlights = .none
        #expect(overlay.highlights.isEmpty)
    }

    /// **Esc is wired to hide**, from the bar's own field — a key a hosted field cannot be sent —
    /// and so is the card's × (Phase 6a: the card's close, where the bar had Done). The card is
    /// mounted over the pages, in the canvas, and no longer under the header.
    @Test func escInTheFieldHidesTheBar() throws {
        let source = try ChromeGlassWiringTests.source("EditorPDFFindBar.swift")
        #expect(source.contains(".onExitCommand { find.hide() }"), "Esc in the PDF find field no longer hides the bar")
        #expect(source.contains("Button { find.hide() } label: {"), "the card's × does not put it away")
        let canvas = try ChromeGlassWiringTests.source("EditorPDFCanvas.swift")
        #expect(canvas.contains("EditorPDFFindBar(find: find, accent: accent)"), "the card is not mounted over the pages")
        let workspace = try ChromeGlassWiringTests.source("EditorWorkspaceView.swift")
        #expect(!workspace.contains("EditorPDFFindBar("), "the find bar is still a row under the header")
    }

    // MARK: Review fixes (2026-10-17)

    /// **Typing back to the query searched drops the settle pending for what was typed between** —
    /// it returned early and left that search to fire.
    @Test func typingBackToTheQueryDropsTheStaleSettle() async {
        let find = find(needles(pages: 2), pages: 2)
        find.show()
        find.search("needle")
        await wait("the search") { find.phase == .done }
        let started = find.searchesStarted
        find.type("needl")
        find.type("needle")
        try? await Task.sleep(for: EditorPDFFind.typingSettle * 3)
        #expect(find.query == "needle", "a stale settle searched for \(find.query)")
        #expect(find.searchesStarted == started, "typing back to the query searched again")
    }

    /// **⌘E on a hidden bar searches once — for the selection**, and a selection made across lines
    /// is put on one.
    @Test func useSelectionSearchesOnceAndOnOneLine() async {
        let file = path("lines.pdf")
        PDFTextFixtures.write(file, pages: [["The annual", "statement is enclosed."]])
        let find = find(file, pages: 1)
        find.search("kept from before")
        let started = find.searchesStarted
        #expect(find.useSelection("annual\nstatement"))
        #expect(find.query == "annual statement")
        #expect(find.searchesStarted == started + 1, "showing the bar searched the old query first")
        await wait("the search") { find.phase == .done }
        #expect(find.matches.count == 1)
    }

    /// **A PDF whose text cannot be read says so**, rather than "Not found".
    @Test func aPDFWhoseTextCannotBeReadSaysSo() async {
        let file = path("not-a-pdf.pdf")
        FileManager.default.createFile(atPath: file, contents: Data("not a pdf".utf8))
        let find = find(file, pages: 3)
        find.show()
        find.search("x")
        await wait("the search") { find.phase == .done }
        #expect(find.caption == EditorPDFFind.unreadableCaption)
    }

    /// **Hiding lets the search's document go and gives the pages the keyboard back.**
    @Test func hidingReleasesTheDocumentAndHandsBackTheKeyboard() async throws {
        let view = EditorPDFViewState()
        let find = find(needles(pages: 2), pages: 2, view: view)
        find.show()
        find.search("needle")
        await wait("the search") { find.phase == .done }
        let source = try #require(find.currentSource)
        let focus = view.focusRequest
        find.hide()
        #expect(find.currentSource !== source, "the bar went away and the search kept its document")
        #expect(view.focusRequest == focus + 1, "the pages were not given the keyboard back")
        find.hide()
        #expect(view.focusRequest == focus + 1, "a second Esc asked again with nothing closed")
    }

    /// **A finished search logs one line, without the query; a withdrawn one logs nothing.**
    @Test func aFinishedSearchLogsOneLineWithoutTheQuery() async {
        // Named so the path holds neither query word: the check is on the line, not the file.
        let find = find(needles("plain.pdf", pages: 3), pages: 3)
        var lines: [String] = []
        find.log = { lines.append($0) }
        find.show()
        find.search("needle")
        find.search("Page")
        await wait("the search") { find.phase == .done }
        #expect(lines.count == 1, "\(lines)")
        #expect(lines.first?.hasPrefix("Editor searched ") == true)
        #expect(lines.first?.contains("(PDF, 3 pages): 3 matches in ") == true, "\(lines)")
        #expect(lines.first?.contains("Page") == false && lines.first?.contains("needle") == false,
                "the log carries the query")
        #expect(EditorPDFFind.logLine(path: "/p.pdf", pageCount: 1, matches: 1, failed: 1,
                                      elapsed: .milliseconds(1500), waited: 2)
                == "Editor searched /p.pdf (PDF, 1 page): 1 match in 1.5 s — 2 page turns waited on other PDF work — 1 page unreadable")
    }

    /// **A reload under an open bar searches the new file again.**
    @Test func aReloadUnderTheBarSearchesAgain() async {
        let file = needles(pages: 3)
        let find = find(file, pages: 3)
        find.show()
        find.search("needle")
        await wait("the search") { find.phase == .done }
        find.attach(path: file, pageCount: 3, hasText: true)
        #expect(find.phase == .searching && find.query == "needle")
        await wait("the search again") { find.phase == .done }
        #expect(find.matches.count == 3)
    }

    /// **The tint leaves the text readable**: black text under the current match's tint against
    /// the tinted page, at WCAG's 4.5:1 for body text.
    @Test func theHighlightLeavesTheTextReadable() throws {
        let tint = try #require(NSColor.findHighlightColor.usingColorSpace(.sRGB))
        func over(_ base: CGFloat, alpha: CGFloat) -> [CGFloat] {
            [tint.redComponent, tint.greenComponent, tint.blueComponent].map { alpha * $0 + (1 - alpha) * base }
        }
        func luminance(_ rgb: [CGFloat]) -> CGFloat {
            let l = rgb.map { $0 <= 0.03928 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return 0.2126 * l[0] + 0.7152 * l[1] + 0.0722 * l[2]
        }
        for alpha in [EditorPDFFindOverlay.currentAlpha, EditorPDFFindOverlay.otherAlpha] {
            let text = luminance(over(0, alpha: alpha)), page = luminance(over(1, alpha: alpha))
            let ratio = (page + 0.05) / (text + 0.05)
            #expect(ratio >= 4.5, "text under a \(alpha) tint reads at \(ratio):1")
        }
    }

    /// **Zooming redraws the highlights**, and a page turn does too — the clip's bounds need not move.
    @Test func zoomingRedrawsTheHighlights() throws {
        let file = needles("zoom.pdf", pages: 2)
        let reader = ReaderPDFView(frame: CGRect(x: 0, y: 0, width: 400, height: 500))
        reader.document = PDFDocument(url: URL(fileURLWithPath: file))
        reader.layoutDocumentView()
        // In a window: `needsDisplay` reads false for a view with nowhere to draw.
        let window = NSWindow(contentRect: reader.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = reader
        defer { window.contentView = nil }
        reader.highlights = EditorPDFHighlights(pages: [0: [[CGRect(x: 72, y: 600, width: 100, height: 20)]]])
        let overlay = try #require(reader.subviews.last as? EditorPDFFindOverlay)
        reader.displayIfNeeded()
        overlay.needsDisplay = false
        NotificationCenter.default.post(name: .PDFViewScaleChanged, object: reader)
        #expect(overlay.needsDisplay, "a zoom left the highlights where the pages were")
        overlay.needsDisplay = false
        NotificationCenter.default.post(name: .PDFViewVisiblePagesChanged, object: reader)
        #expect(overlay.needsDisplay, "a page turn left the highlights where the pages were")
    }

    /// **A step to a match on its own page does not jump to the page's top first**, and a match
    /// already in sight is not scrolled to.
    @Test func showingAMatchDoesNotJumpThePage() throws {
        let reveal = EditorPDFReveal(pageIndex: 3, rect: .zero)
        #expect(!EditorPDFPageView.goesToPageTop(page: 3, reveal: reveal))
        #expect(EditorPDFPageView.goesToPageTop(page: 3, reveal: nil))
        #expect(EditorPDFPageView.goesToPageTop(page: 4, reveal: reveal))

        let file = needles("sight.pdf", pages: 6)
        let document = try #require(PDFDocument(url: URL(fileURLWithPath: file)))
        let reader = ReaderPDFView(frame: CGRect(x: 0, y: 0, width: 700, height: 900))
        reader.displayMode = .singlePageContinuous
        reader.autoScales = false
        reader.scaleFactor = 1
        reader.document = document
        let window = NSWindow(contentRect: reader.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = reader
        defer { window.contentView = nil }
        reader.layoutDocumentView()
        reader.go(to: try #require(document.page(at: 0)))
        let first = try #require(document.page(at: 0)), last = try #require(document.page(at: 5))
        #expect(EditorPDFPageView.isInSight(CGRect(x: 72, y: 650, width: 100, height: 20), on: first, in: reader))
        #expect(!EditorPDFPageView.isInSight(CGRect(x: 72, y: 650, width: 100, height: 20), on: last, in: reader))
        // **Under the find card is not in sight**, though the card keeps no band: a step there
        // scrolls the match out. The card is in the canvas's top-left space, as SwiftUI places it.
        let match = CGRect(x: 72, y: 650, width: 100, height: 20)
        let drawn = reader.convert(match, from: first)
        reader.coveredRects = [CGRect(x: drawn.minX - 4, y: reader.bounds.height - drawn.maxY - 4,
                                      width: drawn.width + 8, height: drawn.height + 8)]
        #expect(!EditorPDFPageView.isInSight(match, on: first, in: reader), "a match under the find card was in sight")
        reader.coveredRects = [CGRect(x: drawn.minX, y: reader.bounds.height - drawn.minY + 40, width: 50, height: 20)]
        #expect(EditorPDFPageView.isInSight(match, on: first, in: reader), "a card clear of the match hid it")
    }

    /// **A step to a match under a floating piece brings it out** — not only judges it covered.
    /// PDFKit's `go(to:on:)` does nothing for a rect already on screen, so a match under Fill &
    /// Sign's palette in the middle of the canvas stayed under it at every ⌘G.
    @Test func aMatchUnderThePaletteIsScrolledClearOfIt() throws {
        let file = needles("palette.pdf", pages: 6)
        let document = try #require(PDFDocument(url: URL(fileURLWithPath: file)))
        let reader = ReaderPDFView(frame: CGRect(x: 0, y: 0, width: 700, height: 900))
        reader.displayMode = .singlePageContinuous
        reader.autoScales = false
        reader.scaleFactor = 1
        reader.document = document
        let window = NSWindow(contentRect: reader.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = reader
        defer { window.contentView = nil }
        reader.layoutDocumentView()
        let first = try #require(document.page(at: 0))
        reader.go(to: first)
        // A match well inside the view, and a palette-shaped piece over it at the canvas's left.
        let match = CGRect(x: 72, y: 500, width: 100, height: 20)
        let drawn = reader.convert(match, from: first)
        reader.coveredRects = [CGRect(x: 0, y: reader.bounds.height - drawn.midY - 120, width: drawn.maxX + 20, height: 240)]
        try #require(!EditorPDFPageView.isInSight(match, on: first, in: reader), "the piece does not cover the match")
        reader.go(to: match.insetBy(dx: -24, dy: -48), on: first)
        try #require(!EditorPDFPageView.isInSight(match, on: first, in: reader),
                     "PDFKit scrolled a visible rect after all, so this proves nothing")

        EditorPDFPageView.reveal(match, on: first, in: reader)
        #expect(EditorPDFPageView.isInSight(match, on: first, in: reader), "the match is still under the palette")
        // The least move: just above or below the piece, not a jump to the page's top.
        let moved = reader.convert(match, from: first)
        #expect(abs(moved.midY - drawn.midY) < 200, "the match moved \(moved.midY - drawn.midY)pt for a 240pt piece")
    }

    /// **The find card and the pieces beside it slide as the card changes size** (TE159) — the
    /// count coming and going and the waiting line, not each new count — and nothing slides for a
    /// window resize alone.
    @Test func theFindCardAndItsNeighboursSlide() throws {
        #expect(EditorPDFFindBar.shape(caption: "") == 0)
        #expect(EditorPDFFindBar.shape(caption: "1 of 12 so far") == EditorPDFFindBar.shape(caption: "3 of 9"))
        let waiting = EditorPDFFind.caption(phase: .searching, query: "tax", count: 9, current: 2, isWaiting: true)
        #expect(EditorPDFFindBar.shape(caption: waiting) == 2)
        let canvas = try ChromeGlassWiringTests.source("EditorPDFCanvas.swift")
        #expect(ChromeGlassWiringTests.count(".designAnimation(.easeOut(duration: 0.2), value: findCard)", in: canvas) == 3,
                "the palette, the save pill and the capsule don't all slide with the card")
        #expect(canvas.contains(".designAnimation(.easeOut(duration: 0.2), value: EditorPDFFindBar.shape(caption: find.caption))"))
        #expect(!canvas.contains("value: canvas)"), "the pieces slide for a window resize")
    }

    /// **A bookmark's place comes to the top of the view** (TE187), not its page's top — and out
    /// from under a piece floating there.
    @Test func aBookmarksPlaceComesToTheTop() throws {
        let file = needles("bookmark.pdf", pages: 6)
        let document = try #require(PDFDocument(url: URL(fileURLWithPath: file)))
        let reader = ReaderPDFView(frame: CGRect(x: 0, y: 0, width: 700, height: 500))
        reader.displayMode = .singlePageContinuous
        reader.autoScales = false
        reader.scaleFactor = 1
        reader.document = document
        let window = NSWindow(contentRect: reader.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = reader
        defer { window.contentView = nil }
        reader.layoutDocumentView()
        reader.go(to: try #require(document.page(at: 0)))
        let third = try #require(document.page(at: 2))
        let heading = CGPoint(x: 72, y: 300)
        EditorPDFPageView.place(heading, on: third, in: reader)
        let shown = reader.convert(heading, from: third)
        let top = reader.isFlipped ? shown.y : reader.bounds.height - shown.y
        #expect(top >= 0 && top < 80, "the heading is \(top)pt below the top, not at it")
        // Judged by where it is drawn: `visiblePages` still names page 1 straight after the jump.
        #expect(EditorPDFPageView.isClear(reader.convert(CGRect(x: 72, y: 280, width: 100, height: 20), from: third), in: reader))
        // A piece over the top band: the place comes out from under it.
        reader.go(to: try #require(document.page(at: 0)))
        reader.coveredRects = [CGRect(x: 0, y: 0, width: reader.bounds.width, height: 60)]
        EditorPDFPageView.place(heading, on: third, in: reader)
        let clear = reader.convert(heading, from: third)
        let below = reader.isFlipped ? clear.y : reader.bounds.height - clear.y
        #expect(below > 60 && below < 160, "the heading is \(below)pt down, under the piece or far below it")
    }

    /// **The pages' right-click menu keeps PDFKit's text items and drops its view controls** —
    /// Automatically Resize, the zooms and the display modes changed the view behind the reader's
    /// state, so a layout picked there snapped back while the capsule showed another.
    @Test func theRightClickMenuHasNoViewControls() throws {
        let file = needles("menu.pdf", pages: 2)
        let reader = ReaderPDFView(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        reader.document = try #require(PDFDocument(url: URL(fileURLWithPath: file)))
        let window = NSWindow(contentRect: reader.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = reader
        defer { window.contentView = nil }
        reader.layoutDocumentView()
        let click = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: NSPoint(x: 300, y: 400), modifierFlags: [],
                                                    timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                    eventNumber: 0, clickCount: 1, pressure: 1))
        // Over a page with nothing selected PDFKit offers only its view controls — so no menu at all.
        #expect(reader.menu(for: click) == nil)
        // On selected text: Copy, and nothing that drives the view.
        let page = try #require(reader.document?.page(at: 0))
        let words = try #require(page.selection(for: page.bounds(for: .mediaBox)))
        reader.go(to: page)
        reader.setCurrentSelection(words, animate: false)
        let onWords = reader.convert(reader.convert(CGPoint(x: words.bounds(for: page).midX, y: words.bounds(for: page).midY), from: page), to: nil)
        let rightClick = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: onWords, modifierFlags: [],
                                                         timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                         eventNumber: 0, clickCount: 1, pressure: 1))
        let menu = try #require(reader.menu(for: rightClick))
        let actions = menu.items.compactMap { $0.action.map(NSStringFromSelector) }
        #expect(actions.contains("copy:"), "Copy went too: \(actions)")
        let left = actions.filter(ReaderPDFView.viewControlActions.contains)
        #expect(left.isEmpty, "view controls still in the menu: \(left)")
        #expect(menu.items.first?.isSeparatorItem == false && menu.items.last?.isSeparatorItem == false)
        #expect(!zip(menu.items, menu.items.dropFirst()).contains { $0.isSeparatorItem && $1.isSeparatorItem })
        // Control: PDFKit's own menu, as a plain PDFView gives it, does carry them.
        let plain = PDFView(frame: reader.frame)
        plain.document = reader.document
        plain.setCurrentSelection(page.selection(for: page.bounds(for: .mediaBox)), animate: false)
        window.contentView = plain
        plain.layoutDocumentView()
        let own = plain.menu(for: rightClick)?.items.compactMap { $0.action.map(NSStringFromSelector) } ?? []
        #expect(own.contains("zoomIn:") || own.contains("_setAutoSize:"), "PDFKit's menu has no view controls to remove: \(own)")
    }

    /// **⌘A over the pages selects the page on screen** — the spread in a two-page layout — not the
    /// whole PDF, whose every page PDFKit read on the main thread first (decided 2026-10-20).
    @Test func selectAllTakesThePageOnScreen() throws {
        let file = needles("select.pdf", pages: 6)
        let reader = ReaderPDFView(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        let document = try #require(PDFDocument(url: URL(fileURLWithPath: file)))
        reader.document = document
        let window = NSWindow(contentRect: reader.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = reader
        defer { window.contentView = nil }
        reader.displayMode = .singlePage
        reader.layoutDocumentView()
        reader.go(to: try #require(document.page(at: 2)))
        EditorPDFReaderSelection.selectPagesOnScreen(in: reader)
        let one = reader.currentSelection?.pages.map { document.index(for: $0) } ?? []
        #expect(one == [2], "selected \(one)")
        #expect(reader.currentSelection?.string?.contains("Page 3") == true)

        reader.displayMode = .twoUp
        reader.displaysAsBook = true
        reader.layoutDocumentView()
        reader.go(to: try #require(document.page(at: 3)))
        EditorPDFReaderSelection.selectPagesOnScreen(in: reader)
        let spread = reader.currentSelection?.pages.map { document.index(for: $0) }.sorted() ?? []
        #expect(spread == [3, 4], "the cover-separately spread holding page 4 is 4–5: \(spread)")
    }

    /// **The least vertical move that clears every piece**, inside the clear rect — or none.
    @Test func theClearingShiftsAreTheLeastMovesOutFirst() {
        let clear = CGRect(x: 0, y: 0, width: 400, height: 600)
        let shown = CGRect(x: 20, y: 290, width: 100, height: 20)
        #expect(EditorPDFPageView.clearingShifts(of: shown, clear: clear, covered: []).first == 0)
        let palette = CGRect(x: 0, y: 250, width: 60, height: 100)
        // Out above the palette (350 + 8 − 290 = 68), then below it (250 − 8 − 310 = −68).
        #expect(EditorPDFPageView.clearingShifts(of: shown, clear: clear, covered: [palette]).prefix(2) == [68, -68])
        // Never into a second piece: above the palette is under the card.
        let card = CGRect(x: 0, y: 352, width: 400, height: 60)
        #expect(EditorPDFPageView.clearingShifts(of: shown, clear: clear, covered: [palette, card]).first == -68)
        // A piece beside the match, not over it, moves nothing.
        #expect(EditorPDFPageView.clearingShifts(of: shown, clear: clear, covered: [CGRect(x: 200, y: 280, width: 50, height: 50)]).first == 0)
        // Nowhere to go.
        #expect(EditorPDFPageView.clearingShifts(of: shown, clear: clear, covered: [clear]).isEmpty)
    }

    /// **Esc in the pages closes the bar when it is up**, and goes on as before when it is not.
    @Test func escInThePagesClosesTheBar() throws {
        let reader = ReaderPDFView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        var closes = 0
        var open = true
        reader.onEscape = { guard open else { return false }; closes += 1; open = false; return true }
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                   windowNumber: 0, context: nil, characters: "\u{1b}",
                                                   charactersIgnoringModifiers: "\u{1b}", isARepeat: false,
                                                   keyCode: ReaderPDFView.escapeKeyCode))
        reader.keyDown(with: escape)
        #expect(closes == 1)
        reader.keyDown(with: escape)
        #expect(closes == 1, "a second Esc closed something that was not open")

        let canvas = try ChromeGlassWiringTests.source("EditorPDFCanvas.swift")
        #expect(canvas.contains("guard find.isShown else { return false }"), "the reader's Esc is not the bar's")
        let source = try ChromeGlassWiringTests.source("EditorPDFFindBar.swift")
        #expect(!source.contains(".disabled(!find.isSearchable)"), "the field is disabled, so Esc cannot reach it")
    }

    /// **⌘E's selection is read from the page view mounted now** — one torn down after its
    /// successor was built leaves the successor's in place.
    @Test func anOldPageViewKeepsItsHandsOffTheNewOnesSelection() {
        let state = EditorPDFViewState()
        let old = ReaderPDFView(), new = ReaderPDFView()
        state.reader = old
        state.reader = new
        EditorPDFPageView.dismantleNSView(old, coordinator: EditorPDFPageView.Coordinator(state: state))
        #expect(state.reader === new, "dismantling the old view took the new one's selection away")
        EditorPDFPageView.dismantleNSView(new, coordinator: EditorPDFPageView.Coordinator(state: state))
        #expect(state.reader == nil)
    }

}

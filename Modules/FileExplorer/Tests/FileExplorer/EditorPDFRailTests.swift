import Testing
import os
import AppKit
import PDFKit
import SwiftUI
import Sync
@testable import FileExplorer
import FileExplorerTestSupport

/// **Phase 1b of the PDF reader: Edit's rail learns PDFs** — the Files tab's two sections, the
/// Pages tab and its thumbnails, and a PDF's bookmarks in Outline.
///
/// Serialized, and every wait bounded in lane TURNS, for `EditorPDFDocumentTests`' reason: the
/// thumbnails and the outline are read through `PDFKitSerialAccess`'s one lane.
@MainActor
@Suite(.serialized) final class EditorPDFRailTests {

    let folder = NSTemporaryDirectory() + "editor-pdf-rail-" + UUID().uuidString

    init() throws {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(atPath: folder) }

    private func path(_ name: String) -> String { (folder as NSString).appendingPathComponent(name) }

    @discardableResult
    private func wait(_ label: String, turns: Int = 1000, until done: () -> Bool) async -> Bool {
        for _ in 0..<turns {
            if done() { return true }
            await PDFKitSerialAccess.perform {}
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("never happened in \(turns) lane turns: \(label)")
        return false
    }

    private func opened(_ file: String) async -> EditorPDFDocument {
        let pdf = EditorPDFDocument(isCloudOnly: { _ in false })
        pdf.open(path: file, log: { _ in })
        await wait("\(file) to open") { pdf.phase != .loading }
        return pdf
    }

    private func entry(_ name: String, kind: EditorRailEntry.Kind = .text) -> EditorRailEntry {
        EditorRailEntry(path: "/a/\(name)", name: name, size: 120, isCloudOnly: false, kind: kind)
    }

    // MARK: The survey

    /// **The text cap is a text read's, and a PDF never takes one.** A 10 MB scan is an ordinary
    /// PDF that opens on the click; the 10 MB `.txt` beside it is still refused, and says why.
    @Test func aTenMegabytePDFIsNotDimmedWhileATenMegabyteTextFileIs() throws {
        let tenMB = 10 * 1024 * 1024
        try Data(count: tenMB).write(to: URL(fileURLWithPath: path("scan.pdf")))
        try Data(repeating: 0x61, count: tenMB).write(to: URL(fileURLWithPath: path("log.txt")))

        let rows = EditorRail.entries(in: folder, showsHidden: false, isCloudOnly: { _ in false })
        let scan = try #require(rows.first { $0.name == "scan.pdf" })
        let log = try #require(rows.first { $0.name == "log.txt" })
        #expect(scan.kind == .pdf && log.kind == .text)
        #expect(scan.size == tenMB && log.size == tenMB, "fixture: \(scan.size), \(log.size)")
        #expect(!scan.isTooLarge && !scan.isDimmed && scan.dimmedReason == nil,
                "a 10 MB PDF was dimmed: \(scan.dimmedReason ?? "no reason")")
        #expect(log.isTooLarge && log.isDimmed)
        #expect(log.dimmedReason?.hasPrefix("Too large to open") == true)
    }

    /// Cloud-only is the one thing that dims a PDF row — in the words the reader's own refusal uses.
    @Test func aCloudOnlyPDFIsDimmedWithTheReadersWords() throws {
        let file = path("statement.pdf")
        try Data(count: 10).write(to: URL(fileURLWithPath: file))
        let row = try #require(EditorRail.entries(in: folder, showsHidden: false,
                                                  isCloudOnly: { $0 == file }).first)
        #expect(row.isDimmed)
        #expect(row.dimmedReason == EditorPDFDocument.notDownloadedReason)
    }

    // MARK: The Files tab

    /// Text Files, then PDFs, each in the order handed in — and a section with no rows is left out.
    @Test func sectionsAreTextThenPDFsAndAnEmptyOneIsLeftOut() {
        let mixed = [entry("a.md"), entry("b.pdf", kind: .pdf), entry("c.txt"), entry("d.pdf", kind: .pdf)]
        let sections = EditorRail.sections(mixed)
        #expect(sections.map(\.title) == ["Text Files", "PDFs"])
        #expect(sections.map { $0.rows.map(\.name) } == [["a.md", "c.txt"], ["b.pdf", "d.pdf"]])

        #expect(EditorRail.sections([entry("a.md")]).map(\.title) == ["Text Files"])
        #expect(EditorRail.sections([entry("b.pdf", kind: .pdf)]).map(\.title) == ["PDFs"])
        #expect(EditorRail.sections([]).isEmpty)
    }

    /// **⌘N in a folder of nothing but PDFs still opens the naming row** — the empty Text Files
    /// section is hidden, and the row is not inside it to be hidden with it.
    @Test func theNamingRowStillShowsInAPDFOnlyFolder() {
        func fields(naming: Bool) -> Int {
            let rail = Self.rail(entries: [entry("scan.pdf", kind: .pdf)], naming: naming)
            let host = NSHostingView(rootView: AnyView(rail.frame(width: 232, height: 400)))
            host.frame = CGRect(x: 0, y: 0, width: 232, height: 400)
            host.layoutSubtreeIfNeeded()
            var found = 0
            func walk(_ v: NSView) {
                if let field = v as? NSTextField, field.placeholderString == "Name" { found += 1 }
                v.subviews.forEach(walk)
            }
            walk(host)
            return found
        }
        #expect(fields(naming: true) == 1, "no naming row in a folder of PDFs")
        #expect(fields(naming: false) == 0, "control: a naming row with no ⌘N")
    }

    /// The captions say "text files and PDFs" now that the list holds both — the arms that changed.
    @Test func theEmptyCaptionsNameBothKinds() {
        #expect(EditorFileRailView.fileEmptyCaption(folderName: "", anyEntries: false, filter: "",
                                                    otherFiles: nil)
                == "Pick a folder in the sidebar to see its text files and PDFs.")
        #expect(EditorFileRailView.fileEmptyCaption(folderName: "Notes", anyEntries: true, filter: "zz",
                                                    otherFiles: nil)
                == "No files here match “zz”.")
        #expect(EditorFileRailView.fileEmptyCaption(folderName: "Notes", anyEntries: false, filter: "",
                                                    otherFiles: 0)
                == "No text files or PDFs in this folder. The + button makes a text file.")
    }

    // MARK: The tabs

    @Test func pagesIsOfferedOnlyWhileAPDFIsOpen() {
        #expect(EditorRailTab.shown(pdfIsOpen: true) == [.files, .pages, .outline])
        #expect(EditorRailTab.shown(pdfIsOpen: false) == [.files, .outline])
        #expect(EditorRailTab.files.title == "Files")
    }

    /// **Pages falls back to Files when text opens** — drawn, not written back, so the next PDF
    /// opens on Pages again. Outline is offered for both kinds and stays.
    @Test func pagesFallsBackToFilesWhenTextOpens() async {
        #expect(EditorRailTab.resolved(.pages, pdfIsOpen: false) == .files)
        #expect(EditorRailTab.resolved(.pages, pdfIsOpen: true) == .pages)
        #expect(EditorRailTab.resolved(.outline, pdfIsOpen: false) == .outline)

        // On the rail itself: the same remembered `.pages`, with a PDF and without.
        let file = path("two.pdf")
        PDFFixtures.write(file, pages: 2)
        let pdf = await opened(file)
        #expect(Self.rail(entries: [], tab: .pages, pdf: pdf).shownTab == .pages)
        #expect(Self.rail(entries: [], tab: .pages, pdf: nil).shownTab == .files)
    }

    // MARK: The thumbnails

    /// **Through the lane**: with the lane held no thumbnail is drawn; released, they arrive — and
    /// never two parses at once while another reader shares the lane.
    @Test func thumbnailsRenderThroughTheLane() async throws {
        let file = path("pages.pdf"), other = path("other.pdf")
        PDFFixtures.write(file, pages: 12)
        PDFFixtures.write(other, pages: 6)
        let pdf = await opened(file)
        #expect(pdf.phase == .open)

        let hold = LaneHold()
        defer { hold.release() }
        try #require(await hold.waitUntilHeld(), "the lane never came free to be held")
        pdf.thumbnails.show([0, 1, 2, 3])
        // **The hold is released the moment the first render is queued**, not after a pause:
        // every other PDF suite in the package waits on this lane, and a hold that waited on the
        // main actor (crowded in a full run) outlasted their 30 s budgets — measured: three lane
        // tests red with this suite in the run, all green with it skipped. `asking` is set as the
        // pump hands its turn to the lane; nothing drawn by then is the claim.
        await Self.until { pdf.thumbnails.asking != nil }
        let queued = pdf.thumbnails.asking
        let source = try #require(pdf.thumbnails.currentSource)
        // Off the main actor from here to the release: the control draws the same page OFF the
        // lane, three times over, so a render that went around the lane has had longer than it
        // needs — then the count is read and the lane let go, from this same task.
        let drawnWhileHeld = await Task.detached { [hold] () -> Int in
            let control = PDFDocument(url: URL(fileURLWithPath: file))
            for _ in 0..<3 {
                _ = control?.page(at: 0).flatMap { EditorPDFThumbnails.drawThumbnail($0, longEdge: 240) }
            }
            let drawn = source.draws.withLock { $0 }
            hold.release()
            return drawn
        }.value
        #expect(queued == 0, "the first visible page was not the first asked for")
        #expect(drawnWhileHeld == 0, "\(drawnWhileHeld) thumbnail(s) drawn while the lane was held — around it")

        async let elsewhere: Int = PDFKitSerialAccess.perform {
            PDFDocument(url: URL(fileURLWithPath: other))?.pageCount ?? 0
        }
        await wait("the visible thumbnails") { (0...3).allSatisfy { pdf.thumbnails.images[$0] != nil } }
        #expect(await elsewhere == 6)
        #expect(PDFKitSerialAccess.peakConcurrentParses <= 1)
        // The margin is rendered ahead of a scroll, and nothing past it.
        await wait("the margin") { pdf.thumbnails.images.count == 4 + EditorPDFThumbnails.margin }
        #expect(Set(pdf.thumbnails.images.keys) == Set(0..<(4 + EditorPDFThumbnails.margin)))
    }

    /// **Pages scrolled away are cancelled**: a window asked for and left before the lane came
    /// free is never drawn. Its one turn already queued skips itself at its head.
    @Test func pagesScrolledAwayAreCancelled() async throws {
        let file = path("long.pdf")
        PDFFixtures.write(file, pages: 300, text: false)
        let pdf = await opened(file)
        #expect(pdf.facts?.pageCount == 300)

        let hold = LaneHold()
        defer { hold.release() }
        try #require(await hold.waitUntilHeld(), "the lane never came free to be held")
        pdf.thumbnails.show(Set(0..<6))
        // The first window's turn must be queued behind the hold before the scroll away, or there
        // is nothing to cancel — and the hold goes the moment it is (see the test above).
        await Self.until { pdf.thumbnails.asking != nil }
        let queued = pdf.thumbnails.asking
        pdf.thumbnails.show(Set(200..<206))
        hold.release()
        try #require(queued == 0, "the first window's turn was never queued")

        await wait("the window scrolled to") { (200..<206).allSatisfy { pdf.thumbnails.images[$0] != nil } }
        let early = pdf.thumbnails.drawn.filter { $0 < 6 + EditorPDFThumbnails.margin }
        #expect(early.isEmpty, "pages scrolled away were drawn anyway: \(early)")
        #expect(pdf.thumbnails.skippedTurns == 1,
                "the turn queued for the first window ran \(pdf.thumbnails.skippedTurns == 0 ? "and drew" : "\(pdf.thumbnails.skippedTurns) times")")
    }

    /// **Bounded, and released with the PDF.** A long scroll keeps at most `capacity` images; a
    /// text file opening (the model's close) drops every one, and the document they came from.
    @Test func theThumbnailCacheIsBoundedAndReleasedOnClose() async {
        let file = path("scroll.pdf")
        PDFFixtures.write(file, pages: 120, text: false)
        let pdf = await opened(file)
        for start in stride(from: 0, to: 120, by: 12) {
            let window = Set(start..<min(start + 6, 120))
            pdf.thumbnails.show(window)
            await wait("window \(start)") { window.allSatisfy { pdf.thumbnails.images[$0] != nil } }
            #expect(pdf.thumbnails.images.count <= EditorPDFThumbnails.capacity,
                    "\(pdf.thumbnails.images.count) images held at window \(start)")
        }
        #expect(pdf.thumbnails.drawn.count > EditorPDFThumbnails.capacity,
                "fixture: the scroll drew only \(pdf.thumbnails.drawn.count) pages, never reaching the cap")
        #expect(pdf.thumbnails.holdsSource)

        pdf.close()
        #expect(pdf.thumbnails.images.isEmpty, "\(pdf.thumbnails.images.count) thumbnails outlived the PDF")
        #expect(!pdf.thumbnails.holdsSource, "the thumbnails' document outlived the PDF")
    }

    /// **The mounted grid asks for what is on screen** — and asks again when the PDF reloads under
    /// it, where no cell appears anew to say so.
    @Test func theMountedGridAsksForItsPagesAndAgainAfterAReload() async throws {
        let file = path("mounted.pdf")
        PDFFixtures.write(file, pages: 40)
        let pdf = EditorPDFDocument(settle: .milliseconds(10), isCloudOnly: { _ in false })
        pdf.open(path: file, log: { _ in })
        await wait("the open") { pdf.phase == .open }

        let grid = EditorPDFRailPages(pdf: pdf, view: pdf.view, thumbnails: pdf.thumbnails, accent: .blue)
        let host = NSHostingView(rootView: AnyView(grid.frame(width: 232, height: 300)))
        host.frame = CGRect(x: 0, y: 0, width: 232, height: 300)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        await wait("the first rows' thumbnails") {
            window.layoutIfNeeded()
            return pdf.thumbnails.images[0] != nil && pdf.thumbnails.images[1] != nil
        }
        #expect(pdf.thumbnails.images[39] == nil, "a page far below the fold was drawn: nothing is lazy")

        // Rewritten on disk: the model reloads, the thumbnails start over — and the grid, which
        // never left the screen, must ask again.
        // Different bytes, so a different size: the stamp moves whatever the clock's resolution.
        PDFFixtures.write(file, pages: 40, text: false)
        let before = pdf.thumbnails.attachments
        pdf.look()
        await wait("the reload") { pdf.thumbnails.attachments > before }
        await wait("the reloaded rows' thumbnails") {
            window.layoutIfNeeded()
            return pdf.thumbnails.images[0] != nil
        }
    }

    /// A page turned a quarter is drawn the way the reader shows it — landscape.
    @Test func aRotatedPageIsDrawnTurned() throws {
        let file = path("turned.pdf")
        PDFFixtures.write(file, pages: 1)
        let page = try #require(PDFDocument(url: URL(fileURLWithPath: file))?.page(at: 0))
        page.rotation = 90
        let image = try #require(EditorPDFThumbnails.drawThumbnail(page, longEdge: 240))
        #expect(image.width > image.height, "a quarter-turned portrait page drew \(image.width)×\(image.height)")
        #expect(max(image.width, image.height) == 240)
    }

    // MARK: The outline

    /// Writes `file` with `pages` blank pages and the bookmarks `tree` describes.
    ///
    /// **Through CoreGraphics' outline, not `PDFDocument.write`**: measured 2026-10-16, a
    /// `PDFOutline` built in memory and set as `outlineRoot` is not written — the file reads back
    /// with no outline at all. `CGPDFContextSetOutline` writes one, its destinations one-based.
    private func writeBookmarked(_ file: String, pages: Int, tree: [Bookmark]) {
        func node(_ mark: Bookmark) -> [String: Any] {
            var entry: [String: Any] = [kCGPDFOutlineTitle as String: mark.title]
            // No page → a web link: CoreGraphics crashes writing an entry with no destination
            // at all (signal 11, measured), and a link is the real-world bookmark with no page.
            entry[kCGPDFOutlineDestination as String] = mark.page.map { $0 + 1 as Any }
                ?? URL(string: "https://example.com/elsewhere")! as CFURL
            if !mark.children.isEmpty { entry[kCGPDFOutlineChildren as String] = mark.children.map(node) }
            return entry
        }
        var box = CGRect(origin: .zero, size: PDFFixtures.letter)
        let context = CGContext(URL(fileURLWithPath: file) as CFURL, mediaBox: &box, nil)!
        for _ in 0..<pages { context.beginPDFPage(nil); context.endPDFPage() }
        CGPDFContextSetOutline(context, [kCGPDFOutlineChildren as String: tree.map(node)] as CFDictionary)
        context.closePDF()
    }

    struct Bookmark {
        var title: String
        var page: Int?
        var children: [Bookmark] = []
    }

    /// **Flattened depth-first, with the right depths and pages**, read in the lane with the open.
    @Test func theOutlineIsFlattenedWithDepthsAndPages() async {
        let file = path("1099.pdf")
        writeBookmarked(file, pages: 6, tree: [
            Bookmark(title: "Summary", page: 0),
            Bookmark(title: "Short-term", page: 1, children: [
                Bookmark(title: "Box 1d", page: 1, children: [Bookmark(title: "Wash sales", page: 2)]),
            ]),
            Bookmark(title: "Long-term\nCovered", page: 3),
            Bookmark(title: "Elsewhere", page: nil),
        ])
        let pdf = await opened(file)
        #expect(pdf.outline == [
            EditorPDFOutlineEntry(title: "Summary", depth: 0, pageIndex: 0),
            EditorPDFOutlineEntry(title: "Short-term", depth: 0, pageIndex: 1),
            EditorPDFOutlineEntry(title: "Box 1d", depth: 1, pageIndex: 1),
            EditorPDFOutlineEntry(title: "Wash sales", depth: 2, pageIndex: 2),
            EditorPDFOutlineEntry(title: "Long-term Covered", depth: 0, pageIndex: 3),
            EditorPDFOutlineEntry(title: "Elsewhere", depth: 0, pageIndex: nil),
        ])
        // As the rail draws them: ids by position, so the scroll memory has a key per row.
        #expect(EditorPDFOutline.rows(pdf.outline).map(\.id) == Array(0..<6))
        #expect(EditorPDFRailOutline.pageLabels(pdf.outline) == [0: "1", 1: "2", 2: "2", 3: "3", 4: "4"])
        pdf.close()
        #expect(pdf.outline.isEmpty, "the bookmarks outlived the PDF")
    }

    /// The bookmark at or before the current page; the chapter rather than its first section when
    /// both start on it; nothing before the first.
    @Test func theCurrentBookmarkFollowsThePage() {
        let marks = [EditorPDFOutlineEntry(title: "A", depth: 0, pageIndex: 1),
                     EditorPDFOutlineEntry(title: "A.1", depth: 1, pageIndex: 1),
                     EditorPDFOutlineEntry(title: "web", depth: 0, pageIndex: nil),
                     EditorPDFOutlineEntry(title: "B", depth: 0, pageIndex: 4)]
        #expect(EditorPDFOutline.currentIndex(page: 0, in: marks) == nil)
        #expect(EditorPDFOutline.currentIndex(page: 1, in: marks) == 0)
        #expect(EditorPDFOutline.currentIndex(page: 3, in: marks) == 0)
        #expect(EditorPDFOutline.currentIndex(page: 9, in: marks) == 3)
    }

    /// **A PDF with no bookmarks keeps its Outline tab, and says so** — the tab count does not
    /// change under the reader.
    @Test func aPDFWithNoBookmarksSaysSo() async {
        let file = path("plain.pdf")
        PDFFixtures.write(file, pages: 2)
        let pdf = await opened(file)
        #expect(pdf.phase == .open && pdf.outline.isEmpty)
        #expect(EditorPDFOutline.emptyCaption(phase: pdf.phase) == "This PDF has no bookmarks.")
        #expect(EditorRailTab.shown(pdfIsOpen: true).contains(.outline))
    }

    /// **A PDF's outline keeps its place per file, in the one anchor map** — and the anchor goes
    /// with the file when it moves (`EditorOutlineScroll.moveAnchor`, the host's rekey).
    @Test func theOutlineAnchorIsRestoredAndSurvivesAMove() async throws {
        let file = path("long-outline.pdf")
        writeBookmarked(file, pages: 40, tree: (0..<40).map { Bookmark(title: "Chapter \($0 + 1)", page: $0) })
        let pdf = await opened(file)
        #expect(pdf.outline.count == 40)

        var anchors = [file: 30]
        EditorOutlineScroll.moveAnchor(in: &anchors, from: file, to: file + ".moved")
        #expect(anchors == [file + ".moved": 30], "the anchor did not follow the move: \(anchors)")
        EditorOutlineScroll.moveAnchor(in: &anchors, from: "/nowhere", to: "/else")
        #expect(anchors == [file + ".moved": 30], "a move of another file touched this one's anchor")

        // Restored on the mounted list, under the PDF's path — the Markdown outline's own wiring.
        final class Box { var anchors: [String: Int] = [:] }
        func offset(_ remembered: [String: Int]) -> CGFloat? {
            let box = Box()
            box.anchors = remembered
            let view = EditorPDFRailOutline(pdf: pdf, view: pdf.view,
                                            outlineAnchors: Binding(get: { box.anchors }, set: { box.anchors = $0 }),
                                            accent: .blue)
            let host = NSHostingView(rootView: AnyView(view.frame(width: 232, height: 200)))
            host.frame = CGRect(x: 0, y: 0, width: 232, height: 200)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            for _ in 0..<30 { _ = CFRunLoopRunInMode(.defaultMode, 0.02, true); window.layoutIfNeeded() }
            var scroll: NSScrollView?
            func walk(_ v: NSView) { if scroll == nil, let s = v as? NSScrollView { scroll = s }; v.subviews.forEach(walk) }
            walk(host)
            return scroll?.documentVisibleRect.origin.y
        }
        // **The Markdown outline's rule, for a page instead of a caret**: the current bookmark wins
        // when the anchor would leave it past the fold. So the reader is put on page 33, which
        // the anchor's view (row 30 onwards) shows — and the same page with no anchor is the
        // control: it opens on the current bookmark, row 32, further down than the anchor.
        pdf.view.currentPage = 32
        let current = try #require(offset([:]), "no scroll view in the mounted outline")
        let restored = try #require(offset([file: 30]))
        #expect(current > 100, "control: the current bookmark did not scroll the list: \(current)")
        #expect(restored > 100 && restored < current - 1,
                "the remembered row 30 did not set the list: \(restored), against \(current) for row 32 alone")
    }

    // MARK: Helpers

    /// Yields the main actor until `done` — no lane turn, for the waits made while the lane is
    /// held, and no fixed pause. Bounded so a pump that never asks fails rather than hangs.
    static func until(_ done: () -> Bool) async {
        for _ in 0..<20_000 where !done() { await Task.yield() }
    }

    static func rail(entries: [EditorRailEntry], naming: Bool = false, tab: EditorRailTab = .files,
                     pdf: EditorPDFDocument? = nil) -> EditorFileRailView {
        EditorFileRailView(folderName: "Notes", entries: entries, selectedPath: nil,
                           accent: .blue, onAccent: .white, tab: .constant(tab),
                           isNaming: .constant(naming), typedName: .constant(""),
                           prefilledName: { "Untitled.md" }, refusal: { _ in nil },
                           filter: .constant(""), filterIsExpanded: .constant(false),
                           outlineAnchors: .constant([:]), pdf: pdf,
                           onOpen: { _ in }, onCreate: { _ in true }, onNewTextFile: nil,
                           rowActions: EditorRailRowActions(revealInBrowse: { _ in }, getInfo: { _ in },
                                                            quickLook: { _ in }))
    }

    /// Holds the lane until released — `EditorPDFDocumentTests`' hold, for the same reason it polls.
    private final class LaneHold: Sendable {
        private let gate = DispatchSemaphore(value: 0)
        private let held = OSAllocatedUnfairLock(initialState: false)
        private let released = OSAllocatedUnfairLock(initialState: false)

        init() {
            Task.detached { [gate, held] in
                await PDFKitSerialAccess.perform { held.withLock { $0 = true }; gate.wait() }
            }
        }

        func waitUntilHeld() async -> Bool {
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline {
                if held.withLock({ $0 }) { return true }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            return false
        }

        func release() {
            let first = released.withLock { done in defer { done = true }; return !done }
            if first { gate.signal() }
        }
    }
}

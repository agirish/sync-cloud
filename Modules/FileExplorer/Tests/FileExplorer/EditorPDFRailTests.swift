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
        #expect(EditorRailTab.shown(pdfIsOpen: true, pdfHasOutline: true) == [.files, .pages, .outline])
        #expect(EditorRailTab.shown(pdfIsOpen: false, pdfHasOutline: false) == [.files, .outline])
        #expect(EditorRailTab.files.title == "Files")
    }

    /// **A PDF keeps Outline only with a contents worth the tab** (asked 2026-10-17): two
    /// bookmarks or more, every level counted. A text file keeps it whatever the flag says.
    /// Mutation: drop the threshold to 1 and the one-bookmark statement keeps its tab.
    @Test func aPDFOffersOutlineOnlyWithTwoBookmarksOrMore() {
        #expect(EditorRailTab.shown(pdfIsOpen: true, pdfHasOutline: false) == [.files, .pages])
        #expect(EditorRailTab.shown(pdfIsOpen: false, pdfHasOutline: false).contains(.outline))
        let one = [EditorPDFOutlineEntry(title: "Page Identifiers", depth: 0, pageIndex: 0)]
        let two = one + [EditorPDFOutlineEntry(title: "Transactions", depth: 1, pageIndex: 1)]
        #expect(!EditorRailTab.pdfOutlineIsWorthATab([]))
        #expect(!EditorRailTab.pdfOutlineIsWorthATab(one), "a lone bookmark — a statement's — kept the tab")
        #expect(EditorRailTab.pdfOutlineIsWorthATab(two), "a chapter with a section under it lost the tab")
        // A remembered Outline falls back to Files on a PDF without one, and comes back on the next.
        #expect(EditorRailTab.resolved(.outline, pdfIsOpen: true, pdfHasOutline: false) == .files)
        #expect(EditorRailTab.resolved(.outline, pdfIsOpen: true, pdfHasOutline: true) == .outline)
    }

    /// **Pages falls back to Files when text opens** — drawn, not written back, so the next PDF
    /// opens on Pages again. Outline is offered for text files and stays.
    @Test func pagesFallsBackToFilesWhenTextOpens() async {
        #expect(EditorRailTab.resolved(.pages, pdfIsOpen: false, pdfHasOutline: false) == .files)
        #expect(EditorRailTab.resolved(.pages, pdfIsOpen: true, pdfHasOutline: false) == .pages)
        #expect(EditorRailTab.resolved(.outline, pdfIsOpen: false, pdfHasOutline: false) == .outline)

        // On the rail itself: the same remembered `.pages`, with a PDF and without.
        let file = path("two.pdf")
        PDFFixtures.write(file, pages: 2)
        let pdf = await opened(file)
        #expect(Self.rail(entries: [], tab: .pages, pdf: pdf).shownTab == .pages)
        #expect(Self.rail(entries: [], tab: .pages, pdf: nil).shownTab == .files)

        // The bar reads the drawn tab and writes the CHOSEN one: a click on the Files it is shown
        // as is still a write, and a click elsewhere lands on the stored tab.
        final class Box { var tab = EditorRailTab.pages }
        let box = Box()
        let rail = Self.rail(entries: [], tab: Binding(get: { box.tab }, set: { box.tab = $0 }), pdf: nil)
        #expect(rail.tabBarSelection.wrappedValue == .files)
        rail.tabBarSelection.wrappedValue = .outline
        #expect(box.tab == .outline)
        rail.tabBarSelection.wrappedValue = .files
        #expect(box.tab == .files, "a click on the drawn Files left the stored Pages behind")
    }

    @Test func aRowWearsItsKindsGlyph() {
        #expect(EditorFileRailView.rowSymbol(.text) == "doc.text")
        #expect(EditorFileRailView.rowSymbol(.pdf) == "doc.richtext")
    }

    // MARK: The thumbnails

    /// **Through the lane**: with the process's PDFKit lane held, the render step draws nothing;
    /// released, it draws. **Held, drawn and released entirely off the main actor** — this is the
    /// one test that holds the real lane, and a hold that waits on the main actor (crowded in a
    /// full run) is what starved the other PDF suites' budgets (see `EditorPDFThumbnails.Lane`).
    @Test func thumbnailsRenderThroughTheLane() async throws {
        let file = path("pages.pdf")
        PDFFixtures.write(file, pages: 12)
        let source = EditorPDFThumbnails.Source(path: file)
        let wanted = EditorPDFThumbnails.Wanted()
        wanted.set([0])
        let (drawnWhileHeld, rendered) = await Task.detached { () -> (Int, Bool) in
            let hold = LaneHold()
            guard await hold.waitUntilHeld() else { hold.release(); return (-1, false) }
            let render = Task.detached { await EditorPDFThumbnails.render(page: 0, source: source, wanted: wanted) }
            // The control draws the same page OFF the lane, three times over, so a render that
            // went around the lane has had longer than it needs; then the count, then the release.
            let control = PDFDocument(url: URL(fileURLWithPath: file))
            for _ in 0..<3 {
                _ = control?.page(at: 0).flatMap { EditorPDFThumbnails.drawThumbnail($0, longEdge: 240) }
            }
            let drawn = source.draws.withLock { $0 }
            hold.release()
            if case .image = await render.value { return (drawn, true) }
            return (drawn, false)
        }.value
        try #require(drawnWhileHeld >= 0, "the lane never came free to be held")
        #expect(drawnWhileHeld == 0, "\(drawnWhileHeld) thumbnail(s) drawn while the lane was held — around it")
        #expect(rendered, "released, the render drew nothing")

        // And the pump, on the app's own lane: the visible pages, then the margin, nothing past it.
        let thumbnails = EditorPDFThumbnails()
        thumbnails.attach(path: file, pageCount: 12)
        thumbnails.show([0, 1, 2, 3])
        await wait("the visible thumbnails") { (0...3).allSatisfy { thumbnails.images[$0] != nil } }
        await wait("the margin") { thumbnails.images.count == 4 + EditorPDFThumbnails.margin }
        #expect(Set(thumbnails.images.keys) == Set(0..<(4 + EditorPDFThumbnails.margin)))
    }

    /// **Pages scrolled away are cancelled**: a window asked for and left before its turn came is
    /// never drawn. Its one turn already queued skips itself at its head. Held on a lane of the
    /// test's own, so nothing else in the package waits on this test.
    @Test func pagesScrolledAwayAreCancelled() async throws {
        let file = path("long.pdf")
        PDFFixtures.write(file, pages: 300, text: false)
        let lane = HeldLane()
        defer { lane.release() }
        let thumbnails = EditorPDFThumbnails(lane: lane.lane)
        thumbnails.attach(path: file, pageCount: 300)
        lane.hold()
        thumbnails.show(Set(0..<6))
        // The first window's turn must be queued behind the hold before the scroll away, or there
        // is nothing to cancel.
        await Self.until { thumbnails.asking != nil }
        let queued = thumbnails.asking
        thumbnails.show(Set(200..<206))
        lane.release()
        try #require(queued == 0, "the first window's turn was never queued")

        await wait("the window scrolled to") { (200..<206).allSatisfy { thumbnails.images[$0] != nil } }
        let early = thumbnails.drawn.filter { $0 < 6 + EditorPDFThumbnails.margin }
        #expect(early.isEmpty, "pages scrolled away were drawn anyway: \(early)")
        #expect(thumbnails.skippedTurns == 1,
                "the turn queued for the first window ran \(thumbnails.skippedTurns == 0 ? "and drew" : "\(thumbnails.skippedTurns) times")")
    }

    /// **Bounded, and released with the PDF.** A long scroll keeps at most `capacity` images; a
    /// text file opening (the model's close) drops every one, and the document they came from.
    @Test func theThumbnailCacheIsBoundedAndReleasedOnClose() async throws {
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
        // **The farthest went, not just any**: the last window is all there, the first all gone.
        #expect((108..<114).allSatisfy { pdf.thumbnails.images[$0] != nil }, "the window on screen was evicted")
        #expect(!pdf.thumbnails.images.keys.contains { $0 < 12 }, "the pages farthest from the screen were kept")
        // **And the document they come from was reopened along the way** (`Source.recycleEvery`).
        let source = try #require(pdf.thumbnails.currentSource)
        let draws = source.draws.withLock { $0 }, opens = source.opens.withLock { $0 }
        #expect(opens >= draws / EditorPDFThumbnails.recycleEvery && opens >= 2,
                "\(draws) pages drawn from \(opens) opening(s) — the thumbnails' document is never let go")

        pdf.close()
        #expect(pdf.thumbnails.images.isEmpty, "\(pdf.thumbnails.images.count) thumbnails outlived the PDF")
        #expect(!pdf.thumbnails.holdsSource, "the thumbnails' document outlived the PDF")
    }

    /// **The mounted grid asks for what is on screen** — and asks again when the PDF reloads under
    /// it, where no cell appears anew to say so.
    @Test func theMountedGridAsksForItsPagesAndAgainAfterAReload() async throws {
        let file = path("mounted.pdf")
        PDFFixtures.write(file, pages: 40)
        // A watch that never settles inside the test: the rewrite below is looked at once, by
        // hand. A live watch looked a second time, re-queuing the reload and withdrawing the first.
        let pdf = EditorPDFDocument(settle: .seconds(3600), isCloudOnly: { _ in false })
        pdf.open(path: file, log: { _ in })
        await wait("the open") { pdf.phase == .open }

        let grid = EditorPDFRailPages(pdf: pdf, view: pdf.view, thumbnails: pdf.thumbnails, tools: pdf.tools, accent: .blue)
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

    /// **A rotated or cropped page draws where the reader sees it** — read in pixels. A page marked
    /// in its top-left corner: turned a quarter clockwise, the mark is top-RIGHT; cropped to its
    /// top-left quarter, the mark is top-left and bigger. This was blank and shifted respectively
    /// while `transform(for:)` was applied on top of `draw(with:to:)` (measured 2026-10-17).
    @Test func aRotatedOrCroppedPageDrawsWhereTheReaderSeesIt() async throws {
        let file = path("marked.pdf")
        var box = CGRect(origin: .zero, size: PDFFixtures.letter)
        let context = try #require(CGContext(URL(fileURLWithPath: file) as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 692, width: 100, height: 100))
        context.endPDFPage()
        context.closePDF()

        struct Drawn: Sendable { let size: CGSize; let quadrants: [Int] }
        func draw(rotation: Int, cropped: Bool) async -> Drawn? {
            await PDFKitSerialAccess.perform {
                guard let page = PDFDocument(url: URL(fileURLWithPath: file))?.page(at: 0) else { return nil }
                page.rotation = rotation
                if cropped { page.setBounds(CGRect(x: 0, y: 392, width: 306, height: 400), for: .cropBox) }
                guard let image = EditorPDFThumbnails.drawThumbnail(page, longEdge: 240)?.cgImage else { return nil }
                return Drawn(size: CGSize(width: image.width, height: image.height),
                             quadrants: EditorPDFRailTests.darkQuadrants(image))
            }
        }
        // Quadrants: top-left, top-right, bottom-left, bottom-right — dark pixels in each.
        let plain = try #require(await draw(rotation: 0, cropped: false))
        #expect(plain.quadrants[0] > 0 && plain.quadrants[1...].allSatisfy { $0 == 0 }, "plain: \(plain.quadrants)")
        let turned = try #require(await draw(rotation: 90, cropped: false))
        #expect(turned.size.width > turned.size.height, "a quarter-turned page drew \(turned.size)")
        #expect(turned.quadrants[1] > 0 && turned.quadrants[0] == 0 && turned.quadrants[2] == 0
                    && turned.quadrants[3] == 0,
                "turned a quarter, the top-left mark is not top-right: \(turned.quadrants)")
        let cropped = try #require(await draw(rotation: 0, cropped: true))
        #expect(cropped.quadrants[0] > plain.quadrants[0] && cropped.quadrants[1...].allSatisfy { $0 == 0 },
                "cropped to the top-left, the mark is not top-left and bigger: \(cropped.quadrants) vs \(plain.quadrants)")
        let both = try #require(await draw(rotation: 90, cropped: true))
        #expect(both.quadrants[1] > 0, "turned and cropped drew \(both.quadrants)")
    }

    /// Dark pixels per quadrant, in the image's own orientation (row 0 at the top).
    nonisolated static func darkQuadrants(_ image: CGImage) -> [Int] {
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return [0, 0, 0, 0] }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return [0, 0, 0, 0] }
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        var counts = [0, 0, 0, 0]
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4] < 80 {
                counts[(y < height / 2 ? 0 : 2) + (x < width / 2 ? 0 : 1)] += 1
            }
        }
        return counts
    }

    /// **The placeholder is the shape the thumbnail will be** — crop box, turned — so a row does not
    /// change height when its image lands. `shownSizes` is read with the facts, in the lane.
    @Test func theFactsCarryEachPagesShownShape() async throws {
        let plain = path("portrait.pdf"), turned = path("turned-on-disk.pdf")
        PDFFixtures.write(plain, pages: 1)
        let written: Bool = await PDFKitSerialAccess.perform {
            guard let document = PDFDocument(url: URL(fileURLWithPath: plain)), let page = document.page(at: 0)
            else { return false }
            page.rotation = 90
            return document.write(to: URL(fileURLWithPath: turned))
        }
        try #require(written, "fixture: the rotated copy was not written")
        let pdf = await opened(turned)
        let facts = try #require(pdf.facts)
        #expect(facts.shownSizes == [CGSize(width: 792, height: 612)], "shown sizes: \(facts.shownSizes)")
        #expect(facts.pageSizes == [PDFFixtures.letter], "the paper stays the media box: \(facts.pageSizes)")
    }

    /// **A turn queued before a reload never draws from the old document** — each attachment has a
    /// wanted set of its own, so the old turn finds nothing wanted even when the reloaded PDF wants
    /// the very same page.
    @Test func aTurnFromBeforeAReloadDrawsNothing() async throws {
        let file = path("reloaded.pdf")
        PDFFixtures.write(file, pages: 10)
        let lane = HeldLane()
        defer { lane.release() }
        let thumbnails = EditorPDFThumbnails(lane: lane.lane)
        thumbnails.attach(path: file, pageCount: 10)
        lane.hold()
        thumbnails.show([0])
        await Self.until { thumbnails.asking != nil }
        let old = try #require(thumbnails.currentSource)
        thumbnails.attach(path: file, pageCount: 10)   // what a reload does
        thumbnails.show([0])                           // and the grid asks for the same page
        lane.release()
        await wait("the reloaded page") { thumbnails.images[0] != nil }
        #expect(old.draws.withLock { $0 } == 0, "the turn from before the reload drew from the old document")
    }

    /// **A password-unlocked PDF has thumbnails** — from the copy unlocked in the same turn, the
    /// password kept nowhere. Without that copy every page would fail, never retried.
    @Test func anUnlockedPDFHasThumbnails() async throws {
        let file = path("locked.pdf")
        PDFFixtures.writeLocked(file, password: "hunter2", pages: 3)
        let pdf = await opened(file)
        #expect(pdf.phase == .locked)
        #expect(await pdf.unlock(password: "hunter2"))
        pdf.thumbnails.show([0, 1, 2])
        await wait("the unlocked PDF's thumbnails") { (0...2).allSatisfy { pdf.thumbnails.images[$0] != nil } }
        let source = try #require(pdf.thumbnails.currentSource)
        #expect(!source.reopens, "an unlocked copy was marked reopenable — reopening would lock it again")
        #expect(source.opens.withLock { $0 } == 0,
                "the thumbnails reopened the locked file instead of drawing from the unlocked copy")
    }

    /// **A turn waiting in the lane does not keep the thumbnails alive.** The pump holds them only
    /// between turns: one waiting behind a long duplicate scan kept the object and its images
    /// past their owner when the loop held `self` through the wait.
    @Test func aQueuedTurnDoesNotKeepTheThumbnailsAlive() async throws {
        let file = path("alive.pdf")
        PDFFixtures.write(file, pages: 4)
        let lane = HeldLane()
        defer { lane.release() }
        lane.hold()
        var thumbnails: EditorPDFThumbnails? = EditorPDFThumbnails(lane: lane.lane)
        weak var weakly = thumbnails
        thumbnails?.attach(path: file, pageCount: 4)
        thumbnails?.show([0])
        await Self.until { thumbnails?.asking != nil }
        #expect(thumbnails?.asking == 0, "fixture: no turn was queued")
        thumbnails = nil
        #expect(weakly == nil, "a turn queued in the held lane is keeping the thumbnails alive")
    }

    /// The Pages tab says why there are no pages: the card's own reason for a refused file.
    @Test func thePagesTabSaysWhyThereAreNone() {
        #expect(EditorPDFRailPages.caption(phase: .refused(EditorPDFDocument.goneReason)) == EditorPDFDocument.goneReason)
        #expect(EditorPDFRailPages.caption(phase: .locked) == "Unlock the PDF to see its pages.")
        #expect(EditorPDFRailPages.caption(phase: .open) == "This PDF has no pages.")
    }

    /// **PDF B's outline opens at its own place, not where A was left** — the list's scroll state
    /// is per document. One model reopened in place, as an outside open does with Edit on screen.
    @Test func anotherPDFsOutlineDoesNotOpenWhereTheLastWasLeft() async throws {
        let first = path("first.pdf"), second = path("second.pdf")
        let marks = (0..<40).map { Bookmark(title: "Chapter \($0 + 1)", page: $0) }
        writeBookmarked(first, pages: 40, tree: marks)
        writeBookmarked(second, pages: 40, tree: marks)
        let pdf = await opened(first)
        pdf.view.currentPage = 32
        let view = EditorPDFRailOutline(pdf: pdf, view: pdf.view, outlineAnchors: .constant([:]), accent: .blue)
        let host = NSHostingView(rootView: AnyView(view.frame(width: 232, height: 200)))
        host.frame = CGRect(x: 0, y: 0, width: 232, height: 200)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        func settle() { for _ in 0..<30 { _ = CFRunLoopRunInMode(.defaultMode, 0.02, true); window.layoutIfNeeded() } }
        func offset() -> CGFloat? {
            var scroll: NSScrollView?
            func walk(_ v: NSView) { if scroll == nil, let s = v as? NSScrollView { scroll = s }; v.subviews.forEach(walk) }
            walk(host)
            return scroll?.documentVisibleRect.origin.y
        }
        settle()
        let onFirst = try #require(offset(), "no scroll view in the mounted outline")
        #expect(onFirst > 100, "control: the first PDF's outline did not open at its current bookmark: \(onFirst)")

        pdf.open(path: second, log: { _ in })
        await wait("the second PDF") { pdf.phase == .open && pdf.path == second }
        settle()
        let onSecond = try #require(offset())
        #expect(abs(onSecond) < 1, "the second PDF's outline opened where the first was left: \(onSecond)")
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
    @Test func theOutlineIsFlattenedWithDepthsAndPages() async throws {
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
        try #require(pdf.outlineRail.rows.map(\.id) == Array(0..<6), "the outline's rows were not built from its bookmarks")
        #expect(pdf.outlineRail.pageLabels == [0: "1", 1: "2", 2: "2", 3: "3", 4: "4"])
        #expect(pdf.outlineRail.inert == [5], "the web-link bookmark is not drawn as going nowhere")
        // A click goes to the bookmark's page; the pageless one goes nowhere.
        #expect(EditorPDFRailOutline.page(for: pdf.outlineRail.rows[3], in: pdf.outline) == 2)
        #expect(EditorPDFRailOutline.page(for: pdf.outlineRail.rows[5], in: pdf.outline) == nil)
        pdf.close()
        #expect(pdf.outline.isEmpty && pdf.outlineRail.rows.isEmpty, "the bookmarks outlived the PDF")
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

    /// **A PDF with no bookmarks has no Outline tab** (asked 2026-10-17). The caption is still
    /// right for the phase, though the tab rule keeps it out of sight.
    @Test func aPDFWithNoBookmarksHasNoOutlineTab() async {
        let file = path("plain.pdf")
        PDFFixtures.write(file, pages: 2)
        let pdf = await opened(file)
        #expect(pdf.phase == .open && pdf.outline.isEmpty)
        #expect(EditorPDFOutline.emptyCaption(phase: pdf.phase) == "This PDF has no bookmarks.")
        #expect(!EditorRailTab.shown(pdfIsOpen: true, pdfHasOutline: EditorRailTab.pdfOutlineIsWorthATab(pdf.outline)).contains(.outline))
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
        rail(entries: entries, naming: naming, tab: .constant(tab), pdf: pdf)
    }

    static func rail(entries: [EditorRailEntry], naming: Bool = false, tab: Binding<EditorRailTab>,
                     pdf: EditorPDFDocument? = nil) -> EditorFileRailView {
        EditorFileRailView(folderName: "Notes", entries: entries, selectedPath: nil,
                           accent: .blue, onAccent: .white, tab: tab,
                           isNaming: .constant(naming), typedName: .constant(""),
                           prefilledName: { "Untitled.md" }, refusal: { _ in nil },
                           filter: .constant(""), filterIsExpanded: .constant(false),
                           outlineAnchors: .constant([:]), pdf: pdf,
                           onOpen: { _ in }, onCreate: { _ in true }, onNewTextFile: nil,
                           rowActions: EditorRailRowActions(revealInBrowse: { _ in }, getInfo: { _ in },
                                                            quickLook: { _ in }))
    }

    // MARK: Grid or list

    /// **The grid gains columns as the column widens, the list gains sharpness** — and the default
    /// grid asks for exactly the thumbnails it always had.
    @Test func theGridGainsColumnsAndTheListGainsSharpness() {
        let grid = EditorPDFPagesLayout.grid, list = EditorPDFPagesLayout.list
        let narrow = EditorLayoutMetrics.railWidth, wide = EditorLayoutMetrics.maxRailWidth
        #expect(grid.columns(railWidth: narrow) == 2)
        #expect(grid.columns(railWidth: wide) == 4)
        #expect(list.columns(railWidth: narrow) == 1 && list.columns(railWidth: wide) == 1)
        #expect(grid.renderEdge(railWidth: narrow) == EditorPDFThumbnails.longEdge)
        // A grid cell stays near its old size as columns come, so its images do too.
        #expect(grid.renderEdge(railWidth: wide) <= EditorPDFThumbnails.longEdge * 2)
        // A list page is drawn for its width: sharper than a grid's, sharper again wider, capped.
        let listNarrow = list.renderEdge(railWidth: narrow), listWide = list.renderEdge(railWidth: wide)
        #expect(listNarrow > grid.renderEdge(railWidth: narrow))
        #expect(listWide > listNarrow && listWide <= EditorPDFThumbnails.longEdge * 6)
        // Enough pixels for the cell on a Retina screen: a Letter page, at the image's width.
        #expect(listWide >= list.imageWidth(railWidth: wide) * 2 * 792 / 612)
    }

    /// **The cap follows the image size**: the grid's 48 at its own size, fewer as each grows, and
    /// never under a list's window. Bigger pages look fewer ahead.
    @Test func theImageCapScalesWithTheImageSize() {
        #expect(EditorPDFThumbnails.capacity(forEdge: EditorPDFThumbnails.longEdge) == EditorPDFThumbnails.capacity)
        #expect(EditorPDFThumbnails.capacity(forEdge: 480) == 12)
        #expect(EditorPDFThumbnails.capacity(forEdge: 1200) == 8)
        #expect(EditorPDFThumbnails.margin(forEdge: 480) == EditorPDFThumbnails.margin)
        #expect(EditorPDFThumbnails.margin(forEdge: 720) == 2)
    }

    /// **A bigger size redraws what is held, and the small image stays until the sharp one lands**
    /// — no cell goes blank on a switch to List. A smaller size redraws nothing.
    @Test func aBiggerSizeRedrawsWithoutBlankingAndASmallerOneRedrawsNothing() async throws {
        let file = path("sharper.pdf")
        PDFFixtures.write(file, pages: 12, text: false)
        let pdf = await opened(file)
        let window: Set<Int> = [0, 1]
        func longEdge(_ page: Int) -> Int { pdf.thumbnails.images[page].map { max($0.width, $0.height) } ?? 0 }
        pdf.thumbnails.show(window)
        await wait("the grid-sized thumbnails") { window.allSatisfy { longEdge($0) == 240 } }

        pdf.thumbnails.setRenderEdge(720)
        #expect(window.allSatisfy { pdf.thumbnails.images[$0] != nil },
                "a cell went blank while its sharper image was drawn")
        await wait("the list-sized thumbnails") { window.allSatisfy { longEdge($0) == 720 } }

        let before = pdf.thumbnails.drawn.count
        pdf.thumbnails.setRenderEdge(240)
        pdf.thumbnails.show(window)
        // The grid's wider margin is drawn ahead: once its last page lands, the lane is quiet.
        await wait("the grid's margin") { pdf.thumbnails.images[1 + EditorPDFThumbnails.margin] != nil }
        let redrawn = pdf.thumbnails.drawn.dropFirst(before).filter(window.contains)
        #expect(redrawn.isEmpty, "a smaller size redrew pages already held bigger: \(Array(redrawn))")
        #expect(window.allSatisfy { longEdge($0) == 720 })
    }

    /// **A mounted list asks for list-sized pages**, and the rail hands the tab its choice and width.
    @Test func theMountedListAsksForSharperPages() async throws {
        let file = path("list.pdf")
        PDFFixtures.write(file, pages: 10, text: false)
        let pdf = await opened(file)
        let width = EditorLayoutMetrics.railWidth
        let pages = EditorPDFRailPages(pdf: pdf, view: pdf.view, thumbnails: pdf.thumbnails, tools: pdf.tools, accent: .blue,
                                       layout: .list, railWidth: width)
        let host = NSHostingView(rootView: AnyView(pages.frame(width: width, height: 400)))
        host.frame = CGRect(x: 0, y: 0, width: width, height: 400)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        let edge = EditorPDFPagesLayout.list.renderEdge(railWidth: width)
        await wait("the first page, list-sized") {
            window.layoutIfNeeded()
            return pdf.thumbnails.images[0].map { max($0.width, $0.height) } == Int(edge)
        }
        #expect(pdf.thumbnails.renderEdge == edge)

        let rail = try ChromeGlassWiringTests.source("EditorFileRailView.swift")
        #expect(rail.contains("layout: pagesLayout, railWidth: width)"), "the Pages tab is not handed the choice and the width")
        #expect(rail.contains("ForEach(EditorPDFPagesLayout.allCases"), "the Pages tab offers no Grid / List switch")
    }

    /// **A lane of the test's own, in front of the real one.** Held, it stops only THIS test's turns;
    /// released, each turn still runs inside `PDFKitSerialAccess` (`run`, from this queue's thread),
    /// so the lane's rule holds in tests too. Holding is immediate — nothing to wait for.
    final class HeldLane: Sendable {
        private let queue = DispatchQueue(label: "EditorPDFRailTests.HeldLane")
        private let gate = DispatchSemaphore(value: 0)
        private let released = OSAllocatedUnfairLock(initialState: false)

        var lane: EditorPDFThumbnails.Lane {
            EditorPDFThumbnails.Lane { [queue] body in
                await withCheckedContinuation { continuation in
                    queue.async { continuation.resume(returning: PDFKitSerialAccess.run(body)) }
                }
            }
        }

        func hold() { queue.async { [gate] in gate.wait() } }

        func release() {
            let first = released.withLock { done in defer { done = true }; return !done }
            if first { gate.signal() }
        }
    }
}

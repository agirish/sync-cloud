import Testing
import AppKit
import PDFKit
import SwiftUI
import Design
@testable import FileExplorer
import FileExplorerTestSupport

/// **Phase 5a: the reader's layouts, its fit for spreads, the zoom ladder, and whose keyboard it
/// is** — measured on laid-out page views, as `EditorPDFDocumentTests` measures the fit.
///
/// Serialized: every test lays out a `PDFView` on the main thread, and several hold a window key.
@MainActor
@Suite(.serialized) final class EditorPDFLayoutTests {

    let folder = NSTemporaryDirectory() + "editor-pdf-layout-" + UUID().uuidString
    private let defaults = ScratchDefaults("EditorPDFLayoutTests")

    init() throws {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(atPath: folder) }

    private func document(pages: Int, size: CGSize = PDFFixtures.letter) throws -> PDFDocument {
        let file = (folder as NSString).appendingPathComponent("p\(pages)-\(UUID().uuidString).pdf")
        PDFFixtures.write(file, pages: pages, size: size)
        return try #require(PDFDocument(url: URL(fileURLWithPath: file)))
    }

    private func state(_ layout: EditorPDFLayout = .continuous, cover: Bool = false) -> EditorPDFViewState {
        let state = EditorPDFViewState(defaults: defaults)
        state.layout = layout
        state.coverSeparately = cover
        return state
    }

    /// The page view mounted the way the card mounts it, in a window of `size` — with the page
    /// count the model sets when it hands the view a document.
    private func mount(_ document: PDFDocument, _ state: EditorPDFViewState,
                       size: CGSize = CGSize(width: 1000, height: 700)) async throws -> (NSWindow, ReaderPDFView) {
        state.pageCount = document.pageCount
        let host = NSHostingView(rootView: EditorPDFPageView(document: document, state: state)
            .frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.layoutIfNeeded()
        let settled = await LayoutPumpWait.pump(window, upTo: 10) { (self.reader(in: host)?.bounds.width ?? 0) > 0 }
        try #require(settled.held)
        let view = try #require(reader(in: host))
        view.layoutSubtreeIfNeeded()
        return (window, view)
    }

    private func reader(in view: NSView) -> ReaderPDFView? {
        if let reader = view as? ReaderPDFView { return reader }
        for sub in view.subviews { if let found = reader(in: sub) { return found } }
        return nil
    }

    /// Where `page` is drawn, in the view's own coordinates.
    private func drawn(_ index: Int, in view: ReaderPDFView) throws -> CGRect {
        let page = try #require(view.document?.page(at: index))
        return view.convert(page.bounds(for: view.displayBox), from: page)
    }

    // MARK: Layouts

    /// **Each layout is the PDFKit mode it names**, and the cover is `displaysAsBook` only where
    /// there are two pages to a row — on the mounted view, not just in the mapping.
    @Test(arguments: EditorPDFLayout.allCases)
    func eachLayoutSetsItsDisplayMode(layout: EditorPDFLayout) async throws {
        let expected: [EditorPDFLayout: PDFDisplayMode] = [.singlePage: .singlePage, .continuous: .singlePageContinuous,
                                                           .twoPages: .twoUp, .twoPagesContinuous: .twoUpContinuous]
        let doc = try document(pages: 5)
        for cover in [false, true] {
            let (window, view) = try await mount(doc, state(layout, cover: cover))
            defer { window.contentView = nil }
            #expect(view.displayMode == expected[layout])
            #expect(view.displaysAsBook == (cover && layout.isTwoUp),
                    "\(layout) with the cover \(cover ? "on" : "off") drew as a book: \(view.displaysAsBook)")
            #expect(EditorPDFLayout(view.displayMode) == layout)
        }
    }

    /// **The layout and the cover are remembered, under the named keys**, and a new view state —
    /// the next launch's — reads them back. Continuous and no cover until something is chosen.
    @Test func theLayoutAndTheCoverPersistAcrossARemount() {
        let first = EditorPDFViewState(defaults: defaults)
        #expect(first.layout == .continuous && first.layout == EditorPDFSettings.layoutDefault)
        #expect(first.coverSeparately == EditorPDFSettings.coverSeparatelyDefault)
        first.layout = .twoPages
        first.coverSeparately = true
        #expect(defaults.string(forKey: EditorPDFSettings.layoutKey) == "twoPages")
        #expect(defaults.object(forKey: EditorPDFSettings.coverSeparatelyKey) as? Bool == true)
        let next = EditorPDFViewState(defaults: defaults)
        #expect(next.layout == .twoPages && next.coverSeparately)
        // And a close keeps them: they are preferences, not where the reader is.
        next.reset()
        #expect(next.layout == .twoPages && next.coverSeparately)
        // An unknown stored value falls back to the default rather than crashing or sticking.
        defaults.set("threePages", forKey: EditorPDFSettings.layoutKey)
        #expect(EditorPDFViewState(defaults: defaults).layout == .continuous)
    }

    /// **A layout change keeps the page in view** — there and back.
    @Test(arguments: [EditorPDFFit.page, .width])
    func thePageStaysPutAcrossALayoutChange(fit: EditorPDFFit) async throws {
        let doc = try document(pages: 40)
        let state = state(.continuous)
        state.fit = fit
        let (window, view) = try await mount(doc, state)
        defer { window.contentView = nil }
        let target = 29
        view.go(to: try #require(doc.page(at: target)))
        view.layoutSubtreeIfNeeded()
        #expect(state.currentPage == target)
        for (layout, cover) in [(EditorPDFLayout.twoPagesContinuous, false), (.continuous, false), (.twoPages, true),
                                (.singlePage, false), (.twoPagesContinuous, true), (.continuous, false)] {
            // Through the view state, as the layout menu asks — the page view applies it on update.
            state.layout = layout
            state.coverSeparately = cover
            let applied = await LayoutPumpWait.pump(window, upTo: 10) {
                view.displayMode == layout.displayMode && view.displaysAsBook == layout.displaysAsBook(coverSeparately: cover)
            }
            try #require(applied.held, "\(layout) was never applied to the page view")
            view.layoutSubtreeIfNeeded()
            let page = view.currentPage.map { doc.index(for: $0) } ?? -1
            let spread = EditorPDFLayout.spread(containing: target, pageCount: 40, twoUp: layout.isTwoUp, coverSeparately: cover)
            #expect(spread.contains(page), "in \(layout) at \(fit) the reader is on page \(page + 1), not page 30's \(spread)")
            let shown = try drawn(target, in: view)
            #expect(shown.intersects(view.bounds), "page 30 is off screen in \(layout) at \(fit): \(shown) in \(view.bounds)")
        }
    }

    /// **The pairing** — 1–2, 3–4 without the cover, 1, 2–3, 4–5 with it; a last odd page alone.
    @Test func spreadsPairAsPDFKitDrawsThem() {
        func s(_ page: Int, _ count: Int, twoUp: Bool = true, cover: Bool = false) -> ClosedRange<Int> {
            EditorPDFLayout.spread(containing: page, pageCount: count, twoUp: twoUp, coverSeparately: cover)
        }
        #expect(s(4, 10, twoUp: false) == 4...4)
        #expect(s(0, 10) == 0...1 && s(1, 10) == 0...1 && s(5, 10) == 4...5)
        #expect(s(0, 10, cover: true) == 0...0)
        #expect(s(1, 10, cover: true) == 1...2 && s(2, 10, cover: true) == 1...2 && s(6, 10, cover: true) == 5...6)
        #expect(s(8, 9) == 8...8, "a last odd page has no partner")
        #expect(s(9, 10, cover: true) == 9...9)
        #expect(s(40, 10) == 8...9, "a page past the end is clamped")
        #expect(s(0, 0) == 0...0)
    }

    /// **The pure pairing is PDFKit's own** — on a laid-out view, both ways round.
    @Test func thePairingMatchesWhatPDFKitDraws() async throws {
        let doc = try document(pages: 7)
        for cover in [false, true] {
            let (window, view) = try await mount(doc, state(.twoPages, cover: cover))
            defer { window.contentView = nil }
            for target in 0..<7 {
                view.go(to: try #require(doc.page(at: target)))
                view.layoutSubtreeIfNeeded()
                let shown = view.visiblePages.map { doc.index(for: $0) }
                let expected = Array(EditorPDFLayout.spread(containing: target, pageCount: 7, twoUp: true,
                                                            coverSeparately: cover))
                #expect(shown == expected, "page \(target + 1) with the cover \(cover): PDFKit shows \(shown)")
            }
        }
    }

    // MARK: Fit for spreads

    /// **The spread's size** — widths and the gap added, the taller height — and the fits on it,
    /// as pure functions. One page is the old rule's numbers exactly.
    @Test func theFitIsMeasuredOnTheSpread() {
        let letter = PDFFixtures.letter, a4 = CGSize(width: 595, height: 842)
        #expect(EditorPDFFit.spreadSize([letter], gap: 8) == letter)
        #expect(EditorPDFFit.spreadSize([letter, a4], gap: 8) == CGSize(width: 612 + 8 + 595, height: 842))
        #expect(EditorPDFFit.spreadSize([], gap: 8) == .zero)
        let view = CGSize(width: 1000, height: 700)
        // One page: what the reader did before layouts existed.
        #expect(EditorPDFFit.scale(.page, spreadSize: letter, viewSize: view, margin: 4)
                == PDFPageFit.scale(pageSize: letter, viewSize: view))
        #expect(EditorPDFFit.scale(.width, spreadSize: letter, viewSize: view, margin: 4) == CGFloat(1000 - 8) / 612)
        // Two: the pair across the width, and both pages wholly inside the view for Page.
        let pair = EditorPDFFit.spreadSize([letter, letter], gap: 8)
        #expect(EditorPDFFit.scale(.width, spreadSize: pair, viewSize: view, margin: 4) == CGFloat(1000 - 8) / 1232)
        let page = EditorPDFFit.scale(.page, spreadSize: pair, viewSize: view, margin: 4)
        #expect(page * 1232 <= 1000 && page * 792 <= 700)
        #expect(EditorPDFFit.scale(.actual, spreadSize: pair, viewSize: view, margin: 4) == 1)
    }

    /// The left edge of a spread's left page to the right edge of its right page, as drawn.
    private func drawnSpread(_ pages: ClosedRange<Int>, in view: ReaderPDFView) throws -> CGRect {
        try drawn(pages.lowerBound, in: view).union(try drawn(pages.upperBound, in: view))
    }

    /// **In Two Pages, Fit Width puts the PAIR across the view, and Fit Page keeps it whole** —
    /// measured on what is drawn, in both two-page layouts.
    @Test(arguments: [EditorPDFLayout.twoPages, .twoPagesContinuous])
    func pageAndWidthFitTheSpread(layout: EditorPDFLayout) async throws {
        let doc = try document(pages: 6)
        let state = state(layout)
        state.fit = .width
        let (window, view) = try await mount(doc, state, size: CGSize(width: 1000, height: 600))
        defer { window.contentView = nil }
        view.layoutSubtreeIfNeeded()
        let spread = try drawnSpread(0...1, in: view)
        #expect(abs(spread.width - (view.bounds.width - 2 * view.sideMargin)) < 2,
                "Fit Width drew a \(spread.width)pt spread in a \(view.bounds.width)pt view")

        state.fit = .page
        view.fit = .page
        view.layoutSubtreeIfNeeded()
        let whole = try drawnSpread(0...1, in: view)
        #expect(whole.width <= view.bounds.width + 0.5 && whole.height <= view.bounds.height + 0.5,
                "Fit Page cut the spread off: \(whole.size) in \(view.bounds.size)")
        #expect(whole.width > view.bounds.width - 12 || whole.height > view.bounds.height - 1,
                "Fit Page fills neither dimension: \(whole.size) in \(view.bounds.size)")
    }

    /// **The cover shown separately is fitted alone in Two Pages** — and the 2–3 after it as a pair.
    @Test func theCoverIsFittedAloneInTwoPages() async throws {
        let doc = try document(pages: 6)
        let state = state(.twoPages, cover: true)
        state.fit = .width
        let (window, view) = try await mount(doc, state, size: CGSize(width: 1000, height: 600))
        defer { window.contentView = nil }
        view.layoutSubtreeIfNeeded()
        let cover = try drawn(0, in: view)
        #expect(abs(cover.width - (view.bounds.width - 2 * view.sideMargin)) < 2,
                "the cover is \(cover.width)pt wide in a \(view.bounds.width)pt view — not fitted alone")
        view.goToNextPage(nil)
        view.layoutSubtreeIfNeeded()
        let pair = try drawnSpread(1...2, in: view)
        #expect(abs(pair.width - (view.bounds.width - 2 * view.sideMargin)) < 2,
                "2–3 drew \(pair.width)pt wide after the cover — the spread was not refitted")
    }

    /// **In Two Pages, Continuous the cover is fitted as the pair beside it**, because every row
    /// is drawn two pages wide: fitting the cover alone would draw 2–3 twice the view's width.
    @Test func continuousTwoPagesFitsTheCoverAsAPair() async throws {
        #expect(ReaderPDFView.fittedSpread(around: 0, pageCount: 6, layout: .twoPagesContinuous, coverSeparately: true) == 1...2)
        #expect(ReaderPDFView.fittedSpread(around: 0, pageCount: 6, layout: .twoPages, coverSeparately: true) == 0...0)
        #expect(ReaderPDFView.fittedSpread(around: 4, pageCount: 5, layout: .twoPagesContinuous, coverSeparately: false) == 2...3)
        #expect(ReaderPDFView.fittedSpread(around: 0, pageCount: 1, layout: .twoPagesContinuous, coverSeparately: true) == 0...0)
        #expect(ReaderPDFView.fittedSpread(around: 3, pageCount: 6, layout: .continuous, coverSeparately: true) == 3...3)

        let doc = try document(pages: 6)
        let state = state(.twoPagesContinuous, cover: true)
        state.fit = .width
        let (window, view) = try await mount(doc, state, size: CGSize(width: 1000, height: 600))
        defer { window.contentView = nil }
        view.layoutSubtreeIfNeeded()
        let pair = try drawnSpread(1...2, in: view)
        #expect(pair.width <= view.bounds.width + 0.5, "2–3 is \(pair.width)pt in a \(view.bounds.width)pt view")
    }

    /// **A mixed letter-and-A4 spread fits on both pages' sizes.**
    @Test func aMixedSpreadFitsBothPages() async throws {
        let file = (folder as NSString).appendingPathComponent("mixed.pdf")
        var box = CGRect(origin: .zero, size: PDFFixtures.letter)
        let context = CGContext(URL(fileURLWithPath: file) as CFURL, mediaBox: &box, nil)!
        for size in [PDFFixtures.letter, CGSize(width: 595, height: 842), PDFFixtures.letter, CGSize(width: 595, height: 842)] {
            var media = CGRect(origin: .zero, size: size)
            let info = [kCGPDFContextMediaBox as String: Data(bytes: &media, count: MemoryLayout<CGRect>.size)] as CFDictionary
            context.beginPDFPage(info)
            context.endPDFPage()
        }
        context.closePDF()
        let doc = try #require(PDFDocument(url: URL(fileURLWithPath: file)))
        let state = state(.twoPages)
        state.fit = .page
        let (window, view) = try await mount(doc, state, size: CGSize(width: 900, height: 500))
        defer { window.contentView = nil }
        view.layoutSubtreeIfNeeded()
        let spread = try drawnSpread(0...1, in: view)
        #expect(spread.width <= view.bounds.width + 0.5 && spread.height <= view.bounds.height + 0.5,
                "a letter-and-A4 spread is cut off: \(spread.size) in \(view.bounds.size)")
    }

    // MARK: Spreads in the header, the status line and the rail

    @Test func thePageFieldShowsAndTakesASpread() {
        #expect(EditorPDFHeaderControls.pageText(6...6) == "7")
        #expect(EditorPDFHeaderControls.pageText(5...6) == "6–7")
        // The field's own spread sent back unchanged goes to its first page — the spread it is.
        #expect(EditorPDFHeaderControls.page(typed: "6–7", pageCount: 64) == 5)
        #expect(EditorPDFHeaderControls.page(typed: "7", pageCount: 64) == 6)
        #expect(EditorPDFHeaderControls.page(typed: "–", pageCount: 64) == nil)
        // Wide enough for "63–64".
        #expect(EditorPDFHeaderControls.fieldWidth(pageCount: 64, twoUp: true)
                > EditorPDFHeaderControls.fieldWidth(pageCount: 64))
    }

    /// **A typed page lands on the spread that holds it** — 7 with the cover separate is 6–7.
    @Test func aTypedPageLandsOnItsSpread() async throws {
        let doc = try document(pages: 12)
        let state = state(.twoPages, cover: true)
        let (window, view) = try await mount(doc, state)
        defer { window.contentView = nil }
        state.requestPage(try #require(EditorPDFHeaderControls.page(typed: "7", pageCount: 12)))
        // The request is handed to the view on the next update, as the field's is.
        _ = await LayoutPumpWait.pump(window, upTo: 10) { state.visiblePages == 5...6 }
        #expect(state.visiblePages == 5...6, "typing 7 shows \(state.visiblePages)")
        #expect(EditorPDFHeaderControls.pageText(state.visiblePages) == "6–7")
        #expect(view.visiblePages.map { doc.index(for: $0) } == [5, 6])
    }

    /// **"Pages 6–7 of 64", then the layout and the zoom** (mockups 15 and 16) — the zoom also being
    /// where its value is still said once the header's control has shed its word.
    @Test func theStatusLineNamesTheSpreadAndTheLayout() {
        let facts = EditorPDFFacts(pageCount: 64, pageSizes: Array(repeating: PDFFixtures.letter, count: 64),
                                   majorVersion: 1, minorVersion: 7, fileSize: "2 MB", hasText: true)
        #expect(EditorPDFStatusLine.segments(facts: facts, pages: 5...6, layout: .twoPages, coverSeparately: true,
                                             zoom: "Fit Page")
                == ["Pages 6–7 of 64", "Two Pages · cover separate", "Fit Page", "Letter · 8.5 × 11 in", "2 MB",
                    "PDF 1.7", "Text selectable"])
        #expect(EditorPDFStatusLine.segments(facts: facts, pages: 6...6, layout: .singlePage).prefix(2)
                == ["Page 7 of 64", "Single Page"])
        // The cover choice says nothing in a single-page layout.
        #expect(EditorPDFStatusLine.segments(facts: facts, pages: 6...6, layout: .continuous, coverSeparately: true)[1]
                == "Continuous")
    }

    /// **The view state's spread is what all three read**, and the Pages tab rings every page in it.
    @Test func theVisiblePagesAreTheSpreadAndThePagesTabRingsThem() throws {
        let state = state(.twoPages, cover: true)
        state.pageCount = 64
        state.currentPage = 6
        #expect(state.visiblePages == 5...6)
        state.layout = .continuous
        #expect(state.visiblePages == 6...6)
        let rail = try ChromeGlassWiringTests.source("EditorPDFRailViews.swift")
        #expect(rail.contains("let isCurrent = view.visiblePages.contains(index)")
                && rail.contains("isCurrent: isCurrent"),
                "the Pages tab rings one page, not the spread")
    }

    /// **⌥← and ⌥→ turn a whole spread** — PDFKit's own previous and next, in both two-page layouts.
    @Test(arguments: [EditorPDFLayout.twoPages, .twoPagesContinuous])
    func theOptionArrowsTurnAWholeSpread(layout: EditorPDFLayout) async throws {
        let doc = try document(pages: 9)
        let state = state(layout, cover: true)
        let (window, view) = try await mount(doc, state)
        defer { window.contentView = nil }
        func press(_ key: Character) throws {
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.option, .numericPad, .function], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: String(key),
                charactersIgnoringModifiers: String(key), isARepeat: false,
                keyCode: key == Character(UnicodeScalar(NSRightArrowFunctionKey)!) ? 124 : 123))
            view.keyDown(with: event)
            view.layoutSubtreeIfNeeded()
        }
        let right = Character(UnicodeScalar(NSRightArrowFunctionKey)!), left = Character(UnicodeScalar(NSLeftArrowFunctionKey)!)
        #expect(state.visiblePages == 0...0)
        try press(right)
        #expect(state.visiblePages == 1...2, "⌥→ from the cover shows \(state.visiblePages)")
        try press(right)
        #expect(state.visiblePages == 3...4)
        try press(left)
        #expect(state.visiblePages == 1...2, "⌥← shows \(state.visiblePages)")
    }

    // MARK: Find in two pages

    /// **A match on the right-hand page is drawn there and counts as in sight** — the overlay maps
    /// through `convert(_:from:)`, so a spread needs nothing of its own.
    @Test func aMatchOnTheRightHandPageIsHighlightedAndInSight() async throws {
        let doc = try document(pages: 4)
        let state = state(.twoPages)
        let (window, view) = try await mount(doc, state, size: CGSize(width: 1200, height: 700))
        defer { window.contentView = nil }
        let right = try #require(doc.page(at: 1))
        let rect = CGRect(x: 72, y: 640, width: 100, height: 24)
        #expect(EditorPDFPageView.isInSight(rect, on: right, in: view), "a match on page 2 of 1–2 is not in sight")
        view.highlights = EditorPDFHighlights(pages: [1: [[rect]]], current: .init(page: 1, ordinal: 0))
        let overlay = try #require(view.subviews.last as? EditorPDFFindOverlay)
        let placed = try #require(overlay.place(rect, on: right))
        #expect(placed.minX > view.bounds.midX, "the match on the right-hand page is drawn at \(placed)")
        // And a reveal there scrolls nothing: going to page 4 is a new spread, going to 2 is not.
        let elsewhere = try #require(doc.page(at: 3))
        #expect(!EditorPDFPageView.isInSight(rect, on: elsewhere, in: view))
    }

    // MARK: The zoom ladder

    @Test func theLadderStepsFromOnAndBetweenStops() {
        #expect(EditorPDFZoom.step(from: 1, in: true) == 1.25)
        #expect(EditorPDFZoom.step(from: 1, in: false) == 0.75)
        #expect(EditorPDFZoom.step(from: 1.37, in: true) == 1.5, "between stops, + goes to the next stop up")
        #expect(EditorPDFZoom.step(from: 1.37, in: false) == 1.25, "between stops, − goes to the next stop down")
        #expect(EditorPDFZoom.step(from: 1.2496, in: true) == 1.5, "124.96% is ON 125%, so + goes past it")
        #expect(EditorPDFZoom.step(from: 6, in: false) == 4, "past the ladder, − comes back onto it")
        #expect(EditorPDFZoom.step(from: 0.2, in: true) == 0.5)
        #expect(EditorPDFZoom.step(from: 4, in: true) == nil && EditorPDFZoom.step(from: 6, in: true) == nil)
        #expect(EditorPDFZoom.step(from: 0.5, in: false) == nil && EditorPDFZoom.step(from: 0.3, in: false) == nil)
    }

    @Test func zoomButtonsAreDisabledAtTheEnds() {
        let state = state()
        state.scale = 4
        #expect(!state.canZoom(in: true) && state.canZoom(in: false))
        state.zoom(in: true)
        #expect(state.scaleRequest == nil, "+ at 400% asked for a scale")
        state.scale = 0.5
        #expect(state.canZoom(in: true) && !state.canZoom(in: false))
        let menu = EditorPDFZoomMenu.menu(for: state)
        #expect(menu.items.first { $0.title == "Zoom Out" }?.isEnabled == false)
        #expect(menu.items.first { $0.title == "Zoom In" }?.isEnabled == true)
    }

    /// **A fit refits on resize; a preset lets the fit go and a resize leaves it.** A bare page
    /// view as the window's content, so a resize of the window is a resize of the view.
    @Test func aFitRefitsOnResizeAndAPresetHolds() throws {
        let doc = try document(pages: 3)
        let view = ReaderPDFView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        view.autoScales = false
        view.displaysPageBreaks = true
        view.document = doc
        view.fit = .width
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.contentView = nil }
        view.layoutDocumentView()
        view.layoutSubtreeIfNeeded()
        let before = view.scaleFactor
        window.setContentSize(CGSize(width: 1100, height: 600))
        view.layoutSubtreeIfNeeded()
        #expect(view.scaleFactor > before * 1.3, "Fit Width did not refit on a resize: \(before) → \(view.scaleFactor)")

        let state = state()
        state.fit = .width
        state.zoom(to: 1.5)
        #expect(state.fit == nil, "a preset left the fit holding")
        view.fit = state.fit
        view.scaleFactor = try #require(state.scaleRequest?.value)
        window.setContentSize(CGSize(width: 700, height: 600))
        view.layoutSubtreeIfNeeded()
        #expect(abs(view.scaleFactor - 1.5) < 0.001, "a preset was refitted by a resize: \(view.scaleFactor)")
    }

    /// **A pinch is the reader's own scale**: the fit lets go and the label says the real value.
    @Test func aPinchLetsTheFitGo() async throws {
        let doc = try document(pages: 3)
        let state = state(.continuous)
        state.fit = .page
        let (window, view) = try await mount(doc, state)
        defer { window.contentView = nil }
        view.layoutSubtreeIfNeeded()
        #expect(state.fit == .page, "the fit's own scale let the fit go")
        view.scaleFactor = 1.37
        #expect(state.fit == nil, "a scale the fit did not set left the fit holding")
        #expect(EditorPDFZoom.label(fit: state.fit, scale: state.scale) == "137%")
    }

    @Test func theLabelSaysTheFitOrThePercent() {
        #expect(EditorPDFZoom.label(fit: .page, scale: 0.83) == "Fit Page")
        #expect(EditorPDFZoom.label(fit: .width, scale: 1.4) == "Fit Width")
        #expect(EditorPDFZoom.label(fit: .actual, scale: 1) == "100%")
        #expect(EditorPDFZoom.label(fit: nil, scale: 1.25) == "125%")
        #expect(EditorPDFZoom.label(fit: nil, scale: 1.3749) == "137%")
    }

    /// **The menu** (mockup 15): the verbs on their chords, the fits, the presets, one tick.
    @Test func theZoomMenuReadsAsTheMockupDoes() throws {
        let state = state()
        state.fit = nil
        state.scale = 1.25
        let menu = EditorPDFZoomMenu.menu(for: state)
        let titles = menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
        #expect(titles == ["Zoom In", "Zoom Out", "Actual Size", "—", "Fit Page", "Fit Width", "—",
                           "50%", "75%", "100%", "125%", "150%", "200%", "400%"])
        #expect(menu.items.filter { $0.state == .on }.map(\.title) == ["125%"])
        for (title, key) in [("Zoom In", "+"), ("Zoom Out", "-"), ("Actual Size", "0")] {
            let item = try #require(menu.items.first { $0.title == title })
            #expect(item.keyEquivalent == key && item.keyEquivalentModifierMask == .command)
        }
        state.fit = .width
        #expect(EditorPDFZoomMenu.menu(for: state).items.filter { $0.state == .on }.map(\.title) == ["Fit Width"])
        // Choosing a preset lets the fit go; choosing a fit takes it back.
        let preset = try #require(EditorPDFZoomMenu.menu(for: state).items.first { $0.title == "200%" })
        _ = preset.target?.perform(preset.action)
        #expect(state.fit == nil && state.scaleRequest?.value == 2)
        let fit = try #require(EditorPDFZoomMenu.menu(for: state).items.first { $0.title == "Fit Page" })
        _ = fit.target?.perform(fit.action)
        #expect(state.fit == .page)
    }

    /// **The layouts' menu** (mockup 16): four, the one in use ticked, the cover greyed where there
    /// is no spread for it to change.
    @Test func theLayoutMenuGreysTheCoverInTheSinglePageLayouts() throws {
        let state = state(.twoPages, cover: true)
        var menu = EditorPDFLayoutMenu.menu(for: state)
        #expect(menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
                == ["Single Page", "Continuous", "Two Pages", "Two Pages, Continuous", "—", "Cover Page Separately"])
        #expect(menu.items.filter { $0.state == .on }.map(\.title) == ["Two Pages", "Cover Page Separately"])
        #expect(menu.items.last?.isEnabled == true)
        for layout in [EditorPDFLayout.singlePage, .continuous] {
            state.layout = layout
            menu = EditorPDFLayoutMenu.menu(for: state)
            #expect(menu.items.last?.isEnabled == false, "Cover Page Separately is live in \(layout)")
        }
        let item = try #require(menu.items.first { $0.title == "Two Pages, Continuous" })
        _ = item.target?.perform(item.action)
        #expect(state.layout == .twoPagesContinuous)
    }

    // MARK: Whose keyboard

    /// **The pages have the keyboard when the reader — or a view inside it — is first responder
    /// in the key window**, and lose it to any other view.
    @Test func theFocusIsThePagesOwnAndFollowsTheFirstResponder() async throws {
        let doc = try document(pages: 3)
        let state = state()
        let other = NSTextField()
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 700, height: 500))
        let host = NSHostingView(rootView: EditorPDFPageView(document: doc, state: state).frame(width: 600, height: 500))
        host.frame = CGRect(x: 0, y: 0, width: 600, height: 500)
        other.frame = CGRect(x: 610, y: 10, width: 80, height: 22)
        root.addSubview(host)
        root.addSubview(other)
        let window = KeyableWindow(contentRect: root.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        defer { window.contentView = nil }
        _ = await LayoutPumpWait.pump(window, upTo: 10) { self.reader(in: host) != nil }
        let view = try #require(reader(in: host))

        // The rule, alone: key and inside, or nothing.
        #expect(ReaderPDFView.holdsFocus(firstResponder: view, isKeyWindow: true, in: view))
        #expect(ReaderPDFView.holdsFocus(firstResponder: view.documentView, isKeyWindow: true, in: view))
        #expect(!ReaderPDFView.holdsFocus(firstResponder: view, isKeyWindow: false, in: view))
        #expect(!ReaderPDFView.holdsFocus(firstResponder: other, isKeyWindow: true, in: view))

        window.makeFirstResponder(view)
        _ = await LayoutPumpWait.pump(window, upTo: 10) { state.hasFocus }
        #expect(state.hasFocus, "the reader is first responder and the state does not know")
        window.makeFirstResponder(other)
        _ = await LayoutPumpWait.pump(window, upTo: 10) { !state.hasFocus }
        #expect(!state.hasFocus, "the field took the keyboard and the reader still claims it")
        // A view INSIDE the reader taking it — where a click in the pages can put first responder.
        // The reader hears nothing of that itself; the window's first responder is watched.
        let inner = try #require(view.documentView)
        window.makeFirstResponder(other)
        _ = await LayoutPumpWait.pump(window, upTo: 10) { !state.hasFocus }
        try #require(window.makeFirstResponder(inner), "PDFKit's document view refuses first responder")
        _ = await LayoutPumpWait.pump(window, upTo: 10) { state.hasFocus }
        #expect(state.hasFocus, "a view inside the reader has the keyboard and the state does not know")
        // The window to the background: the reader is still its first responder, but the
        // keyboard is another window's.
        window.isKey = false
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        #expect(!state.hasFocus, "the window went to the background and the reader kept the keyboard")
        window.isKey = true
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        #expect(state.hasFocus, "the window came back and the reader did not take the keyboard back")
    }
}

/// **A window that says it is key** — a test process has no app to activate, so no window there
/// ever really becomes key; the reader asks `isKeyWindow`, and this answers it.
final class KeyableWindow: NSWindow {
    var isKey = true
    override var isKeyWindow: Bool { isKey }
}

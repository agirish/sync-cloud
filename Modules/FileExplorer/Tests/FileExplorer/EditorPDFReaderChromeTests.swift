import Testing
import AppKit
import PDFKit
import SwiftUI
import Design
@testable import FileExplorer
import FileExplorerTestSupport
import Sync

/// **Phase 6a: the PDF reader's chrome** — the two-row header at a text file's height, row 2's
/// facts, no status line, the floating page and zoom capsule and the find card over the canvas.
///
/// Serialized: the mounted tests lay out a `PDFView` on the main thread.
@MainActor
@Suite(.serialized) final class EditorPDFReaderChromeTests {

    let folder = NSTemporaryDirectory() + "editor-pdf-chrome-" + UUID().uuidString
    private let defaults = ScratchDefaults("EditorPDFReaderChromeTests")

    init() throws {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(atPath: folder) }

    private var scales: [CGFloat] { FontSize.allCases.map(\.scale) }

    private func open(pages: Int, name: String = "Run of show.pdf") async throws -> EditorPDFDocument {
        let file = (folder as NSString).appendingPathComponent(name)
        PDFFixtures.write(file, pages: pages)
        let pdf = EditorPDFDocument(isCloudOnly: { _ in false }, defaults: defaults)
        var phases: [EditorPDFDocument.Phase] = []
        pdf.onLoaded = { phases.append($0) }
        pdf.open(path: file, log: { _ in })
        for _ in 0..<1000 where phases.isEmpty {
            await PDFKitSerialAccess.perform {}
            try? await Task.sleep(for: .milliseconds(5))
        }
        try #require(phases.first == .open)
        return pdf
    }

    private func size<V: View>(_ view: V, width: CGFloat? = nil, scale: CGFloat = 1) -> CGSize {
        let scaled = view.environment(\.appFontScale, scale)
        let hosted = NSHostingView(rootView: AnyView(width.map { AnyView(scaled.frame(width: $0)) } ?? AnyView(scaled)))
        return hosted.fittingSize
    }

    private func host<V: View>(_ view: V, size: CGSize, resizable: Bool = false) -> NSWindow {
        let host = NSHostingView(rootView: view.frame(maxWidth: .infinity, maxHeight: .infinity))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: resizable ? [.titled, .resizable] : [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.layoutIfNeeded()
        return window
    }

    private func descendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let found = view as? T { return found }
        for sub in view.subviews { if let found = descendant(type, in: sub) { return found } }
        return nil
    }

    private func reader(_ pdf: EditorPDFDocument) -> EditorPDFReader {
        EditorPDFReader(document: pdf.document, state: pdf.view, find: pdf.find, fill: pdf.fill,
                        pageCount: pdf.facts?.pageCount ?? 0, accent: .blue)
    }

    private func inWindow(_ view: NSView) -> CGRect { view.convert(view.bounds, to: nil) }

    // MARK: The header

    /// **The PDF header is a text file's height, at every text size** — so switching between a PDF
    /// and a Markdown file in one column moves nothing (decided 2026-10-19, mockup 4's parity).
    @Test func thePDFHeaderIsTheTextHeadersHeight() async throws {
        let pdf = try await open(pages: 4)
        let markdown = try TestTextFiles.document(named: "Run of show.md")
        try #require(markdown.isMarkdown)
        for scale in scales {
            let text = size(EditorWorkspaceView.fixture(document: markdown).readingSettings(from: defaults).header,
                            width: 520, scale: scale)
            let ofPDF = size(EditorWorkspaceView.fixture(pdf: pdf).readingSettings(from: defaults).header,
                             width: 520, scale: scale)
            #expect(abs(text.height - ofPDF.height) < 0.51,
                    "at scale \(scale) the text header is \(text.height)pt and the PDF's is \(ofPDF.height)pt")
        }
    }

    /// **Two rows, the name's and the facts'** — and row 2 starts with "PDF", as a text file's
    /// starts with "Markdown".
    @Test func theHeaderHasTwoRowsAndRowTwoStartsWithPDF() throws {
        let card = try ChromeGlassWiringTests.source("EditorPDFCard.swift")
        let header = try #require(card.range(of: "struct EditorPDFHeader<Trailing: View>: View {"))
        let body = String(card[header.upperBound...].prefix(900))
        #expect(body.contains("VStack(alignment: .leading, spacing: 2) {\n            nameRow\n            metaRow\n        }"),
                "the PDF header is not the name row over the facts row")
        let row = try #require(card.range(of: "struct EditorPDFFactsRow: View {"))
        let rowBody = String(card[row.upperBound...].prefix(900))
        let pdfWord = try #require(rowBody.range(of: "Text(Self.kindWord)"))
        let facts = try #require(rowBody.range(of: "ViewThatFits(in: .horizontal)"))
        #expect(pdfWord.lowerBound < facts.lowerBound, "row 2 does not start with \"PDF\"")
        #expect(!card.contains("Read only\""), "the Read only tag is back")
    }

    /// **Row 2 sheds whole segments** — "Text selectable" first, then the inches, then the paper's
    /// name, then the size — and never cuts one: each is laid out at its own width.
    @Test func rowTwoShedsWholeSegmentsInOrder() throws {
        let letter = EditorPDFFacts(pageCount: 2, pageSizes: [PDFFixtures.letter, PDFFixtures.letter],
                                    majorVersion: 1, minorVersion: 4, fileSize: "42 KB", hasText: true)
        #expect(EditorPDFFactsRow.rungs(letter, page: 0) == [
            ["Letter, 8.5 × 11 in", "42 KB", "Text selectable"],
            ["Letter, 8.5 × 11 in", "42 KB"],
            ["Letter", "42 KB"],
            ["42 KB"],
            [],
        ])
        // A scan keeps the status line's own words; a paper with no name has no shorter reading.
        let odd = EditorPDFFacts(pageCount: 1, pageSizes: [CGSize(width: 288, height: 432)],
                                 majorVersion: 1, minorVersion: 7, fileSize: "9 KB", hasText: false)
        #expect(EditorPDFFactsRow.rungs(odd, page: 0) == [
            ["4 × 6 in", "9 KB", "Image only"],
            ["4 × 6 in", "9 KB"],
            ["9 KB"],
            [],
        ])
        let card = try ChromeGlassWiringTests.source("EditorPDFCard.swift")
        let row = try #require(card.range(of: "private func row(_ segments: [String]) -> some View {"))
        #expect(String(card[row.upperBound...].prefix(400)).contains(".fixedSize()"), "a segment can be cut mid-word")
    }

    /// **Row 2 says nothing of Fill & Sign** (Phase 6b): the unsaved count is the save pill's, so
    /// row 2 reads the same with an item placed as without.
    @Test func rowTwoReadsTheSameWithAnItemPlaced() async throws {
        let pdf = try await open(pages: 2)
        // At row 2's own size: the header sets it, not the row.
        func drawn() -> CGFloat {
            size(EditorPDFFactsRow(state: pdf.view, facts: pdf.facts).scaledFont(.system(size: 10))).width
        }
        let before = drawn()
        pdf.fill.toggle()
        let id = try #require(pdf.fill.place(at: CGPoint(x: 100, y: 600), page: 0))
        pdf.fill.type("Alex Morgan", into: id)
        pdf.fill.endEditing()
        try #require(pdf.fill.unsavedCaption == "1 item not saved")
        #expect(abs(drawn() - before) < 0.5, "row 2 changed with an item placed")
        let card = try ChromeGlassWiringTests.source("EditorPDFCard.swift")
        #expect(!card.contains("unsavedCaption"), "the header counts Fill & Sign's items again")
    }

    /// **No status line under a PDF; a text file keeps its own.**
    @Test func aPDFHasNoStatusLineAndATextFileKeepsOne() throws {
        let workspace = try ChromeGlassWiringTests.source("EditorWorkspaceView.swift")
        #expect(!workspace.contains("EditorPDFStatusLine"), "the PDF's status line is mounted again")
        #expect(workspace.contains("EditorStatusLine(facts: facts, caret: caret"), "the text status line went too")
        for file in ["EditorPDFCard.swift", "EditorPDFCanvas.swift", "EditorPDFCapsule.swift"] {
            #expect(!(try ChromeGlassWiringTests.source(file)).contains("struct EditorPDFStatusLine"))
        }
    }

    // MARK: The capsule: where it is

    /// **Mounted over the canvas, not inside the `PDFView`** — its grip lies within the pages'
    /// frame and is none of PDFKit's views.
    @Test func theCapsuleIsMountedOverTheCanvas() async throws {
        let pdf = try await open(pages: 3)
        let window = host(reader(pdf), size: CGSize(width: 700, height: 600))
        defer { window.contentView = nil }
        let root = try #require(window.contentView)
        let settled = await LayoutPumpWait.pump(window, upTo: 10) {
            self.descendant(EditorPDFGripView.self, in: root) != nil && self.descendant(ReaderPDFView.self, in: root) != nil
        }
        try #require(settled.held, "no grip or no page view on the canvas")
        let grip = try #require(descendant(EditorPDFGripView.self, in: root))
        let pages = try #require(descendant(ReaderPDFView.self, in: root))
        #expect(!grip.isDescendant(of: pages), "the capsule is inside the PDFView")
        #expect(inWindow(pages).contains(inWindow(grip)), "the capsule is not over the pages")
    }

    /// **Each place sits 14pt in from the edges it is named for**, centred on the others.
    @Test func eachPlaceSitsInsetFromItsEdges() {
        let canvas = CGSize(width: 800, height: 600), row = CGSize(width: 300, height: 30)
        let inset = EditorPDFFloating.inset
        #expect(EditorPDFCapsulePlace.topLeading.frame(size: row, in: canvas).origin == CGPoint(x: inset, y: inset))
        #expect(EditorPDFCapsulePlace.top.frame(size: row, in: canvas).midX == 400)
        #expect(EditorPDFCapsulePlace.topTrailing.frame(size: row, in: canvas).maxX == 800 - inset)
        #expect(EditorPDFCapsulePlace.bottom.frame(size: row, in: canvas).maxY == 600 - inset)
        #expect(EditorPDFCapsulePlace.bottom.frame(size: row, in: canvas).midX == 400)
        #expect(EditorPDFCapsulePlace.bottomLeading.frame(size: row, in: canvas).minX == inset)
        #expect(EditorPDFCapsulePlace.bottomTrailing.frame(size: row, in: canvas).maxX == 800 - inset)
        let upright = CGSize(width: 40, height: 200)
        #expect(EditorPDFCapsulePlace.leading.frame(size: upright, in: canvas).minX == inset)
        #expect(EditorPDFCapsulePlace.leading.frame(size: upright, in: canvas).midY == 300)
        #expect(EditorPDFCapsulePlace.trailing.frame(size: upright, in: canvas).maxX == 800 - inset)
        #expect(EditorPDFSettings.capsulePlaceDefault == .bottom)
        #expect(EditorPDFCapsulePlace.allCases.count == 8)
    }

    /// **A drop snaps to the nearest of the eight places** — and a capsule let go where it already
    /// is stays there, even on a canvas so narrow that a corner and the middle of its edge nearly
    /// meet.
    @Test func aDropSnapsToTheNearestPlace() {
        let row = CGSize(width: 300, height: 30), upright = CGSize(width: 40, height: 200)
        for canvas in [CGSize(width: 900, height: 700), CGSize(width: 366, height: 520), CGSize(width: 1400, height: 420)] {
            for place in EditorPDFCapsulePlace.allCases {
                let frame = place.frame(size: place.isVertical ? upright : row, in: canvas)
                let landed = EditorPDFCapsulePlace.nearest(to: CGPoint(x: frame.midX, y: frame.midY),
                                                           horizontal: row, vertical: upright, in: canvas)
                #expect(landed == place, "on a \(canvas) canvas a drop at \(place)'s own centre lands at \(landed)")
            }
        }
        let canvas = CGSize(width: 900, height: 700)
        #expect(EditorPDFCapsulePlace.nearest(to: CGPoint(x: 880, y: 690), horizontal: row, vertical: upright, in: canvas)
                == .bottomTrailing)
        #expect(EditorPDFCapsulePlace.nearest(to: CGPoint(x: 20, y: 360), horizontal: row, vertical: upright, in: canvas)
                == .leading)
        #expect(EditorPDFCapsulePlace.nearest(to: CGPoint(x: 460, y: 30), horizontal: row, vertical: upright, in: canvas)
                == .top)
    }

    /// **The place is remembered as a place, under the named key**, and read back by the next view
    /// state — the next launch's. A close keeps it; an unknown stored value falls back.
    @Test func thePlaceIsStoredByNameAndSurvivesARemount() {
        let first = EditorPDFViewState(defaults: defaults)
        #expect(first.capsulePlace == .bottom)
        first.capsulePlace = .topTrailing
        #expect(defaults.string(forKey: EditorPDFSettings.capsulePlaceKey) == "topTrailing")
        #expect(EditorPDFSettings.capsulePlaceKey == "editorPDFCapsulePlace")
        let next = EditorPDFViewState(defaults: defaults)
        #expect(next.capsulePlace == .topTrailing)
        next.reset()
        #expect(next.capsulePlace == .topTrailing, "closing the PDF moved the capsule")
        defaults.set("middleOfNowhere", forKey: EditorPDFSettings.capsulePlaceKey)
        #expect(EditorPDFViewState(defaults: defaults).capsulePlace == .bottom)
    }

    /// **Settings ▸ Reset All Settings reaches an open reader** — the layout, Cover Page
    /// Separately and both places go back to their defaults on screen as they do on disk, not at
    /// the next launch; and taking them writes nothing back into the emptied domain.
    @Test func aResetReachesTheOpenReader() {
        let reset = ScratchDefaults("EditorPDFReaderReset")
        let state = EditorPDFViewState(defaults: reset)
        state.layout = .twoPages
        state.coverSeparately = true
        state.capsulePlace = .topLeading
        state.palettePlace = .trailing
        reset.removePersistentDomain(forName: reset.scratchSuiteName)
        #expect(state.layout == EditorPDFSettings.layoutDefault)
        #expect(state.coverSeparately == EditorPDFSettings.coverSeparatelyDefault)
        #expect(state.capsulePlace == EditorPDFSettings.capsulePlaceDefault)
        #expect(state.palettePlace == EditorPDFSettings.palettePlaceDefault)
        #expect(reset.object(forKey: EditorPDFSettings.capsulePlaceKey) == nil, "taking the reset wrote the place back")
        // And a choice after it is remembered as ever.
        state.capsulePlace = .top
        #expect(reset.string(forKey: EditorPDFSettings.capsulePlaceKey) == "top")
    }

    /// **The place holds across a resize** — bottom right is still bottom right, 14pt in, in a
    /// wider and taller window: the capsule moves with the corner rather than staying at the points
    /// it was drawn at.
    @Test func thePlaceHoldsAcrossAResize() async throws {
        let pdf = try await open(pages: 3)
        pdf.view.capsulePlace = .bottomTrailing
        let window = host(reader(pdf), size: CGSize(width: 800, height: 600), resizable: true)
        defer { window.contentView = nil }
        let root = try #require(window.contentView)
        _ = await LayoutPumpWait.pump(window, upTo: 10) { self.descendant(EditorPDFGripView.self, in: root) != nil }
        let grip = try #require(descendant(EditorPDFGripView.self, in: root))
        // Let the capsule's measured size land and the place settle.
        _ = await LayoutPumpWait.pump(window, upTo: 2) { false }
        let before = inWindow(grip)
        window.setContentSize(CGSize(width: 1100, height: 700))
        let moved = await LayoutPumpWait.pump(window, upTo: 10) { abs(self.inWindow(grip).minX - before.minX) > 1 }
        #expect(moved.held, "the capsule stayed where it was drawn when the window grew")
        let after = inWindow(grip)
        // Window coordinates run up from the bottom: a capsule anchored there keeps its y.
        #expect(abs((after.minX - before.minX) - 300) < 2, "the grip moved \(after.minX - before.minX)pt for a 300pt wider window")
        #expect(abs(after.minY - before.minY) < 2, "the grip left the bottom edge: \(before.minY) → \(after.minY)")
    }

    /// **A click anywhere on the canvas but the floating pieces reaches the pages** — selecting
    /// text and Fill & Sign's placing must work right up to the capsule and the card. The pieces
    /// fill the canvas to align themselves, so this is what proves those frames are not hit. And
    /// the grip, the one AppKit view in the capsule, gets its own clicks.
    @Test func clicksOffTheFloatingPiecesReachThePages() async throws {
        let pdf = try await open(pages: 3)
        pdf.find.show()
        let window = host(reader(pdf), size: CGSize(width: 700, height: 600))
        defer { window.contentView = nil }
        let root = try #require(window.contentView)
        let settled = await LayoutPumpWait.pump(window, upTo: 10) {
            self.descendant(EditorPDFGripView.self, in: root) != nil && self.descendant(ReaderPDFView.self, in: root) != nil
        }
        try #require(settled.held)
        _ = await LayoutPumpWait.pump(window, upTo: 1) { false }
        let pages = try #require(descendant(ReaderPDFView.self, in: root))
        let grip = try #require(descendant(EditorPDFGripView.self, in: root))
        func hit(_ point: NSPoint) -> NSView? { root.hitTest(root.superview?.convert(point, from: nil) ?? point) }
        let canvas = inWindow(pages)
        let gripFrame = inWindow(grip)
        // Window space runs up: the capsule is at the bottom, the find card at the top right.
        let empty = [NSPoint(x: canvas.midX, y: canvas.midY),
                     NSPoint(x: canvas.minX + 20, y: canvas.maxY - 20),
                     NSPoint(x: canvas.minX + 20, y: canvas.minY + 20),
                     NSPoint(x: canvas.maxX - 20, y: canvas.minY + 20),
                     NSPoint(x: canvas.maxX - 20, y: canvas.midY),
                     // Beside the capsule, level with it.
                     NSPoint(x: gripFrame.minX - 60, y: gripFrame.midY)]
        for point in empty {
            let landed = hit(point)
            #expect(landed.map { $0 === pages || $0.isDescendant(of: pages) } == true,
                    "a click at \(point) landed on \(landed.map { String(describing: type(of: $0)) } ?? "nothing"), not the pages")
        }
        #expect(hit(NSPoint(x: gripFrame.midX, y: gripFrame.midY)) === grip, "the grip does not get its own clicks")
    }

    // MARK: The capsule: the grip

    private func mouse(_ type: NSEvent.EventType, at point: NSPoint, clicks: Int = 1) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                        context: nil, eventNumber: 0, clickCount: clicks, pressure: 1))
    }

    /// **A drag by the grip reports the move, turned into SwiftUI's down-is-positive space, and a
    /// press that never moves past the threshold is only a click.**
    @Test func theGripDragsAndAClickIsOnlyAClick() throws {
        let grip = EditorPDFGripView()
        var dragged: [CGSize] = [], dropped: [CGSize] = []
        grip.onDrag = { dragged.append($0) }
        grip.onDrop = { dropped.append($0) }
        grip.mouseDown(with: try mouse(.leftMouseDown, at: NSPoint(x: 10, y: 100)))
        grip.mouseDragged(with: try mouse(.leftMouseDragged, at: NSPoint(x: 11, y: 99)))
        grip.mouseUp(with: try mouse(.leftMouseUp, at: NSPoint(x: 11, y: 99)))
        #expect(dragged.isEmpty && dropped.isEmpty, "a 1pt wobble was a drag")
        grip.mouseDown(with: try mouse(.leftMouseDown, at: NSPoint(x: 10, y: 100)))
        grip.mouseDragged(with: try mouse(.leftMouseDragged, at: NSPoint(x: 110, y: 50)))
        grip.mouseUp(with: try mouse(.leftMouseUp, at: NSPoint(x: 210, y: 40)))
        #expect(dragged == [CGSize(width: 100, height: 50)])
        #expect(dropped == [CGSize(width: 200, height: 60)])
    }

    /// **A grip taken out of its window mid-drag lets the drag go** — the palette went while its
    /// grip was held. The rest of the drag still reaches the view that took the press; it used to
    /// restart the drag and drop the piece by a frame that was gone.
    @Test func aGripLeavingItsWindowMidDragLetsTheDragGo() throws {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let grip = EditorPDFGripView(frame: CGRect(x: 0, y: 0, width: 20, height: 20))
        window.contentView?.addSubview(grip)
        var dragged: [CGSize] = [], dropped: [CGSize] = []
        grip.onDrag = { dragged.append($0) }
        grip.onDrop = { dropped.append($0) }
        grip.mouseDown(with: try mouse(.leftMouseDown, at: NSPoint(x: 10, y: 100)))
        grip.mouseDragged(with: try mouse(.leftMouseDragged, at: NSPoint(x: 60, y: 100)))
        #expect(dragged.count == 1, "the premise: the drag began")
        grip.removeFromSuperview()
        grip.mouseDragged(with: try mouse(.leftMouseDragged, at: NSPoint(x: 90, y: 100)))
        grip.mouseUp(with: try mouse(.leftMouseUp, at: NSPoint(x: 90, y: 100)))
        #expect(dragged.count == 1, "a drag event after the grip left restarted the drag")
        #expect(dropped.isEmpty, "a mouse-up after the grip left dropped the piece")
    }

    /// **Double-click and Reset Position put it back at bottom centre; Move To moves it** — and the
    /// menu ticks where it is.
    @Test func theGripResetsAndItsMenuMovesIt() throws {
        let state = EditorPDFViewState(defaults: defaults)
        let grip = EditorPDFGripView()
        grip.state = state
        state.capsulePlace = .leading
        grip.mouseDown(with: try mouse(.leftMouseDown, at: .zero, clicks: 2))
        #expect(state.capsulePlace == .bottom, "a double-click on the grip did not reset it")

        state.capsulePlace = .topLeading
        let menu = try #require(grip.menu(for: try mouse(.rightMouseDown, at: .zero)))
        #expect(menu.items.map(\.title) == [EditorPDFCapsuleMenu.moveToTitle, EditorPDFCapsuleMenu.resetTitle])
        let places = try #require(menu.items.first?.submenu)
        #expect(places.items.filter { !$0.isSeparatorItem }.map(\.title) == EditorPDFCapsulePlace.allCases.map(\.title))
        #expect(places.items.filter { $0.state == .on }.map(\.title) == ["Top Left"])
        let topRight = try #require(places.items.first { $0.title == "Top Right" })
        _ = topRight.target?.perform(topRight.action)
        #expect(state.capsulePlace == .topTrailing)
        let reset = try #require(menu.items.last)
        _ = reset.target?.perform(reset.action)
        #expect(state.capsulePlace == .bottom)
        let atRest = try #require(grip.menu(for: try mouse(.rightMouseDown, at: .zero)))
        #expect(atRest.items.last?.isEnabled == false, "Reset Position is live with the capsule already at the bottom")
    }

    /// **Move To's places and Reset Position are the grip's accessibility actions**, so moving the
    /// capsule never needs a drag — and the grip says what it is and where the capsule is.
    @Test func theMoveToActionsAreExposedToAccessibility() throws {
        let state = EditorPDFViewState(defaults: defaults)
        let grip = EditorPDFGripView()
        grip.state = state
        #expect(grip.isAccessibilityElement())
        #expect(grip.accessibilityRole() == .handle)
        #expect(grip.accessibilityLabel() == "Move the page controls")
        let actions = try #require(grip.accessibilityCustomActions())
        #expect(actions.map(\.name) == EditorPDFCapsulePlace.allCases.map { "Move to \($0.title)" } + ["Reset Position"])
        let left = try #require(actions.first { $0.name == "Move to Middle Left" })
        #expect(left.handler?() == true)
        #expect(state.capsulePlace == .leading)
        #expect(grip.accessibilityValue() as? String == "Middle Left")
        _ = actions.last?.handler?()
        #expect(state.capsulePlace == .bottom)
    }

    // MARK: The capsule: its forms

    private func capsule(_ state: EditorPDFViewState, pages: Int = 64, rung: EditorPDFCapsule.Rung,
                         scale: CGFloat = 1) -> CGSize {
        size(EditorPDFCapsule(state: state, pageCount: pages, accent: .blue, forcedRung: rung), scale: scale)
    }

    /// **Upright only in the middle of a side**: there it is taller than wide, with ˄ ˅ and the
    /// percentage; everywhere else a row.
    @Test func theCapsuleStandsUprightOnlyAtTheMiddlePlaces() throws {
        #expect(EditorPDFCapsulePlace.allCases.filter(\.isVertical) == [.leading, .trailing])
        let state = EditorPDFViewState(defaults: defaults)
        state.pageCount = 64
        for place in EditorPDFCapsulePlace.allCases {
            state.capsulePlace = place
            let drawn = capsule(state, rung: .full)
            if place.isVertical {
                #expect(drawn.height > drawn.width, "at \(place) the capsule is \(drawn) — not upright")
            } else {
                #expect(drawn.width > drawn.height, "at \(place) the capsule is \(drawn) — not a row")
            }
        }
        let source = try ChromeGlassWiringTests.source("EditorPDFCapsule.swift")
        #expect(source.contains("isVertical ? (forward ? \"chevron.down\" : \"chevron.up\")"), "upright, ‹ › are not ˄ ˅")
        #expect(source.contains("Text(isVertical ? EditorPDFZoom.percent(state.scale) : said)"),
                "upright, the zoom label does not show the percentage")
        // The menu still ticks the fit upright: it is the same menu, built from the state.
        state.capsulePlace = .trailing
        state.fit = .page
        #expect(EditorPDFViewMenu.menu(for: state).items.filter { $0.state == .on }.map(\.title) == ["Fit Page"])
    }

    /// **Upright, the capsule is one width at every zoom** — its width is the side band a fit is
    /// measured inside, so a width that followed the percentage's digits looped Fit Width between
    /// 99% and 100% at a column width in between, the page flickering for as long as it was left.
    @Test func theUprightCapsuleIsOneWidthAtEveryZoom() {
        let state = EditorPDFViewState(defaults: defaults)
        state.pageCount = 64
        state.capsulePlace = .trailing
        for scale in scales {
            let widths = [EditorPDFViewState.minScale, 0.99, 1, 1.25, EditorPDFViewState.maxScale].map { zoom in
                state.scale = zoom
                return capsule(state, rung: .full, scale: scale).width
            }
            #expect(Set(widths).count == 1, "at \(scale) the upright capsule measures \(widths) across the zooms")
        }
    }

    /// **A narrow canvas takes − and + first, then ‹ and ›** — each rung narrower, at every text size
    /// — **and never "N of M" or the zoom label**: the narrowest still grows with the page count's
    /// digits and with the zoom's words.
    @Test func theCapsuleCompactsInOrderAndKeepsThePageAndTheZoom() throws {
        #expect(EditorPDFCapsule.Rung.allCases == [.full, .noZoomSteps, .pageAndZoomOnly])
        #expect(EditorPDFCapsule.Rung.allCases.map(\.showsZoomSteps) == [true, false, false])
        #expect(EditorPDFCapsule.Rung.allCases.map(\.showsPageSteps) == [true, true, false])
        let state = EditorPDFViewState(defaults: defaults)
        state.pageCount = 64
        for scale in scales {
            let widths = EditorPDFCapsule.Rung.allCases.map { capsule(state, rung: $0, scale: scale).width }
            #expect(zip(widths, widths.dropFirst()).allSatisfy { $0 > $1 + 10 }, "at \(scale) the rungs measure \(widths)")
        }
        // "of M" is drawn: from 9 pages to 99,999 the narrowest capsule grows by the field's own
        // growth AND the count's. The field alone widens with the digits too, so growing at all
        // is not enough — that passed with "of M" deleted.
        let few = capsule(state, pages: 9, rung: .pageAndZoomOnly).width
        let many = capsule(state, pages: 99_999, rung: .pageAndZoomOnly).width
        let fieldGrowth = EditorPDFCapsule.fieldWidth(pageCount: 99_999) - EditorPDFCapsule.fieldWidth(pageCount: 9)
        func count(_ pages: Int) -> CGFloat {
            size(Text("of \(pages)").monospacedDigit().scaledFont(.system(size: 10))).width
        }
        let countGrowth = count(99_999) - count(9)
        try #require(countGrowth > 10, "the count's own growth is \(countGrowth)pt — this check would be vacuous")
        #expect(many - few > fieldGrowth + countGrowth - 1,
                "the narrowest capsule grows \(many - few)pt from 9 pages to 99,999; the field alone grows \(fieldGrowth)pt and \"of M\" \(countGrowth)pt — \"of M\" is not drawn")
        state.fit = .page
        let fitted = capsule(state, rung: .pageAndZoomOnly).width
        state.fit = .width
        let wider = capsule(state, rung: .pageAndZoomOnly).width
        state.fit = nil
        state.scale = 1
        let percent = capsule(state, rung: .pageAndZoomOnly).width
        #expect(fitted != percent && wider != percent, "the narrowest capsule does not draw the zoom label")
    }

    /// **The page bands**: 28pt above the first page, and the capsule's own band on its edge.
    @Test func theCanvasKeepsBandsForThePagesToClear() {
        let row = CGSize(width: 300, height: 30), upright = CGSize(width: 40, height: 200)
        let bottom = EditorPDFFloating.canvasInsets(place: .bottom, capsule: row)
        #expect(bottom.top == 28 && bottom.bottom == 14 + 30 + 8 && bottom.left == 0 && bottom.right == 0)
        let corner = EditorPDFFloating.canvasInsets(place: .topTrailing, capsule: row)
        #expect(corner.top == 14 + 30 + 8 && corner.bottom == 0)
        let side = EditorPDFFloating.canvasInsets(place: .trailing, capsule: upright)
        #expect(side.right == 14 + 40 + 8 && side.top == 28 && side.bottom == 0 && side.left == 0)
        // Spelled as a CGFloat: `#expect` splits a lone `==` and reads a bare `14 + 40 + 8` as an
        // Int, which never equals the CGFloat 62.0 it is compared with.
        #expect(EditorPDFFloating.canvasInsets(place: .leading, capsule: upright).left == CGFloat(14 + 40 + 8))
        // Nothing measured yet: the top band alone.
        #expect(EditorPDFFloating.canvasInsets(place: .bottom, capsule: .zero).bottom == 0)
    }

    /// **The end of the last page scrolls fully clear of the capsule's band**, and the first page
    /// starts below the top band — on a mounted page view with the bands set.
    @Test func theLastPageScrollsClearOfTheCapsule() async throws {
        let pdf = try await open(pages: 3)
        let insets = EditorPDFFloating.canvasInsets(place: .bottom, capsule: CGSize(width: 300, height: 30))
        let window = host(EditorPDFPageView(document: pdf.document, state: pdf.view, canvasInsets: insets),
                            size: CGSize(width: 700, height: 500))
        defer { window.contentView = nil }
        let root = try #require(window.contentView)
        let settled = await LayoutPumpWait.pump(window, upTo: 10) { (self.descendant(ReaderPDFView.self, in: root)?.bounds.width ?? 0) > 0 }
        try #require(settled.held)
        let view = try #require(descendant(ReaderPDFView.self, in: root))
        let scroll = try #require(view.pagesScrollView)
        #expect(NSEdgeInsetsEqual(scroll.contentInsets, insets), "the bands are not the scroll view's insets")
        func gaps(_ index: Int) throws -> (top: CGFloat, bottom: CGFloat) {
            let page = try #require(pdf.document?.page(at: index))
            let drawn = view.convert(page.bounds(for: view.displayBox), from: page)
            return view.isFlipped ? (drawn.minY - view.bounds.minY, view.bounds.maxY - drawn.maxY)
                                  : (view.bounds.maxY - drawn.maxY, drawn.minY - view.bounds.minY)
        }
        // As it opens, at Fit Page.
        let opened = try gaps(0)
        #expect(opened.top >= insets.top - 1, "the first page opens \(opened.top)pt down, inside the top band")
        // Fit Width, scrolled to each end. (A fit change zooms about the middle, as PDFKit always
        // has, so the top is scrolled back to rather than assumed.)
        pdf.view.fit = .width
        view.fit = .width
        view.layoutSubtreeIfNeeded()
        let clip = scroll.contentView
        let flipped = scroll.documentView?.isFlipped ?? true
        func scrollPages(toEnd: Bool) {
            var far = clip.bounds
            far.origin.y = (flipped == toEnd) ? 1e7 : -1e7
            clip.scroll(to: clip.constrainBoundsRect(far).origin)
            scroll.reflectScrolledClipView(clip)
            view.layoutSubtreeIfNeeded()
        }
        scrollPages(toEnd: false)
        let first = try gaps(0)
        #expect(first.top >= insets.top - 1, "scrolled to the top, the first page starts \(first.top)pt down, inside the top band")
        scrollPages(toEnd: true)
        let last = try gaps(2)
        #expect(last.bottom >= insets.bottom - 1,
                "scrolled to the end, the last page stops \(last.bottom)pt from the bottom — under the capsule's \(insets.bottom)pt band")
    }

    // MARK: Floating pieces never overlap

    /// **The capsule slides along its edge until it clears the find card, and goes back when the
    /// card closes** — the one rule every floating piece keeps.
    @Test func theCapsuleSlidesClearOfTheFindCardAndBack() {
        let canvas = CGSize(width: 800, height: 600)
        let card = EditorPDFCapsulePlace.topTrailing.frame(size: CGSize(width: 330, height: 32), in: canvas)
        let docked = EditorPDFCapsulePlace.topTrailing.frame(size: CGSize(width: 300, height: 30), in: canvas)
        let shown = EditorPDFFloating.clear(docked, of: [card], sliding: .horizontal, within: canvas)
        #expect(shown.minY == docked.minY, "the capsule left the top edge")
        #expect(shown.maxX <= card.minX - EditorPDFFloating.gap + 0.01, "the capsule still overlaps the card")
        #expect(shown.minX >= EditorPDFFloating.inset, "the capsule slid off the canvas")
        #expect(EditorPDFFloating.clear(docked, of: [], sliding: .horizontal, within: canvas) == docked,
                "with the card closed the capsule does not go back")
        // Upright at the right on a short canvas: down, along the side.
        let short = CGSize(width: 800, height: 280)
        let side = EditorPDFCapsulePlace.trailing.frame(size: CGSize(width: 40, height: 200), in: short)
        let shortCard = EditorPDFCapsulePlace.topTrailing.frame(size: CGSize(width: 330, height: 32), in: short)
        let slid = EditorPDFFloating.clear(side, of: [shortCard], sliding: .vertical, within: short)
        #expect(slid.minX == side.minX && slid.minY >= shortCard.maxY + EditorPDFFloating.gap - 0.01)
        // No room along the edge: across it, under the card.
        let narrow = CGSize(width: 366, height: 500)
        let wide = EditorPDFCapsulePlace.top.frame(size: CGSize(width: 300, height: 30), in: narrow)
        let narrowCard = EditorPDFCapsulePlace.topTrailing.frame(size: CGSize(width: 330, height: 32), in: narrow)
        let under = EditorPDFFloating.clear(wide, of: [narrowCard], sliding: .horizontal, within: narrow)
        #expect(!under.insetBy(dx: 1, dy: 1).intersects(narrowCard), "with no room along the top the capsule still overlaps")
    }

    /// The canvas hands the find card to the rule only while it is up, and the bands never count it:
    /// opening the card must not move the page.
    @Test func theFindCardIsAnObstacleOnlyWhileItIsUp() throws {
        let canvas = try ChromeGlassWiringTests.source("EditorPDFCanvas.swift")
        #expect(canvas.contains("findCard: find.isShown ? findCard : .zero"))
        #expect(canvas.contains("canvasInsets: EditorPDFFloating.canvasInsets(place: state.capsulePlace, capsule: capsule.now),"),
                "the bands are not the capsule's alone")
        // What floats over the pages is what "a match in sight" keeps clear of: the card, the pill,
        // the palette, and the capsule once it has slid off its band — not the capsule at its place.
        #expect(canvas.contains("coveredRects: frames.covered)"), "the page view is not told what floats over it")
        let canvasSize = CGSize(width: 700, height: 800)
        let card = CGSize(width: 330, height: 30), pill = CGSize(width: 200, height: 28)
        let row = CGSize(width: 260, height: 30)
        let calm = EditorPDFReader.layout(canvas: canvasSize, findCard: .zero, saveStack: .zero, palette: .zero,
                                          palettePlace: .leading, capsule: row, capsulePlace: .bottom)
        #expect(calm.covered.isEmpty, "the capsule at its place, inside its band, counted as covering")
        let busy = EditorPDFReader.layout(canvas: canvasSize, findCard: card, saveStack: pill, palette: .zero,
                                          palettePlace: .leading, capsule: row, capsulePlace: .topTrailing)
        #expect(busy.covered.contains(busy.findCard) && busy.covered.contains(busy.saveStack))
        #expect(busy.capsule != busy.capsuleDocked && busy.covered.contains(busy.capsule),
                "the capsule slid clear of the card is not counted as covering")
        // A refused Fill & Sign's tooltip reads as sentences, whichever line the menu has.
        #expect(EditorPDFFillSignButton.sentence(EditorPDFFillSign.restrictedTitle) == "This PDF doesn’t allow filling.")
        #expect(EditorPDFFillSignButton.sentence("Already one.") == "Already one.")
    }

    // MARK: Glass

    /// **At Clear the floating pieces wear Frosted's glass** — they sit over page text, not the
    /// desktop. Solid and Frosted are left as they are.
    @Test func floatingPiecesWearFrostedAtClear() {
        let clear = SelectionLensAppearance(level: .clear, hue: .blue, tint: 0.5)
        #expect(EditorPDFFloating.appearance(clear).level == .frosted)
        #expect(EditorPDFFloating.appearance(clear).hue == .blue && EditorPDFFloating.appearance(clear).tint == 0.5)
        for level in [GlassLevel.solid, .frosted] {
            let window = SelectionLensAppearance(level: level, hue: .blue, tint: 0.5)
            #expect(EditorPDFFloating.appearance(window) == window)
        }
    }

    /// **In dark mode the glass stands on a dark veil**; light mode, Solid and the probe draw none.
    /// Decided 2026-10-18 over Solid's ground at every level: Frosted in dark let the page's type
    /// show through behind light labels.
    @Test func floatingGlassStandsOnADarkVeilInDarkModeOnly() throws {
        for material in [SelectionLensMaterial.frosted, .clear] {
            #expect(EditorPDFFloating.veil(material: material, colorScheme: .dark) == EditorPDFFloating.darkVeil)
            #expect(EditorPDFFloating.veil(material: material, colorScheme: .light) == 0)
        }
        for material in [SelectionLensMaterial.today, .probe] {
            #expect(EditorPDFFloating.veil(material: material, colorScheme: .dark) == 0)
        }
        #expect(EditorPDFFloating.darkVeil >= 0.9, "a thin veil lets the page's type through again")
        // Behind the glass, not on it, and read off the floating appearance the glass itself draws in.
        let canvas = try ChromeGlassWiringTests.source("EditorPDFCanvas.swift")
        #expect(canvas.contains("material: ChromeGlass.material(appearance: floating, reduceTransparency: reduceTransparency)"))
        let group = try #require(canvas.range(of: ".chromeGlassGroup(shape)"))
        let veil = try #require(canvas.range(of: "if veil > 0 {"))
        let floating = try #require(canvas.range(of: ".environment(\\.selectionLensAppearance, floating)"))
        #expect(group.upperBound < veil.lowerBound && veil.upperBound < floating.lowerBound,
                "the veil is no longer a background behind the floating pieces' glass")
    }

    // MARK: Keyboard and VoiceOver

    /// **⌃⌘L reaches the capsule's field**, and the header has no page field left to compete.
    @Test func goToPageFocusesTheCapsulesField() throws {
        let capsule = try ChromeGlassWiringTests.source("EditorPDFCapsule.swift")
        #expect(capsule.contains(".onChange(of: state.pageFieldRequest) { _, _ in pageFieldFocused = true }"))
        let card = try ChromeGlassWiringTests.source("EditorPDFCard.swift")
        #expect(!card.contains("pageFieldRequest"), "the header still answers Go to Page…")
    }

    /// **After the header in the tab order, and every control named.** The canvas is under the
    /// header in the document column, the pages before the capsule and the capsule before the find
    /// card; each of the capsule's buttons and the field has a label VoiceOver reads.
    @Test func theCapsuleFollowsTheHeaderAndNamesItsControls() throws {
        let canvas = try ChromeGlassWiringTests.source("EditorPDFCanvas.swift")
        let pages = try #require(canvas.range(of: "EditorPDFPageView(document: document"))
        let capsule = try #require(canvas.range(of: "EditorPDFCapsule(state: state"))
        let card = try #require(canvas.range(of: "EditorPDFFindBar(find: find"))
        #expect(pages.lowerBound < capsule.lowerBound && capsule.lowerBound < card.lowerBound)
        let source = try ChromeGlassWiringTests.source("EditorPDFCapsule.swift")
        #expect(ChromeGlassWiringTests.count("return Button {", in: source) == 3,
                "the capsule's three kinds of button were not found — this check would be vacuous")
        for label in ["\"Next page\"", "\"Previous page\"", "\"Zoom in\"", "\"Zoom out\"",
                      ".accessibilityLabel(\"Zoom and page layout\")", ".accessibilityLabel(state.layout.isTwoUp ? \"Pages\" : \"Page\")"] {
            #expect(source.contains(label), "the capsule does not name \(label)")
        }
        #expect(source.contains(".accessibilityElement(children: .contain)"))
    }

    // MARK: Find

    /// **⌘F opens the card and the page does not move** — the reader's frame and the first page's
    /// place in the window, before and after, in the whole workspace as the column draws it.
    @Test func theFindCardLeavesThePageWhereItWas() async throws {
        let pdf = try await open(pages: 3)
        let workspace = EditorWorkspaceView.fixture(pdf: pdf).readingSettings(from: defaults)
        let window = host(workspace, size: CGSize(width: 900, height: 700))
        defer { window.contentView = nil }
        let root = try #require(window.contentView)
        let settled = await LayoutPumpWait.pump(window, upTo: 10) { (self.descendant(ReaderPDFView.self, in: root)?.bounds.width ?? 0) > 0 }
        try #require(settled.held, "no page view in the document card")
        _ = await LayoutPumpWait.pump(window, upTo: 1) { false }
        let view = try #require(descendant(ReaderPDFView.self, in: root))
        let page = try #require(pdf.document?.page(at: 0))
        let frameBefore = inWindow(view)
        let pageBefore = view.convert(view.convert(page.bounds(for: view.displayBox), from: page), to: nil)
        pdf.find.show()
        _ = await LayoutPumpWait.pump(window, upTo: 2) { false }
        #expect(pdf.find.isShown)
        let after = try #require(descendant(ReaderPDFView.self, in: root))
        #expect(after === view, "opening find rebuilt the page view")
        #expect(inWindow(view) == frameBefore, "opening find moved the pages: \(frameBefore) → \(inWindow(view))")
        let pageAfter = view.convert(view.convert(page.bounds(for: view.displayBox), from: page), to: nil)
        #expect(abs(pageAfter.minY - pageBefore.minY) < 0.5 && abs(pageAfter.minX - pageBefore.minX) < 0.5,
                "opening find moved the page: \(pageBefore) → \(pageAfter)")
    }
}

import Testing
import AppKit
import PDFKit
import PDFToolkitCore
import SwiftUI
import Design
@testable import FileExplorer
import FileExplorerTestSupport
import Sync

/// **Phase 6b: Fill & Sign as a palette** (mockup F) — the floating left palette with its flyouts,
/// moved as the capsule is, and the save pill and note card at the top of the canvas, in place of
/// the full-width toolbar and its line of words.
///
/// Serialized: the mounted tests lay out a `PDFView` on the main thread.
@MainActor
@Suite(.serialized) final class EditorPDFFillPaletteTests {

    let folder = NSTemporaryDirectory() + "editor-pdf-palette-" + UUID().uuidString
    private let defaults = ScratchDefaults("EditorPDFFillPaletteTests")

    init() throws {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(atPath: folder) }

    private static let letterBox = EditorPDFPageBox(cropBox: CGRect(x: 0, y: 0, width: 612, height: 792), rotation: 0)

    /// Fill & Sign on, on a flat letter page — or on a form with one text field.
    private func fill(form: Bool = false) -> EditorPDFFillSign {
        let fill = EditorPDFFillSign(store: EditorPDFSignatureStore(defaults: defaults))
        let field = FormField(name: "name", kind: .text(multiline: false), value: nil,
                              widgets: [FormField.Widget(pageIndex: 0, rect: CGRect(x: 10, y: 10, width: 100, height: 20))])
        fill.attach(path: folder + "/Lease.pdf", boxes: [Self.letterBox], encryption: .none, allowsFilling: true,
                    form: form ? EditorPDFForm(fields: [field]) : .none)
        fill.toggle()
        return fill
    }

    /// One typed item on the page, chosen.
    @discardableResult
    private func placeText(_ fill: EditorPDFFillSign, _ words: String = "Alex Morgan") throws -> UUID {
        fill.armed = .text
        let id = try #require(fill.place(at: CGPoint(x: 100, y: 600), page: 0))
        fill.type(words, into: id)
        fill.endEditing()
        fill.select(id)
        return id
    }

    private func open(pages: Int) async throws -> EditorPDFDocument {
        let file = (folder as NSString).appendingPathComponent("Lease \(UUID().uuidString).pdf")
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

    private func size<V: View>(_ view: V, scale: CGFloat = 1) -> CGSize {
        NSHostingView(rootView: view.environment(\.appFontScale, scale)).fittingSize
    }

    private func host<V: View>(_ view: V, size: CGSize) -> NSWindow {
        let host = NSHostingView(rootView: view.frame(maxWidth: .infinity, maxHeight: .infinity))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.layoutIfNeeded()
        return window
    }

    private func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants(type, in: $0) }
    }

    private func inWindow(_ view: NSView) -> CGRect { view.convert(view.bounds, to: nil) }

    private func palette(_ fill: EditorPDFFillSign, at place: EditorPDFCapsulePlace) -> EditorPDFFillPalette {
        EditorPDFFillPalette(fill: fill, state: EditorPDFViewState(defaults: defaults), place: place, accent: .blue)
    }

    // MARK: The tools

    /// **Select, Text, Date, Marks, Signature, Initials, then style (Aa, between Initials and Text
    /// Size — Signature Styles TE93), size and ink** (mockup F) — and Form Fields first, on a file
    /// with fields of its own and there only.
    @Test func theToolsAreInTheMockupsOrderWithFormFieldsFirstOnAForm() {
        let flat: [EditorPDFFillPalette.Tool] = [.select, .text, .date, .marks, .signature, .initials, .style, .size, .ink]
        #expect(EditorPDFFillPalette.tools(for: fill()) == flat)
        #expect(EditorPDFFillPalette.tools(for: fill(form: true)) == [.formFields] + flat)
        // The ones that open a flyout carry its corner triangle; the rest arm on a click.
        #expect(EditorPDFFillPalette.Tool.allCases.filter { $0.flyout != nil } == [.marks, .signature, .initials, .style, .size, .ink])
    }

    /// **The tool whose flyout is open is the one lit, and no other** — Text goes dark while Marks'
    /// flyout is open, and comes back when it closes. Otherwise the armed tool is lit, and Select when
    /// nothing is armed.
    @Test func aFlyoutsToolIsTheOneLitWhileItIsOpen() {
        typealias P = EditorPDFFillPalette
        let lit = { (armed: EditorPDFFillTool?, flyout: P.Flyout?) in P.Tool.allCases.filter { P.isLit($0, armed: armed, flyout: flyout) } }
        #expect(lit(.text, .marks) == [.marks])
        #expect(lit(.text, nil) == [.text])
        #expect(lit(nil, nil) == [.select])
        #expect(lit(nil, .ink) == [.ink])
        #expect(lit(.mark(.cross), nil) == [.marks])
        #expect(lit(.formFields, .size) == [.size])
        let initials = EditorPDFSignature(kind: .initials, look: .typed("AM"))
        #expect(lit(.signature(initials), nil) == [.initials])
        #expect(lit(.signature(initials), .signature) == [.signature])
    }

    // MARK: The flyouts

    /// **Marks' flyout arms the mark chosen, and ticks it** the next time it opens.
    @Test func theMarksFlyoutArmsAMarkAndTicksIt() throws {
        let fill = fill()
        var heard: [EditorPDFFillMark] = []
        let menu = EditorPDFFillFlyouts.marks(for: fill) { heard.append($0) }
        #expect(menu.items.map(\.title) == ["✓  Check mark", "✗  Cross", "•  Dot"])
        #expect(menu.items.allSatisfy { $0.state == .off })
        let cross = try #require(menu.items.dropFirst().first)
        _ = cross.target?.perform(cross.action)
        #expect(fill.armed == .mark(.cross) && heard == [.cross])
        #expect(EditorPDFFillFlyouts.marks(for: fill).items.filter { $0.state == .on }.map(\.title) == ["✗  Cross"])
    }

    /// **The size flyout sets the selected text's size, and the next item's** — one ⌘Z step — and
    /// ticks the size in force. Smaller and Bigger are A− and A+, greyed at the ends.
    @Test func theSizeFlyoutSetsTheSelectedTextAndTheNext() throws {
        let fill = fill()
        let id = try placeText(fill)
        let menu = EditorPDFFillFlyouts.size(for: fill)
        #expect(menu.items.prefix(2).map(\.title) == [EditorPDFFillFlyouts.smallerTitle, EditorPDFFillFlyouts.biggerTitle])
        #expect(menu.items.filter { $0.state == .on }.map(\.title) == ["12 pt"])
        let eighteen = try #require(menu.items.first { $0.title == "18 pt" })
        let before = try #require(fill.items.first { $0.id == id })
        _ = eighteen.target?.perform(eighteen.action)
        let after = try #require(fill.items.first { $0.id == id })
        #expect(after.fontSize == 18 && fill.fontSize == 18)
        #expect(after.rect.width > before.rect.width, "the item did not grow to its bigger words")
        #expect(EditorPDFFillFlyouts.size(for: fill).items.filter { $0.state == .on }.map(\.title) == ["18 pt"])
        fill.undoManager.undo()
        #expect(fill.items.first { $0.id == id }?.fontSize == 12, "choosing a size was not one undo step")
        // The ends: Smaller greyed at the smallest size, Bigger at the largest.
        fill.select(nil)
        fill.setFontSize(EditorPDFFillSign.fontSizes[0])
        #expect(EditorPDFFillFlyouts.size(for: fill).items.first?.isEnabled == false)
        fill.setFontSize(try #require(EditorPDFFillSign.fontSizes.last))
        #expect(EditorPDFFillFlyouts.size(for: fill).items.dropFirst().first?.isEnabled == false)
    }

    /// **The ink flyout sets the selected item's ink, and the next item's**, and ticks it.
    @Test func theInkFlyoutSetsTheInk() throws {
        let fill = fill()
        let id = try placeText(fill)
        let menu = EditorPDFFillFlyouts.ink(for: fill)
        #expect(menu.items.map(\.title) == EditorPDFFillColor.allCases.map(\.title))
        #expect(menu.items.allSatisfy { $0.image != nil }, "an ink has no swatch")
        let black = try #require(menu.items.first { $0.title == EditorPDFFillColor.black.title })
        _ = black.target?.perform(black.action)
        #expect(fill.color == .black && fill.items.first { $0.id == id }?.color == .black)
        #expect(EditorPDFFillFlyouts.ink(for: fill).items.filter { $0.state == .on }.map(\.title) == [EditorPDFFillColor.black.title])
    }

    // MARK: Moving it

    /// **The palette's place is its own**: the middle of the left side until it is moved, stored by
    /// name under its own key, read back by the next view state — and moving it never moves the
    /// capsule.
    @Test func thePalettesPlaceIsStoredByNameApartFromTheCapsules() {
        #expect(EditorPDFSettings.palettePlaceKey == "editorPDFPalettePlace")
        let first = EditorPDFViewState(defaults: defaults)
        #expect(first.palettePlace == .leading && first.capsulePlace == .bottom)
        first.palettePlace = .bottomLeading
        #expect(defaults.string(forKey: EditorPDFSettings.palettePlaceKey) == "bottomLeading")
        #expect(first.capsulePlace == .bottom, "moving the palette moved the capsule")
        let next = EditorPDFViewState(defaults: defaults)
        #expect(next.palettePlace == .bottomLeading && next.capsulePlace == .bottom)
        defaults.set("middleOfNowhere", forKey: EditorPDFSettings.palettePlaceKey)
        #expect(EditorPDFViewState(defaults: defaults).palettePlace == .leading)
    }

    private func mouse(_ type: NSEvent.EventType, clicks: Int = 1) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                        context: nil, eventNumber: 0, clickCount: clicks, pressure: 1))
    }

    /// **The palette's grip is the capsule's, moving the palette**: a double-click puts it back at
    /// the left, Move To and its accessibility actions move it and only it, and it says so.
    @Test func thePalettesGripMovesThePaletteAndOnlyThePalette() throws {
        let state = EditorPDFViewState(defaults: defaults)
        let grip = EditorPDFGripView()
        grip.state = state
        grip.piece = .palette
        state.palettePlace = .topTrailing
        grip.mouseDown(with: try mouse(.leftMouseDown, clicks: 2))
        #expect(state.palettePlace == .leading, "a double-click on the palette's grip did not put it back at the left")
        #expect(state.capsulePlace == .bottom)

        let menu = try #require(grip.menu(for: try mouse(.rightMouseDown)))
        let places = try #require(menu.items.first?.submenu)
        #expect(places.items.filter { $0.state == .on }.map(\.title) == ["Middle Left"])
        #expect(menu.items.last?.isEnabled == false, "Reset Position is live with the palette already at the left")
        let bottomRight = try #require(places.items.first { $0.title == "Bottom Right" })
        _ = bottomRight.target?.perform(bottomRight.action)
        #expect(state.palettePlace == .bottomTrailing && state.capsulePlace == .bottom)

        #expect(grip.accessibilityLabel() == "Move the Fill & Sign tools")
        #expect(grip.accessibilityValue() as? String == "Bottom Right")
        let actions = try #require(grip.accessibilityCustomActions())
        #expect(actions.map(\.name) == EditorPDFCapsulePlace.allCases.map { "Move to \($0.title)" } + ["Reset Position"])
        _ = actions.first { $0.name == "Move to Top Centre" }?.handler?()
        #expect(state.palettePlace == .top && state.capsulePlace == .bottom)
        _ = actions.last?.handler?()
        #expect(state.palettePlace == .leading)
        #expect(EditorPDFMovable.palette.tooltip.contains("Fill & Sign"))
    }

    /// **A column in the middle of a side, a row everywhere else** — the capsule's rule (decided
    /// 2026-10-19).
    @Test func thePaletteIsAColumnAtTheSidesAndARowElsewhere() {
        let fill = fill()
        for place in EditorPDFCapsulePlace.allCases {
            let drawn = size(palette(fill, at: place))
            if place.isVertical {
                #expect(drawn.height > 2 * drawn.width, "at \(place) the palette is \(drawn) — not a column")
            } else {
                #expect(drawn.width > 2 * drawn.height, "at \(place) the palette is \(drawn) — not a row")
            }
        }
    }

    /// **As a row, it fits the narrowest document column**, at every text size and with Form Fields
    /// — the bound 5b's toolbar kept (`EditorPDFHeaderWidthTests.column`).
    @Test func theRowFitsTheNarrowestColumnAtEveryTextSize() {
        let form = fill(form: true)
        let room = EditorPDFHeaderWidthTests.column - 2 * EditorPDFFloating.inset
        for percent in FontSize.selectablePercents {
            let row = size(palette(form, at: .bottomLeading), scale: FontSize(percent: percent).scale).width
            #expect(row <= room, "at \(percent)% the row is \(row)pt, over the \(room)pt the narrowest column has")
        }
    }

    // MARK: Floating pieces never overlap

    /// **In a narrow or short canvas a piece finds the gap beside one piece and under another**,
    /// rather than being drawn over one: one axis at a time found none, and the capsule at Top
    /// Left sat on the pill in the narrowest column while (58, 52) was free. Swept over every pair
    /// of places at the narrow and short sizes, with a form's taller palette — every case here has
    /// room (checked by simulating the rule); only a canvas too short for its pieces does not.
    @Test func aPieceFindsTheGapBesideOneAndUnderAnother() {
        let narrow = EditorPDFReader.layout(canvas: CGSize(width: 368, height: 400), findCard: .zero,
                                            saveStack: CGSize(width: 281, height: 30),
                                            palette: CGSize(width: 36, height: 308), palettePlace: .leading,
                                            capsule: CGSize(width: 253, height: 28), capsulePlace: .topLeading)
        #expect(!narrow.capsule.insetBy(dx: 0.5, dy: 0.5).intersects(narrow.saveStack), "\(narrow.capsule) over the pill")
        #expect(!narrow.capsule.insetBy(dx: 0.5, dy: 0.5).intersects(narrow.palette), "\(narrow.capsule) over the palette")
        let capsule = (row: CGSize(width: 253, height: 28), upright: CGSize(width: 44, height: 181))
        for canvas in [CGSize(width: 368, height: 420), CGSize(width: 368, height: 520),
                       CGSize(width: 700, height: 460), CGSize(width: 1000, height: 400)] {
            for find in [CGSize.zero, CGSize(width: 250, height: 28)] {
                for pill in [CGSize.zero, CGSize(width: 281, height: 30)] {
                    for palettePlace in EditorPDFCapsulePlace.allCases {
                        for capsulePlace in EditorPDFCapsulePlace.allCases {
                            let frames = EditorPDFReader.layout(
                                canvas: canvas, findCard: find, saveStack: pill,
                                palette: palettePlace.isVertical ? CGSize(width: 36, height: 308) : CGSize(width: 308, height: 36),
                                palettePlace: palettePlace,
                                capsule: capsulePlace.isVertical ? capsule.upright : capsule.row, capsulePlace: capsulePlace)
                            let shown = [frames.findCard, frames.saveStack, frames.palette, frames.capsule].filter { !$0.isEmpty }
                            for (i, a) in shown.enumerated() {
                                for b in shown.dropFirst(i + 1) {
                                    #expect(!a.insetBy(dx: 0.5, dy: 0.5).intersects(b),
                                            "\(canvas) palette \(palettePlace), capsule \(capsulePlace), find \(find != .zero), pill \(pill != .zero): \(a) overlaps \(b)")
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// **No two floating pieces overlap, wherever the capsule and the palette are put** — with and
    /// without the find card and the save pill, on a roomy canvas and a short one. The order they
    /// give way in: the pill slides clear of the find card, the palette of both, the capsule of all.
    @Test func noTwoFloatingPiecesOverlapAtAnyPlaces() {
        let capsule = CGSize(width: 300, height: 30), palette = (row: CGSize(width: 330, height: 38), column: CGSize(width: 38, height: 330))
        for canvas in [CGSize(width: 1000, height: 760), CGSize(width: 900, height: 520)] {
            for find in [CGSize.zero, CGSize(width: 330, height: 32)] {
                for pill in [CGSize.zero, CGSize(width: 300, height: 30)] {
                    for palettePlace in EditorPDFCapsulePlace.allCases {
                        for capsulePlace in EditorPDFCapsulePlace.allCases {
                            let frames = EditorPDFReader.layout(
                                canvas: canvas, findCard: find, saveStack: pill,
                                palette: palettePlace.isVertical ? palette.column : palette.row, palettePlace: palettePlace,
                                capsule: capsulePlace.isVertical ? CGSize(width: capsule.height, height: capsule.width) : capsule,
                                capsulePlace: capsulePlace)
                            let shown = [frames.findCard, frames.saveStack, frames.palette, frames.capsule].filter { !$0.isEmpty }
                            for (i, a) in shown.enumerated() {
                                for b in shown.dropFirst(i + 1) {
                                    #expect(!a.insetBy(dx: 0.5, dy: 0.5).intersects(b),
                                            "\(canvas) palette \(palettePlace), capsule \(capsulePlace), find \(find != .zero), pill \(pill != .zero): \(a) overlaps \(b)")
                                }
                            }
                        }
                    }
                }
            }
        }
        // The capsule is the one that gives way: at the left with the palette, the palette stays.
        let canvas = CGSize(width: 1000, height: 760)
        let shared = EditorPDFReader.layout(canvas: canvas, findCard: .zero, saveStack: .zero,
                                            palette: palette.column, palettePlace: .leading,
                                            capsule: CGSize(width: 30, height: 300), capsulePlace: .leading)
        #expect(shared.palette == shared.paletteDocked && shared.capsule != shared.capsuleDocked)
        // And the pill slides along the top, not down, when there is room beside the card.
        let top = EditorPDFReader.layout(canvas: canvas, findCard: CGSize(width: 330, height: 32), saveStack: CGSize(width: 400, height: 30),
                                         palette: .zero, palettePlace: .leading, capsule: capsule, capsulePlace: .bottom)
        #expect(top.saveStack.minY == top.saveStackDocked.minY && top.saveStack.maxX <= top.findCard.minX - EditorPDFFloating.gap + 0.01)
    }

    // MARK: The save pill and the note card

    /// **The pill fits the narrowest column at every text size** — its words give way, the count
    /// kept in its tooltip. With fixed words a form's "2 fields changed · 12 items not saved" ran past
    /// the canvas, where nothing could keep it clear of the find card.
    @Test func thePillFitsTheNarrowestColumnAtEveryTextSize() throws {
        let fill = fill(form: true)
        fill.beginFieldEditing("name")
        fill.typeField("Ada Quill")
        fill.endFieldEditing()
        for n in 0..<12 { try placeText(fill, "Item \(n)") }
        #expect(fill.unsavedCaption == "1 field changed · 12 items not saved", "the premise: \(fill.unsavedCaption ?? "none")")
        #expect(fill.unsavedShortCaption == "1 field · 12 items")
        let room = EditorPDFHeaderWidthTests.column - 2 * EditorPDFFloating.inset
        for percent in FontSize.selectablePercents {
            let stack = EditorPDFFillSaveStack(fill: fill, tools: EditorPDFTools(), accent: .blue)
                .environment(\.appFontScale, FontSize(percent: percent).scale)
            func width(_ proposed: CGFloat) -> CGFloat {
                NSHostingController(rootView: stack).sizeThatFits(in: CGSize(width: proposed, height: 1000)).width
            }
            #expect(width(room) <= room, "at \(percent)% the pill is \(width(room))pt, over the \(room)pt the narrowest column has")
            // With less room than the short words take, it drops them rather than squeezing its
            // buttons — a squeezed pill is as wide as it is let be, one with no words keeps its own
            // width. The column holds the short words at every size, so it keeps them there.
            let bare = width(205)
            #expect(bare <= 205 && width(220) == bare,
                    "at \(percent)% with 220pt and 205pt the pill is \(width(220))pt and \(bare)pt — it squeezed its buttons to keep words")
            #expect(width(room) > bare, "at \(percent)% the pill dropped words the column had room for")
        }
    }

    /// **The pill appears with the first mark, holds the count, and goes when nothing is left to
    /// save** — after Discard, and with Fill & Sign off.
    @Test func thePillHoldsTheCountAndGoesWhenNothingIsLeftToSave() throws {
        let fill = fill()
        let tools = EditorPDFTools()
        func stack() -> CGSize { size(EditorPDFFillSaveStack(fill: fill, tools: tools, accent: .blue)) }
        #expect(stack() == .zero, "the pill is up with nothing placed")
        try placeText(fill)
        let one = stack()
        #expect(one.width > 150 && one.height > 15, "no pill with an item placed: \(one)")
        #expect(fill.unsavedCaption == "1 item not saved")
        try placeText(fill, "Unit 4")
        #expect(stack().width > one.width, "the pill does not hold the count — \"2 items\" is no wider than \"1 item\"")
        fill.discard()
        #expect(stack() == .zero, "the pill stayed after Discard")
        fill.undoManager.undo()
        #expect(stack() != .zero, "Discard's undo did not bring the pill back")
    }

    /// **The note card stands under the pill, and alone when there is nothing to save** — a form's
    /// caveat is said from the moment Fill & Sign opens (decided 2026-10-19).
    @Test func theNoteCardShowsWithOrWithoutThePill() async throws {
        let file = folder + "/1040.pdf"
        try PDFFixtures.writeXFAForm(file)
        let pdf = EditorPDFDocument(isCloudOnly: { _ in false }, defaults: defaults)
        var phases: [EditorPDFDocument.Phase] = []
        pdf.onLoaded = { phases.append($0) }
        pdf.open(path: file, log: { _ in })
        for _ in 0..<1000 where phases.isEmpty {
            await PDFKitSerialAccess.perform {}
            try? await Task.sleep(for: .milliseconds(5))
        }
        try #require(phases.first == .open)
        func stack() -> CGSize { size(EditorPDFFillSaveStack(fill: pdf.fill, tools: pdf.tools, accent: .blue)) }
        #expect(stack() == .zero, "the card is up with Fill & Sign off")
        pdf.fill.toggle()
        try #require(pdf.fill.formNotes == [EditorPDFFillSign.xfaNote] && !pdf.fill.hasUnsavedChanges)
        let alone = stack()
        #expect(alone.height > 15, "no note card on an XFA form with nothing placed")
        pdf.fill.armed = .mark(.check)
        try #require(pdf.fill.place(at: CGPoint(x: 300, y: 300), page: 0) != nil)
        #expect(stack().height > alone.height + 20, "the pill did not stand over the card")
    }

    // MARK: Mounted

    /// **Turning Fill & Sign on leaves the page where it was** (mockup F, second pass) — the reader's
    /// frame and the first page's place in the window, before and after, in the whole workspace.
    @Test func turningFillAndSignOnLeavesThePageWhereItWas() async throws {
        let pdf = try await open(pages: 3)
        let workspace = EditorWorkspaceView.fixture(pdf: pdf).readingSettings(from: defaults)
        let window = host(workspace, size: CGSize(width: 900, height: 700))
        defer { window.contentView = nil }
        let root = try #require(window.contentView)
        let settled = await LayoutPumpWait.pump(window, upTo: 10) { (self.descendants(ReaderPDFView.self, in: root).first?.bounds.width ?? 0) > 0 }
        try #require(settled.held, "no page view in the document card")
        _ = await LayoutPumpWait.pump(window, upTo: 1) { false }
        let view = try #require(descendants(ReaderPDFView.self, in: root).first)
        let page = try #require(pdf.document?.page(at: 0))
        let frameBefore = inWindow(view)
        let pageBefore = view.convert(view.convert(page.bounds(for: view.displayBox), from: page), to: nil)
        pdf.fill.toggle()
        let up = await LayoutPumpWait.pump(window, upTo: 10) {
            self.descendants(EditorPDFGripView.self, in: root).contains { $0.piece == .palette }
        }
        try #require(pdf.fill.isOn && up.held, "the palette did not come up")
        #expect(descendants(ReaderPDFView.self, in: root).first === view, "turning Fill & Sign on rebuilt the page view")
        #expect(inWindow(view) == frameBefore, "turning Fill & Sign on moved the pages: \(frameBefore) → \(inWindow(view))")
        let pageAfter = view.convert(view.convert(page.bounds(for: view.displayBox), from: page), to: nil)
        #expect(abs(pageAfter.minY - pageBefore.minY) < 0.5 && abs(pageAfter.minX - pageBefore.minX) < 0.5,
                "turning Fill & Sign on moved the page: \(pageBefore) → \(pageAfter)")
    }

    /// **The palette floats over the canvas, and a click beside it reaches the pages** — placing
    /// must work right up to its edge. Its grip is its own, and moves the palette.
    @Test func thePaletteFloatsOverThePagesAndClicksBesideItReachThem() async throws {
        let pdf = try await open(pages: 3)
        pdf.fill.toggle()
        let reader = EditorPDFReader(document: pdf.document, state: pdf.view, find: pdf.find, fill: pdf.fill,
                                     tools: pdf.tools, pageCount: 3, accent: .blue)
        let window = host(reader, size: CGSize(width: 700, height: 600))
        defer { window.contentView = nil }
        let root = try #require(window.contentView)
        let settled = await LayoutPumpWait.pump(window, upTo: 10) {
            self.descendants(EditorPDFGripView.self, in: root).count == 2 && !self.descendants(ReaderPDFView.self, in: root).isEmpty
        }
        try #require(settled.held, "no palette grip beside the capsule's")
        _ = await LayoutPumpWait.pump(window, upTo: 1) { false }
        let pages = try #require(descendants(ReaderPDFView.self, in: root).first)
        let grip = try #require(descendants(EditorPDFGripView.self, in: root).first { $0.piece == .palette })
        #expect(!grip.isDescendant(of: pages), "the palette is inside the PDFView")
        let canvas = inWindow(pages), gripFrame = inWindow(grip)
        #expect(canvas.contains(gripFrame), "the palette is not over the pages")
        // At the middle of the left side: the grip tops a column, 14pt in from the left.
        #expect(abs(gripFrame.minX - canvas.minX - EditorPDFFloating.inset) < 12, "the palette is not at the left: \(gripFrame)")
        func hit(_ point: NSPoint) -> NSView? { root.hitTest(root.superview?.convert(point, from: nil) ?? point) }
        for point in [NSPoint(x: gripFrame.maxX + 60, y: gripFrame.midY), NSPoint(x: canvas.midX, y: canvas.maxY - 20)] {
            let landed = hit(point)
            #expect(landed.map { $0 === pages || $0.isDescendant(of: pages) } == true,
                    "a click at \(point) landed on \(landed.map { String(describing: type(of: $0)) } ?? "nothing"), not the pages")
        }
        #expect(hit(NSPoint(x: gripFrame.midX, y: gripFrame.midY)) === grip, "the palette's grip does not get its own clicks")
    }

    // MARK: What went

    /// **The toolbar, its line of words and row 2's count are gone** (decided 2026-10-19): nothing
    /// mounts a Fill & Sign row under the header, and nothing draws the click hint and "14 fields ·
    /// 2 changed" — the tooltips say what a tool does.
    @Test func theToolbarAndItsWordsAreGone() throws {
        let workspace = try ChromeGlassWiringTests.source("EditorWorkspaceView.swift")
        #expect(!workspace.contains("EditorPDFFill"), "the workspace mounts a Fill & Sign row again")
        for file in ["EditorPDFFillPalette.swift", "EditorPDFFillSign.swift", "EditorPDFCanvas.swift", "EditorPDFCard.swift"] {
            let source = try ChromeGlassWiringTests.source(file)
            #expect(!source.contains("statusSegments"), "\(file) draws Fill & Sign's line of words")
            #expect(!source.contains("struct EditorPDFFillSignBar"), "\(file) has the toolbar")
        }
        let canvas = try ChromeGlassWiringTests.source("EditorPDFCanvas.swift")
        #expect(canvas.contains("EditorPDFFillPalette(fill: fill"), "the canvas does not float the palette")
        #expect(canvas.contains("EditorPDFFillSaveStack(fill: fill"), "the canvas does not float the save pill")
    }

    /// **Every tool named for VoiceOver, the palette a group of its own**, after the pages and before
    /// the capsule in the tab order.
    @Test func thePaletteNamesItsToolsAndFollowsThePages() throws {
        let titles = EditorPDFFillPalette.Tool.allCases.map(\.title)
        #expect(Set(titles).count == titles.count && titles.allSatisfy { !$0.isEmpty })
        let source = try ChromeGlassWiringTests.source("EditorPDFFillPalette.swift")
        for line in [".accessibilityLabel(tool.title)", ".accessibilityLabel(\"Fill & Sign tools\")",
                     ".accessibilityAddTraits(lit ? .isSelected : [])", ".accessibilityElement(children: .contain)"] {
            #expect(source.contains(line), "the palette does not say \(line)")
        }
        let canvas = try ChromeGlassWiringTests.source("EditorPDFCanvas.swift")
        let pages = try #require(canvas.range(of: "EditorPDFPageView(document: document"))
        let palette = try #require(canvas.range(of: "EditorPDFFillPalette(fill: fill"))
        let capsule = try #require(canvas.range(of: "EditorPDFCapsule(state: state"))
        #expect(pages.lowerBound < palette.lowerBound && palette.lowerBound < capsule.lowerBound)
    }

    /// **At a right-hand corner a flyout opens leftwards**, away from the edge the palette is docked
    /// to — it used to start at the tool's left edge and run off the canvas. Elsewhere on the top
    /// and bottom it starts at the tool's left, and at the side middles it opens beside the tool.
    @Test func flyoutsOpenAwayFromTheDockedEdge() {
        let tool = CGRect(x: 0, y: 0, width: 28, height: 28), menu = CGSize(width: 120, height: 200)
        for place in EditorPDFCapsulePlace.allCases {
            let origin = EditorPDFCapsule.menuOrigin(menu: menu, in: tool, flipped: true, place: place)
            switch place {
            case .topTrailing, .bottomTrailing:
                #expect(origin.x + menu.width == tool.maxX, "at \(place) the flyout runs toward the docked edge")
            case .leading:
                #expect(origin.x > tool.maxX)
            case .trailing:
                #expect(origin.x + menu.width < tool.minX)
            default:
                #expect(origin.x == tool.minX, "at \(place) the flyout moved")
            }
        }
    }

    /// **A palette that goes while its grip is held takes the drag with it** — a save landing
    /// mid-drag. The snap targets stayed drawn, and a late drop stored the place nearest the corner
    /// of an empty frame. Wired in the canvas, which owns the drag.
    @Test func aPaletteThatGoesMidDragTakesTheDragWithIt() throws {
        let canvas = try ChromeGlassWiringTests.source("EditorPDFCanvas.swift")
        #expect(canvas.contains("if size == .zero, dragging == .palette { dragging = nil; drag = .zero }"))
        #expect(canvas.contains("guard dragging == piece else { return }"), "a drop is taken for a drag no longer held")
    }
}

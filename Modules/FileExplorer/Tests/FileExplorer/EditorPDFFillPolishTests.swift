import Testing
import AppKit
import PDFKit
import PDFToolkitCore
import SwiftUI
import Design
import Sync
@testable import FileExplorer

/// **Fill & Sign's polish (the 2026-10-20 Edit audit, TE98–TE141)** — a way out, a question before
/// a saved signature goes, a form's signature field that signs, tools that grey out where they
/// change nothing, the leave question's Save that leaves, one accent, the first signature straight
/// to the sheet, and the right-click menu, resize cursor and words that went with them.
///
/// Serialized: the saves run in `PDFKitSerialAccess`'s one lane, and the overlay tests lay out a
/// `PDFView` on the main thread.
@MainActor
@Suite(.serialized) final class EditorPDFFillPolishTests {

    let folder = NSTemporaryDirectory() + "editor-pdf-polish-" + UUID().uuidString
    private let defaults = ScratchDefaults("EditorPDFFillPolishTests")

    init() throws {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(atPath: folder) }

    private static let letterBox = EditorPDFPageBox(cropBox: CGRect(x: 0, y: 0, width: 612, height: 792), rotation: 0)

    private static let nameField = FormField(name: "name", kind: .text(multiline: false), value: nil,
                                             widgets: [FormField.Widget(pageIndex: 0, rect: CGRect(x: 10, y: 10, width: 100, height: 20))])
    private static let signatureField = FormField(name: "sig", kind: .signature, value: nil,
                                                  widgets: [FormField.Widget(pageIndex: 0, rect: CGRect(x: 100, y: 100, width: 200, height: 30))])

    /// Fill & Sign on, on one letter page — with these fields, and the owner's commenting permission.
    private func fill(fields: [FormField] = [], allowsFormEntry: Bool = true, allowsCommenting: Bool = true) -> EditorPDFFillSign {
        let fill = EditorPDFFillSign(store: EditorPDFSignatureStore(defaults: defaults))
        fill.attach(path: folder + "/Lease.pdf", boxes: [Self.letterBox], encryption: .none, allowsFilling: true,
                    form: fields.isEmpty ? .none : EditorPDFForm(fields: fields), allowsFormEntry: allowsFormEntry,
                    allowsCommenting: allowsCommenting)
        fill.toggle()
        return fill
    }

    private func path(_ name: String) -> String { (folder as NSString).appendingPathComponent(name) }

    private func open(pages: Int = 1) async throws -> EditorPDFDocument {
        let file = path("Lease \(UUID().uuidString.prefix(8)).pdf")
        PDFFixtures.write(file, pages: pages)
        let pdf = EditorPDFDocument(isCloudOnly: { _ in false }, defaults: defaults)
        pdf.tools.isCloudOnly = { _ in false }
        pdf.open(path: file, log: { _ in })
        for _ in 0..<1000 where pdf.phase == .loading { await PDFKitSerialAccess.perform {} }
        try #require(pdf.phase == .open)
        return pdf
    }

    private func fire(_ item: NSMenuItem?) throws {
        let item = try #require(item)
        _ = item.target?.perform(item.action)
    }

    private func source(_ name: String) throws -> String {
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()      // Tests/FileExplorer
            .deletingLastPathComponent().deletingLastPathComponent()               // FileExplorer
        return try String(contentsOf: here.appendingPathComponent("Sources/FileExplorer/\(name)"), encoding: .utf8)
    }

    private static let typed = EditorPDFSignature(kind: .signature, look: .typed("Alex Morgan"))

    // MARK: TE98 — a way out

    /// **Esc lets go of the tool, then puts Fill & Sign away** — after the reader's own Esc (an open
    /// find card), and through the toggle, so unsaved work is asked about first.
    @Test func escapeLetsGoThenPutsFillAndSignAway() throws {
        let fill = fill()
        var asked = 0
        fill.askLeaving = { _, _ in asked += 1; return .cancel }
        #expect(fill.armed == .text)
        #expect(fill.escape() && fill.isOn && fill.armed == nil, "the first Esc did not just let the tool go")
        var findCard = 0
        #expect(fill.escape(first: { findCard += 1; return true }))
        #expect(fill.isOn && findCard == 1, "the find card did not close before the palette")
        #expect(fill.escape(first: { false }))
        #expect(!fill.isOn, "the last Esc left Fill & Sign up")
        #expect(!fill.escape(), "Esc claimed the key with Fill & Sign already away")

        fill.toggle()
        fill.armed = .mark(.check)
        fill.place(at: CGPoint(x: 100, y: 100), page: 0)
        fill.select(nil)
        fill.armed = nil
        #expect(fill.escape())
        #expect(asked == 1 && fill.isOn && fill.items.count == 1, "Esc put unsaved work away without asking")
    }

    /// **The save pill ends with Done, through the header's toggle** — and Save Filled Copy wears the
    /// window's hue (TE101). The pill's buttons are SwiftUI, so the call is read.
    @Test func thePillEndsWithDoneAndItsSaveWearsTheHue() throws {
        let palette = try source("EditorPDFFillPalette.swift")
        // Its title is "Save Corrected Copy" when only corrections are placed (TE84).
        let save = try #require(palette.range(of: #"Button(fill.saveTitle) { Task { await fill.save() } }"#))
        let done = try #require(palette.range(of: "Button(Self.doneTitle) { fill.toggle() }"), "the pill has no Done")
        #expect(save.upperBound < done.lowerBound, "Done is not after Save Filled Copy")
        let between = palette[save.upperBound..<done.lowerBound]
        #expect(between.contains(".accentedProminent()"), "Save Filled Copy does not wear the window's hue")
        #expect(between.contains("Rectangle()"), "no separator before Done")
        #expect(EditorPDFFillSaveStack.doneTitle == "Done")
    }

    /// **Esc on the pages, through the overlay**: the find card first, then the palette.
    @Test func escapeOnThePagesClosesFindFirstThenThePalette() async throws {
        let pdf = try await open()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 700), styleMask: [.titled],
                              backing: .buffered, defer: false)
        let reader = ReaderPDFView(frame: NSRect(x: 0, y: 0, width: 500, height: 700))
        window.contentView = reader
        reader.document = pdf.document
        reader.layoutSubtreeIfNeeded()
        reader.fillSign = pdf.fill
        var findShown = true
        reader.onEscape = {
            guard findShown else { return false }
            findShown = false
            return true
        }
        pdf.fill.toggle()
        pdf.fill.armed = nil
        let esc = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                                                charactersIgnoringModifiers: "\u{1b}", isARepeat: false,
                                                keyCode: ReaderPDFView.escapeKeyCode))
        reader.fillOverlay.keyDown(with: esc)
        #expect(!findShown && pdf.fill.isOn, "Esc put the palette away before closing Find")
        reader.fillOverlay.keyDown(with: esc)
        #expect(!pdf.fill.isOn, "the second Esc left the palette up")
        reader.fillSign = nil
        reader.document = nil
    }

    // MARK: TE100 — deleting a saved one asks

    /// **Choosing one under Delete asks first** (decision BE's question); Cancel keeps it, Delete
    /// removes it from this Mac and leaves what is already placed. The menus say "Delete a Saved
    /// Signature" and "Delete Saved Initials" (TE100).
    @Test func deletingASavedSignatureAsksFirst() throws {
        let fill = fill()
        let initials = EditorPDFSignature(kind: .initials, look: .typed("AM"))
        fill.store.add(Self.typed)
        fill.store.add(initials)
        fill.armed = .signature(initials)
        let placed = try #require(fill.place(at: CGPoint(x: 300, y: 300), page: 0))
        var asked: [EditorPDFSignature.Kind] = []
        var answer = false
        fill.confirmDeletingSaved = { signature, _ in asked.append(signature.kind); return answer }

        let menu = EditorPDFSignatureMenu.menu(for: fill, kind: .initials)
        let delete = try #require(menu.items.last)
        #expect(delete.title == "Delete Saved Initials")
        #expect(EditorPDFSignatureMenu.menu(for: fill, kind: .signature).items.last?.title == "Delete a Saved Signature")
        try fire(delete.submenu?.items.first)
        #expect(asked == [.initials] && fill.store.saved(.initials) == [initials], "Cancel deleted the initials")
        answer = true
        try fire(delete.submenu?.items.first)
        #expect(fill.store.saved(.initials).isEmpty, "Delete kept the initials")
        #expect(fill.store.saved(.signature) == [Self.typed], "deleting the initials touched the signature")
        #expect(fill.items.contains { $0.id == placed }, "the initials on the page went with the saved ones")

    }

    /// **With six saved, the Add sheet says the next one replaces the oldest** — five say nothing.
    @Test func theAddSheetSaysWhenTheOldestWillGo() throws {
        let store = EditorPDFSignatureStore(defaults: defaults)
        for n in 0..<5 { store.add(EditorPDFSignature(kind: .signature, look: .typed("Signer \(n)"))) }
        #expect(EditorPDFAddSignatureSheet.fullCaption(.signature, store: store) == nil)
        store.add(EditorPDFSignature(kind: .signature, look: .typed("Signer 5")))
        #expect(EditorPDFAddSignatureSheet.fullCaption(.signature, store: store)
                == "You have 6 saved signatures, the most Edit keeps. Adding this one replaces the oldest.")
        #expect(EditorPDFAddSignatureSheet.fullCaption(.initials, store: store) == nil, "a full kind spoke for the other")
        for n in 0..<6 { store.add(EditorPDFSignature(kind: .initials, look: .typed("A\(n)"))) }
        #expect(EditorPDFAddSignatureSheet.fullCaption(.initials, store: store)?.hasSuffix("Adding these replaces the oldest.") == true)
        let sheet = try source("EditorPDFSignatureSheet.swift")
        #expect(sheet.contains("if keep, let full = Self.fullCaption(kind, store: fill.store) {"), "the sheet never shows it")
    }

    // MARK: TE107 — a signature field signs

    /// **A signature chosen for a field fills its box**: typed or drawn, as big as fits keeping its
    /// shape, at the box's left and centred on its height — not the Signature tool's fixed 150 pt.
    @Test func aSignatureChosenForAFieldFitsTheFieldsBox() throws {
        let fill = fill(fields: [Self.nameField, Self.signatureField])
        let field = Self.signatureField
        #expect(fill.signs(field))
        #expect(fill.fieldRefusal(field) == nil && fill.fieldHint(field) == "Signature field — click to sign it")
        let target = try #require(fill.signingTarget(for: field.widgets[0]))
        #expect(target == EditorPDFFillSign.SigningTarget(page: 0, rect: CGRect(x: 100, y: 100, width: 200, height: 30)))

        let typedID = try #require(fill.place(Self.typed, in: target))
        let typed = try #require(fill.items.first { $0.id == typedID })
        #expect(abs(typed.rect.minX - 100) < 0.01 && abs(typed.rect.midY - 115) < 0.51, "placed at \(typed.rect)")
        #expect(typed.rect.width <= 200 && typed.rect.height <= 30, "\(typed.rect) spills out of the field")
        let bigger = try #require(typed.wordsSize(fontSize: typed.fontSize + 0.5))
        #expect(bigger.width > 200 || bigger.height > 30, "\(typed.fontSize) pt is not the largest that fits")
        #expect(fill.undoManager.undoActionName == "Place Signature" && fill.selection == typed.id)

        let tall = EditorPDFSignature(kind: .signature, look: .drawn(strokes: [[.zero, CGPoint(x: 1, y: 1)]], aspect: 3))
        let drawnID = try #require(fill.place(tall, in: target))
        let drawn = try #require(fill.items.first { $0.id == drawnID })
        #expect(drawn.rect == CGRect(x: 100, y: 100, width: 90, height: 30), "a drawn one fitted at \(drawn.rect)")
        let wide = EditorPDFSignature(kind: .signature, look: .drawn(strokes: [[.zero, CGPoint(x: 1, y: 1)]], aspect: 10))
        let longID = try #require(fill.place(wide, in: target))
        let long = try #require(fill.items.first { $0.id == longID })
        #expect(long.rect == CGRect(x: 100, y: 105, width: 200, height: 20), "a wide one fitted at \(long.rect)")
        #expect(fill.armed == .formFields, "signing a field armed another tool")
    }

    /// **Tab stops on a signature field in the form's own order** (decision BK, TE164) — on a form
    /// whose owner doesn't allow filling its fields too, as long as a signature can be placed.
    @Test func tabStopsOnSignatureFieldsWhereASignatureCanGo() throws {
        let later = FormField(name: "date", kind: .text(multiline: false), value: nil,
                              widgets: [FormField.Widget(pageIndex: 0, rect: CGRect(x: 10, y: 200, width: 100, height: 20))])
        let open = fill(fields: [Self.nameField, Self.signatureField, later])
        #expect(open.tabStops == [.field("name"), .field("sig"), .field("date")])
        let noEntry = fill(fields: [Self.nameField, Self.signatureField], allowsFormEntry: false)
        #expect(noEntry.isOn && noEntry.tabStops == [.field("sig")])
        #expect(noEntry.fieldRefusal(Self.signatureField) == nil && noEntry.signs(Self.signatureField))
        let noPlacing = fill(fields: [Self.nameField, Self.signatureField], allowsCommenting: false)
        #expect(noPlacing.tabStops == [.field("name")])
    }

    /// **A form whose owner forbids adding to its pages keeps its refusal**: the field doesn't sign,
    /// and says why.
    @Test func aFieldOnAFormThatForbidsCommentingDoesNotSign() throws {
        let fill = fill(fields: [Self.nameField, Self.signatureField], allowsCommenting: false)
        #expect(fill.isOn && !fill.offersPlacing)
        // Replace is off for the form, and says so in the form's words: no placing implies a form.
        #expect(fill.replaceRefusal == EditorPDFFillSign.formReplaceReason)
        #expect(fill.replaceMenuReason == EditorPDFFillSign.formReplaceMenuReason)
        #expect(!fill.signs(Self.signatureField))
        #expect(fill.fieldRefusal(Self.signatureField) == EditorPDFForm.signFieldRefusal)
        let target = try #require(fill.signingTarget(for: Self.signatureField.widgets[0]))
        #expect(fill.place(Self.typed, in: target) == nil && fill.items.isEmpty)
    }

    /// **The field's menu signs it**: "Sign this field", the saved ones — choosing one places it in
    /// the field — and Add Signature…, whose signature goes there too. No Delete there. A sheet put
    /// away without Add signs nothing.
    @Test func theFieldsMenuAndItsAddSheetSignTheField() throws {
        let fill = fill(fields: [Self.nameField, Self.signatureField])
        fill.store.add(Self.typed)
        let target = try #require(fill.signingTarget(for: Self.signatureField.widgets[0]))
        let menu = EditorPDFSignatureMenu.menu(for: fill, kind: .signature, signing: target)
        #expect(menu.items.map(\.title) == [EditorPDFSignatureMenu.signFieldTitle, "Alex Morgan", "", "Add Signature…"])
        try fire(menu.items[1])
        let placed = try #require(fill.items.last)
        #expect(placed.signature == Self.typed && placed.rect.minX == 100, "the saved one went to \(placed.rect)")
        #expect(fill.armed == .formFields, "choosing for a field armed the Signature tool")

        try fire(menu.items.last)
        #expect(fill.addingSignature == .signature && fill.signing == target)
        let added = EditorPDFSignature(kind: .signature, look: .typed("Sam Reed"))
        fill.add(added, keep: false, makeInitials: false, ink: .black)
        let second = try #require(fill.items.last)
        #expect(second.signature == added && second.rect.minX == 100 && second.color == .black, "Add did not sign the field")
        #expect(fill.signing == nil && fill.armed == .formFields)

        fill.startAdding(.signature, signing: target)
        fill.addingSignature = nil
        #expect(fill.signing == nil, "a cancelled sheet left the field waiting to be signed")
        fill.add(added, keep: false, makeInitials: false, ink: .blue)
        #expect(fill.armed == .signature(added) && fill.items.count == 2, "a later Add signed the field the sheet was cancelled for")
    }

    /// **Over a real page view, a click on a form's signature field signs it**: with one saved, the
    /// Signature menu at the field, whose line places it in the field's box; with none, the Add sheet,
    /// for that field. Pointing at it says so, and it is tinted as a field a click acts on.
    @Test func clickingASignatureFieldOnTheOverlaySignsIt() async throws {
        let file = path("W-9 \(UUID().uuidString.prefix(8)).pdf")
        try PDFFixtures.writeForm(file)
        let pdf = EditorPDFDocument(isCloudOnly: { _ in false }, defaults: defaults)
        pdf.tools.isCloudOnly = { _ in false }
        pdf.open(path: file, log: { _ in })
        for _ in 0..<1000 where pdf.phase == .loading { await PDFKitSerialAccess.perform {} }
        try #require(pdf.phase == .open)
        let document = try #require(pdf.document)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 900), styleMask: [.titled],
                              backing: .buffered, defer: false)
        let reader = ReaderPDFView(frame: NSRect(x: 0, y: 0, width: 700, height: 900))
        window.contentView = reader
        reader.autoScales = false
        reader.fit = nil
        reader.document = document
        reader.scaleFactor = 1
        reader.layoutDocumentView()
        reader.layoutSubtreeIfNeeded()
        reader.fillSign = pdf.fill
        let overlay = reader.fillOverlay
        let fill = pdf.fill
        fill.toggle()
        let field = try #require(fill.form.field(named: "signature"))
        let widget = try #require(field.widgets.first)
        reader.go(to: widget.rect, on: try #require(document.page(at: widget.pageIndex)))
        reader.layoutSubtreeIfNeeded()
        let rect = try #require(overlay.widgetRect(widget))
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: overlay.convert(center, to: nil),
                                                    modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        #expect(overlay.toolTip(at: center) == "Signature field — click to sign it")
        #expect(overlay.hitTest(overlay.convert(center, to: reader)) === overlay)

        overlay.mouseDown(with: click)
        #expect(fill.addingSignature == .signature, "with none saved, the click did not open Add Signature")
        let target = try #require(fill.signingTarget(for: widget))
        #expect(fill.signing == target)
        fill.addingSignature = nil

        fill.store.add(Self.typed)
        var menus: [NSMenu] = []
        overlay.presentMenu = { menu, _, _ in menus.append(menu) }
        overlay.mouseDown(with: click)
        let menu = try #require(menus.last, "the click opened no menu")
        #expect(menu.items.first?.title == EditorPDFSignatureMenu.signFieldTitle)
        try fire(menu.items.dropFirst().first)
        let placed = try #require(fill.items.last)
        #expect(placed.signature == Self.typed)
        #expect(target.rect.insetBy(dx: -0.5, dy: -0.5).contains(placed.rect), "\(placed.rect) is not inside the field's \(target.rect)")
        #expect(abs(placed.rect.midY - target.rect.midY) < 0.51)
        reader.fillSign = nil
        reader.document = nil
    }

    // MARK: TE108 — tools that can change nothing grey out

    /// **Style, Text Size and Ink grey out with a form field focused, Text Size for a drawn
    /// signature, and all three where the owner forbids adding to the pages** — each saying why.
    @Test func styleSizeAndInkGreyOutWhereTheyChangeNothing() throws {
        typealias P = EditorPDFFillPalette
        let styling: [P.Tool] = [.style, .size, .ink]
        let fill = fill(fields: [Self.nameField])
        #expect(styling.allSatisfy { P.refusal($0, fill: fill) == nil })
        fill.focusField("name")
        for tool in styling {
            #expect(P.refusal(tool, fill: fill) == "\(tool.title) — a form field keeps the form’s own text style")
        }
        #expect(P.refusal(.text, fill: fill) == nil && P.refusal(.formFields, fill: fill) == nil)
        // An item clicked while a field has the keyboard: the tools are the item's again.
        fill.armed = .date
        let date = try #require(fill.place(at: CGPoint(x: 400, y: 400), page: 0))
        fill.focusField("name")
        fill.select(date)
        #expect(styling.allSatisfy { P.refusal($0, fill: fill) == nil }, "a selected item's tools stayed greyed")
        fill.focusField(nil)

        fill.armed = .signature(EditorPDFSignature(kind: .signature, look: .drawn(strokes: [[.zero, CGPoint(x: 1, y: 1)]], aspect: 3)))
        fill.place(at: CGPoint(x: 300, y: 300), page: 0)
        #expect(P.refusal(.size, fill: fill) == "Text Size — a drawn signature has no text size")
        #expect(P.refusal(.style, fill: fill) == nil && P.refusal(.ink, fill: fill) == nil)
        fill.armed = .signature(Self.typed)
        fill.place(at: CGPoint(x: 300, y: 500), page: 0)
        #expect(P.refusal(.size, fill: fill) == nil, "a typed signature has a size")

        let closed = self.fill(fields: [Self.nameField], allowsCommenting: false)
        for tool in styling { #expect(P.refusal(tool, fill: closed) == EditorPDFFillSign.noCommentingReason) }
        #expect(P.refusal(.formFields, fill: closed) == nil)

        let palette = try source("EditorPDFFillPalette.swift")
        #expect(palette.contains(".disabled(Self.refusal(tool, fill: fill) != nil)"))
        #expect(palette.contains(".help(Self.refusal(tool, fill: fill) ?? Self.hint(tool))"))
    }

    // MARK: TE115 — the leave question's Save leaves

    /// **Save Filled Copy in the leave question writes the copy, then runs the leave again** — which
    /// goes, with nothing left to ask about (decision AX).
    @Test func saveFilledCopyInTheLeaveQuestionSavesThenLeaves() async throws {
        let pdf = try await open()
        let fill = pdf.fill
        fill.toggle()
        fill.armed = .mark(.check)
        fill.place(at: CGPoint(x: 100, y: 100), page: 0)
        fill.askLeaving = { _, _ in .save }
        var retried = 0
        let left = pdf.tools.mayLeave(thenRetry: { retried += 1 })
        #expect(!left, "the leave went before the copy was written")
        for _ in 0..<1000 where retried == 0 {
            await PDFKitSerialAccess.perform {}
            await Task.yield()
        }
        #expect(retried == 1, "the leave was not run again once the copy landed")
        #expect(!fill.hasUnsavedItems && pdf.tools.mayLeave(), "the retried leave would ask again")
        let copy = try #require(pdf.path).replacingOccurrences(of: ".pdf", with: " (filled).pdf")
        #expect(FileManager.default.fileExists(atPath: copy))
    }

    /// **A save that doesn't land stays** — cancelled, or with something placed while it ran — and
    /// the leave is not run again.
    @Test(arguments: [false, true])
    func aSaveThatDoesNotLandStaysOnThePDF(placesMore: Bool) async throws {
        let pdf = try await open()
        let fill = pdf.fill
        fill.toggle()
        fill.armed = .mark(.check)
        fill.place(at: CGPoint(x: 100, y: 100), page: 0)
        fill.askLeaving = { _, _ in .save }
        pdf.tools.writeStartedHook = { [weak pdf] in
            guard let pdf else { return }
            if placesMore { pdf.fill.place(at: CGPoint(x: 200, y: 200), page: 0) } else { pdf.tools.cancelRun() }
        }
        var retried = 0
        let left = pdf.tools.mayLeave(thenRetry: { retried += 1 })
        #expect(!left)
        for _ in 0..<1000 where pdf.tools.running == nil { await Task.yield() }
        for _ in 0..<1000 where pdf.tools.running != nil {
            await PDFKitSerialAccess.perform {}
            await Task.yield()
        }
        for _ in 0..<50 { await Task.yield() }
        #expect(pdf.tools.running == nil, "the save never finished — this checks nothing")
        #expect(retried == 0, "a save that didn't carry everything left the PDF")
        #expect(fill.hasUnsavedItems && fill.isOn)
        if placesMore {
            // The copy landed without the second mark: its banner says so (TE191).
            let banner = try #require(pdf.tools.banner)
            #expect(banner.kind == .wrote(try #require(pdf.path).replacingOccurrences(of: ".pdf", with: " (filled).pdf")))
            #expect(banner.message.hasSuffix(". " + EditorPDFFillSign.changedWhileSavingNote), "\(banner.message)")
        }
    }

    // MARK: TE141 — the first signature goes straight to the sheet

    /// **Signature or Initials with none saved opens the Add sheet, not a menu of one Add** — with one
    /// saved, the menu.
    @Test func theFirstSignatureGoesStraightToTheSheet() throws {
        typealias P = EditorPDFFillPalette
        let fill = fill()
        var opened: [P.Flyout] = []
        P.press(.signature, fill: fill) { flyout, _ in opened.append(flyout) }
        #expect(fill.addingSignature == .signature && opened.isEmpty, "a menu opened with nothing saved")
        fill.addingSignature = nil
        fill.store.add(Self.typed)
        P.press(.signature, fill: fill) { flyout, _ in opened.append(flyout) }
        #expect(opened == [.signature] && fill.addingSignature == nil)
        P.press(.initials, fill: fill) { flyout, _ in opened.append(flyout) }
        #expect(fill.addingSignature == .initials && opened == [.signature], "Initials opened a menu with none saved")
    }

    // MARK: TE101, TE136 — the overlay's colour and cursor

    /// **The selection ring is drawn in the window's hue, handed in** — not the Mac's accent — and
    /// the corner handle shows a resize pointer, not the placing tools' crosshair.
    @Test func theSelectionWearsTheHueAndTheHandleShowsAResizePointer() async throws {
        let pdf = try await open()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 700), styleMask: [.titled],
                              backing: .buffered, defer: false)
        let reader = ReaderPDFView(frame: NSRect(x: 0, y: 0, width: 500, height: 700))
        window.contentView = reader
        reader.autoScales = false
        reader.fit = nil
        reader.document = pdf.document
        reader.scaleFactor = 0.5
        reader.layoutDocumentView()
        reader.layoutSubtreeIfNeeded()
        reader.fillSign = pdf.fill
        let overlay = reader.fillOverlay
        pdf.fill.toggle()
        pdf.fill.armed = .mark(.check)
        pdf.fill.place(at: CGPoint(x: 306, y: 396), page: 0)
        let item = try #require(pdf.fill.selected)
        let ring = try #require(overlay.viewRect(item)).insetBy(dx: -2, dy: -2)

        func ringPixels(_ accent: NSColor) throws -> Int {
            overlay.accent = accent
            let rep = try #require(overlay.bitmapImageRepForCachingDisplay(in: overlay.bounds))
            overlay.cacheDisplay(in: overlay.bounds, to: rep)
            let scale = CGFloat(rep.pixelsWide) / overlay.bounds.width
            var hits = 0
            for x in Int((ring.minX - 2) * scale)...Int((ring.maxX + 2) * scale) {
                for yView in [ring.minY, ring.maxY] {
                    let y = overlay.isFlipped ? yView : overlay.bounds.height - yView
                    for dy in -2...2 {
                        guard let c = rep.colorAt(x: x, y: Int(y * scale) + dy)?.usingColorSpace(.sRGB), c.alphaComponent > 0.5 else { continue }
                        if c.redComponent > 0.8, c.greenComponent < 0.3, c.blueComponent < 0.3 { hits += 1 }
                    }
                }
            }
            return hits
        }
        #expect(try ringPixels(NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)) > 10, "the ring is not drawn in the hue handed in")
        #expect(try ringPixels(NSColor(srgbRed: 0, green: 0.6, blue: 0.3, alpha: 1)) == 0, "the ring is red whatever the hue")

        #expect(EditorPDFFillOverlay.resizeCursor !== NSCursor.crosshair)
        let handle = try #require(overlay.handle(of: item))
        let moved = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: overlay.convert(handle, to: nil), modifierFlags: [],
                                                    timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                    eventNumber: 0, clickCount: 0, pressure: 0))
        NSCursor.arrow.set()
        overlay.mouseMoved(with: moved)
        #expect(NSCursor.current === EditorPDFFillOverlay.resizeCursor, "the handle shows \(NSCursor.current)")
        reader.fillSign = nil
        reader.document = nil
    }

    /// **The canvas hands the overlay the window's hue**, and the Add sheet's Add and the text
    /// editor's style picker wear it too.
    @Test func theHueReachesTheOverlayTheSheetAndTheStylePicker() throws {
        #expect(try source("EditorPDFCanvas.swift").contains("coveredRects: frames.covered, accent: accent)"))
        #expect(try source("EditorPDFPageView.swift").contains("view.fillOverlay.accent = NSColor(accent)"))
        let overlay = try source("EditorPDFFillOverlay.swift")
        #expect(!overlay.contains("controlAccentColor.") && !overlay.contains("= NSColor.controlAccentColor"),
                "the overlay still draws in the Mac's own accent")
        let sheet = try source("EditorPDFSignatureSheet.swift")
        let add = try #require(sheet.range(of: #"Button("Add") { add() }"#))
        #expect(sheet[add.upperBound...].prefix(300).contains(".accentedProminent(hue)"), "Add is the Mac's blue")
        let bar = try source("EditorFormatBar.swift")
        #expect(bar.contains("EditorStylePicker(current: state.heading, accent: accent)"))
        #expect(bar.contains("fill(hovering ? AccentFill.deepened(accent) : .clear)"))
        #expect(!bar.contains("fill(hovering ? Color.accentColor"))
    }

    // MARK: TE126 — words

    /// **Title case in the menus, and "ink" only where nothing else says Ink.**
    @Test func theMenusAreInTitleCase() {
        #expect(EditorPDFFillMark.check.title == "Check Mark")
        #expect(EditorPDFFillColor.allCases.map(\.title) == ["Blue", "Black"])
        #expect(EditorPDFFillColor.allCases.map(\.inkTitle) == ["Blue ink", "Black ink"])
        #expect(EditorPDFFillFlyouts.originalInkTitle == "Original Ink", "PD13: among Blue and Black")
    }

    /// **Every menu item the app writes is in Title Case** — the menu bar, every context menu and
    /// pop-up menu, in `MacApp/` and every package (TE126, widened by BR9: the pane row said
    /// “Fix name” and “Ignore in comparison” where the menu bar said “Fix Name” and “Ignore in
    /// Comparison”). Mutation: put back “Paste here” in FileTreeView, or “Manage sources…” in
    /// ProviderMenu, and this names the line.
    @Test func everyMenuItemInTheAppIsInTitleCase() throws {
        let found = try AppCopyScan.menuTitleViolations(exemptions: AppCopyScan.menuExemptions)
        #expect(found.isEmpty, "\(found.map { "\($0.path):\($0.line): \($0.text)" }.joined(separator: "\n"))")
        // The exemption still has something to exempt — a scope the scan lost would pass vacuously.
        let all = try AppCopyScan.menuTitleViolations(exemptions: [])
        #expect(all.contains { $0.fileName == "EditorPDFFillSignMenuItems.swift" },
                "the scan no longer reaches the Fill & Sign menu, so its exemption proves nothing")
        #expect(all.contains { $0.fileName == "EditorPDFFillPalette.swift" },
                "the scan no longer reads the palette's …MenuItem(title:) sizes, so its exemption proves nothing")
        #expect(AppCopyScan.isTitleCase("Find Duplicates of This") && AppCopyScan.isTitleCase("Copy \\(count) Items to…"))
        #expect(!AppCopyScan.isTitleCase("Find duplicates of this") && !AppCopyScan.isTitleCase("Paste here"))
    }

    /// The menu scan's reach: a context menu, a menu-content type, a ternary's two branches and
    /// `NSMenuItem` — and not a comment, a labelled argument or a string handed to a function.
    @Test func theMenuScanReadsMenusAndOnlyMenus() {
        let code = """
            struct RowView: View {
                var body: some View {
                    Text("A sentence here is fine")
                        .contextMenu {
                            Button("Paste here") {}
                            // Button("Not this one")
                            Button(action: {}) { Label(on ? "Include in comparison" : "Ignore In Comparison", systemImage: "eye") }
                            Button(Self.title("by 180°")) {}
                        }
                }
            }
            struct ThingMenu: View {
                var body: some View { Label("Fix name", systemImage: "x") }
            }
            let item = NSMenuItem(title: "Show all files", action: nil, keyEquivalent: "")
            let field = EditorClosureMenuItem(title: "Type a value…") {}
            struct ToolsMenu: View {
                var body: some View {
                    Button { go() } label: { Text("Open the file") }
                    Picker("Size", selection: $size) { Text("Extra large").tag(1) }
                    Text("A caption is not an item")
                }
            }
            struct CommandPalettePanel: View {
                var body: some View { Button("Search for files") {} }
            }
            """
        let found = AppCopyScan.menuTitleViolations(in: code, path: "X.swift").map(\.text)
        #expect(found == [#""Paste here""#, #""Include in comparison""#, #""Fix name""#,
                          #""Open the file""#, #""Extra large""#,
                          #""Show all files""#, #""Type a value…""#],
                "\(found)")
    }
}

import Testing
import AppKit
import PDFKit
import PDFToolkitCore
import SwiftUI
import Sync
import EventsTestSupport
@testable import FileExplorer

extension PDFFixtures {
    /// The corpus form with a `/TU` — the description a form gives a field for screen readers —
    /// on `applicant.name` and `subscribe`, added by an appended update that rewrites the two fields.
    static func writeDescribedForm(_ path: String) throws {
        let plain = path + ".plain.pdf"
        try writeForm(plain)
        var data = try Data(contentsOf: URL(fileURLWithPath: plain))
        try? FileManager.default.removeItem(atPath: plain)
        let text = String(decoding: data, as: UTF8.self)
        func object(_ number: Int, adding entry: String) throws -> String {
            let start = try #require(text.range(of: "\n\(number) 0 obj\n")).upperBound
            let line = text[start...].prefix { $0 != "\n" }
            try #require(line.hasPrefix("<<"))
            return "<< " + entry + " " + line.dropFirst(2)
        }
        let name = try object(21, adding: "/TU (Your full name)")
        let subscribe = try object(29, adding: "/TU (Send me the newsletter)")
        let startxref = try #require(text.range(of: "startxref", options: .backwards))
        let previous = text[startxref.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).prefix { $0.isNumber }
        let nameAt = data.count
        data.append(Data("21 0 obj\n\(name)\nendobj\n".utf8))
        let subscribeAt = data.count
        data.append(Data("29 0 obj\n\(subscribe)\nendobj\n".utf8))
        let xrefAt = data.count
        data.append(Data(("xref\n0 1\n0000000000 65535 f \n21 1\n" + String(format: "%010d", nameAt) + " 00000 n \n29 1\n"
                          + String(format: "%010d", subscribeAt) + " 00000 n \n"
                          + "trailer\n<< /Size 83 /Root 1 0 R /Info 10 0 R /Prev \(previous) >>\nstartxref\n\(xrefAt)\n%%EOF\n").utf8))
        try data.write(to: URL(fileURLWithPath: path))
    }
}

/// **Fill & Sign by keyboard alone and with VoiceOver** (decisions AZ–BE, 2026-10-20): Return
/// places the chosen tool's item, Tab walks the form's fields then what is placed, VoiceOver reads
/// and presses every field and item, saved drawn signatures are told apart, deleting one asks, and
/// Add Signature opens on Type. Keys go in through `NSWindow.sendEvent`, as a real key does, to a
/// window buried under everything on screen.
///
/// Serialized, because the opens take `PDFKitSerialAccess`'s one lane.
@MainActor
@Suite(.serialized) final class EditorPDFFillKeyboardTests {

    let folder = NSTemporaryDirectory() + "editor-pdf-fill-keys-" + UUID().uuidString
    private let defaults = ScratchDefaults("EditorPDFFillKeyboardTests")

    init() throws {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(atPath: folder) }

    private func path(_ name: String) -> String { (folder as NSString).appendingPathComponent(name) }

    private func open(_ file: String) async throws -> EditorPDFDocument {
        let pdf = EditorPDFDocument(isCloudOnly: { _ in false }, defaults: defaults)
        pdf.tools.isCloudOnly = { _ in false }
        pdf.open(path: file, log: { _ in })
        for _ in 0..<1000 where pdf.phase == .loading { await PDFKitSerialAccess.perform {} }
        try #require(pdf.phase == .open)
        return pdf
    }

    private func letter(pages: Int = 1) async throws -> EditorPDFDocument {
        let file = path("Lease.pdf")
        PDFFixtures.write(file, pages: pages)
        return try await open(file)
    }

    private func form() async throws -> EditorPDFDocument {
        let file = path("W-9.pdf")
        try PDFFixtures.writeForm(file)
        return try await open(file)
    }

    /// The reader in a buried window, the pages holding the keyboard, Fill & Sign on — the overlay
    /// has taken the keyboard, as it does in the app.
    private struct Stage {
        let window: NSWindow
        let reader: ReaderPDFView
        var overlay: EditorPDFFillOverlay { reader.fillOverlay }
    }

    private func stage(_ pdf: EditorPDFDocument, scale: CGFloat = 1) async throws -> Stage {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 700), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let reader = ReaderPDFView(frame: NSRect(x: 0, y: 0, width: 600, height: 700))
        window.contentView = reader
        window.buryUnderEverything()
        window.makeKeyAndOrderFront(nil)
        #expect(BuriedWindow.isBuried(window))
        reader.autoScales = false
        reader.fit = nil
        reader.document = pdf.document
        reader.scaleFactor = scale
        reader.layoutDocumentView()
        reader.layoutSubtreeIfNeeded()
        reader.fillSign = pdf.fill
        // A real "Save the filled copy?" alert would wait forever: a test that turns it off with
        // work on the page discards it.
        pdf.fill.askLeaving = { _, _ in .discard }
        window.makeFirstResponder(reader)
        for _ in 0..<20 { await Task.yield() }
        pdf.fill.toggle()
        try #require(pdf.fill.isOn)
        for _ in 0..<50 where window.firstResponder !== reader.fillOverlay { await Task.yield() }
        try #require(window.firstResponder === reader.fillOverlay, "the overlay never took the keyboard")
        return Stage(window: window, reader: reader)
    }

    private func close(_ stage: Stage) {
        stage.reader.fillSign = nil
        stage.reader.document = nil
        stage.window.orderOut(nil)
    }

    /// A key, sent to the window as AppKit sends one.
    private func press(_ code: UInt16, _ characters: String, shift: Bool = false, in window: NSWindow) {
        window.sendEvent(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: shift ? .shift : [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!)
    }

    private func returnKey(_ window: NSWindow) { press(36, "\r", in: window) }
    private func tab(_ window: NSWindow, back: Bool = false) { press(48, back ? "\u{19}" : "\t", shift: back, in: window) }

    /// Lets the overlay's refresh — a turn after each change — run.
    private func settle() async { for _ in 0..<20 { await Task.yield() } }

    // MARK: Placing (decision BA)

    /// **Return places the chosen tool's item in the middle of what can be seen of the page** —
    /// selected, so the arrows move it — and a second Return puts the next one just below, not on
    /// top. A signature is placed once; Text takes the typing straight away.
    @Test func returnPlacesTheChosenItemInTheMiddleOfWhatCanBeSeen() async throws {
        let pdf = try await letter()
        let fill = pdf.fill
        fill.formatDate = { _ in "20/10/2026" }
        // At 100% a Letter page is taller than the window, so what can be seen is the page's top —
        // and its middle is not the page's.
        let stage = try await stage(pdf)
        defer { close(stage) }
        let page = try #require(pdf.document?.page(at: 0))
        let seen = stage.reader.convert(page.bounds(for: .cropBox), from: page).intersection(stage.reader.bounds)
        let middle = stage.reader.convert(CGPoint(x: seen.midX, y: seen.midY), to: page)
        try #require(abs(middle.y - 396) > 20, "the whole page is on screen — the middle of it can't be told from the page's")

        fill.armed = .date
        returnKey(stage.window)
        let date = try #require(fill.items.first, "Return with Date chosen placed nothing")
        #expect(abs(date.rect.midX - middle.x) < 1 && abs(date.rect.midY - middle.y) < 1,
                "placed at \(date.rect), not about \(middle)")
        #expect(fill.selection == date.id)
        press(124, String(UnicodeScalar(NSRightArrowFunctionKey)!), in: stage.window)
        #expect(fill.items.first?.rect.minX == date.rect.minX + 1, "the arrows don't move what Return placed")

        returnKey(stage.window)
        try #require(fill.items.count == 2, "a second Return typed into the date instead of placing another")
        let second = fill.items[1]
        #expect(!second.rect.intersects(fill.items[0].rect), "the second date covers the first")
        #expect(second.rect.maxY < fill.items[0].rect.minY && fill.items[0].rect.minY - second.rect.maxY < 10,
                "the second date is not just below the first: \(second.rect) under \(fill.items[0].rect)")

        fill.armed = .mark(.check)
        returnKey(stage.window)
        #expect(fill.items.last?.isMark == true)

        let signature = EditorPDFSignature(kind: .signature, look: .typed("Ada Quill"))
        fill.armed = .signature(signature)
        returnKey(stage.window)
        #expect(fill.items.last?.signature == signature)
        #expect(fill.armed == nil, "a signature stayed chosen after Return placed it")
        let count = fill.items.count
        returnKey(stage.window)
        #expect(fill.items.count == count, "Return with nothing chosen placed something")

        fill.armed = .text
        returnKey(stage.window)
        let box = try #require(fill.items.last)
        #expect(fill.editing == box.id, "a text box placed by Return isn't taking the typing")
        await settle()
        let field = try #require(stage.overlay.field)
        #expect(stage.window.firstResponder === field.currentEditor(), "the typing field doesn't have the keyboard")
        field.currentEditor()?.insertText("Lease ends 1 May")
        #expect(fill.items.last?.words?.string == "Lease ends 1 May")
    }

    /// **Return on a text box reached by Tab types into it**, as a double-click does — only the
    /// one just placed by Return is followed by another instead.
    @Test func returnOnATextBoxReachedByTabTypesIntoIt() async throws {
        let pdf = try await letter()
        let fill = pdf.fill
        let stage = try await stage(pdf, scale: 0.5)
        defer { close(stage) }
        fill.armed = .date
        returnKey(stage.window)
        let date = try #require(fill.items.first)
        press(53, "\u{1b}", in: stage.window)
        #expect(fill.selection == nil)
        tab(stage.window)
        #expect(fill.selection == date.id, "Tab didn't reach the date")
        returnKey(stage.window)
        #expect(fill.editing == date.id, "Return on a date Tab is on didn't start typing into it")
        #expect(fill.items.count == 1)
    }

    // MARK: Tab's ring (decision BB)

    /// **Tab walks the form's fields, then what is placed, round again** — and Tab while typing in
    /// a text box goes on round the ring, the keyboard still in the pages. Unanswered, it ended the
    /// typing and nothing on the page had the keyboard. An item off screen is scrolled into sight.
    @Test func tabWalksTheFormThenThePlacedItems() async throws {
        let pdf = try await form()
        let fill = pdf.fill
        let stage = try await stage(pdf, scale: 1)
        defer { close(stage) }
        let order = fill.form.fillable.map(\.name)
        try #require(order.count > 3)
        // A mark on the second page, out of sight, and a text box on the first.
        stage.reader.go(to: try #require(pdf.document?.page(at: 0)))
        stage.reader.layoutSubtreeIfNeeded()
        fill.armed = .mark(.check)
        let mark = try #require(fill.place(at: CGPoint(x: 300, y: 400), page: 1))
        fill.armed = .text
        let words = try #require(fill.place(at: CGPoint(x: 100, y: 100), page: 0))
        fill.type("Hello", into: words)
        fill.endEditing()
        fill.escape()
        fill.escape()
        await settle()

        #expect(fill.tabStops == order.map(EditorPDFFillSign.TabStop.field) + [.item(mark), .item(words)])
        tab(stage.window, back: true)
        #expect(fill.selection == words, "⇧Tab from nothing didn't go to the last thing placed")
        tab(stage.window, back: true)
        #expect(fill.selection == mark)
        let second = try #require(pdf.document?.page(at: 1))
        let box = try #require(fill.box(1))
        #expect(EditorPDFPageView.isInSight(box.pageRect(display: try #require(fill.selected).rect), on: second,
                                            in: stage.reader), "Tab onto an item off screen left it out of sight")
        tab(stage.window)
        #expect(fill.selection == words)
        tab(stage.window)
        #expect(fill.tabStop == .field(order[0]) && fill.selection == nil, "Tab from the last item didn't go round")

        // Typing in a text box, Tab goes on — to the first field — and the keyboard stays in the pages.
        fill.beginEditing(words)
        await settle()
        let field = try #require(stage.overlay.field)
        try #require(stage.window.firstResponder === field.currentEditor())
        tab(stage.window)
        #expect(fill.editing == nil)
        #expect(fill.tabStop == .field(order[0]), "Tab in a text box didn't go on round the ring: \(String(describing: fill.tabStop))")
        await settle()
        let responder = stage.window.firstResponder as? NSView
        #expect(responder?.isDescendant(of: stage.reader) == true, "the keyboard left the pages: \(String(describing: responder))")

        // Selecting an item lets go of a field being typed into: one thing has the keyboard.
        fill.beginFieldEditing("notes")
        try #require(fill.editingField == "notes")
        fill.select(mark)
        #expect(fill.editingField == nil && fill.focusedField == nil, "a field kept typing with an item selected")

        // A PDF with no form: Tab walks what is placed.
        let flat = try await letter()
        let flatStage = try await self.stage(flat, scale: 0.5)
        defer { close(flatStage) }
        #expect(flat.fill.tabStops.isEmpty)
        flat.fill.armed = .mark(.dot)
        let dot = try #require(flat.fill.place(at: CGPoint(x: 200, y: 200), page: 0))
        flat.fill.escape()
        tab(flatStage.window)
        #expect(flat.fill.selection == dot)
    }

    // MARK: VoiceOver

    /// **VoiceOver reads and presses every field and item on screen** — through the reader, which
    /// lists the overlay among its children once the overlay is an element; each widget as its kind, named, with its value and
    /// whether it takes one; each item by what it is; and where Tab is.
    @Test func voiceOverReadsAndPressesEveryFieldAndItem() async throws {
        let pdf = try await form()
        let fill = pdf.fill
        let stage = try await stage(pdf, scale: 1)
        defer { close(stage) }
        let overlay = stage.overlay
        stage.reader.go(to: try #require(pdf.document?.page(at: 0)))
        stage.reader.layoutSubtreeIfNeeded()
        fill.armed = .mark(.check)
        let mark = try #require(fill.place(at: CGPoint(x: 500, y: 700), page: 0))
        fill.escape()
        fill.escape()
        await settle()

        let children = stage.reader.accessibilityChildren() ?? []
        #expect(children.contains { ($0 as AnyObject) === overlay }, "VoiceOver can't reach Fill & Sign from the pages")
        #expect(overlay.isAccessibilityElement() && overlay.accessibilityRole() == .group)
        let elements = (overlay.accessibilityChildren() ?? []).compactMap { $0 as? EditorPDFFillAccessibilityElement }
        let byLabel = Dictionary(elements.map { ($0.accessibilityLabel() ?? "", $0) }, uniquingKeysWith: { first, _ in first })
        let name = try #require(byLabel["name"], "no element “name” in \(byLabel.keys.sorted())")
        #expect(name.accessibilityRole() == .textField)
        #expect(name.accessibilityValue() as? String == "Ada Quill")
        let subscribe = try #require(byLabel["subscribe"])
        #expect(subscribe.accessibilityRole() == .checkBox)
        #expect(subscribe.accessibilityValue() as? NSNumber == NSNumber(value: 0))
        let plan = elements.filter { ($0.accessibilityLabel() ?? "").hasPrefix("plan, ") }
        #expect(plan.count == 3 && plan.allSatisfy { $0.accessibilityRole() == .radioButton })
        #expect(byLabel["country"]?.accessibilityRole() == .popUpButton)
        let signature = try #require(byLabel["signature"])
        let refusal = fill.fieldRefusal(try #require(fill.form.field(named: "signature")))
        #expect(!signature.isAccessibilityEnabled())
        #expect(signature.accessibilityHelp() == refusal, "a field that takes nothing doesn't say why")
        let placed = try #require(byLabel["Check Mark"])
        #expect(placed.accessibilityRole() == .button)
        #expect(placed.accessibilityRoleDescription() == "placed item")
        // Where it is on screen: the widget's own rect, from the overlay.
        let widget = try #require(fill.form.field(named: "subscribe")?.widgets.first)
        #expect(subscribe.accessibilityFrameInParentSpace() == overlay.widgetRect(widget))

        // Pressed, a checkbox ticks; the element reads the new value.
        #expect(subscribe.accessibilityPerformPress())
        #expect(fill.values["subscribe"] == .checked(true))
        let ticked = (overlay.accessibilityChildren() ?? []).contains { ($0 as AnyObject) === subscribe }
        #expect(ticked && subscribe.accessibilityValue() as? NSNumber == NSNumber(value: 1))
        // Pressed, an item is selected with the keyboard on the pages, for the arrows; its Delete removes it.
        stage.window.makeFirstResponder(nil)
        #expect(placed.accessibilityPerformPress())
        #expect(fill.selection == mark)
        #expect(stage.window.firstResponder === overlay)
        await settle()
        let focused = overlay.accessibilityFocusedUIElement as AnyObject?
        #expect(focused === placed, "VoiceOver's focus isn't where Tab is")
        let delete = try #require(placed.accessibilityCustomActions()?.first { $0.name == "Delete" })
        let deleted = delete.handler?() ?? false
        #expect(deleted)
        #expect(fill.items.isEmpty)

        // Typing into a field, VoiceOver is in the typing field, named for the field.
        #expect(name.accessibilityPerformPress())
        await settle()
        let editor = try #require(overlay.formEditor)
        #expect(editor.accessibilityLabel() == "name")
        #expect((overlay.accessibilityChildren() ?? []).contains { ($0 as AnyObject) === editor })
        let typing = overlay.accessibilityFocusedUIElement as AnyObject?
        #expect(typing === editor)

        fill.toggle()
        await settle()
        #expect(!(stage.reader.accessibilityChildren() ?? []).contains { ($0 as AnyObject) === overlay },
                "VoiceOver still lists Fill & Sign with it off")
    }

    /// **A field is named by the description its form gives it**, else by the last part of its name.
    @Test func fieldsAreNamedByTheirFormsDescriptions() async throws {
        let file = path("Described.pdf")
        try PDFFixtures.writeDescribedForm(file)
        let pdf = try await open(file)
        let form = pdf.fill.form
        #expect(form.descriptions == ["applicant.name": "Your full name", "subscribe": "Send me the newsletter"])
        #expect(form.label(of: try #require(form.field(named: "applicant.name"))) == "Your full name")
        #expect(form.label(of: try #require(form.field(named: "notes"))) == "notes")
        let designed = FormField(name: "topmostSubform[0].Page1[0].f1_1[0]", kind: .text(multiline: false), value: nil, widgets: [])
        #expect(EditorPDFForm(fields: [designed]).label(of: designed) == "f1_1")
    }

    // MARK: Saved signatures (decisions BD, BE)

    /// **Saved drawn signatures are told apart** — by their number among the drawn ones of their
    /// kind, newest first, and their pen — in the palette's flyout, its Delete submenu and on the page.
    @Test func drawnSignaturesAreToldApartByNumberAndPen() throws {
        let store = EditorPDFSignatureStore(defaults: ScratchDefaults("EditorPDFFillKeyboardTests.names"))
        let fill = EditorPDFFillSign(store: store)
        let older = try #require(EditorPDFSignature.drawn([[CGPoint(x: 0, y: 0), CGPoint(x: 40, y: 10)]], kind: .signature, pen: .bold))
        let typed = EditorPDFSignature(kind: .signature, look: .typed("Ada Quill"))
        let newer = try #require(EditorPDFSignature.drawn([[CGPoint(x: 0, y: 5), CGPoint(x: 30, y: 0)]], kind: .signature))
        let initials = try #require(EditorPDFSignature.drawn([[CGPoint(x: 0, y: 0), CGPoint(x: 9, y: 9)]], kind: .initials, pen: .fine))
        for signature in [older, typed, newer, initials] { store.add(signature) }

        let menu = EditorPDFSignatureMenu.menu(for: fill, kind: .signature)
        let labels = menu.items.dropFirst().prefix(3).map { $0.accessibilityLabel() ?? $0.title }
        #expect(labels == ["Drawn signature 1, medium pen", "Ada Quill", "Drawn signature 2, bold pen"])
        let deletes = try #require(menu.items.last?.submenu).items.map { $0.accessibilityLabel() ?? $0.title }
        #expect(deletes == labels)
        #expect(initials.spokenName(among: store.saved) == "Drawn initials 1, fine pen")
        let onPage = EditorPDFFillItem(page: 0, rect: .zero, content: .signature(older), fontSize: 12, color: .blue, font: .sans)
        #expect(onPage.spokenName(among: store.saved) == "Drawn signature 2, bold pen")
    }

    /// **Delete a Saved Signature asks first, and Return keeps it** — Cancel is the alert's default.
    @Test func deletingASavedSignatureAsksFirst() throws {
        let store = EditorPDFSignatureStore(defaults: ScratchDefaults("EditorPDFFillKeyboardTests.delete"))
        let fill = EditorPDFFillSign(store: store)
        let signature = EditorPDFSignature(kind: .signature, look: .typed("Ada Quill"))
        store.add(signature)
        var asked: [String] = []
        var answer = false
        fill.confirmDeletingSaved = { _, name in asked.append(name); return answer }
        func chooseDelete() throws {
            let submenu = try #require(EditorPDFSignatureMenu.menu(for: fill, kind: .signature).items.last?.submenu)
            let line = try #require(submenu.items.first)
            _ = (line.target as AnyObject).perform(line.action, with: line)
        }
        try chooseDelete()
        #expect(asked == ["Ada Quill"], "deleting didn't ask")
        #expect(store.saved == [signature], "a No still deleted it")
        answer = true
        try chooseDelete()
        #expect(store.saved.isEmpty)

        let alert = EditorPDFFillSign.deleteSavedAlert(signature, name: "Ada Quill")
        #expect(alert.buttons.map(\.title) == ["Cancel", "Delete"])
        #expect(alert.buttons[0].keyEquivalent == "\r", "Return deletes")
        #expect(alert.buttons[1].hasDestructiveAction)
    }

    // MARK: Add Signature (decision BC)

    /// **Add Signature opens on Type, the caret in the name field** — on Draw, as it opened, the
    /// keyboard had no way to Type without the Mac's Keyboard navigation setting.
    @Test func addSignatureOpensOnTypeWithTheCaretInTheName() async throws {
        let fill = EditorPDFFillSign(store: EditorPDFSignatureStore(defaults: ScratchDefaults("EditorPDFFillKeyboardTests.sheet")))
        let host = NSHostingView(rootView: EditorPDFAddSignatureSheet(fill: fill, kind: .signature))
        host.frame = NSRect(x: 0, y: 0, width: 440, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.buryUnderEverything()
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        func fields(in view: NSView) -> [NSTextField] {
            (view as? NSTextField).map { [$0] } ?? [] + view.subviews.flatMap(fields(in:))
        }
        var name: NSTextField?
        for _ in 0..<200 where name == nil || window.firstResponder !== name?.currentEditor() {
            host.layoutSubtreeIfNeeded()
            name = fields(in: host).first { $0.placeholderString == "Your name" }
            try await Task.sleep(for: .milliseconds(5))
        }
        let field = try #require(name, "the sheet opened without the name field — on Draw")
        #expect(window.firstResponder === field.currentEditor(), "the caret isn't in the name field")
    }

    // MARK: The menu bar (decision AZ)

    /// **File ▸ Fill & Sign Tool holds the palette's tools**, greyed until Fill & Sign is on, each
    /// ticked as its tool is lit. Choosing one is driven in the app host
    /// (`PDFMenuBarTests.theToolMenuChoosesWhatThePaletteDoes`), where a menu item fires.
    @Test func theToolMenuHoldsThePalettesTools() async throws {
        let pdf = try await form()
        let fill = pdf.fill
        fill.store.add(EditorPDFSignature(kind: .signature, look: .typed("Ada Quill")))
        func menu() -> NSMenu {
            let menu = NSHostingMenu(rootView: EditorPDFFillSignMenuItems(fill: fill, tools: pdf.tools))
            menu.update()
            return menu
        }
        // A tick reads "[on] " — the Check Mark line's own title starts with ✓.
        func line(_ item: NSMenuItem) -> String {
            let title = (item.state == .on ? "[on] " : "") + (item.isSeparatorItem ? "—" : item.title)
            return item.isEnabled || item.isSeparatorItem ? title : "(\(title))"
        }
        func toolLines() throws -> [String] {
            try #require(menu().items.first { $0.title == EditorPDFFillToolMenu.title }?.submenu).items.map(line)
        }
        // Every line a tool or a choice — a submenu's own line reads live whatever its lines say.
        func leaves(_ menu: NSMenu) -> [NSMenuItem] {
            menu.update()
            return menu.items.flatMap { $0.submenu.map(leaves) ?? ($0.isSeparatorItem ? [] : [$0]) }
        }
        let offMenu = try #require(menu().items.first { $0.title == EditorPDFFillToolMenu.title }?.submenu)
        let live = leaves(offMenu).filter(\.isEnabled).map(\.title)
        #expect(leaves(offMenu).count > 15 && live.isEmpty, "live with Fill & Sign off: \(live)")
        fill.toggle()
        let lines = try toolLines()
        // Replace greyed: the file has a fillable form (decision AV).
        #expect(lines == ["[on] Form Fields", "Select", "Text", "(Replace)", "Date", "—", "✓  Check Mark", "✗  Cross", "•  Dot", "—",
                          "Signature", "Initials", "—", "Ink", "Text Size"], "\(lines)")
        fill.armed = .mark(.cross)
        let lit = try toolLines()
        #expect(lit.filter { $0.hasPrefix("[on] ") } == ["[on] ✗  Cross"], "\(lit)")
        let signature = try #require(menu().items.first { $0.title == EditorPDFFillToolMenu.title }?.submenu?
            .items.first { $0.title == "Signature" }?.submenu).items.map(line)
        #expect(signature == ["(Saved on this Mac)", "Ada Quill", "—", "Add Signature…", "Delete a Saved Signature"], "\(signature)")
    }
}

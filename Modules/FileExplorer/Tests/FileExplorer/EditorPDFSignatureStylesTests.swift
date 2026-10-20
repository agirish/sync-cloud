import Testing
import AppKit
import PDFKit
import PDFToolkitCore
@testable import FileExplorer
import EventsTestSupport

/// **Signature Styles (TE88–TE94)**: a typed signature's face, a drawn one's pen, the font of placed
/// text, all changeable after placing with the palette's Aa tool — and the saved signatures from
/// before them still there.
@MainActor
@Suite(.serialized) final class EditorPDFSignatureStylesTests {

    let folder = NSTemporaryDirectory() + "editor-pdf-styles-" + UUID().uuidString
    private let defaults = ScratchDefaults("EditorPDFSignatureStylesTests")

    init() throws {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(atPath: folder) }

    private static let letterBox = EditorPDFPageBox(cropBox: CGRect(x: 0, y: 0, width: 612, height: 792), rotation: 0)

    private func fill() -> EditorPDFFillSign {
        let fill = EditorPDFFillSign(store: EditorPDFSignatureStore(defaults: defaults))
        fill.attach(path: folder + "/Lease.pdf", boxes: [Self.letterBox], encryption: .none, allowsFilling: true)
        fill.toggle()
        return fill
    }

    private func place(_ fill: EditorPDFFillSign, _ signature: EditorPDFSignature) throws -> EditorPDFFillItem {
        fill.armed = .signature(signature)
        let id = try #require(fill.place(at: CGPoint(x: 300, y: 300), page: 0))
        return try #require(fill.items.first { $0.id == id })
    }

    private func placeText(_ fill: EditorPDFFillSign, _ words: String = "Alex Morgan") throws -> UUID {
        fill.armed = .text
        let id = try #require(fill.place(at: CGPoint(x: 100, y: 600), page: 0))
        fill.type(words, into: id)
        fill.endEditing()
        fill.select(id)
        return id
    }

    private func fire(_ item: NSMenuItem?) throws {
        let item = try #require(item)
        _ = item.target?.perform(item.action)
    }

    // MARK: Saved signatures from before

    /// **Signatures saved before faces and pens are all still there**, as Snell Roundhand and Medium
    /// — the JSON a 6.0 build before this wrote, typed and drawn — and one saved with a face this
    /// build doesn't know comes back as Snell rather than taking the rest down with it.
    @Test func signaturesSavedBeforeStylesDecodeAsSnellAndMedium() throws {
        let typedID = UUID(), drawnID = UUID(), laterID = UUID()
        let json = """
        [{"id":"\(typedID)","kind":"signature","look":{"typed":{"_0":"Alex Morgan"}}},
         {"id":"\(drawnID)","kind":"initials","look":{"drawn":{"strokes":[[[0,0],[1,1]]],"aspect":2}}},
         {"id":"\(laterID)","kind":"signature","look":{"typed":{"_0":"Sam Reed"}},"face":"signPainter","pen":"broadNib"}]
        """
        defaults.set(Data(json.utf8), forKey: EditorPDFSignatureStore.key)
        let saved = EditorPDFSignatureStore(defaults: defaults).saved
        #expect(saved.map(\.id) == [typedID, drawnID, laterID], "a saved signature was lost")
        #expect(saved.allSatisfy { $0.face == .snellRoundhand && $0.pen == .medium })
        #expect(saved.first?.look == .typed("Alex Morgan"))
        #expect(saved.dropFirst().first?.look == .drawn(strokes: [[.zero, CGPoint(x: 1, y: 1)]], aspect: 2))
        // And what is written now carries the style, read back as it was.
        let styled = EditorPDFSignature(kind: .signature, look: .typed("Ada"), face: .zapfino, pen: .bold)
        let back = try JSONDecoder().decode(EditorPDFSignature.self, from: JSONEncoder().encode(styled))
        #expect(back == styled && back.face == .zapfino && back.pen == .bold)
    }

    // MARK: What Save writes

    /// **The copy is drawn in the item's face, font and pen** — what the toolkit is handed.
    @Test func theToolkitIsHandedTheFaceTheFontAndThePen() {
        let typed = EditorPDFFillItem(page: 0, rect: CGRect(x: 10, y: 10, width: 200, height: 40),
                                      content: .signature(EditorPDFSignature(kind: .signature, look: .typed("Ada"), face: .savoye)),
                                      fontSize: 28, color: .blue)
        guard case .text(let face) = typed.toolkitItem(on: Self.letterBox).content else { Issue.record("not text"); return }
        #expect(face.isScript && face.font == .named("SavoyeLetPlain"))

        for (font, expected) in [(EditorPDFTextFont.sans, nil), (.serif, FillSignFont.named("Charter-Roman")),
                                 (.rounded, .systemRounded), (.mono, .systemMonospaced),
                                 (.handwritten, .named("Noteworthy-Light"))] as [(EditorPDFTextFont, FillSignFont?)] {
            let text = EditorPDFFillItem(page: 0, rect: CGRect(x: 10, y: 10, width: 200, height: 20), content: .text("4B"),
                                         fontSize: 12, color: .black, font: font)
            guard case .text(let run) = text.toolkitItem(on: Self.letterBox).content else { Issue.record("not text"); return }
            #expect(run.font == expected && !run.isScript, "\(font) was handed \(String(describing: run.font))")
        }

        for pen in EditorPDFPen.allCases {
            let drawn = EditorPDFFillItem(page: 0, rect: CGRect(x: 10, y: 10, width: 150, height: 50),
                                          content: .signature(EditorPDFSignature(kind: .signature, look: .drawn(
                                              strokes: [[.zero, CGPoint(x: 1, y: 1)]], aspect: 3), pen: pen)),
                                          fontSize: 12, color: .black)
            guard case .signature(let ink) = drawn.toolkitItem(on: Self.letterBox).content else { Issue.record("not ink"); return }
            #expect(ink.penWidthFraction == pen.widthFraction)
        }
        #expect(EditorPDFPen.medium.widthFraction == FillSignSignature.defaultPenWidthFraction, "Medium is not today's width")
        #expect(EditorPDFPen.fine.widthFraction < EditorPDFPen.medium.widthFraction)
        #expect(EditorPDFPen.medium.widthFraction < EditorPDFPen.bold.widthFraction)
    }

    /// **Every face is one the Mac has** — under its own name, not a stand-in — and SignPainter,
    /// which saves garbled on a form, is not offered (decision AT).
    @Test func everyFaceIsInstalledAndSignPainterIsNotOffered() {
        #expect(EditorPDFSignatureFace.allCases.count == 7)
        #expect(!EditorPDFSignatureFace.allCases.map(\.postScriptName).contains { $0.hasPrefix("SignPainter") })
        for face in EditorPDFSignatureFace.allCases {
            #expect(NSFont(name: face.postScriptName, size: 12)?.fontName == face.postScriptName, "\(face.title) is missing")
        }
        #expect(NSFont(name: "Charter-Roman", size: 12) != nil)
    }

    /// **A filled copy carries the face** — the toolkit embeds it, so the person it goes to sees it.
    @Test func aFilledCopyEmbedsTheFace() throws {
        let file = folder + "/Plain.pdf"
        PDFFixtures.write(file, pages: 1)
        let item = EditorPDFFillItem(page: 0, rect: CGRect(x: 72, y: 300, width: 300, height: 50),
                                     content: .signature(EditorPDFSignature(kind: .signature, look: .typed("Ada Lovelace"),
                                                                            face: .appleChancery)),
                                     fontSize: 28, color: .blue)
        let data = try PDFToolkit.fillAndSignData(inputURL: URL(fileURLWithPath: file), items: [item.toolkitItem(on: Self.letterBox)])
        #expect(data.range(of: Data("+Apple-Chancery".utf8)) != nil)
        #expect(data.range(of: Data("+SnellRoundhand".utf8)) == nil)
    }

    // MARK: Placing

    /// **Every face is placed at the width Snell Roundhand takes** (TE88), so Zapfino's loops don't
    /// make it a bigger signature.
    @Test func everyFaceIsPlacedAtOneWidth() throws {
        let fill = fill()
        let snell = try place(fill, EditorPDFSignature(kind: .signature, look: .typed("Alex Morgan")))
        #expect(snell.fontSize == EditorPDFFillSign.signatureFontSize)
        for face in EditorPDFSignatureFace.allCases where face != .snellRoundhand {
            let placed = try place(fill, EditorPDFSignature(kind: .signature, look: .typed("Alex Morgan"), face: face))
            let words = { (item: EditorPDFFillItem) in
                EditorPDFFillItem.measure("Alex Morgan", fontSize: item.fontSize, script: true, font: item.toolkitFont).width
            }
            #expect(abs(words(placed) - words(snell)) < 2, "\(face.title) placed \(words(placed))pt wide, Snell \(words(snell))pt")
        }
        let zapfino = try #require(fill.items.first { $0.signature?.face == .zapfino })
        #expect(zapfino.fontSize < EditorPDFFillSign.signatureFontSize)
    }

    /// **A mark keeps the system font**, whatever the next text's font is, and the Aa tool has
    /// nothing for it.
    @Test func aMarkKeepsTheSystemFont() throws {
        let fill = fill()
        fill.setTextFont(.handwritten)
        fill.armed = .mark(.check)
        let id = try #require(fill.place(at: CGPoint(x: 200, y: 200), page: 0))
        let mark = try #require(fill.items.first { $0.id == id })
        #expect(mark.font == .sans && mark.isMark)
        #expect(fill.styleTarget == .mark)
        #expect(EditorPDFFillFlyouts.style(for: fill).items.isEmpty)
        #expect(EditorPDFFillFlyouts.itemMenu(for: fill).items.map(\.title) == ["Delete"])
        fill.armed = .date
        let date = try #require(fill.place(at: CGPoint(x: 300, y: 300), page: 0))
        #expect(fill.items.first { $0.id == date }?.font == .handwritten, "a date did not take the next text's font")
    }

    // MARK: The Aa tool

    /// **Text's font, from the Aa flyout** (TE93): five fonts, each drawn in itself, the current one
    /// ticked; choosing one sets the selected text's — refitted to its words — and the next text's,
    /// in one ⌘Z step.
    @Test func theStyleFlyoutSetsTheSelectedTextsFontAndTheNext() throws {
        let fill = fill()
        let id = try placeText(fill)
        let menu = EditorPDFFillFlyouts.style(for: fill)
        #expect(menu.items.first?.title == "Font of this text" && menu.items.first?.isEnabled == false)
        let fonts = Array(menu.items.dropFirst())
        #expect(fonts.map(\.title) == EditorPDFTextFont.allCases.map(\.title))
        #expect(fonts.filter { $0.state == .on }.map(\.title) == ["Sans"])
        let mono = try #require(fonts.first { $0.title == "Mono" })
        let shown = try #require(mono.attributedTitle?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(shown.isFixedPitch, "Mono is not drawn in itself")
        let before = try #require(fill.items.first { $0.id == id })
        try fire(mono)
        let after = try #require(fill.items.first { $0.id == id })
        #expect(after.font == .mono && fill.textFont == .mono)
        #expect(after.rect.width > before.rect.width, "the box was not refitted to the wider monospaced words")
        #expect(after.rect.maxY == before.rect.maxY, "refitting moved the top of the words")
        #expect(fill.undoManager.undoActionName == "Font")
        fill.undoManager.undo()
        #expect(fill.items.first { $0.id == id } == before, "choosing a font was not one undo step")
        // With nothing selected it sets the next text's font only.
        fill.select(nil)
        let next = EditorPDFFillFlyouts.style(for: fill)
        #expect(next.items.first?.title == "Font of the next text")
        try fire(next.items.first { $0.title == "Serif" })
        #expect(fill.textFont == .serif && fill.items.first { $0.id == id }?.font == .sans)
        let serif = try placeText(fill, "4B")
        #expect(fill.items.first { $0.id == serif }?.font == .serif)
    }

    /// **A typed signature gets the seven faces, each in its own words** (TE92), kept at the width it
    /// was placed at; a saved one changes in the store too, and ⌘Z puts both back (decision AS).
    @Test func restylingASavedTypedSignatureChangesTheSavedOneAndUndoesAsOne() throws {
        let fill = fill()
        let saved = EditorPDFSignature(kind: .signature, look: .typed("Alex Morgan"))
        fill.store.add(saved)
        let placed = try place(fill, saved)
        let menu = EditorPDFFillFlyouts.style(for: fill)
        #expect(menu.items.first?.title == "Face of this signature")
        // Each line is the name in that face, then the face's name: "Alex Morgan   Zapfino".
        let faces = menu.items.filter { $0.target != nil }
        #expect(faces.map(\.title) == EditorPDFSignatureFace.allCases.map { "Alex Morgan   \($0.title)" })
        for (line, face) in zip(faces, EditorPDFSignatureFace.allCases) {
            let shown = line.attributedTitle?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            #expect(shown?.fontName == face.postScriptName, "\(face.title) is not shown in itself")
        }
        #expect(faces.filter { $0.state == .on }.map(\.title) == ["Alex Morgan   Snell Roundhand"])
        #expect(menu.items.last?.title == EditorPDFFillFlyouts.changesSavedLine && menu.items.last?.isEnabled == false)

        try fire(faces.first { $0.title.hasSuffix("Zapfino") })
        let restyled = try #require(fill.items.first { $0.id == placed.id })
        #expect(restyled.signature?.face == .zapfino)
        #expect(fill.store.saved.first { $0.id == saved.id }?.face == .zapfino, "the saved signature did not change")
        #expect(EditorPDFSignatureStore(defaults: defaults).saved.first?.face == .zapfino, "the change was not stored")
        let width = { (item: EditorPDFFillItem) in
            EditorPDFFillItem.measure("Alex Morgan", fontSize: item.fontSize, script: true, font: item.toolkitFont).width
        }
        #expect(abs(width(restyled) - width(placed)) < 2, "the new face changed the signature's width")
        #expect(fill.undoManager.undoActionName == "Signature Style")

        fill.undoManager.undo()
        #expect(fill.items.first { $0.id == placed.id } == placed)
        #expect(fill.store.saved.first { $0.id == saved.id }?.face == .snellRoundhand, "⌘Z left the saved signature restyled")
        fill.undoManager.redo()
        #expect(fill.items.first { $0.id == placed.id }?.signature?.face == .zapfino)
        #expect(fill.store.saved.first { $0.id == saved.id }?.face == .zapfino, "redo did not restyle the saved one again")
    }

    /// **A signature placed without saving changes on the page only** — no line about the saved one,
    /// and the store is not touched.
    @Test func anUnsavedSignatureChangesOnThePageOnly() throws {
        let fill = fill()
        let other = EditorPDFSignature(kind: .signature, look: .typed("Sam Reed"))
        fill.store.add(other)
        let placed = try place(fill, EditorPDFSignature(kind: .signature, look: .typed("Alex Morgan")))
        let menu = EditorPDFFillFlyouts.style(for: fill)
        #expect(!menu.items.map(\.title).contains(EditorPDFFillFlyouts.changesSavedLine))
        try fire(menu.items.first { $0.title.hasSuffix("Savoye") })
        #expect(fill.items.first { $0.id == placed.id }?.signature?.face == .savoye)
        #expect(fill.store.saved == [other], "a signature never saved reached the store")
    }

    /// **A drawn signature gets the three pens** (TE92) — the saved one too, in one ⌘Z step.
    @Test func aDrawnSignatureGetsThePens() throws {
        let fill = fill()
        let drawn = EditorPDFSignature(kind: .initials, look: .drawn(strokes: [[.zero, CGPoint(x: 1, y: 1)]], aspect: 2))
        fill.store.add(drawn)
        let placed = try place(fill, drawn)
        let menu = EditorPDFFillFlyouts.style(for: fill)
        #expect(menu.items.first?.title == "Pen of these initials")
        let pens = menu.items.filter { $0.target != nil }
        #expect(pens.map(\.title) == ["Fine", "Medium", "Bold"])
        #expect(pens.allSatisfy { $0.image != nil })
        #expect(pens.filter { $0.state == .on }.map(\.title) == ["Medium"])
        #expect(menu.items.last?.title == EditorPDFFillFlyouts.changesSavedInitialsLine)
        try fire(pens.last)
        #expect(fill.items.first { $0.id == placed.id }?.signature?.pen == .bold)
        #expect(fill.items.first { $0.id == placed.id }?.rect == placed.rect, "a pen moved or resized the signature")
        #expect(fill.store.saved.first?.pen == .bold)
        fill.undoManager.undo()
        #expect(fill.items.first { $0.id == placed.id }?.signature?.pen == .medium && fill.store.saved.first?.pen == .medium)
    }

    /// **The right-click menu is the Aa flyout and Delete** (TE92).
    @Test func anItemsRightClickMenuIsItsStylesThenDelete() throws {
        let fill = fill()
        let placed = try place(fill, EditorPDFSignature(kind: .signature, look: .typed("Alex Morgan")))
        let menu = EditorPDFFillFlyouts.itemMenu(for: fill)
        let style = EditorPDFFillFlyouts.style(for: fill)
        #expect(Array(menu.items.map(\.title).prefix(style.items.count)) == style.items.map(\.title))
        #expect(menu.items.last?.title == "Delete")
        try fire(menu.items.last)
        #expect(!fill.items.contains { $0.id == placed.id })
    }

    // MARK: The sheet's pieces

    /// **Add makes the initials too, in the signature's face** (TE94) — only while none are saved,
    /// and only when the signature is saved — and its ink becomes the next item's, without
    /// recolouring the selected one (TE89).
    @Test func addingATypedSignatureCanMakeItsInitials() throws {
        let fill = fill()
        let selected = try placeText(fill)
        #expect(fill.offersInitials(with: .signature) && !fill.offersInitials(with: .initials))
        let signature = EditorPDFSignature(kind: .signature, look: .typed("Abhishek Girish"), face: .savoye)
        fill.add(signature, keep: true, makeInitials: true, ink: .black)
        let initials = try #require(fill.store.saved(.initials).first)
        #expect(initials.look == .typed("AG") && initials.face == .savoye)
        #expect(fill.store.saved(.signature) == [signature])
        #expect(fill.armed == .signature(signature) && fill.color == .black)
        #expect(fill.items.first { $0.id == selected }?.color == .blue, "adding a signature recoloured the selected item")
        // Saved initials now: no more are offered, or made.
        #expect(!fill.offersInitials(with: .signature))
        fill.add(EditorPDFSignature(kind: .signature, look: .typed("Sam Reed")), keep: true, makeInitials: true, ink: .blue)
        #expect(fill.store.saved(.initials) == [initials])
        // Not saving the signature saves nothing, initials included.
        let fresh = EditorPDFFillSign(store: EditorPDFSignatureStore(defaults: ScratchDefaults("EditorPDFSignatureStylesInitials")))
        fresh.add(signature, keep: false, makeInitials: true, ink: .blue)
        #expect(fresh.store.saved.isEmpty && fresh.armed == .signature(signature))
        fresh.add(signature, keep: true, makeInitials: false, ink: .blue)
        #expect(fresh.store.saved(.initials).isEmpty)
    }

    /// **Smoothing keeps where a stroke starts and ends, and takes out the jitter** (TE91); a dot and
    /// a dash are left as drawn.
    @Test func smoothingKeepsTheEndsAndTakesOutTheJitter() throws {
        let jitter = (0...60).map { CGPoint(x: CGFloat($0) * 4, y: 50 + ($0 % 2 == 0 ? 3 : -3)) }
        let smooth = try #require(EditorPDFSignature.smoothed([jitter]).first)
        #expect(smooth.first == jitter.first && smooth.last == jitter.last)
        let wobble = { (points: [CGPoint]) in points.dropFirst(4).dropLast(4).map { abs($0.y - 50) }.max() ?? 0 }
        #expect(wobble(jitter) == 3)
        #expect(wobble(smooth) < 1, "the jitter is still \(wobble(smooth))pt")
        let dot = [CGPoint(x: 5, y: 5)], dash = [CGPoint(x: 0, y: 0), CGPoint(x: 9, y: 0)]
        #expect(EditorPDFSignature.smoothed([dot, dash, []]) == [dot, dash, []])
    }

    @Test func initialsAreTheFirstLetterOfEachWord() {
        #expect(EditorPDFSignature.initials(of: "Abhishek Girish") == "AG")
        #expect(EditorPDFSignature.initials(of: "  ada   lovelace byron king ") == "ALB")
        #expect(EditorPDFSignature.initials(of: "J. R. R. Tolkien") == "JRR")
        #expect(EditorPDFSignature.initials(of: "") == "")
    }

    /// **The pad draws in the chosen ink and pen** (TE89, TE90) — black is black, and Bold is wider
    /// than Fine.
    @Test func thePadDrawsInTheChosenInkAndPen() throws {
        func render(_ ink: EditorPDFFillColor, _ pen: EditorPDFPen) throws -> (blue: Int, dark: Int) {
            let pad = EditorPDFSignaturePad.PadView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
            pad.ink = ink
            pad.pen = pen
            pad.strokes = [[CGPoint(x: 20, y: 40), CGPoint(x: 180, y: 40)]]
            let rep = try #require(pad.bitmapImageRepForCachingDisplay(in: pad.bounds))
            pad.cacheDisplay(in: pad.bounds, to: rep)
            var blue = 0, dark = 0
            for x in stride(from: 0, to: rep.pixelsWide, by: 1) {
                for y in stride(from: 0, to: rep.pixelsHigh, by: 1) {
                    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.9 else { continue }
                    if c.blueComponent > 0.4, c.redComponent < 0.25 { blue += 1 }
                    if c.blueComponent < 0.15, c.redComponent < 0.15, c.greenComponent < 0.15 { dark += 1 }
                }
            }
            return (blue, dark)
        }
        let black = try render(.black, .medium), blue = try render(.blue, .medium)
        #expect(black.dark > 100 && black.blue == 0, "black ink drew \(black)")
        #expect(blue.blue > 100 && blue.dark == 0, "blue ink drew \(blue)")
        let fine = try render(.black, .fine), bold = try render(.black, .bold)
        #expect(bold.dark > fine.dark * 2, "Bold drew \(bold.dark) dark pixels, Fine \(fine.dark)")
    }
}

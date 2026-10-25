import Testing
import AppKit
import PDFKit
import PDFToolkitCore
import SwiftUI
import Design
import Sync
import EventsTestSupport
@testable import FileExplorer

extension PDFFixtures {
    /// One Letter page whose `/Rotate` is `degrees` — a scan put in on its side.
    static func writeRotated(_ path: String, degrees: Int) {
        let plain = path + ".plain.pdf"
        write(plain, pages: 1)
        let document = PDFDocument(url: URL(fileURLWithPath: plain))!
        document.page(at: 0)!.rotation = degrees
        document.write(to: URL(fileURLWithPath: path))
        try? FileManager.default.removeItem(atPath: plain)
    }
}

/// **Fill & Sign (Phase 5b)** — items placed on the open PDF, drawn by pdf-toolkit's
/// `fillAndSignData` into a NEW copy beside it, never into the file itself.
///
/// Serialized, because the saves and the opens run in `PDFKitSerialAccess`'s one lane; every wait
/// is bounded in lane turns, as `EditorPDFDocumentTests`' are.
@MainActor
@Suite(.serialized) final class EditorPDFFillSignTests {

    let folder = NSTemporaryDirectory() + "editor-pdf-fill-" + UUID().uuidString
    private let defaults = ScratchDefaults("EditorPDFFillSignTests")

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

    private func letter(_ name: String = "Lease.pdf", pages: Int = 2) async throws -> (EditorPDFDocument, String) {
        let file = path(name)
        PDFFixtures.write(file, pages: pages)
        return (try await open(file), file)
    }

    private func text(of file: String) -> String {
        PDFDocument(url: URL(fileURLWithPath: file))?.string ?? ""
    }

    // MARK: The page's two spaces

    /// **Display space and page space round-trip under every rotation**, crop box off the origin.
    @Test(arguments: [0, 90, 180, 270, -90, 450])
    func displayAndPageSpaceRoundTrip(rotation: Int) {
        let box = EditorPDFPageBox(cropBox: CGRect(x: 20, y: 30, width: 600, height: 800), rotation: rotation)
        let page = CGPoint(x: 100, y: 700)
        #expect(box.pagePoint(display: box.displayPoint(page: page)) == page)
        let rect = CGRect(x: 40, y: 60, width: 120, height: 30)
        #expect(box.displayRect(page: box.pageRect(display: rect)) == rect)
        let quarter = box.rotation == 90 || box.rotation == 270
        #expect(box.displaySize == (quarter ? CGSize(width: 800, height: 600) : CGSize(width: 600, height: 800)))
        // Every corner of the crop box lands on a corner of the displayed page.
        for corner in [CGPoint(x: 20, y: 30), CGPoint(x: 620, y: 830)] {
            let shown = box.displayPoint(page: corner)
            #expect([0, box.displaySize.width].contains(shown.x) && [0, box.displaySize.height].contains(shown.y),
                    "\(corner) shows at \(shown)")
        }
    }

    /// **A quarter turn clockwise puts the page's bottom edge on the left** — PDFKit's `/Rotate`.
    @Test func aQuarterTurnPutsTheBottomEdgeOnTheLeft() {
        let box = EditorPDFPageBox(cropBox: CGRect(x: 0, y: 0, width: 612, height: 792), rotation: 90)
        #expect(box.displayPoint(page: CGPoint(x: 300, y: 0)).x == 0, "the bottom edge is not on the left")
        #expect(box.displayPoint(page: CGPoint(x: 0, y: 300)).y == 612, "the left edge is not at the top")
    }

    /// **Ground truth: on a page turned a quarter, words and a drawn stroke come out where they
    /// were placed and the way up they were placed** — rendered from the toolkit's copy as the
    /// reader sees it. A horizontal stroke left in page space would come out vertical.
    @Test func itemsOnATurnedPageComeOutUprightWhereTheyWerePlaced() async throws {
        let file = path("Turned.pdf")
        PDFFixtures.writeRotated(file, degrees: 90)
        let pdf = try await open(file)
        let box = try #require(pdf.fill.box(0))
        #expect(box.rotation == 90 && box.displaySize == CGSize(width: 792, height: 612))

        // A stroke straight across, in a box in the display's lower right.
        let line = EditorPDFSignature(kind: .signature, look: .drawn(strokes: [[CGPoint(x: 0, y: 0.5), CGPoint(x: 1, y: 0.5)]], aspect: 4))
        let stroke = EditorPDFFillItem(page: 0, rect: CGRect(x: 500, y: 100, width: 200, height: 50),
                                       content: .signature(line), fontSize: 12, color: .blue)
        // Words in the display's upper left.
        let words = EditorPDFFillItem(page: 0, rect: CGRect(x: 60, y: 480, width: 300, height: 60),
                                      content: .text("MMMMMM"), fontSize: 40, color: .blue)
        let data = try PDFToolkit.fillAndSignData(inputURL: URL(fileURLWithPath: file),
                                                  items: [stroke, words].map { $0.toolkitItem(on: box) })
        let page = try #require(PDFDocument(data: data)?.page(at: 0))
        let image = page.thumbnail(of: box.displaySize, for: .cropBox)
        let rep = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let scale = CGFloat(rep.pixelsWide) / box.displaySize.width

        /// Blue pixels inside `rect`, in display space.
        func blue(in rect: CGRect) -> Int {
            var count = 0
            let pixels = rect.applying(CGAffineTransform(scaleX: scale, y: scale))
            for x in stride(from: Int(pixels.minX), to: Int(pixels.maxX), by: 1) {
                for y in stride(from: Int(pixels.minY), to: Int(pixels.maxY), by: 1) {
                    guard let color = rep.colorAt(x: x, y: rep.pixelsHigh - 1 - y)?.usingColorSpace(.sRGB) else { continue }
                    if color.blueComponent - color.redComponent > 0.2 { count += 1 }
                }
            }
            return count
        }
        #expect(blue(in: words.rect) > 200, "the words are not where they were placed")
        // The stroke: a band across the box's middle has ink at both ends; the box's top and bottom
        // quarters have none — they would, were the stroke drawn upright.
        #expect(blue(in: CGRect(x: 505, y: 118, width: 30, height: 14)) > 10, "no ink at the stroke's left end")
        #expect(blue(in: CGRect(x: 665, y: 118, width: 30, height: 14)) > 10, "no ink at the stroke's right end")
        #expect(blue(in: CGRect(x: 500, y: 100, width: 200, height: 12)) == 0, "the stroke runs up the page, not across")
        #expect(blue(in: CGRect(x: 500, y: 138, width: 200, height: 12)) == 0, "the stroke runs up the page, not across")
    }

    /// **Words placed at the box they measure come out whole** — the toolkit word-wraps inside the
    /// rect and draws only what fits, so a box a hair too narrow drops the end of the words.
    @Test func wordsPlacedAtTheirMeasuredBoxComeOutWhole() async throws {
        let file = path("Words.pdf")
        PDFFixtures.write(file, pages: 1, text: false)
        let box = EditorPDFPageBox(cropBox: CGRect(x: 0, y: 0, width: 612, height: 792), rotation: 0)
        let strings = ["Alex Morgan", "1 November 2026", "17/10/2026", "4B", "Wilhelmina Fairweather-Ashby",
                       "illiterate lily", "WWW MMM", "x", "Ünïcødé façade", "12,345.67 €"]
        let sizes: [CGFloat] = [6, 8, 9, 10, 11, 12, 14, 18, 24, 32, 48]
        var items: [EditorPDFFillItem] = []
        var y: CGFloat = 780
        for (index, string) in strings.enumerated() {
            for size in sizes {
                let script = index % 3 == 2
                let extent = EditorPDFFillItem.size(of: string, fontSize: size, script: script)
                if y - extent.height < 0 { break }
                y -= extent.height
                let content: EditorPDFFillItem.Content = script
                    ? .signature(EditorPDFSignature(kind: .signature, look: .typed(string))) : .text(string)
                items.append(EditorPDFFillItem(page: 0, rect: CGRect(origin: CGPoint(x: 4, y: y), size: extent),
                                               content: content, fontSize: size, color: .black))
            }
            let data = try PDFToolkit.fillAndSignData(inputURL: URL(fileURLWithPath: file),
                                                      items: items.map { $0.toolkitItem(on: box) })
            let page = try #require(PDFDocument(data: data)?.page(at: 0))
            for item in items {
                let shown = page.selection(for: box.pageRect(display: item.rect).insetBy(dx: -1, dy: -1))?.string ?? ""
                let want = item.words!.string
                #expect(shown.replacingOccurrences(of: "\n", with: " ").contains(want),
                        "“\(want)” at \(item.fontSize)pt\(item.words!.script ? " (script)" : "") came out as “\(shown)”")
            }
            items = []
            y = 780
        }
    }

    // MARK: Signatures

    /// **A drawn signature is fitted to its own box**, its shape kept; a flat one is not a hair high.
    @Test func aDrawnSignatureIsFittedToItsOwnBox() throws {
        let made = try #require(EditorPDFSignature.drawn([[CGPoint(x: 10, y: 20), CGPoint(x: 110, y: 70)], [CGPoint(x: 60, y: 40)]],
                                                         kind: .signature))
        guard case .drawn(let strokes, let aspect) = made.look else { Issue.record("not drawn"); return }
        #expect(aspect == 2)
        #expect(strokes == [[CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)], [CGPoint(x: 0.5, y: 0.4)]])
        let flat = try #require(EditorPDFSignature.drawn([[CGPoint(x: 0, y: 5), CGPoint(x: 100, y: 5)]], kind: .initials))
        guard case .drawn(_, let flatAspect) = flat.look else { Issue.record("not drawn"); return }
        #expect(flatAspect == 5, "a flat stroke's box is \(flatAspect)× as wide as tall")
        #expect(EditorPDFSignature.drawn([], kind: .signature) == nil)
        #expect(EditorPDFSignature.drawn([[]], kind: .signature) == nil)
    }

    /// **A tall, narrow drawing is placed no taller than its box is wide**, in its own shape — an
    /// upright stroke came out five times as tall as wide: a 150 × 750 pt signature on a 792 pt page.
    @Test func aTallDrawingIsPlacedNoTallerThanItIsWide() async throws {
        let (pdf, _) = try await letter("Tall.pdf")
        let fill = pdf.fill
        fill.toggle()
        let upright = try #require(EditorPDFSignature.drawn([[CGPoint(x: 50, y: 0), CGPoint(x: 51, y: 300)]], kind: .signature))
        fill.armed = .signature(upright)
        try #require(fill.place(at: CGPoint(x: 300, y: 400), page: 0) != nil)
        let rect = try #require(fill.items.first?.rect)
        #expect(rect.height <= EditorPDFFillSign.signatureWidth + 0.5, "placed \(rect.size)")
        #expect(abs(rect.width / rect.height - 0.2) < 0.01, "lost its shape: \(rect.size)")
    }

    /// **Saved signatures stay in this Mac's defaults**, newest first, each kind to its limit.
    @Test func savedSignaturesAreKeptPerKindAndSurviveARelaunch() {
        let store = EditorPDFSignatureStore(defaults: defaults)
        let first = EditorPDFSignature(kind: .signature, look: .typed("Alex Morgan"))
        let initials = EditorPDFSignature(kind: .initials, look: .typed("AM"))
        store.add(first)
        store.add(initials)
        for n in 0..<EditorPDFSignatureStore.limit { store.add(EditorPDFSignature(kind: .signature, look: .typed("S\(n)"))) }
        #expect(store.saved(.signature).count == EditorPDFSignatureStore.limit)
        #expect(!store.saved(.signature).contains(first), "the oldest signature was kept past the limit")
        #expect(store.saved(.initials) == [initials], "initials were trimmed with the signatures")
        let again = EditorPDFSignatureStore(defaults: defaults)
        #expect(again.saved == store.saved, "the saved signatures did not survive a new store")
        again.delete(initials.id)
        #expect(EditorPDFSignatureStore(defaults: defaults).saved(.initials).isEmpty)
    }

    /// **A reset of every setting takes the saved signatures for good** — Reset All Settings empties
    /// the domain under a store already up, and its next add used to write back the signatures the
    /// reset had just removed.
    @Test func savedSignaturesDoNotComeBackAfterAReset() throws {
        let scratch = ScratchDefaults("EditorPDFSignatureReset")
        let store = EditorPDFSignatureStore(defaults: scratch)
        let old = EditorPDFSignature(kind: .signature, look: .typed("Alex Morgan"))
        store.add(old)
        scratch.removePersistentDomain(forName: scratch.scratchSuiteName)
        let new = EditorPDFSignature(kind: .signature, look: .typed("Sam Reed"))
        store.add(new)
        let stored = try JSONDecoder().decode([EditorPDFSignature].self,
                                              from: try #require(scratch.data(forKey: EditorPDFSignatureStore.key)))
        #expect(stored == [new], "the reset's removed signature was written back")
        #expect(store.saved == [new])
        // A delete after a reset is built on what is stored too — not the list held before it.
        scratch.removePersistentDomain(forName: scratch.scratchSuiteName)
        store.delete(old.id)
        let afterDelete = try JSONDecoder().decode([EditorPDFSignature].self,
                                                   from: try #require(scratch.data(forKey: EditorPDFSignatureStore.key)))
        #expect(afterDelete.isEmpty, "the delete wrote back signatures the reset removed: \(afterDelete)")
    }

    /// **A reset takes them from the open app at once** — not only from disk. The list held in
    /// memory went on offering a removed signature in the Signature flyout, ready to place, until
    /// a relaunch or the next add.
    @Test func aResetTakesSavedSignaturesOffTheMenuAtOnce() throws {
        let scratch = ScratchDefaults("EditorPDFSignatureResetLive")
        let store = EditorPDFSignatureStore(defaults: scratch)
        store.add(EditorPDFSignature(kind: .signature, look: .typed("Alex Morgan")))
        store.add(EditorPDFSignature(kind: .initials, look: .typed("AM")))
        try #require(store.saved.count == 2)
        scratch.removePersistentDomain(forName: scratch.scratchSuiteName)
        #expect(store.saved.isEmpty, "a reset left \(store.saved.count) saved signatures on offer")
        #expect(store.saved(.signature).isEmpty && store.saved(.initials).isEmpty)
        #expect(scratch.data(forKey: EditorPDFSignatureStore.key) == nil, "taking the reset wrote the list back")
    }

    /// **A write to the signatures' domain from another thread never waits for the main thread**,
    /// and the list still follows it — the reader's twin (`EditorPDFReaderChromeTests`).
    @Test func aWriteOffTheMainThreadNeverWaitsForTheSignatures() async throws {
        let scratch = ScratchDefaults("EditorPDFSignatureOffMain")
        let store = EditorPDFSignatureStore(defaults: scratch)
        store.add(EditorPDFSignature(kind: .signature, look: .typed("Alex Morgan")))
        try #require(store.saved.count == 1)
        let written = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            scratch.removePersistentDomain(forName: scratch.scratchSuiteName)
            written.signal()
        }
        #expect(holdingTheMainThread(until: written) == .success,
                "a background write to the signatures' defaults waited on the main thread")
        let end = Date().addingTimeInterval(15)
        while !store.saved.isEmpty, Date() < end { try? await Task.sleep(nanoseconds: 8_000_000) }
        #expect(store.saved.isEmpty, "a reset from another thread left \(store.saved.count) signatures on offer")
    }

    /// Blocks the main thread — this test runs on it — until `done` is signalled or five seconds
    /// pass. Synchronous, because a wait in an async test would hand the main thread back.
    private func holdingTheMainThread(until done: DispatchSemaphore) -> DispatchTimeoutResult {
        done.wait(timeout: .now() + 5)
    }

    // MARK: Placing

    @Test func turningItOnChoosesTextAndAClickPlacesWordsToType() async throws {
        let (pdf, _) = try await letter()
        let fill = pdf.fill
        fill.toggle()
        #expect(fill.isOn && fill.armed == .text)
        let id = try #require(fill.place(at: CGPoint(x: 100, y: 600), page: 0))
        #expect(fill.editing == id && fill.selection == id)
        #expect(!fill.hasUnsavedItems, "an empty text box counts as placed")
        fill.type("Alex Morgan", into: id)
        let item = try #require(fill.items.first)
        #expect(item.rect.width >= EditorPDFFillItem.size(of: "Alex Morgan", fontSize: 12, script: false).width)
        #expect(abs(item.rect.minX - 98) < 0.01, "the words do not start at the click")
        fill.endEditing()
        #expect(fill.unsavedCaption == "1 item not saved")
        #expect(fill.undoManager.undoActionName == "Place Text")
        fill.undoManager.undo()
        #expect(fill.items.isEmpty)
        fill.undoManager.redo()
        #expect(fill.items.first?.words?.string == "Alex Morgan")
        #expect(fill.armed == .text, "Text was let go after one use")
    }

    /// **Text left empty goes as though it was never placed** — no item, and nothing to undo.
    @Test func textLeftEmptyLeavesNothingBehind() async throws {
        let (pdf, _) = try await letter()
        pdf.fill.toggle()
        pdf.fill.place(at: CGPoint(x: 100, y: 600), page: 0)
        pdf.fill.endEditing()
        #expect(pdf.fill.items.isEmpty)
        #expect(!pdf.fill.undoManager.canUndo)
    }

    @Test func aDateIsTodayInTheMacsFormatAndAMarkIsCentredOnTheClick() async throws {
        let (pdf, _) = try await letter()
        let fill = pdf.fill
        fill.formatDate = { _ in "17/10/2026" }
        fill.toggle()
        fill.armed = .date
        fill.place(at: CGPoint(x: 300, y: 300), page: 1)
        #expect(fill.items.last?.words?.string == "17/10/2026")
        #expect(fill.items.last?.page == 1)
        fill.armed = .mark(.check)
        fill.place(at: CGPoint(x: 200, y: 200), page: 0)
        let mark = try #require(fill.items.last)
        #expect(mark.words?.string == "✓")
        #expect(abs(mark.rect.midX - 200) < 0.01 && abs(mark.rect.midY - 200) < 0.01)
        #expect(fill.armed == .mark(.check), "a mark was let go after one use")
    }

    /// **A signature is placed once**, at its drawn shape, and the tool lets go.
    @Test func aSignatureIsPlacedOnceAtItsShape() async throws {
        let (pdf, _) = try await letter()
        let fill = pdf.fill
        fill.toggle()
        let signature = EditorPDFSignature(kind: .signature, look: .drawn(strokes: [[.zero, CGPoint(x: 1, y: 1)]], aspect: 3))
        fill.armed = .signature(signature)
        fill.place(at: CGPoint(x: 300, y: 200), page: 0)
        let placed = try #require(fill.items.first)
        #expect(placed.rect.size == CGSize(width: EditorPDFFillSign.signatureWidth, height: EditorPDFFillSign.signatureWidth / 3))
        #expect(fill.armed == nil)
        #expect(fill.unsaved.map(\.isSignature) == [true] && fill.unsavedCaption == "1 item not saved")
        #expect(fill.place(at: CGPoint(x: 10, y: 10), page: 0) == nil, "a second click placed it again")
    }

    /// **Items stay on their page**: a drag past the edge stops at it.
    @Test func aDragKeepsTheItemOnItsPageAndIsOneUndoStep() async throws {
        let (pdf, _) = try await letter()
        let fill = pdf.fill
        fill.toggle()
        fill.armed = .mark(.cross)
        let id = try #require(fill.place(at: CGPoint(x: 100, y: 100), page: 0))
        let start = try #require(fill.items.first?.rect)
        fill.beginGesture()
        fill.moveLive(id, to: start.offsetBy(dx: 50, dy: 50))
        fill.moveLive(id, to: start.offsetBy(dx: 5000, dy: -5000))
        fill.endGesture("Move")
        let moved = try #require(fill.items.first?.rect)
        #expect(moved.maxX == 612 && moved.minY == 0, "the drag left the page: \(moved)")
        #expect(fill.undoManager.undoActionName == "Move")
        fill.undoManager.undo()
        #expect(fill.items.first?.rect == start, "one undo did not take back the whole drag")
    }

    @Test func deleteSizeAndInkAreUndoable() async throws {
        let (pdf, _) = try await letter()
        let fill = pdf.fill
        fill.toggle()
        fill.armed = .mark(.dot)
        fill.place(at: CGPoint(x: 100, y: 100), page: 0)
        let before = try #require(fill.items.first)
        fill.stepFontSize(bigger: true)
        #expect(fill.items.first!.fontSize == 14 && fill.items.first!.rect.height > before.rect.height)
        #expect(fill.items.first!.rect.maxY == before.rect.maxY, "growing moved the top of the words")
        fill.setColor(.black)
        #expect(fill.items.first?.color == .black && fill.color == .black)
        fill.deleteSelection()
        #expect(fill.items.isEmpty)
        fill.undoManager.undo()
        fill.undoManager.undo()
        fill.undoManager.undo()
        #expect(fill.items == [before])
    }

    // MARK: Refusals

    /// **A file whose owner restricted editing gets no Fill & Sign** — the reason, and the way out.
    @Test func anOwnerRestrictedFileIsRefusedWithTheWayOut() async throws {
        let file = path("Statement.pdf")
        PDFFixtures.writeRestricted(file)
        let pdf = try await open(file)
        var said: [String] = []
        pdf.fill.presentRefusal = { said.append($0) }
        pdf.fill.toggle()
        #expect(!pdf.fill.isOn)
        #expect(said == [EditorPDFFillSign.restrictedReason])
        #expect(said.first?.contains("Remove Password") == true)
    }

    @Test func refusalsAreTheToolsForALockedFileAndTheOwnersForARestrictedOne() {
        #expect(EditorPDFFillSign.refusal(encryption: .lockedToOpen, allowsFilling: true) == EditorPDFTools.lockedReason)
        #expect(EditorPDFFillSign.refusal(encryption: .restrictedOnly, allowsFilling: false) == EditorPDFFillSign.restrictedReason)
        #expect(EditorPDFFillSign.refusal(encryption: .restrictedOnly, allowsFilling: true) == nil,
                "a restricted file whose owner allows filling was refused")
        #expect(EditorPDFFillSign.refusal(encryption: .none, allowsFilling: true) == nil)
    }

    // MARK: Saving

    /// **Save Filled Copy writes "(filled)" beside the original and leaves the original as it was.**
    @Test func savingWritesAFilledCopyAndNeverTheOriginal() async throws {
        let (pdf, file) = try await letter()
        let original = try Data(contentsOf: URL(fileURLWithPath: file))
        let fill = pdf.fill
        fill.toggle()
        let id = try #require(fill.place(at: CGPoint(x: 100, y: 500), page: 1))
        fill.type("QUOKKA4471", into: id)
        let outcome = await fill.save()
        guard case .wrote(let copy) = outcome else { Issue.record("\(outcome)"); return }
        #expect((copy as NSString).lastPathComponent == "Lease (filled).pdf")
        #expect(text(of: copy).contains("QUOKKA4471"), "the copy does not carry the words")
        #expect(try Data(contentsOf: URL(fileURLWithPath: file)) == original, "the original was written")
        #expect(!text(of: file).contains("QUOKKA4471"))
        #expect(fill.items.isEmpty && !fill.isOn, "the items outlived the save")
        #expect(pdf.tools.banner?.kind == .wrote(copy))
        #expect(pdf.path == file, "the original did not stay open")
    }

    /// **The note card says a flat save flattens the file's own comments (FR57)** — and a sticky
    /// note's text goes with it. Both claims measured on the copy: no comment is left as one, and
    /// the closed note's words are nowhere in it. A file with a highlight only says the first half;
    /// a file with none says nothing.
    @Test func aFlatSaveSaysTheFilesCommentsAreFlattened() async throws {
        func annotated(_ name: String, _ kinds: [PDFAnnotationSubtype]) throws -> String {
            let file = path(name)
            PDFFixtures.write(file, pages: 2)
            let document = try #require(PDFDocument(url: URL(fileURLWithPath: file)))
            let page = try #require(document.page(at: 1))
            for kind in kinds {
                let note = PDFAnnotation(bounds: CGRect(x: 300, y: 300, width: 24, height: 24), forType: kind, withProperties: nil)
                note.contents = "WALLABY note text"
                note.color = .yellow
                page.addAnnotation(note)
            }
            try #require(document.write(to: URL(fileURLWithPath: file)))
            return file
        }
        let noted = try await open(try annotated("Noted.pdf", [.text, .highlight]))
        #expect(noted.fill.comments == EditorPDFComments(any: true, notes: true))
        #expect(noted.fill.formNotes.first == EditorPDFComments.notesFlattenedNote)
        let highlighted = try await open(try annotated("Highlighted.pdf", [.highlight]))
        #expect(highlighted.fill.formNotes.first == EditorPDFComments.commentsFlattenedNote)
        let plain = try await open(try annotated("Plain.pdf", []))
        #expect(!plain.fill.formNotes.contains { $0.contains("comments") }, "a file with no comments was warned")

        // The claims, on the copy.
        let fill = noted.fill
        fill.toggle()
        let id = try #require(fill.place(at: CGPoint(x: 100, y: 500), page: 0))
        fill.type("QUOKKA4471", into: id)
        guard case .wrote(let copy) = await fill.save() else { Issue.record("the copy was not written"); return }
        let page = try #require(PDFDocument(url: URL(fileURLWithPath: copy))?.page(at: 1))
        #expect(!page.annotations.contains { EditorPDFComments.markupTypes.contains($0.type ?? "") },
                "a comment is still one in the copy — the note says they are flattened")
        let original = try #require(PDFDocument(url: URL(fileURLWithPath: path("Noted.pdf")))?.page(at: 1))
        #expect(original.annotations.contains { $0.contents == "WALLABY note text" }, "the fixture has no note text")
        #expect(!page.annotations.contains { $0.contents?.contains("WALLABY") == true } && !text(of: copy).contains("WALLABY"),
                "the note's text is in the copy — the note says it isn't")
    }

    // MARK: Keeping the file's comments (FR57, decided 2026-10-25)
    //
    // Every PDF read and write below runs in the PDFKit lane, as the app's do, handing back only
    // facts: off it, they race the package's other PDF suites.

    /// A two-page Letter file whose second page carries a sticky note with its popup and a yellow
    /// highlight across `highlight` — written by PDFKit, which gives each an appearance.
    private func commented(_ name: String) async throws -> String {
        let file = path(name)
        let written = await PDFKitSerialAccess.perform { () -> Bool in
            PDFFixtures.write(file, pages: 2)
            guard let document = PDFDocument(url: URL(fileURLWithPath: file)), let page = document.page(at: 1) else { return false }
            let note = PDFAnnotation(bounds: CGRect(x: 60, y: 300, width: 24, height: 24), forType: .text, withProperties: nil)
            note.contents = "WALLABY note text"
            note.color = .yellow
            page.addAnnotation(note)
            let popup = PDFAnnotation(bounds: CGRect(x: 90, y: 300, width: 150, height: 80), forType: .popup, withProperties: nil)
            note.popup = popup
            page.addAnnotation(popup)
            let marker = PDFAnnotation(bounds: Self.highlight, forType: .highlight, withProperties: nil)
            marker.color = .yellow
            page.addAnnotation(marker)
            return document.write(to: URL(fileURLWithPath: file))
        }
        try #require(written, "the fixture was not written")
        return file
    }

    nonisolated static let highlight = CGRect(x: 300, y: 300, width: 160, height: 40)

    /// **How much yellow page `index`'s own content draws across ``highlight``** — the page's
    /// content stream alone, as `drawPDFPage` draws it, with no annotation: a comment drawn into
    /// the page shows here, one kept as a comment does not. `-1` for a page that can't be read.
    private func yellowInContent(_ data: Data, page index: Int) async -> Int {
        await PDFKitSerialAccess.perform { () -> Int in
            guard let document = CGDataProvider(data: data as CFData).flatMap(CGPDFDocument.init),
                  let page = document.page(at: index + 1) else { return -1 }
            let box = page.getBoxRect(.mediaBox)
            let (w, h) = (Int(box.width), Int(box.height))
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return -1 }
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.translateBy(x: -box.minX, y: -box.minY)
            ctx.drawPDFPage(page)
            guard let pixels = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return -1 }
            let rect = Self.highlight
            var count = 0
            for y in Int(rect.minY)..<Int(rect.maxY) {
                for x in Int(rect.minX)..<Int(rect.maxX) {
                    let at = ((h - 1 - y) * w + x) * 4
                    if pixels[at] > 200, pixels[at + 1] > 200, pixels[at + 2] < 120 { count += 1 }
                }
            }
            return count
        }
    }

    /// One annotation as the file holds it, read by CoreGraphics rather than PDFKit (which
    /// rewrites what it reads).
    struct Comment: Sendable, Equatable {
        var subtype: String
        var contents: String?
        /// For a popup: the subtype of the annotation its `/Parent` names.
        var parent: String?
    }

    private func comments(_ data: Data, page index: Int) async -> [Comment] {
        await PDFKitSerialAccess.perform { () -> [Comment] in
            func subtype(_ annotation: CGPDFDictionaryRef) -> String? {
                var name: UnsafePointer<CChar>?
                return CGPDFDictionaryGetName(annotation, "Subtype", &name) ? name.map { String(cString: $0) } : nil
            }
            guard let document = CGDataProvider(data: data as CFData).flatMap(CGPDFDocument.init),
                  let page = document.page(at: index + 1)?.dictionary else { return [] }
            var annots: CGPDFArrayRef?
            guard CGPDFDictionaryGetArray(page, "Annots", &annots), let annots else { return [] }
            return (0..<CGPDFArrayGetCount(annots)).compactMap { i in
                var annotation: CGPDFDictionaryRef?
                guard CGPDFArrayGetDictionary(annots, i, &annotation), let annotation, let kind = subtype(annotation) else { return nil }
                var contents: CGPDFStringRef?
                var parent: CGPDFDictionaryRef?
                return Comment(
                    subtype: kind,
                    contents: CGPDFDictionaryGetString(annotation, "Contents", &contents) ? contents.flatMap { CGPDFStringCopyTextString($0) as String? } : nil,
                    parent: CGPDFDictionaryGetDictionary(annotation, "Parent", &parent) ? parent.flatMap(subtype) : nil)
            }
        }
    }

    /// **"Keep comments as comments" writes the file's comments into the copy as comments, and draws
    /// none of them into its pages** — the sticky note with its text and its popup, the highlight —
    /// while a save left as it is still draws them in. Off by default, offered on a flat file with
    /// comments, and for that save only.
    @Test func keepingCommentsWritesThemAsCommentsAndDrawsNoneIn() async throws {
        #expect(EditorPDFComments.markupTypes == [
            "Text", "FreeText", "Line", "Square", "Circle", "Polygon", "PolyLine", "Highlight", "Underline",
            "Squiggly", "StrikeOut", "Stamp", "Caret", "Ink", "Sound", "Redact",
        ], "the comments the card counts are not the ones the toolkit keeps")
        let file = try await commented("Noted.pdf")
        let source = try Data(contentsOf: URL(fileURLWithPath: file))
        try #require(await yellowInContent(source, page: 1) == 0, "the fixture draws yellow into its page — this tests nothing")
        let pdf = try await open(file)
        let fill = pdf.fill
        fill.toggle()
        #expect(fill.offersKeepingComments && !fill.keepsComments, "not offered, or on by default")
        func save() async throws -> Data {
            let id = try #require(fill.place(at: CGPoint(x: 100, y: 500), page: 0))
            fill.type("QUOKKA4471", into: id)
            fill.endEditing()
            guard case .wrote(let copy) = await fill.save() else { throw CancellationError() }
            return try Data(contentsOf: URL(fileURLWithPath: copy))
        }

        // Left as it is: drawn in, as before.
        let flat = try await save()
        #expect(await yellowInContent(flat, page: 1) > 1000, "a save left as it is did not draw the highlight in")
        #expect(await comments(flat, page: 1).filter { EditorPDFComments.markupTypes.contains($0.subtype) }.isEmpty,
                "a save left as it is kept a comment")

        fill.toggle()
        fill.keepsComments = true
        #expect(fill.formNotes.first == EditorPDFComments.commentsKeptNote, "the card still says they are drawn in")
        let kept = try await save()
        #expect(!fill.keepsComments, "the choice outlived its save")
        #expect(pdf.tools.banner?.message.contains(EditorPDFComments.keptFellBackNote) == false)
        #expect(await yellowInContent(kept, page: 1) == 0, "a kept comment is drawn into the page too")
        let carried = await comments(kept, page: 1)
        #expect(carried.map(\.subtype).sorted() == ["Highlight", "Popup", "Text"], "\(carried)")
        #expect(carried.first { $0.subtype == "Text" }?.contents == "WALLABY note text", "the note's text did not come along")
        #expect(carried.first { $0.subtype == "Popup" }?.parent == "Text", "the popup no longer belongs to its note")
    }

    /// **The choice goes back off with Discard and with another file**, as the links' does.
    @Test func keepingCommentsLastsOneSaveOnly() async throws {
        let pdf = try await open(try await commented("Noted.pdf"))
        let fill = pdf.fill
        fill.toggle()
        fill.keepsComments = true
        fill.discard()
        #expect(!fill.keepsComments, "Discard kept the choice")
        fill.keepsComments = true
        pdf.open(path: try await commented("Other.pdf"), log: { _ in })
        for _ in 0..<1000 where pdf.phase == .loading { await PDFKitSerialAccess.perform {} }
        try #require(pdf.phase == .open)
        #expect(!fill.keepsComments, "another file kept the choice")
        // Offered only with comments to keep.
        let plain = try await letter("Plain.pdf")
        #expect(!plain.0.fill.offersKeepingComments, "offered on a file with no comments")
    }

    /// **Comments the toolkit could not keep are said to have been drawn in** — it draws them in
    /// then and reports `.flatten`, as it does with an encrypted copy, which this run's stand-in for
    /// the toolkit (called in the lane, as the toolkit is) does on purpose. The banner names it; the
    /// copy has them drawn in.
    @Test func commentsThatCouldNotBeKeptAreSaidToBeDrawnIn() async throws {
        let pdf = try await open(try await commented("Noted.pdf"))
        pdf.tools.fillAndSignHook = { input, items, _ in
            (try PDFToolkit.fillAndSignData(inputURL: input, items: items, annotations: .flatten).data, .flatten)
        }
        let fill = pdf.fill
        fill.toggle()
        let id = try #require(fill.place(at: CGPoint(x: 100, y: 500), page: 0))
        fill.type("QUOKKA4471", into: id)
        fill.keepsComments = true
        guard case .wrote(let copy) = await fill.save() else { Issue.record("the copy was not written"); return }
        let message = try #require(pdf.tools.banner?.message)
        #expect(message.hasPrefix("Saved “") && message.hasSuffix(". " + EditorPDFComments.keptFellBackNote), "\(message)")
        #expect(await yellowInContent(try Data(contentsOf: URL(fileURLWithPath: copy)), page: 1) > 1000)
    }

    /// **The engine never keeps comments with a page made a picture** (FR57): the picture pass
    /// copies the other pages through PDFKit, which rewrites a kept comment, so it draws them in.
    /// The same run with no picture keeps them — the fixture can tell the two apart. The engine is
    /// called in the lane, as the app calls it.
    @Test func theEngineDrawsCommentsInWhenAPageIsMadeAPicture() async throws {
        let file = try await commented("Pictured.pdf")
        let item = FillSignItem(pageIndex: 0, rect: CGRect(x: 100, y: 500, width: 120, height: 20),
                                content: .text(FillSignText(string: "QUOKKA4471", fontSize: 12, red: 0, green: 0, blue: 0)))
        let staging = URL(fileURLWithPath: folder)
        func copy(pictures: [Int]) async throws -> Data {
            let data = await PDFKitSerialAccess.perform { () -> Data? in
                guard case .bytes(let data, _)? = try? EditorPDFToolEngine.output(
                    of: .fillAndSign([item], pictures: pictures, keepsComments: true), input: URL(fileURLWithPath: file),
                    staging: staging, progress: nil, isCancelled: nil) else { return nil }
                return data
            }
            return try #require(data, "the engine wrote nothing")
        }
        try #require(await yellowInContent(try await copy(pictures: []), page: 1) == 0, "kept with no picture — this tests nothing")
        #expect(await yellowInContent(try await copy(pictures: [0]), page: 1) > 1000,
                "kept with a page made a picture, whose pass rewrites them")
    }

    /// **What changes while the copy is being written is kept, not cleared** — it is not in the copy,
    /// and clearing deleted it without a word. The save is held on its lane turn while a second item
    /// goes down, then let finish: the copy has the first words only, and both items are still there.
    @Test func anItemPlacedWhileTheCopyIsWrittenOutlivesTheSave() async throws {
        let (pdf, _) = try await letter("Lease during.pdf")
        let fill = pdf.fill, tools = pdf.tools
        fill.toggle()
        let first = try #require(fill.place(at: CGPoint(x: 100, y: 500), page: 1))
        fill.type("NUMBAT-FIRST", into: first)
        let save = Task { await fill.save() }
        for _ in 0..<10_000 where tools.running == nil { await Task.yield() }
        try #require(tools.running != nil, "the save never began")
        let late = try #require(fill.place(at: CGPoint(x: 100, y: 300), page: 1))
        fill.type("NUMBAT-LATE", into: late)
        fill.endEditing()
        guard case .wrote(let copy) = await save.value else { Issue.record("the save wrote no copy"); return }
        #expect(text(of: copy).contains("NUMBAT-FIRST"))
        #expect(!text(of: copy).contains("NUMBAT-LATE"), "the late item reached the copy, so this proves nothing")
        #expect(fill.isOn, "the toolbar went down over an item the copy does not carry")
        #expect(fill.items.map(\.id).contains(late), "the item placed during the save was cleared")
        #expect(fill.hasUnsavedChanges, "the leave question would no longer ask about it")
    }

    /// **Fill & Sign does not go off while its own save is writing** — turning it off asked whether
    /// to save the very items being saved; Save was then refused as "still running", and Discard
    /// cleared what the copy was taking.
    @Test func itDoesNotTurnOffWhileTheSaveIsWriting() async throws {
        let (pdf, _) = try await letter("Lease saving.pdf")
        let fill = pdf.fill, tools = pdf.tools
        fill.toggle()
        let id = try #require(fill.place(at: CGPoint(x: 100, y: 500), page: 1))
        fill.type("QUOLL", into: id)
        var asked = 0
        fill.askLeaving = { _, _ in asked += 1; return .discard }
        let save = Task { await fill.save() }
        for _ in 0..<10_000 where tools.running == nil { await Task.yield() }
        try #require(tools.running != nil, "the save never began")
        #expect(!fill.mayToggle)
        fill.toggle()
        #expect(asked == 0, "turning it off mid-save asked about the items being saved")
        #expect(fill.isOn)
        guard case .wrote = await save.value else { Issue.record("the save wrote nothing"); return }
        #expect(!fill.isOn && fill.mayToggle)
    }

    /// **A signature or initials make it "(signed)"** — drawn or typed.
    @Test(arguments: [false, true])
    func aSignatureMakesItSigned(typed: Bool) async throws {
        let (pdf, _) = try await letter("Form \(typed).pdf")
        let fill = pdf.fill
        fill.toggle()
        fill.armed = .signature(EditorPDFSignature(
            kind: .initials, look: typed ? .typed("AM") : .drawn(strokes: [[.zero, CGPoint(x: 1, y: 1)]], aspect: 2)))
        fill.place(at: CGPoint(x: 300, y: 100), page: 0)
        let outcome = await fill.save()
        guard case .wrote(let copy) = outcome else { Issue.record("\(outcome)"); return }
        #expect((copy as NSString).lastPathComponent == "Form \(typed) (signed).pdf")
    }

    @Test func theCopysNameAndTheLogSayNoMoreThanCounts() {
        let words = FillSignItem(pageIndex: 0, rect: CGRect(x: 0, y: 0, width: 50, height: 20),
                                 content: .text(FillSignText(string: "WOMBAT-SECRET", fontSize: 12, red: 0, green: 0, blue: 0)))
        let typed = FillSignItem(pageIndex: 0, rect: CGRect(x: 0, y: 0, width: 50, height: 20),
                                 content: .text(FillSignText(string: "Alex", fontSize: 12, red: 0, green: 0, blue: 0, isScript: true)))
        #expect(EditorPDFTool.fillAndSign([words]).suffix == "filled")
        #expect(EditorPDFTool.fillAndSign([words, typed]).suffix == "signed")
        #expect(EditorPDFTool.fillAndSign([words, typed]).logDetail == "fill and sign (2 items, 1 signature)")
        #expect(!EditorPDFTool.fillAndSign([words]).logDetail.contains("WOMBAT"))
        #expect(EditorPDFTool.fillAndSign([words]).formLoss == .formFlattened)
        #expect(EditorPDFTool.fillAndSign([words]).rebuildsDocument)
        #expect(EditorPDFToolEngine.refusal(.fillAndSign([]), pageCount: 2) == PDFOperationError.noFillSignItems.errorDescription)
        var far = words
        far.pageIndex = 5
        #expect(EditorPDFToolEngine.refusal(.fillAndSign([far]), pageCount: 2) == PDFOperationError.pageOutOfBounds(6).errorDescription)
    }

    /// **The words typed never reach the log** — the save's line names the copy and counts.
    @Test func theWordsNeverReachTheLog() async throws {
        let log = LogCapture()
        let stem = "Words-\(UUID().uuidString.prefix(8))"
        let (pdf, _) = try await letter("\(stem).pdf")
        pdf.fill.toggle()
        let id = try #require(pdf.fill.place(at: CGPoint(x: 100, y: 500), page: 0))
        pdf.fill.type("PLATYPUS-9917", into: id)
        _ = await pdf.fill.save()
        let entries = await log.entries
        #expect(entries.contains { $0.message.contains("Edit wrote \(stem) (filled).pdf") && $0.message.contains("fill and sign (1 item)") },
                "the save was not logged — the absence below would be vacuous")
        #expect(!entries.contains { $0.message.contains("PLATYPUS") }, "typed words reached the log")
    }

    // MARK: Leaving

    @Test func leavingWithUnsavedItemsAsksAndEachAnswerDoesWhatItSays() async throws {
        let (pdf, file) = try await letter("Leave.pdf")
        let fill = pdf.fill
        fill.toggle()
        fill.armed = .mark(.check)
        fill.place(at: CGPoint(x: 100, y: 100), page: 0)
        #expect(pdf.tools.hasWorkToLose)
        var asked: [(String, Int)] = []
        var answer = EditorPDFFillSign.LeaveAnswer.cancel
        fill.askLeaving = { asked.append(($0, $1)); return answer }

        #expect(!pdf.tools.mayLeave(), "Cancel left")
        #expect(asked.count == 1 && asked[0].0 == "Leave.pdf" && asked[0].1 == 1)
        answer = .discard
        #expect(pdf.tools.mayLeave(), "Discard Items stayed")
        #expect(fill.items.count == 1, "the question dropped the items itself — the close does that")

        answer = .save
        #expect(!pdf.tools.mayLeave(), "Save Filled Copy left before the copy was written")
        let copy = path("Leave (filled).pdf")
        for _ in 0..<1000 where !FileManager.default.fileExists(atPath: copy) { await PDFKitSerialAccess.perform {} }
        for _ in 0..<100 where fill.hasUnsavedItems { await Task.yield() }
        #expect(FileManager.default.fileExists(atPath: copy))
        #expect(!fill.hasUnsavedItems && pdf.tools.mayLeave(), "the next leave still asks")
        #expect(asked.count == 3)
        _ = file
    }

    @Test func theToolbarGoesDownOnlyOnceTheItemsAreSettled() async throws {
        let (pdf, _) = try await letter()
        let fill = pdf.fill
        fill.toggle()
        fill.armed = .mark(.check)
        fill.place(at: CGPoint(x: 100, y: 100), page: 0)
        fill.askLeaving = { _, _ in .cancel }
        fill.toggle()
        #expect(fill.isOn && fill.items.count == 1, "Cancel put the toolbar away")
        fill.askLeaving = { _, _ in .discard }
        fill.toggle()
        #expect(!fill.isOn && fill.items.isEmpty)
    }

    /// **A closed file takes its items with it**, and a reload that changed the pages drops them
    /// with a word; one that kept every page keeps them.
    @Test func aCloseOrAReloadThatChangedThePagesDropsTheItems() async throws {
        let (pdf, file) = try await letter()
        let fill = pdf.fill
        fill.toggle()
        fill.armed = .mark(.check)
        fill.place(at: CGPoint(x: 100, y: 100), page: 0)
        let boxes = fill.boxes
        fill.attach(path: file, boxes: boxes, encryption: .none, allowsFilling: true)
        #expect(fill.items.count == 1, "a reload of the same pages dropped the items")
        fill.attach(path: file, boxes: Array(boxes.prefix(1)), encryption: .none, allowsFilling: true)
        #expect(fill.items.isEmpty)
        #expect(pdf.tools.banner?.message.contains("dropped") == true)
        fill.place(at: CGPoint(x: 100, y: 100), page: 0)
        pdf.close()
        #expect(fill.items.isEmpty && !fill.isOn)
    }

    /// **A reload that now refuses the file takes what was placed, and says so** — the owner's
    /// rules changed in place, the pages did not. With the palette and pill down and the overlay
    /// not drawing, the items were out of sight, yet File ▸ Save Filled Copy and the leave question
    /// could still flatten them into a copy of a file that now forbids it.
    @Test(arguments: [true, false])
    func aReloadThatRefusesTheFileTakesWhatWasPlaced(formEntry: Bool) async throws {
        let (pdf, file) = try await letter()
        let fill = pdf.fill
        fill.toggle()
        fill.armed = .mark(.check)
        fill.place(at: CGPoint(x: 100, y: 100), page: 0)
        #expect(fill.canSave, "the premise: the mark can be saved")
        fill.attach(path: file, boxes: fill.boxes, encryption: .restrictedOnly, allowsFilling: formEntry,
                    allowsFormEntry: formEntry, allowsCommenting: false)
        #expect(!fill.isOn)
        #expect(!fill.canSave, "File ▸ Save Filled Copy is live for items nobody can see")
        #expect(!fill.hasUnsavedChanges, "the items outlived the palette and pill that showed them")
        #expect(pdf.tools.banner?.message.contains("no longer allows filling") == true)
    }

    /// **What a vanished file took is what the pill counted** — a text box opened and not typed
    /// into is no work, and was reported as "1 item".
    @Test func anEmptyTextBoxIsNoLostWork() async throws {
        let (pdf, _) = try await letter()
        let fill = pdf.fill
        fill.toggle()
        fill.armed = .text
        fill.place(at: CGPoint(x: 100, y: 100), page: 0)
        #expect(!fill.hasUnsavedItems, "the premise: an empty text box is not counted")
        #expect(fill.unsavedWork == nil)
        fill.armed = .mark(.check)
        fill.place(at: CGPoint(x: 100, y: 300), page: 0)
        #expect(fill.unsavedWork == "1 item")
    }

    /// **A file that goes from under the reader says what unsaved work went with it** — a rename,
    /// the Trash, a sync client's half-written file. The leave question cannot ask then, and the
    /// items used to go with only a log line to say so.
    @Test func aFileThatGoesFromUnderTheReaderSaysWhatWorkWentWithIt() async throws {
        let (pdf, file) = try await letter()
        let fill = pdf.fill
        fill.toggle()
        fill.armed = .mark(.check)
        fill.place(at: CGPoint(x: 100, y: 100), page: 0)
        fill.place(at: CGPoint(x: 100, y: 200), page: 0)
        try FileManager.default.removeItem(atPath: file)
        // Two looks: an empty path is believed only when a second agrees (FR52).
        pdf.look()
        pdf.lookAsAnEventWould()
        #expect(pdf.phase == .refused(EditorPDFDocument.goneReason))
        #expect(fill.items.isEmpty)
        #expect(pdf.tools.banner?.message
                == "The file was moved or deleted, so Fill & Sign’s unsaved work — 2 items — was dropped.")
        // With nothing unsaved there is nothing to say.
        let (quiet, other) = try await letter("Quiet.pdf")
        try FileManager.default.removeItem(atPath: other)
        quiet.look()
        quiet.lookAsAnEventWould()
        #expect(quiet.phase == .refused(EditorPDFDocument.goneReason) && quiet.tools.banner == nil)
        // A file left unreadable — a sync client's half-written copy — says it the same way.
        let (torn, tornFile) = try await letter("Torn.pdf")
        torn.fill.toggle()
        torn.fill.armed = .mark(.check)
        torn.fill.place(at: CGPoint(x: 100, y: 100), page: 0)
        try Data("not a PDF any more".utf8).write(to: URL(fileURLWithPath: tornFile))
        var phases: [EditorPDFDocument.Phase] = []
        torn.onLoaded = { phases.append($0) }
        torn.look()
        for _ in 0..<1000 where phases.isEmpty { await PDFKitSerialAccess.perform {} }
        #expect(phases == [.refused(EditorPDFDocument.unreadableReason)])
        #expect(torn.tools.banner?.message
                == "The file couldn’t be read, so Fill & Sign’s unsaved work — 1 item — was dropped.")
    }

    /// **A file renamed aside and then put back keeps the work on it** (FR52). A sync client, or an
    /// app's save, that moves the original aside before installing the new revision leaves the path
    /// empty for a moment that can outlast the settle. One look at that moment dropped every item,
    /// field value and undo step, and said so in a banner, for a file back a moment later.
    @Test func aFileRenamedAsideAndPutBackKeepsTheWorkOnIt() async throws {
        let (pdf, file) = try await letter()
        let fill = pdf.fill
        fill.toggle()
        fill.armed = .mark(.check)
        fill.place(at: CGPoint(x: 100, y: 100), page: 0)
        fill.place(at: CGPoint(x: 100, y: 200), page: 0)
        try #require(fill.items.count == 2)

        // No `await` from the rename to the new file, so no look but these two can come between.
        try FileManager.default.moveItem(atPath: file, toPath: file + ".sb-old")
        pdf.lookAsAnEventWould()
        #expect(pdf.phase == .open, "one look at an empty path let the file go")
        #expect(fill.items.count == 2, "the work went at the first look at an empty path")
        #expect(pdf.tools.banner == nil)
        // The new revision lands: the same pages, new bytes.
        PDFFixtures.write(file, pages: 2, text: false)
        let returned = pdf.loadsReturned
        pdf.lookAsAnEventWould()
        let deadline = Date().addingTimeInterval(10)
        while pdf.loadsReturned == returned, Date() < deadline { await PDFKitSerialAccess.perform {} }
        try #require(pdf.loadsReturned > returned, "the file put back was never reloaded")
        #expect(pdf.phase == .open)
        #expect(fill.items.count == 2, "the reload of a file with the same pages dropped its items")
        #expect(pdf.tools.banner == nil)
    }

    /// **And a file that stays gone is let go at the second look** — the control: waiting must not
    /// mean keeping a document whose file is not coming back. The first look's own second look,
    /// a settle later, is what lets it go.
    @Test func aFileThatStaysGoneIsLetGoAtTheSecondLook() async throws {
        let (pdf, file) = try await letter()
        let fill = pdf.fill
        fill.toggle()
        fill.armed = .mark(.check)
        fill.place(at: CGPoint(x: 100, y: 100), page: 0)
        try FileManager.default.moveItem(atPath: file, toPath: file + ".filed")
        pdf.look()
        #expect(pdf.phase == .open)
        let deadline = Date().addingTimeInterval(10)
        while pdf.phase == .open, Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(pdf.phase == .refused(EditorPDFDocument.goneReason))
        #expect(fill.items.isEmpty)
        #expect(pdf.tools.banner?.message
                == "The file was moved or deleted, so Fill & Sign’s unsaved work — 1 item — was dropped.")
    }

    /// **A reload that changed the pages takes the undo steps too**, with nothing placed at the
    /// time: ⌘Z after a Discard put an item back on a page the file no longer had — counted as
    /// unsaved, drawn nowhere, and left out of the copy that Save then cleared it as saved.
    @Test func aReloadThatChangedThePagesForgetsTheUndoSteps() async throws {
        let (pdf, file) = try await letter()
        let fill = pdf.fill
        fill.toggle()
        fill.armed = .mark(.check)
        fill.place(at: CGPoint(x: 100, y: 100), page: 1)
        fill.discard()
        #expect(fill.undoManager.canUndo, "the premise: Discard is a step ⌘Z undoes")
        fill.attach(path: file, boxes: Array(fill.boxes.prefix(1)), encryption: .none, allowsFilling: true)
        #expect(!fill.undoManager.canUndo, "the steps outlived the pages they were taken on")
        fill.undoManager.undo()
        #expect(fill.items.isEmpty)
    }

    // MARK: The menu bar

    /// **File ▸ Fill & Sign and Save Filled Copy, as AppKit builds them** — `NSHostingMenu`, which
    /// is how the menu bar turns SwiftUI items into an `NSMenu`. Drawn afresh for each read, so
    /// what is read is the state, not whether a hosted menu has redrawn yet. A tick reads "✓ ", a
    /// line nothing can choose is in brackets.
    private func menuLines(_ fill: EditorPDFFillSign, _ tools: EditorPDFTools) -> [String] {
        let menu = NSHostingMenu(rootView: EditorPDFFillSignMenuItems(fill: fill, tools: tools))
        menu.update()
        return menu.items.map { item in
            // A submenu's own line reads live whatever its lines say: File ▸ Fill & Sign Tool's are
            // `EditorPDFFillKeyboardTests`'.
            if item.submenu != nil { return item.title + " ▸" }
            let title = (item.state == .on ? "✓ " : "") + item.title
            return item.isEnabled ? title : "(\(title))"
        }
    }

    /// **The toggle is the header button, and Save is the toolbar's** — greyed with no file; live
    /// and ticked as the button is lit; Save live only with something placed and no tool running.
    /// The acts are driven directly: a menu item fires only in the app host, where
    /// `PDFMenuBarTests.fillAndSignsLinesDoWhatTheButtonAndTheSaveDo` chooses each one.
    @Test func theMenuBarsItemsFollowTheButtonAndTheToolbarsSave() async throws {
        let idle = EditorPDFFillSign(store: EditorPDFSignatureStore(defaults: defaults))
        #expect(menuLines(idle, EditorPDFTools()) == ["(Fill & Sign)", "Fill & Sign Tool ▸", "(Save Filled Copy)"],
                "a line is live with no PDF open")

        let (pdf, _) = try await letter()
        let fill = pdf.fill, tools = pdf.tools
        #expect(menuLines(fill, tools) == ["Fill & Sign", "Fill & Sign Tool ▸", "(Save Filled Copy)"])
        fill.toggle()
        #expect(menuLines(fill, tools) == ["✓ Fill & Sign", "Fill & Sign Tool ▸", "(Save Filled Copy)"], "Save is live with nothing placed")

        fill.armed = .mark(.check)
        fill.place(at: CGPoint(x: 100, y: 100), page: 0)
        #expect(menuLines(fill, tools) == ["✓ Fill & Sign", "Fill & Sign Tool ▸", "Save Filled Copy"])
        let save = Task { await fill.save() }
        for _ in 0..<10_000 where tools.running == nil { await Task.yield() }
        try #require(tools.running != nil, "the save never began")
        // Both grey while it writes: turning it off then asked about the items being saved.
        #expect(menuLines(fill, tools) == ["(✓ Fill & Sign)", "Fill & Sign Tool ▸", "(Save Filled Copy)"], "a line is live while the save runs")
        guard case .wrote = await save.value else { Issue.record("the save wrote no copy"); return }
        #expect(menuLines(fill, tools) == ["Fill & Sign", "Fill & Sign Tool ▸", "(Save Filled Copy)"], "the toolbar outlived the save")
    }

    /// **Under a sheet both lines grey** — Add Signature's or a tool's. The menu bar stays live over
    /// a window-modal sheet, and the toggle took Add Signature down with its strokes.
    @Test func theMenuBarsItemsGreyUnderASheet() async throws {
        let (pdf, _) = try await letter("Under a sheet.pdf")
        let fill = pdf.fill, tools = pdf.tools
        fill.toggle()
        fill.armed = .mark(.check)
        fill.place(at: CGPoint(x: 100, y: 100), page: 0)
        #expect(menuLines(fill, tools) == ["✓ Fill & Sign", "Fill & Sign Tool ▸", "Save Filled Copy"])
        fill.addingSignature = .signature
        #expect(menuLines(fill, tools) == ["(✓ Fill & Sign)", "Fill & Sign Tool ▸", "(Save Filled Copy)"], "live under Add Signature")
        fill.addingSignature = nil
        tools.sheet = .compress
        #expect(menuLines(fill, tools) == ["(✓ Fill & Sign)", "Fill & Sign Tool ▸", "(Save Filled Copy)"], "live under a tool's sheet")
    }

    /// **A refused file: the toggle greyed and the reason under it**, short enough for a menu — the
    /// alert's title for an owner's restriction, the locked reason's first sentence for a file locked
    /// to open, as the right-click Replace Text… row says it (F-E7).
    @Test func aRefusedFileGreysTheToggleAndSaysWhy() async throws {
        let file = path("Statement.pdf")
        PDFFixtures.writeRestricted(file)
        let pdf = try await open(file)
        #expect(menuLines(pdf.fill, pdf.tools)
                == ["(Fill & Sign)", "(\(EditorPDFFillSign.restrictedTitle))", "Fill & Sign Tool ▸", "(Save Filled Copy)"])

        let locked = EditorPDFFillSign(store: EditorPDFSignatureStore(defaults: defaults))
        locked.attach(path: file, boxes: pdf.fill.boxes, encryption: .lockedToOpen, allowsFilling: true)
        #expect(menuLines(locked, pdf.tools)
                == ["(Fill & Sign)", "(Remove the password first)", "Fill & Sign Tool ▸", "(Save Filled Copy)"])
        // One rule: every refusal Fill & Sign can give is said the same in both menus.
        for refusal in [EditorPDFTools.lockedReason, EditorPDFFillSign.restrictedReason,
                        EditorPDFFillSign.nothingToFillReason] {
            #expect(EditorPDFFillSign.replaceMenuLine(refusal) == EditorPDFFillSign.menuLine(refusal), "\(refusal)")
        }
        #expect(EditorPDFFillSign.replaceMenuLine(EditorPDFFillSign.formReplaceReason) == EditorPDFFillSign.formReplaceMenuReason)
    }

    // MARK: The overlay

    /// **The overlay over a real page view**: it lets clicks through to PDFKit unless it has
    /// something to do with them, places at the pointer, drags in one undo step, and answers ⌘Z —
    /// while the reader itself never claims Undo, whose menu PDFKit validates its own way.
    @Test func theOverlayPlacesAtThePointerAndOnlyTakesTheClicksItUses() async throws {
        let (pdf, _) = try await letter(pages: 1)
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
        #expect(overlay.superview === reader)
        let page = try #require(pdf.document?.page(at: 0))
        let click = reader.convert(CGPoint(x: 306, y: 396), from: page)

        #expect(overlay.hitTest(click) == nil, "the overlay took a click with Fill & Sign off")
        // Turned on with the pages holding the keyboard, the overlay takes it — so ⌘Z is Fill &
        // Sign's from the start — and gives it back when it goes.
        window.makeFirstResponder(reader)
        // The reader's own hand-off runs a turn after it takes the keyboard; let it run first, so
        // what is tested is the toggle's.
        for _ in 0..<20 { await Task.yield() }
        #expect(window.firstResponder === reader)
        pdf.fill.toggle()
        for _ in 0..<20 where window.firstResponder !== overlay { await Task.yield() }
        #expect(window.firstResponder === overlay, "the pages kept the keyboard with Fill & Sign on")
        pdf.fill.toggle()
        for _ in 0..<20 where window.firstResponder !== reader { await Task.yield() }
        #expect(window.firstResponder === reader, "the keyboard was not handed back to the pages")
        pdf.fill.toggle()
        pdf.fill.armed = nil
        #expect(overlay.hitTest(click) == nil, "with nothing chosen a click on the page did not reach PDFKit")
        pdf.fill.armed = .mark(.check)
        #expect(overlay.hitTest(click) === overlay)

        func event(_ type: NSEvent.EventType, at point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: reader.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        // A ⌃-click is a right-click, and places nothing — away from an item there is no menu.
        overlay.mouseDown(with: NSEvent.mouseEvent(with: .leftMouseDown, location: reader.convert(click, to: nil),
                                                   modifierFlags: .control, timestamp: 0, windowNumber: window.windowNumber,
                                                   context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
        #expect(pdf.fill.items.isEmpty, "a ⌃-click placed an item")
        overlay.mouseDown(with: event(.leftMouseDown, at: click))
        let placed = try #require(pdf.fill.items.first)
        #expect(abs(placed.rect.midX - 306) < 0.5 && abs(placed.rect.midY - 396) < 0.5, "placed at \(placed.rect)")
        let shown = try #require(overlay.viewRect(placed))
        #expect(shown.contains(overlay.convert(click, from: reader)))

        pdf.fill.armed = nil
        overlay.mouseDown(with: event(.leftMouseDown, at: click))
        overlay.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: click.x + 25, y: click.y)))
        overlay.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: click.x + 25, y: click.y)))
        let moved = try #require(pdf.fill.items.first)
        #expect(abs(moved.rect.minX - placed.rect.minX - 50) < 0.5, "a 25pt drag at half scale moved \(moved.rect.minX - placed.rect.minX)")

        #expect(overlay.responds(to: EditorUndoCommands.undo))
        #expect(!reader.responds(to: EditorUndoCommands.undo), "the reader claims Undo, which PDFKit validates")
        let item = NSMenuItem(title: "Undo", action: EditorUndoCommands.undo, keyEquivalent: "z")
        #expect(overlay.validateMenuItem(item) && item.title == "Undo Move")
        overlay.undo(nil)
        #expect(pdf.fill.items.first?.rect == placed.rect)

        // A press just inside the corner — within reach of the handle — still moves the item.
        let corner = try #require(overlay.viewPoint(display: CGPoint(x: placed.rect.maxX, y: placed.rect.minY), page: 0))
        // 1.5pt in from each edge: a whole point inside even when the event rounds its location.
        let near = CGPoint(x: corner.x - 1.5, y: corner.y + (overlay.isFlipped ? -1.5 : 1.5))
        let reach = try #require(overlay.handle(of: placed))
        #expect(hypot(reach.x - near.x, reach.y - near.y) <= EditorPDFFillOverlay.handleRadius + 2,
                "the press is out of the handle's reach — this checks nothing")
        let inside = overlay.convert(near, to: reader)
        overlay.mouseDown(with: event(.leftMouseDown, at: inside))
        overlay.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: inside.x + 5, y: inside.y)))
        overlay.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: inside.x + 5, y: inside.y)))
        #expect(pdf.fill.undoManager.undoActionName == "Move", "a press inside the item resized it")
        #expect(pdf.fill.items.first?.fontSize == placed.fontSize)
        overlay.undo(nil)

        // The handle, just outside the corner, resizes: words take the size that fills the height.
        let handle = try #require(overlay.handle(of: placed))
        #expect(!(overlay.viewRect(placed)?.contains(handle) ?? true), "the handle is inside the item")
        let grab = overlay.convert(handle, to: reader)
        overlay.mouseDown(with: event(.leftMouseDown, at: grab))
        overlay.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: grab.x + 20, y: grab.y - 20)))
        overlay.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: grab.x + 20, y: grab.y - 20)))
        let grown = try #require(pdf.fill.items.first)
        #expect(grown.fontSize > placed.fontSize * 2, "the handle did not resize: \(grown.fontSize)pt")
        #expect(abs(grown.rect.maxY - placed.rect.maxY) < 0.5, "resizing moved the top")
        #expect(pdf.fill.undoManager.undoActionName == "Resize")
        reader.fillSign = nil
    }
}

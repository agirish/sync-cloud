import Testing
import AppKit
import PDFKit
import PDFToolkitCore
import Sync
import EventsTestSupport
@testable import FileExplorer

/// More fixtures for the tools: a real catalog form, an owner-restricted file, and a scan heavy
/// enough for Compress to make smaller.
extension PDFFixtures {
    /// A 2-page PDF carrying a REAL catalog `/AcroForm` with one text field on page 1 — assembled
    /// byte by byte, because PDFKit will not write an `/AcroForm` from widget annotations (a fixture
    /// built that way reports no form and tests nothing). pdf-toolkit's own fixture, ported.
    static func writeAcroForm(_ path: String) throws {
        let stream = "BT /Helv 24 Tf 72 396 Td (MARKERPAGE1) Tj ET"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [5 0 R] /DA (/Helv 0 Tf 0 g) >> >>",
            "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [5 0 R] /Contents 6 0 R /Resources << /Font << /Helv 7 0 R >> >> >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 6 0 R /Resources << /Font << /Helv 7 0 R >> >> >>",
            "<< /Type /Annot /Subtype /Widget /FT /Tx /T (FullName) /V (typed value) /Rect [72 600 272 624] /DA (/Helv 12 Tf 0 g) /F 4 /P 3 0 R >>",
            "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        ]
        var pdf = "%PDF-1.7\n"
        var offsets: [Int] = []
        for (index, body) in objects.enumerated() {
            offsets.append(pdf.utf8.count)
            pdf += "\(index + 1) 0 obj\n\(body)\nendobj\n"
        }
        let xref = pdf.utf8.count
        pdf += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { pdf += String(format: "%010d 00000 n \n", offset) }
        pdf += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        try Data(pdf.utf8).write(to: URL(fileURLWithPath: path))
    }

    /// Opens without a password; page assembly needs the owner's — what Protect's Restrict editing
    /// writes, and what bank statements often are.
    static func writeRestricted(_ path: String, pages: Int = 3) {
        let plain = path + ".plain.pdf"
        write(plain, pages: pages)
        let document = PDFDocument(url: URL(fileURLWithPath: plain))!
        document.write(to: URL(fileURLWithPath: path),
                       withOptions: [.ownerPasswordOption: "owner-only",
                                     .accessPermissionsOption: NSNumber(value: PDFPermissionPreset.openAndPrintOnly)])
        try? FileManager.default.removeItem(atPath: plain)
    }

    /// Pages that are one large noise picture each — a scan, as far as Compress is concerned: no
    /// text layer, and far more bytes than a redraw at a lower resolution needs.
    static func writeScan(_ path: String, pages: Int, pixels: Int = 900) {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<(pixels * pixels)).map { _ in UInt8.random(in: 0...255, using: &generator) }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let image = CGImage(width: pixels, height: pixels, bitsPerComponent: 8, bitsPerPixel: 8,
                            bytesPerRow: pixels, space: CGColorSpaceCreateDeviceGray(),
                            bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider, decode: nil,
                            shouldInterpolate: false, intent: .defaultIntent)!
        var box = CGRect(origin: .zero, size: letter)
        let context = CGContext(URL(fileURLWithPath: path) as CFURL, mediaBox: &box, nil)!
        for _ in 0..<pages {
            context.beginPDFPage(nil)
            context.draw(image, in: CGRect(x: 0, y: 90, width: 612, height: 612))
            context.endPDFPage()
        }
        context.closePDF()
    }
}

/// **Edit's PDF tools — every one writes a NEW copy beside the original and never touches it.**
///
/// Serialized, because every tool runs in `PDFKitSerialAccess`'s one lane. No test here holds the
/// lane: each awaits its own run, so a crowded lane makes them slow, never wrong.
@MainActor
@Suite(.serialized) final class EditorPDFToolsTests {

    let folder = NSTemporaryDirectory() + "editor-pdf-tools-" + UUID().uuidString

    init() throws {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(atPath: folder) }

    private func path(_ name: String) -> String { (folder as NSString).appendingPathComponent(name) }

    private func files() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).sorted()
    }

    /// Tools attached to `file` as an open would attach them, without a reader — and with every
    /// question answered yes unless the test says otherwise.
    private func tools(_ file: String, encryption: PDFEncryptionState = .none) -> EditorPDFTools {
        let tools = EditorPDFTools()
        let count = PDFDocument(url: URL(fileURLWithPath: file))?.pageCount ?? 0
        tools.attach(path: file, pageCount: count, encryption: encryption)
        tools.confirm = { _, _ in true }
        tools.confirmDiscardingArrangement = { true }
        return tools
    }

    /// The original as it was, to hold it to afterwards: its bytes and its modification date —
    /// set into the past first, so a write in this second could not hide behind it.
    private struct Original {
        let bytes: Data
        let modified: Date
    }

    private func pin(_ file: String) throws -> Original {
        let past = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: file)
        return Original(bytes: try Data(contentsOf: URL(fileURLWithPath: file)), modified: past)
    }

    private func expectUntouched(_ file: String, _ original: Original, _ label: String) throws {
        let now = try Data(contentsOf: URL(fileURLWithPath: file))
        #expect(now == original.bytes, "\(label): the original's bytes changed")
        let modified = try FileManager.default.attributesOfItem(atPath: file)[.modificationDate] as? Date
        #expect(modified == original.modified, "\(label): the original's date moved to \(String(describing: modified))")
    }

    private func texts(_ file: String) -> [String] {
        guard let document = PDFDocument(url: URL(fileURLWithPath: file)) else { return [] }
        return (0..<document.pageCount).map {
            (document.page(at: $0)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    // MARK: Every tool

    /// One case per tool, each on the fixture it needs.
    enum Case: String, CaseIterable, Sendable {
        case rotate, delete, reorder, extract, compress, metadata, protect, removePassword

        var suffix: String {
            switch self {
            case .rotate: return "rotated"
            case .delete: return "pages removed"
            case .reorder: return "reordered"
            case .extract: return "pages 2–3"
            case .compress: return "compressed"
            case .metadata: return "metadata cleaned"
            case .protect: return "protected"
            case .removePassword: return "unlocked"
            }
        }

        var tool: EditorPDFTool {
            switch self {
            case .rotate: return .rotate(pages: [1], quarterTurns: 1)
            case .delete: return .deletePages([0])
            case .reorder: return .reorder([2, 0, 1])
            case .extract: return .extract([1, 2])
            case .compress: return .compress(.quality(0.35))
            case .metadata: return .cleanMetadata(.cleared)
            case .protect: return .protect(restrictEditing: false, password: EditorPDFSecret("pw-protect"))
            case .removePassword: return .removePassword(EditorPDFSecret("pw-remove"))
            }
        }
    }

    private func fixture(for item: Case) -> (file: String, encryption: PDFEncryptionState) {
        let file = path("Invoice.pdf")
        switch item {
        case .compress: PDFFixtures.writeScan(file, pages: 3)
        case .removePassword:
            PDFFixtures.writeLocked(file, password: "pw-remove", pages: 3)
            return (file, .lockedToOpen)
        default: PDFFixtures.write(file, pages: 3)
        }
        return (file, .none)
    }

    /// **The whole contract, per tool**: a new file with the tool's name, the original byte for
    /// byte and date for date as it was, a second run named "… 2", and never two parses at once.
    @Test(arguments: Case.allCases)
    func everyToolWritesANewCopyAndLeavesTheOriginal(_ item: Case) async throws {
        let (file, encryption) = fixture(for: item)
        let original = try pin(file)
        let tools = tools(file, encryption: encryption)

        let first = await tools.run(item.tool)
        let expected = path("Invoice (\(item.suffix)).pdf")
        #expect(first == .wrote(expected), "\(item): \(first)")
        #expect(FileManager.default.fileExists(atPath: expected), "\(item): no copy at \(expected)")
        try expectUntouched(file, original, "\(item), first run")
        #expect(tools.banner?.kind == .wrote(expected))
        #expect(tools.banner?.message.contains("Invoice (\(item.suffix)).pdf") == true,
                "\(item): banner says \(tools.banner?.message ?? "nothing")")

        let second = await tools.run(item.tool)
        #expect(second == .wrote(path("Invoice (\(item.suffix)) 2.pdf")), "\(item), second run: \(second)")
        try expectUntouched(file, original, "\(item), second run")

        #expect(PDFKitSerialAccess.peakConcurrentParses <= 1)
        #expect(!files().contains { $0.hasPrefix(".tmp_") }, "\(item) left staging behind: \(files())")
    }

    // MARK: Writing — never over anything

    /// **A file that appears after the name was chosen is refused by the write, not replaced** — the
    /// name chooser here answers from a stale look at the folder, as a sync landing a file in between
    /// would leave it. `createNew` refuses with `RENAME_EXCL`; `write` would have swapped it out.
    @Test func aCopyNeverReplacesAFileThatAppearedUnderItsName() throws {
        let original = path("Statement.pdf")
        PDFFixtures.write(original, pages: 1)
        let taken = path("Statement (rotated).pdf")
        let sentinel = Data("somebody else's file".utf8)
        try sentinel.write(to: URL(fileURLWithPath: taken))

        var asked = 0
        let landed = try EditorPDFCopyWriter.write(Data("%PDF-new".utf8), besides: original, suffix: "rotated",
                                                   chooseName: { wanted, refused in
            asked += 1
            // The stale answer: the first look missed the file now sitting there.
            return refused.isEmpty ? wanted : FileSyncManager.generateUniqueURL(for: wanted, reserved: refused)
        })
        #expect(landed == path("Statement (rotated) 2.pdf"))
        #expect(try Data(contentsOf: URL(fileURLWithPath: taken)) == sentinel, "the file under the name was replaced")
        #expect(asked == 2)
        #expect(!files().contains { $0.hasPrefix(".tmp_") }, "staging left behind: \(files())")
    }

    // MARK: Names

    @Test func theCopysNameSaysWhatWasDone() {
        #expect(EditorPDFCopyName.firstChoice(for: "/a/Invoice.pdf", suffix: "compressed") == "/a/Invoice (compressed).pdf")
        #expect(EditorPDFCopyName.firstChoice(for: "/a/scan.PDF", suffix: "rotated") == "/a/scan (rotated).pdf")
        #expect(EditorPDFTool.extract([2, 3, 4, 0]).suffix == "pages 3–5, 1")
        #expect(EditorPDFTool.extract([6]).suffix == "page 7")
        // Past a readable length the name is just "extract".
        let scattered = stride(from: 0, to: 40, by: 2).map { $0 }
        #expect(EditorPDFTool.extract(scattered).suffix == "extract")
        #expect(EditorPDFPageMenu.rangeText([1, 2, 3, 6]) == "2-4, 7")
    }

    // MARK: Rotate

    /// **Exactly the pages asked for turn**, and by the amount asked.
    @Test func rotateTurnsExactlyTheSelectedPages() async throws {
        let file = path("Four.pdf")
        PDFFixtures.write(file, pages: 4)
        let tools = tools(file)
        let outcome = await tools.run(.rotate(pages: [1, 3], quarterTurns: 1))
        guard case .wrote(let copy) = outcome else { Issue.record("\(outcome)"); return }
        let rotations = try #require(PDFDocument(url: URL(fileURLWithPath: copy))).pageRotations
        #expect(rotations == [0, 90, 0, 90], "rotations: \(rotations)")

        let left = await tools.run(.rotate(pages: [0], quarterTurns: -1))
        guard case .wrote(let leftCopy) = left else { Issue.record("\(left)"); return }
        #expect(try #require(PDFDocument(url: URL(fileURLWithPath: leftCopy))).pageRotations == [270, 0, 0, 0])
    }

    // MARK: Delete

    /// **Deleting every page is refused before the lane is asked**, and nothing is written.
    @Test func deletingEveryPageIsRefused() async {
        let file = path("Two.pdf")
        PDFFixtures.write(file, pages: 2)
        let tools = tools(file)
        let outcome = await tools.run(.deletePages([0, 1]))
        #expect(outcome == .failed(PDFOperationError.cannotRemoveEveryPage.errorDescription!))
        #expect(files() == ["Two.pdf"], "something was written: \(files())")
        #expect(tools.banner?.kind == .failure)
        // BEFORE the lane: on a path with no file there, the toolkit would say it couldn't open it.
        let unread = EditorPDFTools()
        unread.attach(path: path("not-there.pdf"), pageCount: 2, encryption: .none)
        #expect(await unread.run(.deletePages([1, 0])) == .failed(PDFOperationError.cannotRemoveEveryPage.errorDescription!))
        // The sheet refuses it before the button can be pressed, too.
        #expect(EditorPDFPageRangeSheet.parse("1-2", action: .delete, pageCount: 2).pages == nil)
    }

    // MARK: Reorder

    /// **An order that is not a permutation is refused** — the toolkit would keep a repeated page
    /// twice and drop the missing one, under the name "reordered".
    @Test func reorderValidatesThePermutation() async {
        let file = path("Three.pdf")
        PDFFixtures.write(file, pages: 3)
        let tools = tools(file)
        for order in [[0, 0, 2], [0, 1], [2, 1, 0, 3], [0, 1, 2]] {
            let outcome = await tools.run(.reorder(order))
            guard case .failed = outcome else { Issue.record("\(order) ran: \(outcome)"); continue }
        }
        #expect(files() == ["Three.pdf"], "something was written: \(files())")
        #expect(EditorPDFToolEngine.isPermutation([2, 0, 1], pageCount: 3))
    }

    /// **A drag is a pending order, written nowhere** until Save; Reset puts the pages back; Save
    /// writes the copy in the dragged order and the pending order goes.
    @Test func aDraggedOrderIsWrittenOnlyOnSave() async throws {
        let file = path("Three.pdf")
        PDFFixtures.write(file, pages: 3)
        let original = try pin(file)
        let tools = tools(file)

        tools.move([0], onto: 2)
        #expect(tools.arrangement == [1, 2, 0])
        #expect(tools.order == [1, 2, 0])
        // Turns of the lane and the main actor, for any write a drag might have started.
        for _ in 0..<5 { await PDFKitSerialAccess.perform {}; await Task.yield() }
        #expect(files() == ["Three.pdf"], "a drag wrote something: \(files())")

        tools.resetArrangement()
        #expect(tools.arrangement == nil)
        #expect(tools.order == [0, 1, 2])

        tools.move([2], onto: 0)
        #expect(tools.arrangement == [2, 0, 1])
        // Dragged back to where it was: no arrangement at all.
        tools.move([2], onto: 1)
        #expect(tools.arrangement == nil, "the identity is kept as an arrangement: \(String(describing: tools.arrangement))")

        tools.move([2], onto: 0)
        let saved = await tools.saveArrangement()
        guard case .wrote(let copy) = saved else { Issue.record("\(saved)"); return }
        #expect(copy == path("Three (reordered).pdf"))
        #expect(texts(copy) == ["Page 3", "Page 1", "Page 2"], "pages: \(texts(copy))")
        #expect(tools.arrangement == nil)
        try expectUntouched(file, original, "reorder")
    }

    /// **Leaving with a pending order asks first** — No keeps it and stays; Yes drops it. With no
    /// pending order nothing is asked.
    @Test func leavingWithAnUnsavedOrderAsksFirst() async {
        let file = path("Three.pdf")
        PDFFixtures.write(file, pages: 3)
        let pdf = EditorPDFDocument(isCloudOnly: { _ in false })
        var asked = 0
        var answer = false
        pdf.tools.confirmDiscardingArrangement = { asked += 1; return answer }
        #expect(pdf.tools.confirmLeaving())
        #expect(asked == 0, "asked with nothing to lose")

        pdf.open(path: file, log: { _ in })
        for _ in 0..<1000 where pdf.phase == .loading { await PDFKitSerialAccess.perform {} }
        #expect(pdf.phase == .open)
        pdf.tools.move([0], onto: 1)
        #expect(pdf.tools.arrangement != nil)

        #expect(!pdf.tools.confirmLeaving(), "a declined question still let the document go")
        #expect(asked == 1)
        #expect(pdf.tools.arrangement == [1, 0, 2], "a declined question dropped the order")

        answer = true
        #expect(pdf.tools.confirmLeaving())
        #expect(asked == 2)
        #expect(pdf.tools.arrangement == nil)
        pdf.close()
    }

    /// **A different document clears the selection and the pending order**; the same one reloaded
    /// with the same pages keeps them.
    @Test func theSelectionAndOrderBelongToOneDocument() {
        let tools = EditorPDFTools()
        tools.attach(path: "/a/one.pdf", pageCount: 3, encryption: .none)
        tools.click(1, .plain)
        tools.move([0], onto: 2)
        tools.attach(path: "/a/one.pdf", pageCount: 3, encryption: .none)
        #expect(tools.selection.pages == [1] && tools.arrangement != nil)
        tools.attach(path: "/a/two.pdf", pageCount: 3, encryption: .none)
        #expect(tools.selection.pages.isEmpty && tools.arrangement == nil)
    }

    // MARK: Selection

    @Test func clickSelectsCommandTogglesShiftExtends() {
        var selection = EditorPDFPageSelection()
        let order = [0, 1, 2, 3, 4]
        selection.click(1, .plain, order: order)
        #expect(selection.pages == [1])
        selection.click(3, .extend, order: order)
        #expect(selection.pages == [1, 2, 3])
        selection.click(2, .toggle, order: order)
        #expect(selection.pages == [1, 3])
        selection.click(4, .plain, order: order)
        #expect(selection.pages == [4])
        // Extends over the pages as SHOWN — a pending order is not page order.
        selection.click(4, .plain, order: [4, 0, 2, 1, 3])
        selection.click(2, .extend, order: [4, 0, 2, 1, 3])
        #expect(selection.pages == [4, 0, 2])
        #expect(selection.target(for: 0, order: [4, 0, 2, 1, 3]) == [4, 0, 2])
        #expect(selection.target(for: 3, order: [4, 0, 2, 1, 3]) == [3], "a page outside the selection is its own target")
        #expect(EditorPDFPageSelection.click(for: [.command]) == .toggle)
        #expect(EditorPDFPageSelection.click(for: [.shift]) == .extend)
        #expect(EditorPDFPageSelection.click(for: []) == .plain)
    }

    @Test func aDroppedPageTakesTheTargetsPlace() {
        #expect(EditorPDFArrangement.moving([0], onto: 2, in: [0, 1, 2, 3]) == [1, 2, 0, 3])
        #expect(EditorPDFArrangement.moving([3], onto: 1, in: [0, 1, 2, 3]) == [0, 3, 1, 2])
        #expect(EditorPDFArrangement.moving([0, 2], onto: 3, in: [0, 1, 2, 3]) == [1, 3, 0, 2])
        #expect(EditorPDFArrangement.moving([1], onto: 1, in: [0, 1, 2]) == [0, 1, 2])
        let mine = UUID(), theirs = UUID()
        #expect(EditorPDFPageDrag.page(in: EditorPDFPageDrag.payload(token: mine, page: 4), token: mine) == 4)
        #expect(EditorPDFPageDrag.page(in: EditorPDFPageDrag.payload(token: theirs, page: 4), token: mine) == nil,
                "a page from another PDF was taken for a reorder")
        #expect(EditorPDFPageDrag.page(in: "4", token: mine) == nil)
    }

    // MARK: Extract

    /// **Extract keeps the order typed** — "3-5, 1" is pages 3, 4, 5 and then 1, named for it.
    @Test func extractKeepsTheOrderTyped() async throws {
        let file = path("Five.pdf")
        PDFFixtures.write(file, pages: 5)
        let tools = tools(file)
        let parsed = EditorPDFPageRangeSheet.parse("3-5, 1", action: .extract, pageCount: 5)
        let pages = try #require(parsed.pages)
        #expect(pages == [2, 3, 4, 0])
        let outcome = await tools.run(.extract(pages))
        #expect(outcome == .wrote(path("Five (pages 3–5, 1).pdf")))
        #expect(texts(path("Five (pages 3–5, 1).pdf")) == ["Page 3", "Page 4", "Page 5", "Page 1"])
        #expect(EditorPDFPageRangeSheet.parse("", action: .extract, pageCount: 5).pages == nil, "blank means everything")
        #expect(EditorPDFPageRangeSheet.parse("9", action: .extract, pageCount: 5).pages == nil)
    }

    // MARK: Compress

    /// **A compress that does not help writes nothing** — a lean text PDF redrawn as images comes
    /// back no smaller, and the toolkit hands back the original's bytes.
    @Test func aCompressThatDoesNotHelpWritesNothing() async throws {
        let file = path("Lean.pdf")
        PDFFixtures.write(file, pages: 2)
        let original = try pin(file)
        let tools = tools(file)
        let outcome = await tools.run(.compress(.quality(0.85)))
        #expect(outcome == .nothingWritten("Already about as small as this compression gets — nothing was written."))
        #expect(files() == ["Lean.pdf"], "written: \(files())")
        try expectUntouched(file, original, "no-gain compress")
    }

    /// **Cancel stops the run between pages and leaves nothing** — no copy, no `.tmp_` orphan.
    /// Cancelled as soon as the run has begun, so the lane meets the flag before its first page
    /// whatever the load: what is measured is what Cancel leaves, not a race with the lane.
    @Test func cancellingACompressLeavesNoFile() async throws {
        let file = path("Scan.pdf")
        PDFFixtures.writeScan(file, pages: 4)
        let tools = tools(file)
        let run = Task { await tools.run(.compress(.quality(0.35))) }
        for _ in 0..<10_000 where tools.running == nil { await Task.yield() }
        try #require(tools.running != nil, "the run never began")
        tools.cancelRun()
        let outcome = await run.value
        #expect(outcome == .cancelled, "\(outcome)")
        #expect(files() == ["Scan.pdf"], "a cancelled run left: \(files())")
        #expect(tools.banner?.message == "Compress cancelled — nothing was written.")
        #expect(tools.running == nil)
    }

    /// **Compress's progress reaches the main actor** — every page, ending on the last — however late
    /// the hops land behind the lane. Bounded in main-actor turns, not seconds.
    @Test func compressProgressReachesTheMainActor() async throws {
        let file = path("Scan.pdf")
        PDFFixtures.writeScan(file, pages: 3)
        let tools = tools(file)
        let outcome = await tools.run(.compress(.quality(0.35)))
        guard case .wrote = outcome else { Issue.record("\(outcome)"); return }
        for _ in 0..<10_000 where tools.progressReports < 3 { await Task.yield() }
        #expect(tools.progressReports == 3, "reports reaching the main actor: \(tools.progressReports)")
        #expect(tools.progress == EditorPDFTools.Progress(page: 3, total: 3), "\(String(describing: tools.progress))")
    }

    /// **A size target**: one the file already meets is said and nothing written; one no setting
    /// reaches writes the smallest and says it missed, giving the size; one that is met says the sizes.
    @Test func compressToATargetSaysWhatHappened() async throws {
        let file = path("Scan.pdf")
        PDFFixtures.writeScan(file, pages: 2)
        let size = try #require(EditorFileStore.stamp(ofPath: file)?.size)
        let tools = tools(file)

        let fits = await tools.run(.compress(.target(bytes: size + 1)))
        guard case .nothingWritten(let already) = fits else { Issue.record("\(fits)"); return }
        #expect(already.contains("already") && already.contains("nothing was written"), "\(already)")
        #expect(files() == ["Scan.pdf"])

        let missed = await tools.run(.compress(.target(bytes: 1_000)))
        guard case .wrote(let copy) = missed else { Issue.record("\(missed)"); return }
        let copySize = try #require(EditorFileStore.stamp(ofPath: copy)?.size)
        #expect(copySize > 1_000 && copySize < size)
        let message = try #require(tools.banner?.message)
        #expect(message.contains("No setting reached") && message.contains(FileSyncManager.formatBytes(copySize)),
                "\(message)")

        let met = await tools.run(.compress(.target(bytes: size - 1)))
        guard case .wrote = met else { Issue.record("\(met)"); return }
        let sizes = try #require(tools.banner?.message)
        #expect(sizes.contains("→") && !sizes.contains("No setting reached"), "\(sizes)")
    }

    // MARK: Fidelity

    /// **The form warning is pdf-utils' per tool**: Compress flattens, Extract and Reorder orphan,
    /// and Rotate and Delete lose nothing — and it is asked only of a file that HAS a form. Declining
    /// writes nothing.
    @Test func aFormWarnsOnCompressExtractAndReorderOnly() async throws {
        let form = path("Form.pdf")
        try PDFFixtures.writeAcroForm(form)
        let plain = path("Plain.pdf")
        PDFFixtures.write(plain, pages: 2)

        let asking: [(EditorPDFTool, String?)] = [
            (.compress(.quality(0.35)), "Form fields will be flattened"),
            (.extract([1, 0]), "Form fields will stop working"),
            (.reorder([1, 0]), "Form fields will stop working"),
            (.rotate(pages: [0], quarterTurns: 1), nil),
            (.deletePages([1]), nil),
        ]
        for (tool, title) in asking {
            let tools = tools(form)
            var asked: [String] = []
            tools.confirm = { warning, _ in asked.append(warning.confirmationTitle); return false }
            let outcome = await tools.run(tool)
            if let title {
                #expect(asked == [title], "\(tool.title): asked \(asked)")
                #expect(outcome == .declined, "\(tool.title): \(outcome)")
            } else {
                #expect(asked.isEmpty, "\(tool.title) warned: \(asked)")
                guard case .wrote = outcome else { Issue.record("\(tool.title): \(outcome)"); continue }
            }
            // The same tools on a file with no form never ask.
            let plainTools = self.tools(plain)
            var plainAsked = 0
            plainTools.confirm = { _, _ in plainAsked += 1; return false }
            _ = await plainTools.run(tool)
            #expect(plainAsked == 0, "\(tool.title) warned about a file with no form")
        }
        let declinedCopies = files().filter {
            ["Form (compressed).pdf", "Form (pages 2, 1).pdf", "Form (reordered).pdf"].contains($0)
        }
        #expect(files().contains("Form (rotated).pdf") && files().contains("Form (pages removed).pdf"),
                "the tools that lose nothing did not write: \(files())")
        #expect(declinedCopies.isEmpty, "a declined warning still wrote: \(declinedCopies)")
    }

    // MARK: Encryption

    /// **A file locked to open offers Remove Password and nothing else**, with the reason; read in
    /// the lane when the PDF opens.
    @Test func aFileLockedToOpenOffersOnlyRemovePassword() async throws {
        let file = path("Locked.pdf")
        PDFFixtures.writeLocked(file, password: "open-sesame")
        let pdf = EditorPDFDocument(isCloudOnly: { _ in false })
        pdf.open(path: file, log: { _ in })
        for _ in 0..<1000 where pdf.phase == .loading { await PDFKitSerialAccess.perform {} }
        #expect(pdf.phase == .locked)
        let tools = pdf.tools
        #expect(tools.encryption == .lockedToOpen)
        #expect(!tools.offersPageTools && !tools.offersMetadata && !tools.offersProtect)
        #expect(tools.offersRemovePassword)
        #expect(tools.disabledReason == "Remove the password first. That writes an unlocked copy.")

        // Unlocking it in the reader does not unlock the file the tools open.
        #expect(await pdf.unlock(password: "open-sesame"))
        #expect(tools.encryption == .lockedToOpen && !tools.offersPageTools)
        #expect(tools.pageCount == 2)
        pdf.close()
        #expect(tools.encryption == nil && tools.path == nil)
    }

    /// **A restricted file opens, offers the page tools, and a page tool that cannot run on it says
    /// why in the toolkit's words.** Clean Metadata and Protect are not offered at all.
    @Test func aRestrictedFileShowsTheToolkitsMessage() async throws {
        let file = path("Statement.pdf")
        PDFFixtures.writeRestricted(file)
        let pdf = EditorPDFDocument(isCloudOnly: { _ in false })
        pdf.open(path: file, log: { _ in })
        for _ in 0..<1000 where pdf.phase == .loading { await PDFKitSerialAccess.perform {} }
        let tools = pdf.tools
        #expect(tools.encryption == .restrictedOnly)
        #expect(tools.offersPageTools && tools.offersRemovePassword)
        #expect(!tools.offersMetadata && !tools.offersProtect)

        let outcome = await tools.run(.rotate(pages: [0], quarterTurns: 1))
        let expected = PDFOperationError.permissionsForbidEditing(URL(fileURLWithPath: file)).errorDescription!
        #expect(outcome == .failed(expected), "\(outcome)")
        #expect(tools.banner?.message == expected && tools.banner?.kind == .failure)
        #expect(files() == ["Statement.pdf"])
        pdf.close()
    }

    // MARK: Passwords

    /// **No password reaches the log** — not Protect's, not Remove Password's, not a wrong one —
    /// nor the description of the tool that carries it.
    @Test func passwordsNeverAppearInTheLog() async throws {
        let log = LogCapture()
        let secret = "Zebra-Quartz-9931"
        let file = path("Plain.pdf")
        PDFFixtures.write(file, pages: 2)
        let tool = EditorPDFTool.protect(restrictEditing: false, password: EditorPDFSecret(secret))
        #expect(!"\(tool)".contains(secret) && !String(reflecting: tool).contains(secret))
        #expect(!"\(EditorPDFSecret(secret))".contains(secret) && !String(reflecting: EditorPDFSecret(secret)).contains(secret))

        let protected = await tools(file).run(tool)
        guard case .wrote(let copy) = protected else { Issue.record("\(protected)"); return }
        #expect(PDFDocument(url: URL(fileURLWithPath: copy))?.isLocked == true, "the copy doesn't need a password")

        let lockedTools = tools(copy, encryption: .lockedToOpen)
        let wrong = await lockedTools.run(.removePassword(EditorPDFSecret(secret + "-wrong")))
        #expect(wrong == .failed(PDFOperationError.incorrectPassword.errorDescription!))
        let unlocked = await lockedTools.run(.removePassword(EditorPDFSecret(secret)))
        guard case .wrote(let open) = unlocked else { Issue.record("\(unlocked)"); return }
        #expect(PDFDocument(url: URL(fileURLWithPath: open))?.isLocked == false)

        let entries = await log.entries
        #expect(entries.contains { $0.message.contains("Edit wrote") && $0.message.contains("Plain (protected).pdf") },
                "the protect run was not logged at all — the absence below would be vacuous")
        let leaked = entries.filter { $0.message.contains(secret) }
        #expect(leaked.isEmpty, "a password reached the log: \(leaked.map(\.message))")
    }

    /// **The log line says what was written, from what, and how** — with sizes for Compress.
    @Test func aCopyIsLoggedWithWhatWasDone() async throws {
        let log = LogCapture()
        let file = path("Ledger-\(UUID().uuidString.prefix(6)).pdf")
        PDFFixtures.writeScan(file, pages: 2)
        let name = (file as NSString).lastPathComponent
        let base = (name as NSString).deletingPathExtension
        _ = await tools(file).run(.compress(.quality(0.35)))
        let line = try #require(await log.line(containing: "Edit wrote \(base) (compressed).pdf from \(name)"))
        #expect(line.contains("compress 0.35") && line.contains("→"), "\(line)")
    }

    // MARK: What the review found

    /// **A symlinked PDF compresses** — the toolkit measures the source with a call that does not
    /// follow a link, so it is handed the file itself; the copy is still named beside the link.
    @Test func aSymlinkedPDFCompresses() async throws {
        let real = path("real-scan.pdf")
        PDFFixtures.writeScan(real, pages: 2)
        let link = path("Scan.pdf")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
        let outcome = await tools(link).run(.compress(.quality(0.35)))
        #expect(outcome == .wrote(path("Scan (compressed).pdf")), "\(outcome)")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link)) == real, "the link was replaced")
    }

    /// **Cancel holds for every tool**, not only Compress's page loop — pressed while the run waits
    /// for the lane, it still writes nothing.
    @Test func cancelStopsAToolThatHasNoPageLoop() async {
        let file = path("Four.pdf")
        PDFFixtures.write(file, pages: 4)
        let tools = tools(file)
        let run = Task { await tools.run(.rotate(pages: [0], quarterTurns: 1)) }
        for _ in 0..<10_000 where tools.running == nil { await Task.yield() }
        tools.cancelRun()
        #expect(await run.value == .cancelled)
        #expect(files() == ["Four.pdf"], "a cancelled rotate wrote: \(files())")
    }

    /// **A run that ends after its file was closed says nothing about the next one** — no banner,
    /// no running state carried over.
    @Test func aRunThatOutlivesItsFileLeavesTheNextOneAlone() async {
        let file = path("Four.pdf")
        PDFFixtures.write(file, pages: 4)
        let tools = tools(file)
        let run = Task { await tools.run(.rotate(pages: [0], quarterTurns: 1)) }
        for _ in 0..<10_000 where tools.running == nil { await Task.yield() }
        tools.detach()
        tools.attach(path: path("Other.pdf"), pageCount: 2, encryption: .none)
        _ = await run.value
        #expect(tools.banner == nil, "the closed file's run spoke on the next: \(tools.banner?.message ?? "")")
        #expect(tools.running == nil)
    }

    /// **No drop is taken where no reorder can be saved** — a file locked to open, or while a run is
    /// in flight, whose save would clear an order dragged since.
    @Test func aReorderIsRefusedWhereItCouldNotBeSaved() async {
        let locked = EditorPDFTools()
        locked.attach(path: "/a/locked.pdf", pageCount: 3, encryption: .lockedToOpen)
        locked.move([0], onto: 2)
        #expect(locked.arrangement == nil && !locked.acceptsReorder)

        let file = path("Three.pdf")
        PDFFixtures.write(file, pages: 3)
        let tools = tools(file)
        tools.move([0], onto: 2)
        let save = Task { await tools.saveArrangement() }
        for _ in 0..<10_000 where tools.running == nil { await Task.yield() }
        tools.move([2], onto: 1)
        #expect(tools.arrangement == [1, 2, 0], "a drop was taken while the save ran")
        guard case .wrote = await save.value else { Issue.record("the save did not write"); return }
        #expect(tools.arrangement == nil)
    }

    /// **The same file changed on disk under a pending order drops the order, and says so.**
    @Test func anOrderDroppedByAChangeOnDiskIsSaid() {
        let tools = EditorPDFTools()
        tools.attach(path: "/a/one.pdf", pageCount: 3, encryption: .none)
        tools.move([0], onto: 2)
        tools.attach(path: "/a/one.pdf", pageCount: 4, encryption: .none)
        #expect(tools.arrangement == nil)
        #expect(tools.banner?.message == "The file changed on disk, so the new page order was dropped.")
    }

    /// **A password survives no reflection** — `dump` walks a value's mirror, not its description.
    @Test func aPasswordSurvivesNoReflection() {
        let secret = "Plover-Sextant-4417"
        var dumped = ""
        dump(EditorPDFTool.removePassword(EditorPDFSecret(secret)), to: &dumped)
        #expect(!dumped.contains(secret), "dump printed it: \(dumped)")
        #expect(Mirror(reflecting: EditorPDFSecret(secret)).children.isEmpty)
    }

    /// The target field's text, read on the button rather than when the field commits.
    @Test func aTypedTargetIsReadAsTyped() {
        #expect(EditorPDFCompressSheet.megabytes("1.5") == 1.5)
        #expect(EditorPDFCompressSheet.megabytes(" 2,5 ") == 2.5)
        #expect(EditorPDFCompressSheet.megabytes("0") == nil)
        #expect(EditorPDFCompressSheet.megabytes("lots") == nil)
        #expect(EditorPDFCompression.bytes(megabytes: 1e300) == 500_000_000)
        #expect(EditorPDFCompression.bytes(megabytes: 0.01) == 100_000)
    }
}


private extension PDFDocument {
    var pageRotations: [Int] { (0..<pageCount).map { page(at: $0)?.rotation ?? -1 } }
}

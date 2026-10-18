import Testing
import os
import AppKit
import PDFKit
import PDFToolkitCore
import SwiftUI
import Design
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

    /// **Leaving with a pending order asks first** — No keeps it and stays; Yes lets the document
    /// go, and the order goes only when it really does (the close), so a leave that fails after the
    /// answer keeps it. With no pending order nothing is asked.
    @Test func leavingWithAnUnsavedOrderAsksFirst() async {
        let file = path("Three.pdf")
        PDFFixtures.write(file, pages: 3)
        let pdf = EditorPDFDocument(isCloudOnly: { _ in false })
        var asked = 0
        var answer = false
        pdf.tools.confirmDiscardingArrangement = { asked += 1; return answer }
        #expect(pdf.tools.mayLeave())
        #expect(asked == 0, "asked with nothing to lose")

        pdf.open(path: file, log: { _ in })
        for _ in 0..<1000 where pdf.phase == .loading { await PDFKitSerialAccess.perform {} }
        #expect(pdf.phase == .open)
        pdf.tools.move([0], onto: 1)
        #expect(pdf.tools.arrangement != nil)

        #expect(!pdf.tools.mayLeave(), "a declined question still let the document go")
        #expect(asked == 1)
        #expect(pdf.tools.arrangement == [1, 0, 2], "a declined question dropped the order")

        answer = true
        #expect(pdf.tools.mayLeave())
        #expect(asked == 2)
        #expect(pdf.tools.arrangement == [1, 0, 2],
                "the answer dropped the order before the leave happened — a leave that then fails loses it")
        pdf.close()
        #expect(pdf.tools.arrangement == nil, "the close kept the order")
    }

    /// **A tool still running is asked about too**, in the words of what stops — and nothing is
    /// asked once it has finished.
    @Test func leavingWhileAToolRunsAsksFirst() async throws {
        let file = path("Four.pdf")
        PDFFixtures.write(file, pages: 4)
        let tools = tools(file)
        var asked = 0
        tools.confirmDiscardingArrangement = { asked += 1; return false }
        let run = Task { await tools.run(.rotate(pages: [0], quarterTurns: 1)) }
        for _ in 0..<10_000 where tools.running == nil { await Task.yield() }
        try #require(tools.running != nil, "the run never began")
        #expect(tools.hasWorkToLose)
        #expect(!tools.mayLeave())
        #expect(asked == 1)
        _ = await run.value
        #expect(tools.mayLeave() && asked == 1, "asked again with nothing running")
        let question = EditorPDFTools.leaveQuestion(running: "Compress", hasArrangement: true)
        #expect(question.title == "Stop Compress?" && question.detail.contains("new page order is discarded too"))
        #expect(EditorPDFTools.leaveQuestion(running: nil, hasArrangement: true).go == "Discard")
    }

    /// **A different document clears the selection and the pending order**; the same one reloaded
    /// with the same pages keeps them.
    @Test func theSelectionAndOrderBelongToOneDocument() {
        let tools = EditorPDFTools()
        tools.attach(path: "/a/one.pdf", pageCount: 3, encryption: .none)
        tools.click(1, .plain)
        tools.move([0], onto: 2)
        tools.attach(path: "/a/one.pdf", pageCount: 3, encryption: .none)
        // A reload of the same file: the selection stays, the pending order goes (said in its own test).
        #expect(tools.selection.pages == [1] && tools.arrangement == nil)
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

    /// **Cancel stops Compress BETWEEN PAGES and leaves nothing** — no copy, no `.tmp_` orphan.
    ///
    /// Cancelled from inside the lane, at page 2, through the run's own flag: the main actor could
    /// otherwise see its first report only after the lane had finished. What proves the toolkit
    /// stopped — rather than the run finishing and the cancel being caught afterwards — is that no
    /// page past 2 was ever begun.
    @Test func cancellingACompressStopsBetweenPagesAndLeavesNoFile() async throws {
        let file = path("Scan.pdf")
        PDFFixtures.writeScan(file, pages: 5)
        let tools = tools(file)
        let reached = OSAllocatedUnfairLock(initialState: 0)
        tools.laneProgressHook = { page, _, flag in
            reached.withLock { $0 = max($0, page) }
            if page == 2 { flag.cancel() }
        }
        let outcome = await tools.run(.compress(.quality(0.35)))
        #expect(outcome == .cancelled, "\(outcome)")
        #expect(reached.withLock { $0 } == 2, "the toolkit went on past the cancel, to page \(reached.withLock { $0 })")
        #expect(files() == ["Scan.pdf"], "a cancelled run left: \(files())")
        #expect(tools.banner?.message == "Compress cancelled — nothing was written.")
        #expect(tools.running == nil)
    }

    /// **Cancel pressed while the run still waits for the lane** writes nothing either.
    @Test func cancellingACompressBeforeItStartsLeavesNoFile() async throws {
        let file = path("Scan.pdf")
        PDFFixtures.writeScan(file, pages: 2)
        let tools = tools(file)
        let run = Task { await tools.run(.compress(.quality(0.35))) }
        for _ in 0..<10_000 where tools.running == nil { await Task.yield() }
        try #require(tools.running != nil, "the run never began")
        tools.cancelRun()
        #expect(await run.value == .cancelled)
        #expect(files() == ["Scan.pdf"], "a cancelled run left: \(files())")
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
        #expect(tools.progress?.total == 3, "\(String(describing: tools.progress))")
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
        // A name of its own, so the presence check below is not satisfied by a sibling's line.
        let stem = "Plain-\(UUID().uuidString.prefix(8))"
        let file = path("\(stem).pdf")
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
        #expect(entries.contains { $0.message.contains("Edit wrote") && $0.message.contains("\(stem) (protected).pdf") },
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
    @Test func cancelStopsAToolThatHasNoPageLoop() async throws {
        let file = path("Four.pdf")
        PDFFixtures.write(file, pages: 4)
        let tools = tools(file)
        let run = Task { await tools.run(.rotate(pages: [0], quarterTurns: 1)) }
        for _ in 0..<10_000 where tools.running == nil { await Task.yield() }
        try #require(tools.running != nil, "the run never began")
        tools.cancelRun()
        #expect(await run.value == .cancelled)
        #expect(files() == ["Four.pdf"], "a cancelled rotate wrote: \(files())")
    }

    /// **A run that ends after its file was closed says nothing about the next one** — no banner,
    /// no running state carried over.
    @Test func aRunThatOutlivesItsFileLeavesTheNextOneAlone() async throws {
        let file = path("Four.pdf")
        PDFFixtures.write(file, pages: 4)
        let tools = tools(file)
        let run = Task { await tools.run(.rotate(pages: [0], quarterTurns: 1)) }
        for _ in 0..<10_000 where tools.running == nil { await Task.yield() }
        try #require(tools.running != nil, "the run never began")
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

    /// **The same file changed on disk under a pending order drops the order, and says so** —
    /// with the same page count too, since the pages may now say something else. The selection
    /// stays while the count does.
    @Test func anOrderDroppedByAChangeOnDiskIsSaid() {
        for count in [4, 3] {
            let tools = EditorPDFTools()
            tools.attach(path: "/a/one.pdf", pageCount: 3, encryption: .none)
            tools.click(1, .plain)
            tools.move([0], onto: 2)
            tools.attach(path: "/a/one.pdf", pageCount: count, encryption: .none)
            #expect(tools.arrangement == nil, "count \(count)")
            #expect(tools.banner?.message == "The file changed on disk, so the new page order was dropped.")
            #expect(tools.selection.pages == (count == 3 ? [1] : []), "count \(count): \(tools.selection.pages)")
        }
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
        #expect(EditorPDFCompression.megabytes("1.5") == 1.5)
        #expect(EditorPDFCompression.megabytes(" 2,5 ") == 2.5)
        #expect(EditorPDFCompression.megabytes("1,000") == 1000, "a thousands comma read as a decimal point")
        #expect(EditorPDFCompression.megabytes("1,000.5") == 1000.5)
        #expect(EditorPDFCompression.megabytes("0") == nil)
        #expect(EditorPDFCompression.megabytes("lots") == nil)
        #expect(EditorPDFCompression.bytes(megabytes: 1e300) == 1_000_000_000_000)
        #expect(EditorPDFCompression.bytes(megabytes: 0.01) == 100_000)
        // Past pdf-utils' 500 MB, a target is still a target: a file under it is told so.
        #expect(EditorPDFCompression.bytes(megabytes: 1000) == 1_000_000_000)
    }

    // MARK: The second review

    /// **A sheet closes when its run says something, and stays when it failed or was declined** —
    /// a failure is shown in place, beside the field that caused it.
    @Test func aSheetClosesOnlyWhenItsRunEnded() async {
        let file = path("Three.pdf")
        PDFFixtures.write(file, pages: 3)
        let tools = tools(file)
        tools.sheet = .pages(.extract, prefill: "")
        #expect(await tools.runFromSheet(.extract([1])) == nil)
        #expect(tools.sheet == nil, "a copy that landed left its sheet up")

        tools.sheet = .pages(.delete, prefill: "")
        let failure = await tools.runFromSheet(.deletePages([0, 1, 2]))
        #expect(failure == PDFOperationError.cannotRemoveEveryPage.errorDescription)
        #expect(tools.sheet == .pages(.delete, prefill: ""), "a failed run closed its sheet")
        #expect(tools.banner?.kind != .failure, "a sheet's failure was ALSO put on the banner")

        let form = path("Form.pdf")
        try? PDFFixtures.writeAcroForm(form)
        let formTools = self.tools(form)
        formTools.confirm = { _, _ in false }
        formTools.sheet = .compress
        #expect(await formTools.runFromSheet(.compress(.quality(0.35))) == nil)
        #expect(formTools.sheet == .compress, "a declined warning closed the sheet")
    }

    /// **The window hears of a copy exactly once, and only of a copy** — never of a failure, a
    /// refusal or a compress that gained nothing.
    @Test func theWindowHearsOfEachCopyOnce() async {
        let file = path("Lean.pdf")
        PDFFixtures.write(file, pages: 3)
        let tools = tools(file)
        var written: [String] = []
        tools.host = EditorPDFToolHost(didWrite: { written.append($0) })
        _ = await tools.run(.rotate(pages: [0], quarterTurns: 1))
        #expect(written == [path("Lean (rotated).pdf")])
        _ = await tools.run(.deletePages([0, 1, 2]))
        _ = await tools.run(.compress(.quality(0.85)))
        _ = await tools.run(.reorder([0, 0, 1]))
        #expect(written == [path("Lean (rotated).pdf")], "the window heard of something that wrote nothing: \(written)")
    }

    /// **A second run while one is in flight is refused as a failure** — so a sheet keeps itself
    /// up and says why, rather than closing as if it had run.
    @Test func aRunWhileAnotherRunsIsRefused() async throws {
        let file = path("Four.pdf")
        PDFFixtures.write(file, pages: 4)
        let tools = tools(file)
        let first = Task { await tools.run(.rotate(pages: [0], quarterTurns: 1)) }
        for _ in 0..<10_000 where tools.running == nil { await Task.yield() }
        try #require(tools.running != nil, "the run never began")
        let second = await tools.run(.rotate(pages: [1], quarterTurns: 1))
        guard case .failed(let why) = second else { Issue.record("\(second)"); return }
        #expect(why.contains("still running"))
        guard case .wrote = await first.value else { Issue.record("the first run did not write"); return }
    }

    /// **The Tools menu, as the reader meets it** — what each kind of file offers, and the
    /// selection's own lines.
    @Test func theToolsMenuOffersWhatTheFileAllows() {
        func enabled(_ tools: EditorPDFTools) -> Set<String> {
            Set(EditorPDFToolsMenuEntry.entries(tools).filter(\.enabled).map { ($0.submenu.map { $0 + " ▸ " } ?? "") + $0.title })
        }
        let plain = EditorPDFTools()
        plain.attach(path: "/a/plain.pdf", pageCount: 3, encryption: .none)
        #expect(enabled(plain) == ["Rotate All Pages ▸ Rotate Left", "Rotate All Pages ▸ Rotate Right",
                                   "Rotate All Pages ▸ Rotate 180°", "Extract Pages…", "Delete Pages…",
                                   "Compress…", "Clean Metadata…", "Protect with Password…"])

        plain.click(2, .plain)
        plain.click(0, .toggle)
        let entries = EditorPDFToolsMenuEntry.entries(plain)
        #expect(entries.first?.submenu == "Rotate 2 Selected Pages")
        #expect(entries.first?.action == .run(.rotate(pages: [0, 2], quarterTurns: -1)))
        #expect(entries.contains { $0.action == .sheet(.pages(.delete, prefill: "1, 3")) })

        let locked = EditorPDFTools()
        locked.attach(path: "/a/locked.pdf", pageCount: 0, encryption: .lockedToOpen)
        let lockedEntries = EditorPDFToolsMenuEntry.entries(locked)
        #expect(lockedEntries.first == EditorPDFToolsMenuEntry(title: EditorPDFTools.lockedReason, enabled: false,
                                                                action: .none))
        #expect(enabled(locked) == ["Remove Password…"])

        let restricted = EditorPDFTools()
        restricted.attach(path: "/a/restricted.pdf", pageCount: 3, encryption: .restrictedOnly)
        #expect(enabled(restricted).contains("Remove Password…") && enabled(restricted).contains("Compress…"))
        #expect(EditorPDFToolsMenuEntry.entries(restricted).contains {
            $0.title == EditorPDFTools.metadataEncryptedReason && !$0.enabled
        })
        #expect(EditorPDFTools.metadataEncryptedReason.count <= 64, "a menu row does not wrap")

        let one = EditorPDFTools()
        one.attach(path: "/a/one.pdf", pageCount: 1, encryption: .none)
        #expect(!enabled(one).contains("Delete Pages…"), "a one-page file offers to delete its only page")
    }

    /// **The page field reads what it prefills and what it shows** — hyphens, en dashes from the
    /// copy's own name, and a Delete range.
    @Test func thePageFieldReadsItsOwnWords() throws {
        let pages = [1, 2, 3, 6]
        let text = EditorPDFPageMenu.rangeText(pages)
        #expect(text == "2-4, 7")
        #expect(EditorPDFPageRangeSheet.parse(text, action: .extract, pageCount: 8).pages == pages)
        #expect(EditorPDFPageRangeSheet.parse("3–5, 1", action: .extract, pageCount: 8).pages == [2, 3, 4, 0],
                "the copy name's en dash is not read back")
        let delete = EditorPDFPageRangeSheet.parse("4, 1-2", action: .delete, pageCount: 5)
        #expect(delete.pages == [0, 1, 3] && delete.caption.contains("pages removed"))
        let blank = EditorPDFPageRangeSheet.parse("  ", action: .extract, pageCount: 5)
        #expect(blank.pages == nil && blank.isBlank, "a blank field reads as an error before anything is typed")
    }

    /// **Clean Metadata's copy carries no metadata** — the fields the file had are gone, not only
    /// renamed.
    @Test func cleanMetadataClearsTheCopy() async throws {
        let file = path("Word.pdf")
        var box = CGRect(origin: .zero, size: PDFFixtures.letter)
        let info: [CFString: Any] = [kCGPDFContextTitle: "Quarterly", kCGPDFContextAuthor: "A. Person",
                                     kCGPDFContextCreator: "Microsoft Word"]
        let context = try #require(CGContext(URL(fileURLWithPath: file) as CFURL, mediaBox: &box, info as CFDictionary))
        context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
        let read = await EditorPDFMetadataSheet.read(path: file)
        guard case .success(let before) = read else { Issue.record("\(read)"); return }
        #expect(before.fields.title == "Quarterly" && before.fields.author == "A. Person" && !before.hasForm)

        let outcome = await tools(file).run(.cleanMetadata(.cleared))
        guard case .wrote(let copy) = outcome else { Issue.record("\(outcome)"); return }
        let after = try #require(PDFDocument(url: URL(fileURLWithPath: copy))?.documentAttributes)
        #expect(after[PDFDocumentAttribute.titleAttribute] == nil && after[PDFDocumentAttribute.authorAttribute] == nil,
                "the copy still says: \(after)")
    }

    /// **Restrict editing writes a restricted copy, and Remove Password lifts it with nothing typed**
    /// — the toolkit cannot check an owner password on a file that opens freely.
    @Test func restrictEditingRoundTrips() async throws {
        let file = path("Plain.pdf")
        PDFFixtures.write(file, pages: 2)
        let outcome = await tools(file).run(.protect(restrictEditing: true, password: EditorPDFSecret("owner-9")))
        guard case .wrote(let copy) = outcome else { Issue.record("\(outcome)"); return }
        #expect(PDFToolkit.encryptionState(of: URL(fileURLWithPath: copy)) == .restrictedOnly)

        let lifted = await tools(copy, encryption: .restrictedOnly).run(.removePassword(EditorPDFSecret("")))
        guard case .wrote(let open) = lifted else { Issue.record("\(lifted)"); return }
        #expect(PDFToolkit.encryptionState(of: URL(fileURLWithPath: open)) == PDFEncryptionState.none)
    }

    /// **A copy of a restricted file says it is not restricted** — the rebuilding tools write a fresh
    /// document, and that is the reader's to know.
    @Test func aCopyOfARestrictedFileSaysItIsNotRestricted() async {
        let file = path("Statement.pdf")
        PDFFixtures.writeRestricted(file)
        let tools = tools(file, encryption: .restrictedOnly)
        guard case .wrote = await tools.run(.extract([0])) else { Issue.record("extract did not write"); return }
        #expect(tools.banner?.message.hasSuffix("The copy has no editing restrictions") == true,
                "\(tools.banner?.message ?? "")")
    }

    /// **A name near the volume's limit still gets a copy** — the base is shortened, a whole
    /// character at a time, so the name fits the volume's 255 with room for " 2". "é" because it is
    /// two units once decomposed, which is how the limit counts.
    @Test func aVeryLongNameStillGetsACopy() async throws {
        let base = String(repeating: "é", count: 120) + "-statement"   // 250 units decomposed
        let file = path("\(base).pdf")
        PDFFixtures.write(file, pages: 2)
        let tools = tools(file)
        for _ in 0..<2 {
            let outcome = await tools.run(.rotate(pages: [0], quarterTurns: 1))
            guard case .wrote(let copy) = outcome else { Issue.record("\(outcome)"); return }
            let name = (copy as NSString).lastPathComponent
            #expect(EditorPDFCopyName.nameLength(name) <= 255 && name.contains("(rotated)"),
                    "\(EditorPDFCopyName.nameLength(name)): \(name)")
        }
        #expect(files().filter { $0.contains("(rotated)") }.count == 2)
    }

    /// **A file evicted to the cloud since it opened is refused before the lane** — opening a
    /// dataless file there downloads it on the lane every duplicate scan waits on.
    @Test func aCloudOnlyFileIsRefusedBeforeTheLane() async {
        let tools = EditorPDFTools()
        tools.attach(path: path("not-there.pdf"), pageCount: 3, encryption: .none)
        tools.isCloudOnly = { _ in true }
        #expect(await tools.run(.compress(.quality(0.35))) == .failed(EditorPDFDocument.notDownloadedReason))
    }

    /// **A copy that has since gone is said to be gone** — the banner's Open does not silently do
    /// nothing.
    @Test func aBannerDoorToAGoneCopySaysSo() {
        let tools = EditorPDFTools()
        var opened: [String] = []
        tools.follow(path("gone.pdf")) { opened.append($0) }
        #expect(opened.isEmpty)
        #expect(tools.banner?.message == "“gone.pdf” is no longer there — it was moved or deleted.")
    }

    /// **VoiceOver's reorder is the drag's** — one place at a time, a pending order like any other.
    @Test func moveEarlierAndLaterReorder() {
        let tools = EditorPDFTools()
        tools.attach(path: "/a/x.pdf", pageCount: 3, encryption: .none)
        tools.step(2, by: -1)
        #expect(tools.arrangement == [0, 2, 1])
        tools.step(0, by: -1)
        #expect(tools.arrangement == [0, 2, 1], "moved past the start")
        tools.step(2, by: 1)
        #expect(tools.arrangement == nil, "back to the file's order is no arrangement")
        tools.selectAll()
        #expect(tools.selection.pages == [0, 1, 2])
        tools.clearSelection()
        #expect(tools.selection.pages.isEmpty)
    }

    /// **Every way a run ends is in the log** — a refusal, a decline and a cancel included, so a
    /// copy that never appeared is explained there.
    @Test func everyEndingIsLogged() async throws {
        let log = LogCapture()
        let stem = "Logged-\(UUID().uuidString.prefix(8))"
        let form = path("\(stem).pdf")
        try PDFFixtures.writeAcroForm(form)
        let tools = tools(form)
        tools.confirm = { _, _ in false }
        _ = await tools.run(.deletePages([0, 1]))
        _ = await tools.run(.extract([0]))
        tools.laneProgressHook = { _, _, flag in flag.cancel() }
        tools.confirm = { _, _ in true }
        _ = await tools.run(.compress(.quality(0.35)))
        let lines = await log.entries.map(\.message).filter { $0.contains(stem) }
        #expect(lines.contains { $0.hasPrefix("Edit refused delete") && $0.contains(" in \(folder)") }, "\(lines)")
        #expect(lines.contains { $0.hasPrefix("Edit did not extract") && $0.contains("declined") }, "\(lines)")
        #expect(lines.contains { $0.hasPrefix("Edit cancelled compress") }, "\(lines)")
    }

    /// **The Tools menu fits the header's pinned card at every text size** — open, where it sits
    /// beside the page controls, and locked, where it is the only control. The header's height is
    /// pinned to the pane toolbar card's, so rows taller than the pin would be clipped, not grown.
    @Test func theToolsMenuFitsTheHeaderAtEveryTextSize() async throws {
        let open = path("Open.pdf"), locked = path("Locked.pdf")
        PDFFixtures.write(open, pages: 3)
        PDFFixtures.writeLocked(locked, password: "pw")
        for (file, phase) in [(open, EditorPDFDocument.Phase.open), (locked, .locked)] {
            let pdf = EditorPDFDocument(isCloudOnly: { _ in false })
            pdf.open(path: file, log: { _ in })
            for _ in 0..<1000 where pdf.phase == .loading { await PDFKitSerialAccess.perform {} }
            try #require(pdf.phase == phase, "\(file) opened as \(pdf.phase)")
            for scale in FontSize.allCases.map(\.scale) {
                let rows = NSHostingView(rootView: AnyView(
                    EditorDocumentHeader {
                        EditorPDFHeader(pdf: pdf, accent: .blue, onAccent: .white, onRevealInBrowse: { _ in },
                                        onClose: {}) { EmptyView() }
                    }
                    .environment(\.appFontScale, scale)
                    .frame(width: 520)))
                rows.frame = CGRect(x: 0, y: 0, width: 520, height: 200)
                rows.layoutSubtreeIfNeeded()
                #expect(rows.fittingSize.height <= LiquidGlass.headerHeight,
                        "\(phase) at \(scale): the rows need \(rows.fittingSize.height)pt in a \(LiquidGlass.headerHeight)pt card")
            }
            pdf.close()
        }
    }

    /// **A file closed while the form warning is up writes nothing** — the answer comes back for a
    /// file no longer open, and is not acted on.
    @Test func aCloseDuringTheFormWarningWritesNothing() async throws {
        let form = path("Form.pdf")
        try PDFFixtures.writeAcroForm(form)
        let tools = tools(form)
        tools.confirm = { _, _ in tools.detach(); return true }
        #expect(await tools.run(.extract([0])) == .cancelled)
        #expect(files() == ["Form.pdf"], "a closed file's run still wrote: \(files())")
        #expect(tools.banner == nil)
    }
}


private extension PDFDocument {
    var pageRotations: [Int] { (0..<pageCount).map { page(at: $0)?.rotation ?? -1 } }
}

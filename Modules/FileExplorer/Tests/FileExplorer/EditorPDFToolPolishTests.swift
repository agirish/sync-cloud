import Testing
import AppKit
import PDFKit
import PDFToolkitCore
import SwiftUI
import Sync
@testable import FileExplorer

/// **The 2026-10-20 polish of the PDF tools** (TE99–TE142): what each sheet says while it works,
/// what Clean Metadata opens with, where Compress's size starts, the Delete key's rule, a batch's
/// reasons, and the sentences that name a run.
///
/// The sheets are hosted for real where AppKit can be read back — a SwiftUI `TextField` is an
/// `NSTextField` and a `ProgressView` an `NSProgressIndicator` — so the rule and the view that
/// draws it are held together. Serialized: every run is in `PDFKitSerialAccess`'s one lane.
@MainActor
@Suite(.serialized) final class EditorPDFToolPolishTests {

    let folder = NSTemporaryDirectory() + "editor-pdf-polish-" + UUID().uuidString

    init() throws {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(atPath: folder) }

    private func path(_ name: String) -> String { (folder as NSString).appendingPathComponent(name) }

    private func tools(_ file: String, pageCount: Int? = nil) -> EditorPDFTools {
        let tools = EditorPDFTools()
        let count = pageCount ?? PDFDocument(url: URL(fileURLWithPath: file))?.pageCount ?? 0
        tools.attach(path: file, pageCount: count, encryption: .none)
        tools.confirm = { _, _ in true }
        tools.confirmDiscardingArrangement = { true }
        return tools
    }

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

    /// A sheet in a window that is never ordered in — laid out and appeared, off everyone's screen.
    private func host(_ view: some View, width: CGFloat = 420, height: CGFloat = 420) -> (NSWindow, NSHostingView<AnyView>) {
        let host = NSHostingView(rootView: AnyView(view.frame(width: width, height: height)))
        host.frame = CGRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return (window, host)
    }

    private static func subviews<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        view.subviews.flatMap { ($0 as? T).map { [$0] } ?? [] + subviews(type, in: $0) }
    }

    private static func spinners(in view: NSView) -> Int {
        view.layoutSubtreeIfNeeded()
        return subviews(NSProgressIndicator.self, in: view).filter { !$0.isHidden }.count
    }

    // MARK: TE99 — Clean Metadata on one file opens cleared

    /// **The form opens cleared, with the file's values kept for the placeholders**, and each button
    /// only does something when it would change the fields (decision AW).
    @Test func theMetadataFormOpensClearedAndKeepsTheFilesValuesToHand() {
        let file = PDFMetadataFields(title: "Quarterly", author: "A. Person", creator: "Microsoft Word", producer: "Quartz")
        var form = EditorPDFMetadataForm(current: file)
        #expect(form.fields.isCleared, "the sheet opens with the file's own values: \(form.fields)")
        #expect(form.current == file)
        #expect(form.canKeepCurrentValues && !form.canClearAll)

        form.keepCurrentValues()
        #expect(form.fields == file)
        #expect(!form.canKeepCurrentValues && form.canClearAll)

        form.fields.title = "Edited"
        #expect(form.canKeepCurrentValues && form.canClearAll)
        form.clearAll()
        #expect(form.fields.isCleared && !form.canClearAll)

        #expect(!EditorPDFMetadataForm(current: .cleared).canKeepCurrentValues,
                "a file with no metadata offers to keep the none it has")
    }

    /// **The sheet itself opens cleared, the file's title greyed in its field** — read from the hosted
    /// `NSTextField`s, so a sheet that went back to filling its fields fails here, not only the model.
    @Test func theMetadataSheetShowsTheFilesValuesAsPlaceholders() async throws {
        let file = path("Word.pdf")
        var box = CGRect(origin: .zero, size: PDFFixtures.letter)
        let info: [CFString: Any] = [kCGPDFContextTitle: "Quarterly", kCGPDFContextAuthor: "A. Person"]
        let context = try #require(CGContext(URL(fileURLWithPath: file) as CFURL, mediaBox: &box, info as CFDictionary))
        context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
        let tools = tools(file)
        let (window, host) = host(EditorPDFToolSheetView(tools: tools, sheet: .metadata, accentFill: .blue), height: 460)
        defer { window.contentView = nil }

        var fields: [NSTextField] = []
        await wait("the sheet's fields") {
            host.layoutSubtreeIfNeeded()
            fields = Self.subviews(NSTextField.self, in: host).filter(\.isEditable)
            return fields.count == 5
        }
        #expect(fields.map(\.stringValue) == ["", "", "", "", ""], "the fields opened filled: \(fields.map(\.stringValue))")
        #expect(fields.prefix(2).map { $0.placeholderString ?? "" } == ["Quarterly", "A. Person"],
                "the file's values are not the placeholders: \(fields.map { $0.placeholderString ?? "nil" })")
    }

    // MARK: TE105 — every sheet shows it is working

    @Test func theWorkingCaptionIsForEverySheetButOneWithItsOwnProgress() {
        #expect(EditorPDFToolSheetFrame<EmptyView>.workingCaption(isRunning: true, drawsOwnProgress: false) == "Writing the copy…")
        #expect(EditorPDFToolSheetFrame<EmptyView>.workingCaption(isRunning: false, drawsOwnProgress: false) == nil)
        #expect(EditorPDFToolSheetFrame<EmptyView>.workingCaption(isRunning: true, drawsOwnProgress: true) == nil)
    }

    /// **A sheet that was silent while its run worked now spins** — Extract's, hosted, read while the
    /// copy is being written. Idle it draws no spinner; Compress, which has its own progress row,
    /// draws one, not two.
    @Test func aRunningSheetDrawsItsSpinner() async throws {
        let file = path("Pages.pdf")
        PDFFixtures.write(file, pages: 3)
        let tools = tools(file)
        let sheet = EditorPDFToolSheet.pages(.extract, prefill: "2")
        tools.sheet = sheet
        let (window, host) = host(EditorPDFToolSheetView(tools: tools, sheet: sheet, accentFill: .blue))
        defer { window.contentView = nil }
        #expect(Self.spinners(in: host) == 0, "an idle sheet spins")

        var whileWriting: Int?
        tools.writeStartedHook = { whileWriting = Self.spinners(in: host) }
        _ = await tools.runFromSheet(.extract([1]))
        #expect(whileWriting == 1, "Extract's sheet drew \(String(describing: whileWriting)) spinners while it wrote")

        let scan = path("Scan.pdf")
        PDFFixtures.writeScan(scan, pages: 2)
        let compressing = self.tools(scan)
        compressing.sheet = .compress
        let (compressWindow, compressHost) = self.host(EditorPDFToolSheetView(tools: compressing, sheet: .compress, accentFill: .blue))
        defer { compressWindow.contentView = nil }
        var compressWhileWriting: Int?
        compressing.writeStartedHook = { compressWhileWriting = Self.spinners(in: compressHost) }
        let outcome = await compressing.runFromSheet(.compress(.quality(0.35)))
        #expect(outcome == nil)
        #expect(compressWhileWriting == 1,
                "Compress drew \(String(describing: compressWhileWriting)) progress views — its row and the frame's both")
    }

    // MARK: TE106 — the Delete key keeps the menus' rule

    /// **Delete in the Pages tab does what the greyed menu item does: nothing** — on every page
    /// selected, and on a one-page file. A selection that leaves a page asks for the sheet.
    @Test func theDeleteKeyKeepsTheMenusRule() {
        let three = EditorPDFTools()
        three.attach(path: "/a/three.pdf", pageCount: 3, encryption: .none)
        three.selectAll()
        #expect(!three.deleteSelectedPages() && three.sheet == nil, "every page selected opened \(String(describing: three.sheet))")
        #expect(!three.mayDelete([0, 1, 2]))

        three.click(0, .plain)
        three.click(1, .extend)
        #expect(three.deleteSelectedPages())
        #expect(three.sheet == .pages(.delete, prefill: "1-2"))

        let one = EditorPDFTools()
        one.attach(path: "/a/one.pdf", pageCount: 1, encryption: .none)
        one.click(0, .plain)
        #expect(!one.deleteSelectedPages() && one.sheet == nil, "a one-page file opened \(String(describing: one.sheet))")
        #expect(!one.mayDelete([]), "the Tools menu offers to delete a one-page file's only page")
        #expect(three.mayDelete([]), "the Tools menu's unselected Delete Pages… is offered on three pages")
    }

    /// The key and both menus ask the one rule — read from their source, since a `.contextMenu` body
    /// and an `.onKeyPress` handler never run in a package test.
    @Test func theKeyAndBothMenusAskTheOneRule() throws {
        let rail = try EditorRailRowMenuTests.source("EditorPDFRailViews.swift")
        #expect(rail.contains("tools.deleteSelectedPages() ? .handled : .ignored"), "the Delete key decides for itself")
        #expect(rail.contains(".disabled(!tools.mayDelete(pages))"), "the Pages tab's menu decides for itself")
        let menu = try EditorRailRowMenuTests.source("EditorPDFToolViews.swift")
        #expect(menu.contains("enabled: pages && tools.mayDelete(selected)"), "the Tools menu decides for itself")
    }

    // MARK: TE113 — a batch keeps its reasons

    /// **An unreadable file fails with its reason named in the detail**, under a summary that only
    /// counts — and "PDFKit" is nowhere in it (TE122).
    @Test func aBatchNamesTheFileItCouldNotRead() async throws {
        let junk = path("Junk.pdf"), plain = path("Plain.pdf")
        try Data("not a PDF at all".utf8).write(to: URL(fileURLWithPath: junk))
        PDFFixtures.write(plain, pages: 1)
        let batch = EditorPDFBatch(kind: .rotate(quarterTurns: 1), paths: [junk, plain], writer: "PDF Tools in Browse")
        batch.isCloudOnly = { _ in false }
        await batch.run(.rotate(quarterTurns: 1))
        #expect(batch.banner?.message == "Saved 1 rotated copy · 1 failed")
        #expect(batch.banner?.detail == "“Junk.pdf” — couldn’t read this PDF", "\(String(describing: batch.banner?.detail))")
    }

    /// Past five files the detail says how many more, rather than standing over the panes.
    @Test func theReasonsStopAtFiveAndCountTheRest() {
        let files = (1...7).map { ("\($0).pdf", EditorPDFBatch.Status.skipped(.alreadySmall)) }
            + [("8.pdf", .skipped(.cancelled)), ("9.pdf", .wrote("x", sizes: nil))]
        let lines = EditorPDFBatch.reasons(files)?.components(separatedBy: "\n")
        #expect(lines == ["“1.pdf” — already small", "“2.pdf” — already small", "“3.pdf” — already small",
                          "“4.pdf” — already small", "“5.pdf” — already small", "and 2 more"])
        #expect(EditorPDFBatch.reasons([("a.pdf", .wrote("x", sizes: nil)), ("b.pdf", .skipped(.cancelled))]) == nil)
    }

    // MARK: TE142 — Compress's size target starts under the file

    @Test func theSizeTargetStartsAtAboutHalfTheFileAndNeverAboveTwo() {
        #expect(EditorPDFCompression.startingTarget(forSize: 1_400_000) == "0.7")
        #expect(EditorPDFCompression.startingTarget(forSize: 3_000_000) == "1.5")
        #expect(EditorPDFCompression.startingTarget(forSize: 4_000_000) == "2")
        #expect(EditorPDFCompression.startingTarget(forSize: 80_000_000) == "2")
        #expect(EditorPDFCompression.startingTarget(forSize: 50_000) == "0.1", "under the 0.1 MB floor")
        #expect(EditorPDFCompression.startingTarget(forSize: nil) == "2")
        // What the field says is what the run reads, and it comes in under the file.
        let typed = EditorPDFCompression.startingTarget(forSize: 1_400_000)
        let target = EditorPDFCompression.megabytes(typed).map(EditorPDFCompression.bytes(megabytes:))
        #expect(target == 700_000)
    }

    /// **The hosted sheet's field says it** — "To a size" chosen through its segmented control, then
    /// the field read back: a sheet that still started at "2" fails here.
    @Test func theCompressSheetsFieldStartsUnderTheFile() async throws {
        let file = path("Scan.pdf")
        PDFFixtures.writeScan(file, pages: 1, pixels: 600)
        let size = try #require(EditorFileStore.stamp(ofPath: file)?.size)
        let expected = EditorPDFCompression.startingTarget(forSize: size)
        try #require(expected != "2", "the fixture is \(size) bytes — too big to tell the new start from the old")
        let tools = tools(file)
        let (window, host) = host(EditorPDFToolSheetView(tools: tools, sheet: .compress, accentFill: .blue))
        defer { window.contentView = nil }

        let segments = try #require(Self.subviews(NSSegmentedControl.self, in: host).first, "no segmented control")
        segments.selectedSegment = 1
        _ = segments.sendAction(segments.action, to: segments.target)
        var field: NSTextField?
        await wait("the size field") {
            host.layoutSubtreeIfNeeded()
            field = Self.subviews(NSTextField.self, in: host).first(where: \.isEditable)
            return field?.stringValue == expected
        }
        #expect(field?.stringValue == expected, "the field says \(String(describing: field?.stringValue)) for \(size) bytes")
    }

    // MARK: TE127 — sentences, not tool names

    @Test func aRunIsNamedInASentence() {
        let rotate = EditorPDFTools.Running(.rotate(pages: [0], quarterTurns: 1))
        let question = EditorPDFTools.leaveQuestion(running: rotate, hasArrangement: false)
        #expect(question.title == "Stop rotating the pages?")
        #expect(question.detail == "The pages are still being rotated. Leaving stops it, and nothing is written. "
                + "The original file is unchanged either way.")
        #expect(EditorPDFTools.Running(.protect(restrictEditing: false, password: EditorPDFSecret("x"))).sentence
                == "Protecting with a password")
        // A rotate in the dragged order is still a rotate.
        #expect(EditorPDFTool.arranged(order: [1, 0], then: .rotate(pages: [0], quarterTurns: 1)).doing == "rotating the pages")

        #expect(EditorPDFToolBannerView.runningMessage(rotate, progress: nil) == "Rotating the pages…",
                "a tool that reports no pages said it was waiting for the whole run")
        let compress = EditorPDFTools.Running(.compress(.quality(0.6)))
        #expect(EditorPDFToolBannerView.runningMessage(compress, progress: nil) == "Compressing — waiting for other PDF work…")
        #expect(EditorPDFToolBannerView.runningMessage(compress, progress: .init(page: 4, total: 12))
                == "Compressing — page 4 of 12")
    }

    // MARK: TE128 — the page menu names the pages

    @Test func thePageMenuNamesThePagesItRotates() {
        #expect(EditorPDFPageMenu.rotateTitle([1, 2, 3], "Left") == "Rotate 3 Pages Left")
        #expect(EditorPDFPageMenu.rotateTitle([4], "180°") == "Rotate Page 5 180°")
        #expect(EditorPDFPageMenu.title("Extract", [1, 2, 3]) == "Extract 3 Pages…")
    }

    // MARK: TE137 — the current page's ring sits inside the selected wash

    /// **The ring's corners stay inside the wash's** — read in pixels from the mounted grid, the
    /// first page current and selected. The ring's own box is found by its strong accent; the wash by
    /// its pale one. Square corners 4 pt out sat on the wash's edge, past its rounding.
    @Test func theCurrentPagesRingSitsInsideTheSelectedWash() async throws {
        let file = path("Ring.pdf")
        PDFFixtures.write(file, pages: 4)
        let pdf = EditorPDFDocument(isCloudOnly: { _ in false })
        pdf.open(path: file, log: { _ in })
        await wait("the open") { pdf.phase == .open }
        pdf.tools.click(0, .plain)
        let grid = EditorPDFRailPages(pdf: pdf, view: pdf.view, thumbnails: pdf.thumbnails, tools: pdf.tools, accent: .blue, accentFill: .blue)
        // On an opaque ground: over a clear one the wash reads back as full-strength accent.
        let (window, host) = host(grid.background(Color.white), width: 232, height: 300)
        defer { window.contentView = nil; pdf.close() }
        await wait("the first thumbnail") {
            window.layoutIfNeeded()
            return pdf.thumbnails.images[0] != nil
        }
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: NSTemporaryDirectory() + "pdf-ring-te137.png"))

        let scale = CGFloat(rep.pixelsWide) / host.bounds.width
        func box(_ matches: (NSColor) -> Bool) -> (minX: Int, minY: Int, maxX: Int, maxY: Int)? {
            var found: (Int, Int, Int, Int)?
            // The first cell only: the left half of the grid's top.
            for y in 0..<Int(200 * scale) {
                for x in 0..<Int(116 * scale) {
                    guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), matches(color) else { continue }
                    found = found.map { (min($0.0, x), min($0.1, y), max($0.2, x), max($0.3, y)) } ?? (x, y, x, y)
                }
            }
            return found.map { (minX: $0.0, minY: $0.1, maxX: $0.2, maxY: $0.3) }
        }
        let strong = { (c: NSColor) in c.blueComponent > 0.85 && c.redComponent < 0.35 }
        let pale = { (c: NSColor) in c.blueComponent - c.redComponent > 0.06 && c.redComponent > 0.6 }
        let ring = try #require(box(strong), "no ring drawn")
        let wash = try #require(box(pale), "no wash drawn")
        #expect(ring.minX > wash.minX && ring.minY > wash.minY && ring.maxX < wash.maxX && ring.maxY < wash.maxY,
                "the ring \(ring) reaches the wash's edge \(wash)")
        // The ring's own corner is rounded: a point 1 pt in from its box's corner is outside a 6 pt
        // curve, and inside a 2 pt one's stroke.
        let inset = Int(scale.rounded())
        let corner = rep.colorAt(x: ring.minX + inset, y: ring.minY + inset)?.usingColorSpace(.sRGB)
        #expect(corner.map(strong) == false, "the ring's corner is square: \(String(describing: corner))")
    }
}

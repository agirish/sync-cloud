import Testing
import os
import AppKit
import PDFKit
import PDFToolkitCore
import SwiftUI
import Sync
@testable import FileExplorer
import FileExplorerTestSupport

/// Real PDFs on disk, made the way a reader meets them: pages with a text layer, pages that are
/// only a picture (a scan), a password, and bytes that are not a PDF at all.
enum PDFFixtures {
    static let letter = CGSize(width: 612, height: 792)

    static func write(_ path: String, pages: Int, size: CGSize = letter, text: Bool = true) {
        var box = CGRect(origin: .zero, size: size)
        let context = CGContext(URL(fileURLWithPath: path) as CFURL, mediaBox: &box, nil)!
        for index in 0..<pages {
            context.beginPDFPage(nil)
            if text {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
                ("Page \(index + 1)" as NSString).draw(at: NSPoint(x: 72, y: size.height - 120),
                                                       withAttributes: [.font: NSFont.systemFont(ofSize: 24)])
                NSGraphicsContext.restoreGraphicsState()
            } else {
                context.setFillColor(gray: 0.4, alpha: 1)
                context.fill(CGRect(x: 72, y: 72, width: 200, height: 200))
            }
            context.endPDFPage()
        }
        context.closePDF()
    }

    static func writeLocked(_ path: String, password: String, pages: Int = 2) {
        let plain = path + ".plain.pdf"
        write(plain, pages: pages)
        let document = PDFDocument(url: URL(fileURLWithPath: plain))!
        document.write(to: URL(fileURLWithPath: path),
                       withOptions: [.userPasswordOption: password, .ownerPasswordOption: password + "-owner"])
        try? FileManager.default.removeItem(atPath: plain)
    }
}

/// **Counts `PDFDocument(url:)` per path, process-wide** — by replacing `-[PDFDocument
/// initWithURL:]` with a counting trampoline the first time it is asked, for the whole test
/// process. Behaviour is unchanged: the original runs with the same arguments. Counted per PATH, so
/// a sibling suite opening its own files in parallel never moves another test's count.
///
/// The trampoline passes raw pointers, never objects: an `init` consumes `self` and returns +1,
/// which a Swift closure of objects cannot say, so ARC is kept out of it entirely.
enum PDFURLOpens {
    private static let counts = OSAllocatedUnfairLock(initialState: [String: Int]())

    static func count(_ path: String) -> Int {
        _ = installed
        return counts.withLock { $0[path, default: 0] }
    }

    private static let installed: Void = {
        let selector = #selector(PDFDocument.init(url:))
        let method = class_getInstanceMethod(PDFDocument.self, selector)!
        typealias Init = @convention(c) (UnsafeRawPointer, Selector, UnsafeRawPointer) -> UnsafeRawPointer?
        let original = unsafeBitCast(method_getImplementation(method), to: Init.self)
        let counting: @convention(block) (UnsafeRawPointer, UnsafeRawPointer) -> UnsafeRawPointer? = { object, url in
            if let path = Unmanaged<NSURL>.fromOpaque(url).takeUnretainedValue().path {
                counts.withLock { $0[path, default: 0] += 1 }
            }
            return original(object, selector, url)
        }
        method_setImplementation(method, imp_implementationWithBlock(counting))
    }()
}

/// **The read-only PDF model Edit shows instead of a text document** — `EditorPDFDocument`.
///
/// Serialized, because these open through `PDFKitSerialAccess`'s one lane (Phase 0's lesson: lane
/// work in parallel suites starves sibling waits). **Every wait is bounded in lane TURNS, not
/// seconds** (`docs/flaky-tests.md`, "The wait that hangs instead of failing"): in a full-package
/// run the lane is queued behind other suites' holds for minutes, which is congestion, not a
/// failure — while a load that never comes still fails, after its turns, naming what it waited for.
@MainActor
@Suite(.serialized) final class EditorPDFDocumentTests {

    let folder = NSTemporaryDirectory() + "editor-pdf-" + UUID().uuidString
    var lines: [String] = []
    /// Never the shared domain — see `EditorWorkspaceView.readingSettings(from:)`.
    private let defaults = ScratchDefaults("EditorPDFDocumentTests")

    init() throws {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(atPath: folder) }

    private func path(_ name: String) -> String { (folder as NSString).appendingPathComponent(name) }

    /// Waits until `done` holds, a lane turn and a short main-actor pause at a time — bounded, and a
    /// labeled failure rather than a hang when it never does.
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

    /// Runs `action` and waits for the model's next applied load; `nil` when none came.
    private func loaded(_ pdf: EditorPDFDocument, by action: () -> Void) async -> EditorPDFDocument.Phase? {
        var phases: [EditorPDFDocument.Phase] = []
        pdf.onLoaded = { phases.append($0) }
        defer { pdf.onLoaded = nil }
        action()
        await wait("a load of \(pdf.path ?? "nothing") to be applied") { !phases.isEmpty }
        return phases.first
    }

    private func open(_ pdf: EditorPDFDocument, _ file: String) async -> EditorPDFDocument.Phase? {
        await loaded(pdf) { pdf.open(path: file, log: { [weak self] in self?.lines.append($0) }) }
    }

    // MARK: Opening

    @Test func aPDFOpensWithItsFacts() async {
        let file = path("report.pdf")
        PDFFixtures.write(file, pages: 3)
        let pdf = EditorPDFDocument(isCloudOnly: { _ in false })
        #expect(await open(pdf, file) == .open)
        #expect(pdf.path == file)
        #expect(pdf.document != nil)
        let facts = try? #require(pdf.facts)
        #expect(facts?.pageCount == 3)
        #expect(pdf.view.pageCount == 3, "the view state cannot say what spread the reader is on")
        #expect(facts?.paperFact(page: 0) == "Letter, 8.5 × 11 in")
        #expect(facts?.hasText == true)
        #expect(facts?.fileSize != nil)
        #expect(lines.last == "Editor opened \(file) (PDF, 3 pages)")
    }

    /// A scan's pages are pictures: nothing to select, and the header's second row says so.
    @Test func aScanSaysImageOnly() async {
        let file = path("scan.pdf")
        PDFFixtures.write(file, pages: 2, size: CGSize(width: 595, height: 842), text: false)
        let pdf = EditorPDFDocument(isCloudOnly: { _ in false })
        #expect(await open(pdf, file) == .open)
        #expect(pdf.facts?.hasText == false)
        #expect(pdf.facts?.textCaption == "Image only")
        #expect(pdf.facts?.paperFact(page: 1) == "A4, 8.26 × 11.69 in")
    }

    /// **Bytes that are not a PDF are refused, not shown as text** — the mockup's "PDFKit couldn't
    /// read this file", with no document handed to any view.
    @Test func anUnreadableFileIsRefused() async throws {
        let file = path("broken.pdf")
        try Data("not a pdf at all".utf8).write(to: URL(fileURLWithPath: file))
        let pdf = EditorPDFDocument(isCloudOnly: { _ in false })
        #expect(await open(pdf, file) == .refused(EditorPDFDocument.unreadableReason))
        #expect(pdf.document == nil)
        #expect(pdf.refusal == EditorPDFDocument.unreadableReason)
        #expect(lines.last == "Editor could not open \(file) — \(EditorPDFDocument.unreadableReason)")
    }

    /// **A cloud-only PDF is never parsed in place** — `PDFDocument(url:)` would download it on the
    /// lane's thread. It is refused at once, in the text path's words, for the fetch-then-open path.
    @Test func aCloudOnlyFileIsRefusedWithoutAParse() async {
        let file = path("cloud.pdf")
        PDFFixtures.write(file, pages: 1)
        let pdf = EditorPDFDocument(isCloudOnly: { _ in true })
        var phases: [EditorPDFDocument.Phase] = []
        pdf.onLoaded = { phases.append($0) }
        pdf.open(path: file, log: { _ in })
        // Synchronous: no lane round trip happened.
        #expect(phases == [.refused(EditorPDFDocument.notDownloadedReason)])
        #expect(pdf.document == nil)
        #expect(pdf.refusal == EditorPDFDocument.notDownloadedReason)
    }

    // MARK: Locked

    /// **A locked PDF waits for its password, which is used once and kept nowhere.**
    @Test func aLockedPDFUnlocksWithItsPasswordAndNeverLogsIt() async {
        let file = path("locked.pdf")
        let secret = "correct-horse-\(UUID().uuidString.prefix(6))"
        PDFFixtures.writeLocked(file, password: secret, pages: 2)
        let pdf = EditorPDFDocument(isCloudOnly: { _ in false })
        #expect(await open(pdf, file) == .locked)
        #expect(pdf.document == nil, "a locked document must not reach the page view")
        #expect(!pdf.canPrint)

        #expect(await pdf.unlock(password: "wrong") == false)
        #expect(pdf.phase == .locked)
        #expect(await pdf.unlock(password: secret) == true)
        #expect(pdf.phase == .open)
        #expect(pdf.document != nil)
        #expect(pdf.facts?.pageCount == 2)
        #expect(lines.contains("Editor unlocked \(file) (PDF, 2 pages)"))
        #expect(!lines.contains { $0.contains(secret) || $0.contains("wrong") },
                "a password reached the log: \(lines)")
    }

    // MARK: Latest request wins, and closing releases

    /// Two opens in a row: the second file is what ends up open, whichever load lands first.
    @Test func theLatestOpenWins() async {
        let first = path("first.pdf"), second = path("second.pdf")
        PDFFixtures.write(first, pages: 4)
        PDFFixtures.write(second, pages: 2)
        let pdf = EditorPDFDocument(isCloudOnly: { _ in false })
        let phase = await loaded(pdf) {
            pdf.open(path: first, log: { _ in })
            pdf.open(path: second, log: { _ in })
        }
        #expect(phase == .open)
        #expect(pdf.path == second)
        #expect(pdf.facts?.pageCount == 2)
        #expect(pdf.document?.documentURL?.path == second)
        // Both loads back — the first was dropped, and it must not have replaced the second.
        await wait("both loads to come back") { pdf.loadsReturned >= 2 }
        #expect(pdf.document?.documentURL?.path == second)
    }

    /// **Close lets the document go** — the decoded pages of a long scan with it.
    @Test func closeReleasesTheDocument() async {
        let file = path("long.pdf")
        PDFFixtures.write(file, pages: 6)
        let pdf = EditorPDFDocument(isCloudOnly: { _ in false })
        #expect(await open(pdf, file) == .open)
        weak var held = pdf.document
        #expect(held != nil)
        pdf.close()
        #expect(pdf.path == nil && pdf.document == nil && pdf.facts == nil)
        // The lane's own work item may still be draining; let it, then the document must be gone.
        await PDFKitSerialAccess.perform {}
        for _ in 0..<100 where held != nil { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(held == nil, "the model let go, but something still holds the PDFDocument")
    }

    // MARK: The disk watch

    /// **A change on disk reloads through the lane on the page the reader was on.**
    @Test func aChangeOnDiskReloadsAndKeepsThePage() async throws {
        let file = path("growing.pdf")
        PDFFixtures.write(file, pages: 5)
        let pdf = EditorPDFDocument(settle: .milliseconds(50), isCloudOnly: { _ in false })
        #expect(await open(pdf, file) == .open)
        // As the view would report it: the reader is on page 4.
        pdf.view.currentPage = 3

        let phase = await loaded(pdf) {
            let replacement = self.path("replacement.pdf")
            PDFFixtures.write(replacement, pages: 6)
            _ = try? FileManager.default.replaceItemAt(URL(fileURLWithPath: file),
                                                       withItemAt: URL(fileURLWithPath: replacement))
        }
        #expect(phase == .open)
        #expect(pdf.facts?.pageCount == 6, "the reload did not read the new file")
        #expect(pdf.view.pageRequest?.value == 3, "the reload did not ask for the page the reader was on")
        #expect(lines.last == "Editor reloaded \(file) (PDF, 6 pages) — changed elsewhere; kept page 4")
    }

    /// **A new revision of a file evicted while open is not read** — reading it would download it,
    /// in the lane — as the text watch leaves an evicted text file alone. The reader keeps what it
    /// showed. (The settle is long so only the direct look below can reload.)
    @Test func aChangeToAFileEvictedWhileOpenIsNotDownloadedToShowIt() async throws {
        final class Flag { var cloudOnly = false }
        let flag = Flag()
        let file = path("evicted.pdf")
        PDFFixtures.write(file, pages: 5)
        let pdf = EditorPDFDocument(settle: .seconds(600), isCloudOnly: { _ in flag.cloudOnly })
        #expect(await open(pdf, file) == .open)
        let replacement = path("revision.pdf")
        PDFFixtures.write(replacement, pages: 6)
        _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: file), withItemAt: URL(fileURLWithPath: replacement))
        flag.cloudOnly = true
        let returned = pdf.loadsReturned
        pdf.look()
        #expect(pdf.facts?.pageCount == 5)
        // Back on disk, the same look reads it — and that is the only load that returns. A load the
        // evicted look had started would be withdrawn by this one and still return, ahead of it in
        // the lane, so the count decides the absence rather than a pump that may beat the load.
        flag.cloudOnly = false
        let phase = await loaded(pdf) { pdf.look() }
        #expect(phase == .open && pdf.facts?.pageCount == 6)
        #expect(pdf.loadsReturned == returned + 1, "the look at the evicted file started a load")
    }

    /// **A refusal that only said what happened says what to do next** — a file still in the cloud,
    /// one moved or deleted from under the reader. The damaged file's card has its own buttons.
    @Test func aRefusalSaysWhatToDoNext() {
        #expect(EditorPDFBody.nextStep(for: EditorPDFDocument.notDownloadedReason)?.contains("File ▸ Download") == true)
        #expect(EditorPDFBody.nextStep(for: EditorPDFDocument.goneReason)?.contains("Browse") == true)
        #expect(EditorPDFBody.nextStep(for: EditorPDFDocument.unreadableReason) == nil)
    }

    /// **The text probe reads the front and a spread to the end**, each page once, and never past it.
    @Test func theTextProbeReadsTheFrontAndASpreadToTheEnd() {
        #expect(EditorPDFFacts.textProbe(pageCount: 0) == [])
        #expect(EditorPDFFacts.textProbe(pageCount: 1) == [0])
        #expect(EditorPDFFacts.textProbe(pageCount: 7) == [0, 1, 2, 3, 4, 6])
        #expect(EditorPDFFacts.textProbe(pageCount: 1000) == [0, 1, 2, 3, 4, 199, 399, 599, 799, 999])
    }

    /// A file deleted from under the reader says so, and lets its document go.
    @Test func aDeletedFileSaysSo() async throws {
        let file = path("doomed.pdf")
        PDFFixtures.write(file, pages: 1)
        let pdf = EditorPDFDocument(settle: .milliseconds(50), isCloudOnly: { _ in false })
        #expect(await open(pdf, file) == .open)
        let phase = await loaded(pdf) { try? FileManager.default.removeItem(atPath: file) }
        #expect(phase == .refused(EditorPDFDocument.goneReason))
        #expect(pdf.document == nil)
    }

    // MARK: The lane

    /// **The open is in the lane**: with the lane held, the model stays loading and no document
    /// reaches it; released, it opens. A parse anywhere else would have opened behind the hold.
    @Test func theOpenWaitsForTheLane() async throws {
        let file = path("held.pdf")
        PDFFixtures.write(file, pages: 2)
        let pdf = EditorPDFDocument(isCloudOnly: { _ in false })
        let hold = LaneHold()
        defer { hold.release() }
        try #require(await hold.waitUntilHeld(), "the lane never came free to be held")

        pdf.open(path: file, log: { _ in })
        // The control: the same file parsed OFF the lane, to completion — so the model has had at
        // least as long as an off-lane parse needs, plus main-actor turns to apply it, before its
        // absence is believed. A bare sleep would be a guess that shrinks as the machine slows.
        let control = await Task.detached { PDFDocument(url: URL(fileURLWithPath: file))?.pageCount }.value
        #expect(control == 2, "fixture: the file does not parse even off the lane")
        for _ in 0..<10 { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(pdf.loadsReturned == 0 && pdf.phase == .loading && pdf.document == nil,
                "the PDF opened while the lane was held — the parse did not take its turn")

        hold.release()
        await wait("the held open to land once released") { pdf.phase != .loading }
        #expect(pdf.phase == .open)
    }

    /// **An open overtaken before its turn is never parsed** — the column preview's ticket. Arrowing
    /// through a folder of PDFs in Edit's pane would otherwise queue a parse per file passed over,
    /// each ahead of the one the reader stopped on.
    @Test func anOpenOvertakenBeforeItsTurnIsSkipped() async throws {
        let passed = path("passed-over.pdf"), stopped = path("stopped-on.pdf")
        PDFFixtures.write(passed, pages: 3)
        PDFFixtures.write(stopped, pages: 1)
        let pdf = EditorPDFDocument(isCloudOnly: { _ in false })
        let hold = LaneHold()
        defer { hold.release() }
        try #require(await hold.waitUntilHeld())
        let skippedBefore = pdf.skippedOpens
        pdf.open(path: passed, log: { _ in })
        pdf.open(path: stopped, log: { _ in })
        hold.release()
        await wait("both opens to come back") { pdf.loadsReturned >= 2 }
        // Exactly one: the count is this model's own, so nothing running alongside can add to it.
        #expect(pdf.skippedOpens - skippedBefore == 1, "the passed-over PDF was parsed anyway, or more than one open was withdrawn")
        #expect(pdf.path == stopped && pdf.facts?.pageCount == 1)
    }

    /// **A PDF's header draws no location line** — the text header's "in Finance" or "iCloud ›
    /// Documents › …" crumbs (asked 2026-10-17: "it doesn't make sense"). Its second row says what
    /// the file is; Reveal in Browse on the name is the way to where it lives. Read over the
    /// header's own body and its second row's, which close the file, so the text header's location
    /// line is untouched by this.
    @Test func thePDFHeaderDrawsNoLocationLine() throws {
        let card = try ChromeGlassWiringTests.source("EditorPDFCard.swift")
        let start = try #require(card.range(of: "struct EditorPDFHeader<Trailing: View>: View {"))
        try #require(card.range(of: "struct EditorPDFFactsRow: View {", range: start.upperBound..<card.endIndex),
                     "row 2 no longer follows the header — this read would miss it")
        let header = String(card[start.upperBound..<card.endIndex])
        #expect(!header.contains("EditorLocationLabel"), "the PDF header draws the location crumbs again")
        #expect(!header.contains("EditorDocumentLocation"), "the PDF header takes a location again")
        #expect(header.contains("Label(\"Reveal in Browse\""), "the PDF's name lost its way to where it lives")
        let workspace = try ChromeGlassWiringTests.source("EditorWorkspaceView.swift")
        #expect(workspace.contains("EditorLocationLabel(location: location"), "the TEXT header lost its location line too")
    }

    /// **The reader counts its skips on itself, never on the column preview's counter.**
    /// `PDFPreviewMountedTests` asserts that counter does not move across a held lane; this suite
    /// withdraws opens on purpose, so counting there turned the preview's test red whenever the two
    /// ran together — the first CI run with Edit's reader on main (2026-10-17).
    @Test func theReaderNeverCountsOnThePreviewsSkipCounter() throws {
        let source = try ChromeGlassWiringTests.source("EditorPDFDocument.swift")
        // Absence only: that the reader still counts its own is held by the `== 1` test above.
        #expect(!source.contains("PDFOpenTicket.noteSkipped("),
                "Edit's reader counts its withdrawn opens on the column preview's process-wide counter")
    }

    /// **A load that comes back after the PDF was closed is dropped** — latest request wins, and a
    /// close is a request. Otherwise a slow open would put a document back after the × was pressed.
    @Test func aLoadThatLandsAfterCloseIsDropped() async throws {
        let file = path("closed-early.pdf")
        PDFFixtures.write(file, pages: 2)
        let pdf = EditorPDFDocument(isCloudOnly: { _ in false })
        let hold = LaneHold()
        defer { hold.release() }
        try #require(await hold.waitUntilHeld())
        pdf.open(path: file, log: { _ in })
        pdf.close()
        hold.release()
        // Waited for by its RETURN, not by a guess: the load comes back and is dropped.
        await wait("the load from before the close to come back") { pdf.loadsReturned >= 1 }
        #expect(pdf.document == nil && pdf.path == nil && pdf.facts == nil,
                "a load from before the close was assigned after it")
    }

    /// **Never two parses at once**, with the model's open queued behind another parse.
    @Test func everyParseTakesItsTurnInTheLane() async {
        let file = path("lane.pdf"), other = path("other.pdf")
        PDFFixtures.write(file, pages: 2)
        PDFFixtures.write(other, pages: 8)
        let pdf = EditorPDFDocument(isCloudOnly: { _ in false })
        async let elsewhere: Int = PDFKitSerialAccess.perform {
            PDFDocument(url: URL(fileURLWithPath: other))?.pageCount ?? 0
        }
        #expect(await open(pdf, file) == .open)
        #expect(await elsewhere == 8)
        #expect(PDFKitSerialAccess.peakConcurrentParses <= 1)
    }

    /// **An open parses the file ONCE** — the protection the tools need is read off the document
    /// it opened, not by handing the URL to `PDFToolkit.encryptionState(of:)`, which opens it again
    /// in the lane everyone else waits on. Counted at `PDFDocument(url:)` itself, so a second parse
    /// inside the toolkit counts too. A file with no form: one WITH fields is listed by the toolkit's
    /// own open as well (``EditorPDFForm/read(_:url:)``).
    @Test func anOpenParsesTheFileOnce() async {
        let file = path("once.pdf")
        PDFFixtures.writeRestricted(file)
        let before = PDFURLOpens.count(file)
        guard case .open(_, _, _, let encryption) = await EditorPDFDocument.read(file) else {
            Issue.record("the restricted fixture did not open")
            return
        }
        #expect(encryption == .restrictedOnly)
        #expect(PDFURLOpens.count(file) - before == 1, "the open parsed \(file) more than once")
    }

    /// **A pane menu's probe parses the file ONCE too** — `EditorPDFToolEngine.probe(_:)`, which
    /// runs before a PDF Tools item opens anything, reads the protection off its own document by
    /// the same rule, not by a second open inside `PDFToolkit.encryptionState(of:)`.
    @Test func aPaneProbeParsesTheFileOnce() async {
        let file = path("probe.pdf")
        PDFFixtures.writeRestricted(file, pages: 2)
        let before = PDFURLOpens.count(file)
        let probe = await EditorPDFToolEngine.probe(URL(fileURLWithPath: file))
        #expect(probe == .facts(pageCount: 2, encryption: .restrictedOnly))
        #expect(PDFURLOpens.count(file) - before == 1, "the probe parsed \(file) more than once")
    }

    /// **The local rule answers as the toolkit does** — on a plain, a restricted and a locked file,
    /// both through a real open and through the rule itself. What keeps ``EditorPDFDocument/
    /// encryption(of:)`` honest if pdf-toolkit's rule ever moves.
    @Test(arguments: ["plain", "restricted", "locked"])
    func theToolsLearnTheProtectionTheToolkitWould(_ kind: String) async {
        let file = path("\(kind).pdf")
        switch kind {
        case "restricted": PDFFixtures.writeRestricted(file)
        case "locked": PDFFixtures.writeLocked(file, password: "open-sesame")
        default: PDFFixtures.write(file, pages: 2)
        }
        let toolkit = PDFToolkit.encryptionState(of: URL(fileURLWithPath: file))
        let pdf = EditorPDFDocument(isCloudOnly: { _ in false })
        #expect(await open(pdf, file) == (kind == "locked" ? .locked : .open))
        #expect(pdf.tools.encryption == toolkit, "\(kind): the tools were told \(String(describing: pdf.tools.encryption)), the toolkit says \(toolkit)")
        let opened = await PDFKitSerialAccess.perform {
            PDFDocument(url: URL(fileURLWithPath: file)).map(EditorPDFDocument.encryption(of:))
        }
        #expect(opened == toolkit, "\(kind): the local rule says \(String(describing: opened)), the toolkit \(toolkit)")
        let expected: [String: PDFEncryptionState] = ["plain": .none, "restricted": .restrictedOnly,
                                                      "locked": .lockedToOpen]
        #expect(toolkit == expected[kind], "the \(kind) fixture is not what it says it is")
    }

    // MARK: The page view

    private func host<V: View>(_ view: V, size: CGSize) -> NSWindow {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.layoutIfNeeded()
        return window
    }

    private func readerView(in view: NSView) -> ReaderPDFView? {
        if let reader = view as? ReaderPDFView { return reader }
        for sub in view.subviews { if let found = readerView(in: sub) { return found } }
        return nil
    }

    /// **Page fits a whole page** — both shapes, as `PDFPreviewMountedTests` measures the preview:
    /// the page's drawn size in the view's own coordinates, not the scale that produced it.
    @Test(arguments: [CGSize(width: 820, height: 600), CGSize(width: 420, height: 900)])
    func pageFitShowsAWholePage(size: CGSize) async throws {
        let file = path("fit.pdf")
        PDFFixtures.write(file, pages: 3)
        let pdf = EditorPDFDocument(isCloudOnly: { _ in false })
        #expect(await open(pdf, file) == .open)
        let window = host(EditorPDFPageView(document: pdf.document, state: pdf.view), size: size)
        defer { window.contentView = nil }
        let settled = await LayoutPumpWait.pump(window, upTo: 10) {
            (readerView(in: window.contentView!)?.bounds.width ?? 0) > 0
        }
        try #require(settled.held)
        let view = try #require(readerView(in: window.contentView!))
        view.refit()
        let drawn = CGSize(width: PDFFixtures.letter.width * view.scaleFactor,
                           height: PDFFixtures.letter.height * view.scaleFactor)
        #expect(drawn.width <= view.bounds.width + 0.5 && drawn.height <= view.bounds.height + 0.5,
                "a \(drawn) page in a \(view.bounds.size) view is cut off")
        #expect(drawn.width > view.bounds.width - 1 || drawn.height > view.bounds.height - 1,
                "the page does not fill either dimension — it is not fitted")
    }

    /// **Width fills the width** — and lets the height run on, which is what makes it not Page.
    @Test func widthFitFillsTheWidth() async throws {
        let file = path("width.pdf")
        PDFFixtures.write(file, pages: 3)
        let pdf = EditorPDFDocument(isCloudOnly: { _ in false })
        #expect(await open(pdf, file) == .open)
        pdf.view.fit = .width
        let window = host(EditorPDFPageView(document: pdf.document, state: pdf.view),
                          size: CGSize(width: 820, height: 500))
        defer { window.contentView = nil }
        let settled = await LayoutPumpWait.pump(window, upTo: 10) {
            (readerView(in: window.contentView!)?.bounds.width ?? 0) > 0
        }
        try #require(settled.held)
        let view = try #require(readerView(in: window.contentView!))
        view.refit()
        let drawnWidth = PDFFixtures.letter.width * view.scaleFactor
        #expect(abs(drawnWidth - (view.bounds.width - 2 * view.sideMargin)) < 1)
        #expect(PDFFixtures.letter.height * view.scaleFactor > view.bounds.height)
    }

    // MARK: The workspace

    /// **While a PDF is open, the document card draws pages and no text surface at all** — the
    /// `EditorTextView` a save could be typed into is not mounted.
    @Test func theWorkspaceDrawsPagesAndNoTextSurface() async throws {
        let file = path("card.pdf")
        PDFFixtures.write(file, pages: 2)
        let pdf = EditorPDFDocument(isCloudOnly: { _ in false })
        #expect(await open(pdf, file) == .open)
        let view = EditorWorkspaceView.fixture(pdf: pdf)
            .readingSettings(from: defaults)
        let window = host(view, size: CGSize(width: 900, height: 700))
        defer { window.contentView = nil }
        let settled = await LayoutPumpWait.pump(window, upTo: 10) { readerView(in: window.contentView!) != nil }
        #expect(settled.held, "no page view in the document card")
        func texts(_ view: NSView) -> Int {
            (view is EditorTextView ? 1 : 0) + view.subviews.map(texts).reduce(0, +)
        }
        #expect(texts(window.contentView!) == 0, "a text surface is mounted under a PDF")
    }

    // MARK: Words and rules

    /// Row 2's paper (decided 2026-10-19): the name and the inches with a comma, since "·" is the
    /// row's own separator — and the name alone once the inches are shed, or nothing for a paper
    /// with no name.
    @Test func paperFacts() {
        #expect(EditorPDFFacts.paperFact(CGSize(width: 612, height: 792)) == "Letter, 8.5 × 11 in")
        #expect(EditorPDFFacts.paperFact(CGSize(width: 792, height: 612)) == "Letter, 11 × 8.5 in")
        #expect(EditorPDFFacts.paperFact(CGSize(width: 288, height: 432)) == "4 × 6 in")
        #expect(EditorPDFFacts.paperFact(CGSize(width: 612, height: 792), inches: false) == "Letter")
        #expect(EditorPDFFacts.paperFact(CGSize(width: 288, height: 432), inches: false) == nil)
    }

    @Test func aTypedPageIsClampedIntoTheDocument() {
        #expect(EditorPDFCapsule.page(typed: "3", pageCount: 10) == 2)
        #expect(EditorPDFCapsule.page(typed: "0", pageCount: 10) == 0)
        #expect(EditorPDFCapsule.page(typed: "99", pageCount: 10) == 9)
        #expect(EditorPDFCapsule.page(typed: " 4 ", pageCount: 10) == 3)
        #expect(EditorPDFCapsule.page(typed: "x", pageCount: 10) == nil)
        // Past what `Int` holds is past the last page, and a Japanese keyboard's digits are digits.
        #expect(EditorPDFCapsule.page(typed: "99999999999999999999", pageCount: 10) == 9)
        #expect(EditorPDFCapsule.page(typed: "３", pageCount: 10) == 2)
        #expect(EditorPDFCapsule.page(typed: "", pageCount: 10) == nil)
    }

    /// **Row 2 says paper, size and text, and no version** — the version is in the tooltip on
    /// "PDF", after the note that Edit never changes the file (decided 2026-10-19).
    @Test func rowTwoSaysPaperSizeAndTextAndKeepsTheVersionForTheTooltip() {
        let facts = EditorPDFFacts(pageCount: 3, pageSizes: Array(repeating: PDFFixtures.letter, count: 3),
                                   majorVersion: 1, minorVersion: 7, fileSize: "184 KB", hasText: true)
        let widest = EditorPDFFactsRow.rungs(facts, page: 1).first
        #expect(widest == ["Letter, 8.5 × 11 in", "184 KB", "Text selectable"])
        #expect(!(widest ?? []).joined().contains("1.7"), "the version is back in row 2")
        #expect(EditorPDFFactsRow.kindHelp(facts)
                == "Edit never changes this file. Tools and Fill & Sign save a new copy beside it.\nPDF version 1.7")
        #expect(EditorPDFFactsRow.kindHelp(nil) == "Edit never changes this file. Tools and Fill & Sign save a new copy beside it.")
        #expect(EditorPDFFactsRow.kindWord == "PDF")
    }

    @Test func zoomingLeavesTheFitAndStepsTheScale() {
        let state = EditorPDFViewState()
        state.scale = 1
        state.zoom(in: true)
        #expect(state.fit == nil)
        #expect(state.scaleRequest?.value == 1.25)
    }
}

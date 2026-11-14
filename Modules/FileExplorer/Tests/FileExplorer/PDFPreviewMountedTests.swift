import AppKit
import Events
import EventsTestSupport
import os
import PDFKit
import Quartz
import SwiftUI
import Sync
import Testing
import UniformTypeIdentifiers
@testable import FileExplorer

/// The PDF preview as the pane mounts it, the half `PDFPagePreviewTests` can't see.
///
/// Those tests pin the rules; these pin that the rules reach a real view: a PDF goes to PDFKit and
/// everything else to Quick Look, the page laid out is a whole page, and the document under it can
/// be scrolled. Every number is read off laid-out AppKit views, never from the constants that
/// produced them, because "there is a scroll view" and "it has somewhere to scroll to" are
/// different claims.
///
/// Serialized, because several of these hold PDFKit's one lane: a hold stops every parse in the
/// process, so two in parallel can wait out their whole budget behind each other.
@MainActor
@Suite(.serialized) struct PDFPreviewMountedTests {

    /// A real multi-page PDF and a real image, because both renderers read the file.
    private final class Fixture {
        let root: String
        let pdf: String
        /// A second PDF, for the tests that move the preview from one document to another.
        let otherPDF: String
        /// A `.pdf` that is not a PDF, for the open that fails.
        let brokenPDF: String
        /// A real PDF behind a user password, which opens but shows nothing.
        let lockedPDF: String
        let png: String
        /// US Letter, the shape the fit rule is most often asked about.
        static let pageSize = CGSize(width: 612, height: 792)
        static let pageCount = 5

        init() throws {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("PDFPreviewMounted-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            root = dir.path

            let doc = PDFDocument()
            for index in 0..<Self.pageCount {
                let image = NSImage(size: Self.pageSize)
                image.lockFocus()
                NSColor.white.setFill()
                NSRect(origin: .zero, size: Self.pageSize).fill()
                ("Page \(index + 1)" as NSString).draw(
                    at: NSPoint(x: 40, y: 700),
                    withAttributes: [.font: NSFont.boldSystemFont(ofSize: 44)])
                image.unlockFocus()
                if let page = PDFPage(image: image) { doc.insert(page, at: index) }
            }
            pdf = dir.appendingPathComponent("report.pdf").path
            doc.write(toFile: pdf)
            otherPDF = dir.appendingPathComponent("other.pdf").path
            try FileManager.default.copyItem(atPath: pdf, toPath: otherPDF)
            brokenPDF = dir.appendingPathComponent("broken.pdf").path
            try Data("not a PDF".utf8).write(to: URL(fileURLWithPath: brokenPDF))
            lockedPDF = dir.appendingPathComponent("locked.pdf").path
            doc.write(to: URL(fileURLWithPath: lockedPDF),
                      withOptions: [.userPasswordOption: "secret", .ownerPasswordOption: "secret"])

            let art = NSImage(size: NSSize(width: 200, height: 200))
            art.lockFocus()
            NSColor.systemGreen.setFill()
            NSRect(x: 0, y: 0, width: 200, height: 200).fill()
            art.unlockFocus()
            let rep = NSBitmapImageRep(data: art.tiffRepresentation!)!
            png = dir.appendingPathComponent("art.png").path
            try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: png))
        }
        deinit { try? FileManager.default.removeItem(atPath: root) }
    }

    private func item(_ path: String, uti: String?) -> ColumnPreviewItem {
        ColumnPreviewItem(node: FileNode(id: path, name: (path as NSString).lastPathComponent,
                                         isDirectory: false, fileSize: 1, kind: uti))
    }

    /// Mounts the preview column itself, so what is measured is the pane's own choice of renderer.
    private func mount(_ item: ColumnPreviewItem, width: CGFloat, height: CGFloat)
    -> (window: NSWindow, host: NSView) {
        let host = NSHostingView(rootView: ColumnPreviewColumn(
            item: item,
            paneToken: PaneToken(isLeft: true, isSingleSource: true),
            isAwaitingDownload: false,
            downloadChannel: NotificationCenter()))
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.layoutIfNeeded()
        return (window, host)
    }

    private func descendants(of view: NSView) -> [NSView] {
        var found: [NSView] = []
        func walk(_ v: NSView) { found.append(v); v.subviews.forEach(walk) }
        walk(view)
        return found
    }

    private func pdfView(in view: NSView) -> FitPagePDFView? {
        descendants(of: view).compactMap { $0 as? FitPagePDFView }.first
    }

    private func quickLookViews(in view: NSView) -> [QLPreviewView] {
        descendants(of: view).compactMap { $0 as? QLPreviewView }
    }

    /// Mounts the fixture PDF and waits until its page is laid out. The waits here pump the shared
    /// loop: the preview is held back by `previewSettleDelay`, and what it waits on arrives on
    /// main-actor turns, not on a clock.
    private func laidOutPDFView(_ fixture: Fixture, width: CGFloat, height: CGFloat) async throws
    -> (view: FitPagePDFView, window: NSWindow) {
        let mounted = mount(item(fixture.pdf, uti: UTType.pdf.identifier), width: width, height: height)
        let settled = await LayoutPumpWait.pump(mounted.window, upTo: 10) {
            (pdfView(in: mounted.host)?.scaleFactor ?? 0) > 0 && pdfView(in: mounted.host)?.document != nil
        }
        try #require(settled.held, "the PDF never laid out (\(settled.pumps) passes)")
        return (try #require(pdfView(in: mounted.host)), mounted.window)
    }

    /// A PDF is drawn by PDFKit, in this process: the Quick Look path renders in an `NSRemoteView`
    /// whose scrolling and scale belong to the extension.
    @Test func testAPDFIsMountedInPDFKitAndNotInQuickLook() async throws {
        let fixture = try Fixture()
        let mounted = mount(item(fixture.pdf, uti: UTType.pdf.identifier), width: 820, height: 700)
        let settled = await LayoutPumpWait.pump(mounted.window, upTo: 10) { pdfView(in: mounted.host) != nil }
        try #require(settled.held, "no PDF view after \(settled.pumps) layout passes")
        #expect(quickLookViews(in: mounted.host).isEmpty,
                "the file reached Quick Look as well — both renderers are mounted")
    }

    /// Everything else still goes to Quick Look, which already shows a whole image.
    @Test func testAnImageStillGoesToQuickLook() async throws {
        let fixture = try Fixture()
        let mounted = mount(item(fixture.png, uti: UTType.png.identifier), width: 820, height: 700)
        let settled = await LayoutPumpWait.pump(mounted.window, upTo: 10) { !quickLookViews(in: mounted.host).isEmpty }
        try #require(settled.held, "no Quick Look view after \(settled.pumps) layout passes")
        #expect(pdfView(in: mounted.host) == nil)
    }

    /// The page is whole in a preview far wider than tall (fitted to the width, a letter page in
    /// 560pt would be about 1060pt tall and show only the top third) and in a narrow one. Both
    /// shapes, because a rule that fitted only one would look right in whichever was tried.
    /// Asserted on the page's size in the view's own coordinates, which is what the reader sees,
    /// not on `scaleFactor`.
    @Test(arguments: [(820, 700, true), (420, 900, false)] as [(CGFloat, CGFloat, Bool)])
    func testAPreviewOfEitherShapeShowsAWholePage(width: CGFloat, height: CGFloat, heightBound: Bool) async throws {
        let fixture = try Fixture()
        let (view, window) = try await laidOutPDFView(fixture, width: width, height: height)
        defer { _ = window }

        let drawn = CGSize(width: Fixture.pageSize.width * view.scaleFactor,
                           height: Fixture.pageSize.height * view.scaleFactor)
        #expect(drawn.height <= view.bounds.height,
                "the page is \(drawn.height)pt tall in a \(view.bounds.height)pt view — it is cut off")
        #expect(drawn.width <= view.bounds.width,
                "the page is \(drawn.width)pt wide in a \(view.bounds.width)pt view")
        if heightBound {
            // Height-bound at the wide shape, which is where fitting on width goes wrong.
            #expect(drawn.height > view.bounds.height - 1)
        }
    }

    /// Nothing paints a slab behind the page. The preview sits on the pane's own surface, and in
    /// dark mode a white rectangle would be the brightest thing in the window. Both halves are
    /// asserted: `backgroundColor` governs the view, and PDFKit's enclosing scroll view draws the
    /// area around the page independently and comes up white.
    @Test func testThePageSitsOnThePanesSurfaceRatherThanAWhiteSlab() async throws {
        let fixture = try Fixture()
        let mounted = mount(item(fixture.pdf, uti: UTType.pdf.identifier), width: 820, height: 700)
        // The document as well as the view: it arrives from the lane after the view mounts, and the
        // scroll view read here is the one PDFKit lays out around a document.
        let settled = await LayoutPumpWait.pump(mounted.window, upTo: 10) { pdfView(in: mounted.host)?.document != nil }
        try #require(settled.held, "no PDF document after \(settled.pumps) layout passes")
        let view = try #require(pdfView(in: mounted.host))

        #expect(view.backgroundColor.alphaComponent == 0,
                "the PDF view paints its own background")
        let scroll = try #require(descendants(of: view).compactMap { $0 as? NSScrollView }.first)
        #expect(scroll.drawsBackground == false,
                "PDFKit's scroll view still fills the area around the page")
    }

    /// There is somewhere to scroll to, and it is the rest of the document: the scrolling content
    /// is taller than the viewport by about the four off-screen pages. A single-page display mode
    /// would pass a mere "a scroll view exists" check.
    @Test func testTheWholeDocumentIsScrollable() async throws {
        let fixture = try Fixture()
        let (view, window) = try await laidOutPDFView(fixture, width: 820, height: 700)
        #expect(view.displayMode == .singlePageContinuous,
                "a paged mode scrolls within one page — the document is not reachable")

        let scroll = try #require(descendants(of: view).compactMap { $0 as? NSScrollView }.first)
        let content = try #require(scroll.documentView).frame.height
        let visible = scroll.documentVisibleRect.height
        #expect(content > visible * 2,
                "the document is \(content)pt against a \(visible)pt viewport — \(Fixture.pageCount) pages should be far more")

        // And it moves all the way to the end, asserted as "the last page is under the reader's
        // eye", since a scroll view that travels a few points and stops would satisfy "the origin
        // changed".
        //
        // Which numeric end is the end is an OS convention: up to macOS 26 PDFKit used an unflipped
        // clip view, opening at the scroller's maximum; macOS 27 flips it and opens at 0. So the
        // far end is measured off the laid-out views, not assumed.
        let opensAt = scroll.documentVisibleRect.origin.y
        #expect(pageUnderViewport(of: view) == 1,
                "the preview did not open at page one of the document")
        let span = content - visible                         // the other end of the legal band
        let farEnd = abs(opensAt - span) > abs(opensAt) ? span : 0
        scroll.contentView.scroll(to: NSPoint(x: scroll.documentVisibleRect.origin.x, y: farEnd))
        scroll.reflectScrolledClipView(scroll.contentView)
        window.layoutIfNeeded()

        #expect(abs(scroll.documentVisibleRect.origin.y - opensAt) > visible,
                "the clip view moved \(scroll.documentVisibleRect.origin.y - opensAt)pt from \(opensAt) — there is a scroll view but nothing scrolls")
        #expect(pageUnderViewport(of: view) == Fixture.pageCount,
                "the far end of the scroll shows page \(pageUnderViewport(of: view).map(String.init) ?? "nothing") of \(Fixture.pageCount) — the rest of the document is not reachable")
    }

    // MARK: The load goes through the lane

    /// Every document a `PDFView` was handed, in order, read off `PDFViewDocumentChanged`, which
    /// PDFKit posts on each assignment, so an assignment later overwritten still shows.
    @MainActor
    private final class DocumentLog {
        private(set) var urls: [URL?] = []
        private var token: NSObjectProtocol?

        init(_ view: PDFView) {
            token = NotificationCenter.default.addObserver(
                forName: .PDFViewDocumentChanged, object: view, queue: nil
            ) { [weak self, weak view] _ in
                // Posted synchronously from the assignment, on the main actor. The view is read
                // directly rather than off the notification: it is the only object observed.
                MainActor.assumeIsolated { self?.urls.append(view?.document?.documentURL) }
            }
        }

        /// The documents actually assigned, leaving out the clears in between.
        var assigned: [URL] { urls.compactMap { $0 } }

        func stop() { token.map(NotificationCenter.default.removeObserver); token = nil }
    }

    /// Every outcome a preview reported, in order.
    @MainActor
    private final class Outcomes {
        private(set) var reported: [PDFOpenOutcome] = []
        func record(_ url: URL, _ outcome: PDFOpenOutcome) { reported.append(outcome) }
    }

    /// The placeholder a `PDFPagePreview` stands behind its page, as a real view a test can find.
    private final class PlaceholderMarker: NSView {
        var outcome: PDFOpenOutcome?
    }

    private struct Placeholder: NSViewRepresentable {
        let outcome: PDFOpenOutcome?
        func makeNSView(context: Context) -> PlaceholderMarker { PlaceholderMarker() }
        func updateNSView(_ view: PlaceholderMarker, context: Context) { view.outcome = outcome }
    }

    private func placeholders(in view: NSView) -> [PlaceholderMarker] {
        descendants(of: view).compactMap { $0 as? PlaceholderMarker }
    }

    /// Hosts a view on its own, so a test can change its URL or unmount it; the column mounts a
    /// fresh preview per selection and offers neither.
    private func host(_ root: some View) -> (window: NSWindow, host: NSHostingView<AnyView>) {
        let host = NSHostingView(rootView: AnyView(root))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 700)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.layoutIfNeeded()
        return (window, host)
    }

    private func page(_ path: String, outcomes: Outcomes? = nil) -> PDFPageView {
        PDFPageView(url: URL(fileURLWithPath: path)) { url, outcome in outcomes?.record(url, outcome) }
    }

    /// Re-renders a preview without changing its URL. Only a change in the representable's own
    /// value reaches `updateNSView`; ancestor re-renders and environment flips around an unchanged
    /// `PDFPageView` make no call. So each render hands it a fresh closure, as the column's own
    /// re-renders do.
    private final class Renders: ObservableObject { @Published var count = 0 }

    private struct ReRendered: View {
        @ObservedObject var renders: Renders
        let path: String
        let outcomes: Outcomes?
        var body: some View {
            let render = renders.count
            PDFPageView(url: URL(fileURLWithPath: path)) { url, outcome in
                _ = render
                outcomes?.record(url, outcome)
            }
        }
    }

    /// Returns once every parse queued before the call has run and the main-actor turns those
    /// parses scheduled have been taken, so a late load has landed by now if it ever will. A
    /// barrier, not a fixed pump: under load a fixed pump can end before the parse, and a "nothing
    /// was assigned" assertion then passes having waited for nothing.
    private func drainTheLane(_ window: NSWindow) async {
        await PDFKitSerialAccess.perform {}
        _ = await LayoutPumpWait.pump(window, upTo: 0.1) { false }
    }

    /// The parse is in the lane, so it is off the main thread. With the lane held, the view mounts
    /// and stays empty, checked again after it has had main-actor turns, so a parse that went off
    /// the main thread but around the lane fails too. Released, the page arrives and the preview
    /// says so.
    @Test func thePreviewOpensItsDocumentInTheLaneRatherThanOnTheMainThread() async throws {
        let fixture = try Fixture()
        defer { withExtendedLifetime(fixture) {} }
        let hold = LaneHold()
        defer { hold.release() }
        try #require(await hold.waitUntilHeld(), "the lane never came free to be held")

        // Hosted directly rather than through the column, so the lane is held for a few passes and
        // not through the column's settle delay: every other PDFKit reader in the process queues
        // behind this hold. The column's choice of this view is pinned above.
        let outcomes = Outcomes()
        let hosted = host(page(fixture.pdf, outcomes: outcomes))
        let view = try #require(pdfView(in: hosted.host), "the preview did not mount")
        #expect(view.document == nil,
                "the document was there at mount while the lane was held — it was parsed on the main thread")
        _ = await LayoutPumpWait.pump(hosted.window, upTo: 0.3) { false }
        #expect(view.document == nil,
                "the document arrived while the lane was held — it was parsed outside the lane")
        #expect(outcomes.reported.isEmpty)

        hold.release()
        let arrived = await LayoutPumpWait.pump(hosted.window, upTo: 10) { view.document != nil }
        #expect(arrived.held, "the document never arrived once the lane was free (\(arrived.pumps) passes)")
        #expect(view.document?.documentURL?.path == fixture.pdf)
        #expect(outcomes.reported == [.opened])
    }

    /// Latest request wins. A, then B, both queued behind a held lane: A must never be shown under
    /// B's name. The final document can't tell (on a FIFO lane B lands last either way), so every
    /// assignment is read.
    @Test func aLoadForAFileNoLongerShownIsDropped() async throws {
        let fixture = try Fixture()
        defer { withExtendedLifetime(fixture) {} }
        let first = URL(fileURLWithPath: fixture.pdf)
        let second = URL(fileURLWithPath: fixture.otherPDF)
        let hold = LaneHold()
        defer { hold.release() }
        try #require(await hold.waitUntilHeld(), "the lane never came free to be held")

        let hosted = host(page(fixture.pdf))
        let view = try #require(pdfView(in: hosted.host))
        let log = DocumentLog(view)
        defer { log.stop() }
        hosted.host.rootView = AnyView(page(fixture.otherPDF))
        hosted.window.layoutIfNeeded()
        #expect(pdfView(in: hosted.host) === view, "the URL change rebuilt the view instead of updating it")

        hold.release()
        await drainTheLane(hosted.window)

        #expect(view.document?.documentURL == second)
        #expect(!log.assigned.contains(first),
                "the view was handed \(log.assigned.map(\.lastPathComponent)) — a stale load was assigned")
    }

    /// A page already showing comes down the moment another file is asked for, not when the new one
    /// lands: the previous file's page under the new file's name is a wrong preview.
    @Test func switchingFilesClearsThePreviousPageAtOnce() async throws {
        let fixture = try Fixture()
        defer { withExtendedLifetime(fixture) {} }
        let hosted = host(page(fixture.pdf))
        let view = try #require(pdfView(in: hosted.host))
        let loaded = await LayoutPumpWait.pump(hosted.window, upTo: 10) { view.document != nil }
        try #require(loaded.held, "the first document never arrived (\(loaded.pumps) passes)")

        let hold = LaneHold()
        defer { hold.release() }
        try #require(await hold.waitUntilHeld(), "the lane never came free to be held")
        hosted.host.rootView = AnyView(page(fixture.otherPDF))
        hosted.window.layoutIfNeeded()
        #expect(view.document == nil,
                "the previous file's page stayed up while the next one was queued")

        hold.release()
        let arrived = await LayoutPumpWait.pump(hosted.window, upTo: 10) { view.document != nil }
        #expect(arrived.held)
        #expect(view.document?.documentURL?.path == fixture.otherPDF)
    }

    /// A re-render while the page is loading does not queue another parse. The view has no document
    /// until the lane answers, so a guard on the document's URL would read every re-render as "a
    /// different file" and open it again.
    @Test func aReRenderDuringTheLoadDoesNotOpenTheDocumentAgain() async throws {
        let fixture = try Fixture()
        defer { withExtendedLifetime(fixture) {} }
        let url = URL(fileURLWithPath: fixture.pdf)
        let hold = LaneHold()
        defer { hold.release() }
        try #require(await hold.waitUntilHeld(), "the lane never came free to be held")

        let renders = Renders()
        let hosted = host(ReRendered(renders: renders, path: fixture.pdf, outcomes: nil))
        let view = try #require(pdfView(in: hosted.host))
        let log = DocumentLog(view)
        defer { log.stop() }
        let skippedBefore = PDFOpenTicket.skippedOpens
        for _ in 0..<4 {
            renders.count += 1
            hosted.window.layoutIfNeeded()
        }
        #expect(pdfView(in: hosted.host) === view)

        hold.release()
        await drainTheLane(hosted.window)

        #expect(log.assigned == [url],
                "the document was opened \(log.assigned.count) times for one file")
        // A re-queued open withdraws the one before it, so a guard that re-requested on every
        // render would still assign once, but would have withdrawn an open per render.
        #expect(PDFOpenTicket.skippedOpens == skippedBefore,
                "the re-renders queued \(PDFOpenTicket.skippedOpens - skippedBefore) extra open(s) for the same file")
    }

    /// Nor does a re-render after a failed open try again. A file that never gets a document would
    /// read as "not this one" to a guard on the document's URL, so every re-render would parse it
    /// and log the failure again.
    @Test func aFileThatFailedToOpenIsNotReopenedOnEveryRender() async throws {
        let fixture = try Fixture()
        defer { withExtendedLifetime(fixture) {} }
        let outcomes = Outcomes()
        let renders = Renders()
        let hosted = host(ReRendered(renders: renders, path: fixture.brokenPDF, outcomes: outcomes))
        let failed = await LayoutPumpWait.pump(hosted.window, upTo: 10) { !outcomes.reported.isEmpty }
        try #require(failed.held, "the broken file never reported (\(failed.pumps) passes)")

        for _ in 0..<4 {
            renders.count += 1
            hosted.window.layoutIfNeeded()
            await drainTheLane(hosted.window)
        }
        #expect(outcomes.reported == [.unreadable],
                "the broken file was opened \(outcomes.reported.count) times across four re-renders")
    }

    /// A preview unmounted before the lane's turn costs no parse. The column mounts one per
    /// selection, so a walk through a folder during a scan would leave one queued open per file it
    /// settled on, each ahead of the file being looked at.
    @Test func anOpenWithdrawnBeforeItsTurnIsNeverParsed() async throws {
        let fixture = try Fixture()
        defer { withExtendedLifetime(fixture) {} }
        let hold = LaneHold()
        defer { hold.release() }
        try #require(await hold.waitUntilHeld(), "the lane never came free to be held")

        let skippedBefore = PDFOpenTicket.skippedOpens
        let hosted = host(page(fixture.pdf))
        // Held here, so the view outlives its dismantle: the case the withdrawal exists for.
        let view = try #require(pdfView(in: hosted.host))
        hosted.host.rootView = AnyView(Color.clear)
        hosted.window.layoutIfNeeded()
        #expect(pdfView(in: hosted.host) == nil, "the preview was not unmounted")

        hold.release()
        await drainTheLane(hosted.window)
        #expect(PDFOpenTicket.skippedOpens > skippedBefore,
                "the lane parsed an open whose view had already gone")
        #expect(view.document == nil, "a dismantled preview was handed its document after all")
    }

    /// And one withdrawn after its parse, before it is shown, is dropped. Staged by holding the
    /// main thread across the parse: `run` from the main actor blocks until the lane has passed the
    /// preview's open, the preview is unmounted while its result waits for the main actor, and only
    /// then does the main actor take that turn.
    @Test func anOpenWithdrawnAfterItsParseIsNotShown() async throws {
        let fixture = try Fixture()
        defer { withExtendedLifetime(fixture) {} }
        let hold = LaneHold()
        defer { hold.release() }
        try #require(await hold.waitUntilHeld(), "the lane never came free to be held")

        let outcomes = Outcomes()
        let hosted = host(page(fixture.pdf, outcomes: outcomes))
        let view = try #require(pdfView(in: hosted.host))
        // Turns for the preview's task to start and queue its open behind the hold: it is created
        // in `makeNSView` but runs on a later main-actor turn, and an open not yet queued when the
        // view goes is the other test's case, skipped before it parses.
        _ = await LayoutPumpWait.pump(hosted.window, upTo: 0.1) { false }
        let skippedBefore = PDFOpenTicket.skippedOpens
        hold.release()
        PDFKitSerialAccess.run {}                    // the preview's parse has run when this returns
        hosted.host.rootView = AnyView(Color.clear)  // …and its result has not reached the view
        hosted.window.layoutIfNeeded()
        #expect(pdfView(in: hosted.host) == nil, "the preview was not unmounted")

        await drainTheLane(hosted.window)
        try #require(PDFOpenTicket.skippedOpens == skippedBefore,
                     "the open was skipped before it parsed — this staged the other test's case, not this one")
        #expect(view.document == nil, "a dismantled preview was handed the document it had parsed")
        #expect(outcomes.reported.isEmpty, "a withdrawn open still reported an outcome")
    }

    // MARK: When the page never comes

    /// A file PDFKit can't read says so, to the column and in the log; otherwise a preview that
    /// stays on its icon is unexplained. Asserted on the file's own path, which no sibling test's
    /// line contains.
    @Test func anUnreadablePDFIsReportedAndLogged() async throws {
        let fixture = try Fixture()
        defer { withExtendedLifetime(fixture) {} }
        let log = LogCapture()
        let outcomes = Outcomes()
        let hosted = host(page(fixture.brokenPDF, outcomes: outcomes))
        let view = try #require(pdfView(in: hosted.host))
        let reported = await LayoutPumpWait.pump(hosted.window, upTo: 10) { !outcomes.reported.isEmpty }
        try #require(reported.held, "no outcome for the broken file (\(reported.pumps) passes)")

        #expect(outcomes.reported == [.unreadable])
        #expect(view.document == nil)
        #expect(await log.holds(.warning, containing: "\(fixture.brokenPDF) could not be opened"),
                "a PDF that failed to open left nothing in the log")
    }

    /// A password-protected PDF is not shown and not called broken. It opens, but a preview never
    /// asks for a password, so it has nothing to draw, and holding it would keep the file open.
    @Test func aLockedPDFIsReportedAsLockedAndNotShown() async throws {
        let fixture = try Fixture()
        defer { withExtendedLifetime(fixture) {} }
        let log = LogCapture()
        let outcomes = Outcomes()
        let hosted = host(page(fixture.lockedPDF, outcomes: outcomes))
        let view = try #require(pdfView(in: hosted.host))
        let reported = await LayoutPumpWait.pump(hosted.window, upTo: 10) { !outcomes.reported.isEmpty }
        try #require(reported.held, "no outcome for the locked file (\(reported.pumps) passes)")

        #expect(outcomes.reported == [.locked])
        #expect(view.document == nil, "a locked document was handed to the view")
        #expect(await log.holds(.info, containing: "\(fixture.lockedPDF) is password-protected"))
    }

    /// The pane is never blank while the page loads. The placeholder stands behind the empty view
    /// until the page lands, then goes: the page leaves margins, and a leftover placeholder would
    /// show around them.
    @Test func thePlaceholderStaysUntilThePageArrives() async throws {
        let fixture = try Fixture()
        defer { withExtendedLifetime(fixture) {} }
        let hold = LaneHold()
        defer { hold.release() }
        try #require(await hold.waitUntilHeld(), "the lane never came free to be held")

        let hosted = host(PDFPagePreview(url: URL(fileURLWithPath: fixture.pdf)) { outcome in
            Placeholder(outcome: outcome)
        })
        let view = try #require(pdfView(in: hosted.host))
        let waiting = placeholders(in: hosted.host)
        #expect(waiting.count == 1, "nothing stands behind the empty page while it loads")
        #expect(waiting.first?.outcome == nil)
        // Standing behind it only counts if the empty view paints nothing over it, checked after a
        // few layout passes so PDFKit has built whatever scroll view it builds without a document.
        _ = await LayoutPumpWait.pump(hosted.window, upTo: 0.2) { false }
        #expect(view.backgroundColor.alphaComponent == 0, "the empty PDF view paints over the placeholder")
        let scrollers = descendants(of: view).compactMap { $0 as? NSScrollView }
        try #require(!scrollers.isEmpty, "PDFKit built no scroll view, so the check below would check nothing")
        #expect(scrollers.allSatisfy { !$0.drawsBackground },
                "PDFKit's scroll view paints over the placeholder while the page loads")

        hold.release()
        let arrived = await LayoutPumpWait.pump(hosted.window, upTo: 10) {
            view.document != nil && placeholders(in: hosted.host).isEmpty
        }
        #expect(arrived.held,
                "the placeholder outlived the page (document: \(view.document != nil), placeholders: \(placeholders(in: hosted.host).count))")
    }

    /// And it stays, carrying the reason, when the page never comes.
    @Test func thePlaceholderStaysWithTheReasonWhenTheOpenFails() async throws {
        let fixture = try Fixture()
        defer { withExtendedLifetime(fixture) {} }
        let hosted = host(PDFPagePreview(url: URL(fileURLWithPath: fixture.brokenPDF)) { outcome in
            Placeholder(outcome: outcome)
        })
        let settled = await LayoutPumpWait.pump(hosted.window, upTo: 10) {
            placeholders(in: hosted.host).first?.outcome == .unreadable
        }
        #expect(settled.held,
                "the placeholder never learned the open had failed (outcome: \(String(describing: placeholders(in: hosted.host).first?.outcome)))")
    }

    /// Which page the reader is looking at, read off the laid-out pages under the middle of the
    /// view. Not `PDFView.currentPage`, which PDFKit updates on its own cadence rather than the
    /// clip view's, so it can lag a scroll in either direction and make the scroll assertions lie.
    private func pageUnderViewport(of view: FitPagePDFView) -> Int? {
        guard let document = view.document,
              let page = view.page(for: NSPoint(x: view.bounds.midX, y: view.bounds.midY),
                                   nearest: true)
        else { return nil }
        return document.index(for: page) + 1
    }
}

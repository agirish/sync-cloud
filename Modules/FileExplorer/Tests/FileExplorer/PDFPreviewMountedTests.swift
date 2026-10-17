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

/// The PDF preview as the pane actually mounts it — the half `PDFPagePreviewTests` cannot see.
///
/// Those tests pin the rules. These pin that the rules are wired to a real view: that a PDF reaches
/// PDFKit and everything else still reaches Quick Look, that the page laid out is a WHOLE page, and
/// that the document under it can be scrolled. Every number below is read off laid-out AppKit views,
/// never from the constants that produced them — which matters most for the scroll, because "there
/// is a scroll view" and "it has somewhere to scroll to" are different claims and only the second is
/// the complaint this change answers.
///
/// **Serialized, because several of these hold PDFKit's one lane.** A hold stops every parse in the
/// process, so two in parallel queue behind each other: in a loaded full-package run three of them
/// waited out their whole budget for a lane a sibling was holding.
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
        ColumnPreviewItem(row: PaneRow(
            side: .left, version: 1,
            node: FileNode(id: path, name: (path as NSString).lastPathComponent,
                           isDirectory: false, fileSize: 1, kind: uti),
            children: nil))
    }

    /// Mounts the preview column itself, so what is measured is the pane's own choice of renderer
    /// rather than a view this test picked.
    private func mount(_ item: ColumnPreviewItem, width: CGFloat, height: CGFloat)
    -> (window: NSWindow, host: NSView) {
        let host = NSHostingView(rootView: ColumnPreviewColumn(
            item: item,
            paneToken: PaneToken(isLeft: true, isSingleSource: true),
            isAwaitingDownload: false,
            downloadChannel: NotificationCenter(),
            onOpenInEditor: { _ in }))
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

    /// Waits for a condition on the shared pumping loop — the preview is held back by
    /// `previewSettleDelay`, and what it waits on arrives on main-actor turns rather than on a clock.
    private func wait(_ window: NSWindow, upTo seconds: Double,
                      for condition: () -> Bool) async -> (held: Bool, pumps: Int) {
        await LayoutPumpWait.pump(window, upTo: seconds, until: condition)
    }

    /// A PDF is drawn by PDFKit, in this process — which is the whole point, because the Quick Look
    /// path renders in an `NSRemoteView` whose scrolling and scale belong to the extension.
    @Test func testAPDFIsMountedInPDFKitAndNotInQuickLook() async throws {
        let fixture = try Fixture()
        let mounted = mount(item(fixture.pdf, uti: UTType.pdf.identifier), width: 820, height: 700)
        let settled = await wait(mounted.window, upTo: 10) { pdfView(in: mounted.host) != nil }
        try #require(settled.held, "no PDF view after \(settled.pumps) layout passes")
        #expect(quickLookViews(in: mounted.host).isEmpty,
                "the file reached Quick Look as well — both renderers are mounted")
    }

    /// And everything else still is not. The image is the measured case: Quick Look already shows a
    /// whole image, so moving it would be a change with nothing to gain.
    @Test func testAnImageStillGoesToQuickLook() async throws {
        let fixture = try Fixture()
        let mounted = mount(item(fixture.png, uti: UTType.png.identifier), width: 820, height: 700)
        let settled = await wait(mounted.window, upTo: 10) { !quickLookViews(in: mounted.host).isEmpty }
        try #require(settled.held, "no Quick Look view after \(settled.pumps) layout passes")
        #expect(pdfView(in: mounted.host) == nil)
    }

    /// **The defect, measured on the laid-out view.** In a preview far wider than it is tall, the page
    /// must still be whole: Quick Look fitted it to the width and rendered a letter page about 1060pt
    /// tall inside 560pt, showing the top third.
    ///
    /// The assertion is on the page's size in the view's own coordinates, which is what the reader
    /// sees — not on `scaleFactor`, which is the input to it.
    @Test func testAWidePreviewShowsAWholePage() async throws {
        let fixture = try Fixture()
        let mounted = mount(item(fixture.pdf, uti: UTType.pdf.identifier), width: 820, height: 700)
        let settled = await wait(mounted.window, upTo: 10) {
            (pdfView(in: mounted.host)?.scaleFactor ?? 0) > 0 && pdfView(in: mounted.host)?.document != nil
        }
        try #require(settled.held, "the PDF never laid out (\(settled.pumps) passes)")
        let view = try #require(pdfView(in: mounted.host))

        let drawn = CGSize(width: Fixture.pageSize.width * view.scaleFactor,
                           height: Fixture.pageSize.height * view.scaleFactor)
        #expect(drawn.height <= view.bounds.height,
                "the page is \(drawn.height)pt tall in a \(view.bounds.height)pt view — it is cut off")
        #expect(drawn.width <= view.bounds.width)
        // Height-bound at this shape, which is exactly where fitting on width goes wrong.
        #expect(drawn.height > view.bounds.height - 1)
    }

    /// The same page in a narrow preview: whole again, and width-bound this time. Both shapes,
    /// because a rule that fitted only one of them would look correct in whichever the author tried.
    @Test func testANarrowPreviewShowsAWholePage() async throws {
        let fixture = try Fixture()
        let mounted = mount(item(fixture.pdf, uti: UTType.pdf.identifier), width: 420, height: 900)
        let settled = await wait(mounted.window, upTo: 10) {
            (pdfView(in: mounted.host)?.scaleFactor ?? 0) > 0 && pdfView(in: mounted.host)?.document != nil
        }
        try #require(settled.held, "the PDF never laid out (\(settled.pumps) passes)")
        let view = try #require(pdfView(in: mounted.host))

        let drawn = CGSize(width: Fixture.pageSize.width * view.scaleFactor,
                           height: Fixture.pageSize.height * view.scaleFactor)
        #expect(drawn.width <= view.bounds.width,
                "the page is \(drawn.width)pt wide in a \(view.bounds.width)pt view")
        #expect(drawn.height <= view.bounds.height)
    }

    /// **Nothing paints a slab behind the page.** The preview sits on the pane's own surface, and a
    /// PDF that brought its own white rectangle was the one file type that did not blend into it —
    /// in dark mode that rectangle would be the brightest thing in the window.
    ///
    /// Both halves are asserted because turning off only one leaves the slab: `backgroundColor`
    /// governs the view, and PDFKit's own enclosing scroll view draws the area around the page
    /// independently and comes up white.
    @Test func testThePageSitsOnThePanesSurfaceRatherThanAWhiteSlab() async throws {
        let fixture = try Fixture()
        let mounted = mount(item(fixture.pdf, uti: UTType.pdf.identifier), width: 820, height: 700)
        // The document as well as the view: it arrives from the lane after the view mounts, and
        // the scroll view this reads is the one PDFKit lays out around a document.
        let settled = await wait(mounted.window, upTo: 10) { pdfView(in: mounted.host)?.document != nil }
        try #require(settled.held, "no PDF document after \(settled.pumps) layout passes")
        let view = try #require(pdfView(in: mounted.host))

        #expect(view.backgroundColor.alphaComponent == 0,
                "the PDF view paints its own background")
        let scroll = try #require(descendants(of: view).compactMap { $0 as? NSScrollView }.first)
        #expect(scroll.drawsBackground == false,
                "PDFKit's scroll view still fills the area around the page")
    }

    /// **There is somewhere to scroll to, and it is the rest of the document.** The complaint this
    /// answers is not "the scroll bar is missing" but "scrolling gets me nothing", so the assertion
    /// is that the scrolling content is taller than what is on screen by about the four pages that
    /// are off it — a single-page display mode would pass a mere "a scroll view exists" check.
    @Test func testTheWholeDocumentIsScrollable() async throws {
        let fixture = try Fixture()
        let mounted = mount(item(fixture.pdf, uti: UTType.pdf.identifier), width: 820, height: 700)
        let settled = await wait(mounted.window, upTo: 10) {
            (pdfView(in: mounted.host)?.scaleFactor ?? 0) > 0 && pdfView(in: mounted.host)?.document != nil
        }
        try #require(settled.held, "the PDF never laid out (\(settled.pumps) passes)")
        let view = try #require(pdfView(in: mounted.host))
        #expect(view.displayMode == .singlePageContinuous,
                "a paged mode scrolls within one page — the document is not reachable")

        let scroll = try #require(descendants(of: view).compactMap { $0 as? NSScrollView }.first)
        let content = try #require(scroll.documentView).frame.height
        let visible = scroll.documentVisibleRect.height
        #expect(content > visible * 2,
                "the document is \(content)pt against a \(visible)pt viewport — \(Fixture.pageCount) pages should be far more")

        // And it really moves, all the way to the end — asserted as "the LAST page is now under the
        // reader's eye" rather than "the origin changed", because a scroll view that travels a few
        // points and stops would satisfy the second and none of the complaint.
        //
        // **Which numeric end is "the end" is an OS convention, not a promise, and it changed.**
        // Through macOS 26 PDFKit laid its pages out bottom-up in an UNFLIPPED scroll view: the
        // document opened at the scroller's MAXIMUM and the way forward was toward zero, so this
        // test scrolled to `.zero`. macOS 27 flips the clip view — the document opens at origin 0,
        // measured `before=0` against a 792pt viewport — and the old spelling then asserted that a
        // perfectly working preview had not opened where it was supposed to. So the far end is
        // MEASURED off the laid-out views rather than assumed, and the test survives the next flip.
        let opensAt = scroll.documentVisibleRect.origin.y
        #expect(pageUnderViewport(of: view) == 1,
                "the preview did not open at page one of the document")
        let span = content - visible                         // the other end of the legal band
        let farEnd = abs(opensAt - span) > abs(opensAt) ? span : 0
        scroll.contentView.scroll(to: NSPoint(x: scroll.documentVisibleRect.origin.x, y: farEnd))
        scroll.reflectScrolledClipView(scroll.contentView)
        mounted.window.layoutIfNeeded()

        #expect(abs(scroll.documentVisibleRect.origin.y - opensAt) > visible,
                "the clip view moved \(scroll.documentVisibleRect.origin.y - opensAt)pt from \(opensAt) — there is a scroll view but nothing scrolls")
        #expect(pageUnderViewport(of: view) == Fixture.pageCount,
                "the far end of the scroll shows page \(pageUnderViewport(of: view).map(String.init) ?? "nothing") of \(Fixture.pageCount) — the rest of the document is not reachable")
    }

    // MARK: The load goes through the lane

    /// Holds `PDFKitSerialAccess`'s one lane until released, so a test can see what the preview
    /// does while its parse is queued behind someone else's.
    ///
    /// The hold is queued like any parse, so `waitUntilHeld` returns only once it is really in the
    /// lane — a parse that got there first runs to completion before it. **The wait polls rather
    /// than blocking on a semaphore**: these tests are main-actor, and a main thread parked behind
    /// another hold is a main thread that hold's owner needs in order to release it.
    private final class LaneHold: Sendable {
        private let gate = DispatchSemaphore(value: 0)
        private let held = OSAllocatedUnfairLock(initialState: false)
        private let released = OSAllocatedUnfairLock(initialState: false)

        init() {
            Task.detached { [gate, held] in
                await PDFKitSerialAccess.perform { held.withLock { $0 = true }; gate.wait() }
            }
        }

        func waitUntilHeld() async -> Bool {
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline {
                if held.withLock({ $0 }) { return true }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            return false
        }

        /// Idempotent, so a `defer` can always call it without stealing a later hold's signal.
        func release() {
            let first = released.withLock { done in defer { done = true }; return !done }
            if first { gate.signal() }
        }
    }

    /// Every document a `PDFView` was handed, in order — read off `PDFViewDocumentChanged`, which
    /// PDFKit posts on each assignment, so an assignment that was later overwritten still shows.
    @MainActor
    private final class DocumentLog {
        private(set) var urls: [URL?] = []
        private var token: NSObjectProtocol?

        init(_ view: PDFView) {
            token = NotificationCenter.default.addObserver(
                forName: .PDFViewDocumentChanged, object: view, queue: nil
            ) { [weak self, weak view] _ in
                // Posted synchronously from the assignment, which is on the main actor. The view is
                // read directly rather than off the notification: it is the only object observed.
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

    /// Hosts a view on its own, so a test can change its URL or unmount it — the column mounts a
    /// fresh preview per selection and gives no way to drive either.
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

    /// Re-renders a preview without changing its URL.
    ///
    /// **Only a change in the representable's own value reaches `updateNSView`** — measured: three
    /// re-renders of an ancestor around an unchanged `PDFPageView`, and four environment flips, made
    /// no call at all, while three bumps of a value its closure captures made three. So each render
    /// hands it a fresh closure, which is also what the column's own re-renders do.
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

    /// Returns once every parse queued before the call has run AND the main-actor turns those parses
    /// scheduled have been taken — so a late load has landed by now if it was ever going to. A
    /// barrier rather than a fixed pump: under load a fixed pump can end before the parse does,
    /// and a test that asserts "nothing was assigned" then passes having waited for nothing.
    private func drainTheLane(_ window: NSWindow) async {
        await PDFKitSerialAccess.perform {}
        _ = await LayoutPumpWait.pump(window, upTo: 0.1) { false }
    }

    /// **The parse is in the lane, so it is off the main thread.** With the lane held, the view
    /// mounts and stays empty — checked again after it has had main-actor turns, so a parse that
    /// went off the main thread but AROUND the lane fails here too. Release it and the page arrives,
    /// and the preview says so.
    @Test func thePreviewOpensItsDocumentInTheLaneRatherThanOnTheMainThread() async throws {
        let fixture = try Fixture()
        defer { withExtendedLifetime(fixture) {} }
        let hold = LaneHold()
        defer { hold.release() }
        try #require(await hold.waitUntilHeld(), "the lane never came free to be held")

        // Hosted directly rather than through the column, so the lane is held for a few passes and
        // not through the column's settle delay — every other PDFKit reader in the process is
        // queued behind this hold. The column's choice of this view is pinned above.
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
        let arrived = await wait(hosted.window, upTo: 10) { view.document != nil }
        #expect(arrived.held, "the document never arrived once the lane was free (\(arrived.pumps) passes)")
        #expect(view.document?.documentURL?.path == fixture.pdf)
        #expect(outcomes.reported == [.opened])
    }

    /// **Latest request wins.** A, then B, both queued behind a held lane: A must never be shown
    /// under B's name. The final document is not enough to tell — on a FIFO lane B lands last
    /// either way — so every assignment is read.
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

    /// **A page already showing comes down the moment another file is asked for**, not when the new
    /// one lands — the previous file's page under the new file's name is a wrong preview.
    @Test func switchingFilesClearsThePreviousPageAtOnce() async throws {
        let fixture = try Fixture()
        defer { withExtendedLifetime(fixture) {} }
        let hosted = host(page(fixture.pdf))
        let view = try #require(pdfView(in: hosted.host))
        let loaded = await wait(hosted.window, upTo: 10) { view.document != nil }
        try #require(loaded.held, "the first document never arrived (\(loaded.pumps) passes)")

        let hold = LaneHold()
        defer { hold.release() }
        try #require(await hold.waitUntilHeld(), "the lane never came free to be held")
        hosted.host.rootView = AnyView(page(fixture.otherPDF))
        hosted.window.layoutIfNeeded()
        #expect(view.document == nil,
                "the previous file's page stayed up while the next one was queued")

        hold.release()
        let arrived = await wait(hosted.window, upTo: 10) { view.document != nil }
        #expect(arrived.held)
        #expect(view.document?.documentURL?.path == fixture.otherPDF)
    }

    /// **A re-render while the page is loading does not queue another parse.** The view has no
    /// document until the lane answers, so a guard on the document's URL would read every re-render
    /// as "a different file" and open it again.
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
        // render would still assign once — but it would have withdrawn an open per render.
        #expect(PDFOpenTicket.skippedOpens == skippedBefore,
                "the re-renders queued \(PDFOpenTicket.skippedOpens - skippedBefore) extra open(s) for the same file")
    }

    /// **Nor does a re-render after a failed open try again.** A file that never gets a document
    /// would read as "not this one" to a guard on the document's URL, so every re-render would parse
    /// it again — and log the failure again.
    @Test func aFileThatFailedToOpenIsNotReopenedOnEveryRender() async throws {
        let fixture = try Fixture()
        defer { withExtendedLifetime(fixture) {} }
        let outcomes = Outcomes()
        let renders = Renders()
        let hosted = host(ReRendered(renders: renders, path: fixture.brokenPDF, outcomes: outcomes))
        let failed = await wait(hosted.window, upTo: 10) { !outcomes.reported.isEmpty }
        try #require(failed.held, "the broken file never reported (\(failed.pumps) passes)")

        for _ in 0..<4 {
            renders.count += 1
            hosted.window.layoutIfNeeded()
            await drainTheLane(hosted.window)
        }
        #expect(outcomes.reported == [.unreadable],
                "the broken file was opened \(outcomes.reported.count) times across four re-renders")
    }

    /// **A preview unmounted before the lane's turn costs no parse.** The column mounts one per
    /// selection, so a walk through a folder during a scan leaves one queued open per file it
    /// settled on, and each parsed would sit ahead of the file being looked at.
    @Test func anOpenWithdrawnBeforeItsTurnIsNeverParsed() async throws {
        let fixture = try Fixture()
        defer { withExtendedLifetime(fixture) {} }
        let hold = LaneHold()
        defer { hold.release() }
        try #require(await hold.waitUntilHeld(), "the lane never came free to be held")

        let skippedBefore = PDFOpenTicket.skippedOpens
        let hosted = host(page(fixture.pdf))
        // Held here, so the view outlives its dismantle — the case the withdrawal exists for.
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

    /// **And one withdrawn after its parse, before it is shown, is dropped.** Staged by holding the
    /// main thread across the parse: `run` from the main actor blocks until the lane has passed the
    /// preview's open, the preview is unmounted while its result is still waiting for the main
    /// actor, and only then does the main actor take that turn.
    @Test func anOpenWithdrawnAfterItsParseIsNotShown() async throws {
        let fixture = try Fixture()
        defer { withExtendedLifetime(fixture) {} }
        let hold = LaneHold()
        defer { hold.release() }
        try #require(await hold.waitUntilHeld(), "the lane never came free to be held")

        let outcomes = Outcomes()
        let hosted = host(page(fixture.pdf, outcomes: outcomes))
        let view = try #require(pdfView(in: hosted.host))
        // Turns for the preview's task to start and queue its open behind the hold — it is created
        // in `makeNSView` but runs on a later main-actor turn, and an open not yet queued when the
        // view goes is the OTHER test's case, skipped before it parses.
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

    /// **A file PDFKit cannot read says so**, to the column and in the log — a preview that stays
    /// on its icon is otherwise unexplained. Asserted on the file's own path, which no sibling
    /// test's line contains.
    @Test func anUnreadablePDFIsReportedAndLogged() async throws {
        let fixture = try Fixture()
        defer { withExtendedLifetime(fixture) {} }
        let log = LogCapture()
        let outcomes = Outcomes()
        let hosted = host(page(fixture.brokenPDF, outcomes: outcomes))
        let view = try #require(pdfView(in: hosted.host))
        let reported = await wait(hosted.window, upTo: 10) { !outcomes.reported.isEmpty }
        try #require(reported.held, "no outcome for the broken file (\(reported.pumps) passes)")

        #expect(outcomes.reported == [.unreadable])
        #expect(view.document == nil)
        #expect(await log.holds(.warning, containing: "\(fixture.brokenPDF) could not be opened"),
                "a PDF that failed to open left nothing in the log")
    }

    /// **A password-protected PDF is not shown and not called broken.** It opens, but a preview never
    /// asks for a password, so it has nothing to draw — and holding it would keep the file open.
    @Test func aLockedPDFIsReportedAsLockedAndNotShown() async throws {
        let fixture = try Fixture()
        defer { withExtendedLifetime(fixture) {} }
        let log = LogCapture()
        let outcomes = Outcomes()
        let hosted = host(page(fixture.lockedPDF, outcomes: outcomes))
        let view = try #require(pdfView(in: hosted.host))
        let reported = await wait(hosted.window, upTo: 10) { !outcomes.reported.isEmpty }
        try #require(reported.held, "no outcome for the locked file (\(reported.pumps) passes)")

        #expect(outcomes.reported == [.locked])
        #expect(view.document == nil, "a locked document was handed to the view")
        #expect(await log.holds(.info, containing: "\(fixture.lockedPDF) is password-protected"))
    }

    /// **The pane is never blank while the page loads.** The placeholder stands behind the empty
    /// view until the page lands and then goes — the page leaves margins, and a placeholder left
    /// behind would show around them.
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
        // Standing behind it is only seeing it if the empty view paints nothing over it — after a
        // few layout passes, so PDFKit has built whatever scroll view it builds without a document.
        _ = await LayoutPumpWait.pump(hosted.window, upTo: 0.2) { false }
        #expect(view.backgroundColor.alphaComponent == 0, "the empty PDF view paints over the placeholder")
        #expect(descendants(of: view).compactMap { $0 as? NSScrollView }.allSatisfy { !$0.drawsBackground },
                "PDFKit's scroll view paints over the placeholder while the page loads")

        hold.release()
        let arrived = await wait(hosted.window, upTo: 10) {
            view.document != nil && placeholders(in: hosted.host).isEmpty
        }
        #expect(arrived.held,
                "the placeholder outlived the page (document: \(view.document != nil), placeholders: \(placeholders(in: hosted.host).count))")
    }

    /// **And it stays, carrying the reason, when the page never comes.**
    @Test func thePlaceholderStaysWithTheReasonWhenTheOpenFails() async throws {
        let fixture = try Fixture()
        defer { withExtendedLifetime(fixture) {} }
        let hosted = host(PDFPagePreview(url: URL(fileURLWithPath: fixture.brokenPDF)) { outcome in
            Placeholder(outcome: outcome)
        })
        let settled = await wait(hosted.window, upTo: 10) {
            placeholders(in: hosted.host).first?.outcome == .unreadable
        }
        #expect(settled.held,
                "the placeholder never learned the open had failed (outcome: \(String(describing: placeholders(in: hosted.host).first?.outcome)))")
    }

    /// Which page the reader is actually looking at, read off the laid-out pages under the middle
    /// of the view.
    ///
    /// **Not `PDFView.currentPage`**, which is maintained on PDFKit's own cadence rather than the
    /// clip view's: driven to the last page of the fixture it still reported page 1, and it stayed
    /// on page 5 after a scroll back to the start. It would have made both assertions above lie in
    /// whichever direction the stale value happened to point.
    private func pageUnderViewport(of view: FitPagePDFView) -> Int? {
        guard let document = view.document,
              let page = view.page(for: NSPoint(x: view.bounds.midX, y: view.bounds.midY),
                                   nearest: true)
        else { return nil }
        return document.index(for: page) + 1
    }
}

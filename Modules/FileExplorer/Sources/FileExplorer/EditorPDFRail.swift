import AppKit
import os
import PDFKit
import SwiftUI
import Sync

// MARK: - The outline

/// One bookmark of the open PDF, flattened into the rail's Outline tab.
public struct EditorPDFOutlineEntry: Equatable, Sendable {
    public var title: String
    /// How deep it sits: 0 for a child of the outline's root.
    public var depth: Int
    /// The page it goes to, zero-based — `nil` for a bookmark with no page in this file (a link to
    /// a web address, or a destination PDFKit cannot resolve). Drawn, and not clickable.
    public var pageIndex: Int?
}

enum EditorPDFOutline {

    /// The PDF's bookmarks, depth-first in the order the file gives them. **Called inside the lane
    /// only** — `outlineRoot` is a parse like any other.
    ///
    /// **A loop over an explicit stack, not recursion**: the nesting is the file's to choose, and a
    /// damaged or hostile outline nested a few thousand deep would otherwise take the lane's thread
    /// down with it.
    nonisolated static func flatten(_ document: PDFDocument) -> [EditorPDFOutlineEntry] {
        guard let root = document.outlineRoot else { return [] }
        var rows: [EditorPDFOutlineEntry] = []
        var stack: [(node: PDFOutline, depth: Int)] = children(of: root).reversed().map { ($0, 0) }
        while let (node, depth) = stack.popLast() {
            rows.append(EditorPDFOutlineEntry(title: title(node.label), depth: depth,
                                              pageIndex: pageIndex(of: node, in: document)))
            stack.append(contentsOf: children(of: node).reversed().map { ($0, depth + 1) })
        }
        return rows
    }

    private nonisolated static func children(of node: PDFOutline) -> [PDFOutline] {
        (0..<node.numberOfChildren).compactMap { node.child(at: $0) }
    }

    /// The page a bookmark goes to. `destination` covers both ways a file can say it — PDFKit
    /// fills it from a go-to action too (measured: an action-only fallback here changed nothing,
    /// and was removed as dead).
    private nonisolated static func pageIndex(of node: PDFOutline, in document: PDFDocument) -> Int? {
        guard let page = node.destination?.page else { return nil }
        let index = document.index(for: page)
        return index == NSNotFound ? nil : index
    }

    /// One line, as a rail row can draw it: a label with a line break in it is common in files
    /// made by a scanner's software.
    private nonisolated static func title(_ label: String?) -> String {
        (label ?? "").split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// **What the Outline tab draws from the bookmarks, worked out once per load** — not on every
    /// page turn, which redraws the tab: a manual with thousands of bookmarks walked them four
    /// times per turn when this was computed in the view.
    struct Rail: Equatable {
        let rows: [MarkdownOutlineEntry]
        /// Each bookmark's page number, one-based, by row id.
        let pageLabels: [Int: String]
        /// Rows with no page in this file.
        let inert: Set<Int>

        init(_ entries: [EditorPDFOutlineEntry]) {
            rows = EditorPDFOutline.rows(entries)
            var labels: [Int: String] = [:]
            var none: Set<Int> = []
            for (index, entry) in entries.enumerated() {
                if let page = entry.pageIndex { labels[index] = String(page + 1) } else { none.insert(index) }
            }
            pageLabels = labels
            inert = none
        }
    }

    /// The bookmarks as the rail's outline rows draw them — the Markdown outline's row type, so the
    /// Outline tab's list, its scroll memory and its opening scroll serve both kinds of file. The
    /// row's id is its position in the list (`line`), which is what the scroll memory keys on.
    static func rows(_ entries: [EditorPDFOutlineEntry]) -> [MarkdownOutlineEntry] {
        entries.enumerated().map { index, entry in
            MarkdownOutlineEntry(line: index, level: entry.depth + 1,
                                 depth: MarkdownOutline.drawnDepth(entry.depth), title: entry.title)
        }
    }

    /// The bookmark the reader is in: the one going to the latest page at or before `page`, the
    /// first in the list among bookmarks that go to the same page — a chapter rather than its first
    /// section, both of which start there. `nil` before the first bookmark's page.
    static func currentIndex(page: Int, in entries: [EditorPDFOutlineEntry]) -> Int? {
        var best: (index: Int, page: Int)?
        for (index, entry) in entries.enumerated() {
            guard let target = entry.pageIndex, target <= page else { continue }
            if best == nil || target > best!.page { best = (index, target) }
        }
        return best?.index
    }

    /// What the Outline tab says for a PDF with no rows — why there are none.
    ///
    /// **Out of sight since the tab became conditional** (asked 2026-10-17): a PDF shows Outline
    /// only with ``EditorRailTab/minimumPDFBookmarks`` or more, so the list is never drawn empty.
    /// Kept because the list needs a caption to hold and the phases still name the right reason.
    static func emptyCaption(phase: EditorPDFDocument.Phase) -> String {
        switch phase {
        case .open: return "This PDF has no bookmarks."
        case .loading: return "Reading the PDF…"
        case .locked: return "Unlock the PDF to see its bookmarks."
        case .refused: return "There is no outline to show for this file."
        }
    }
}

// MARK: - The Pages tab's layout

/// **How the Pages tab lays out a PDF's pages** (asked 2026-10-17): a grid, which gains columns as
/// the side column is dragged wider, or a list, one page under another at the column's width.
///
/// The geometry lives here rather than in the view so the thumbnails can be asked for at the size
/// the cells draw them: a list page at full width is two to five times a grid cell's, and drawn
/// from a grid-sized image it would be a blur.
public enum EditorPDFPagesLayout: String, CaseIterable, Sendable {
    case grid, list

    var title: String { self == .grid ? "Grid" : "List" }
    var symbol: String { self == .grid ? "square.grid.2x2" : "rectangle.grid.1x2" }
    var help: String { self == .grid ? "Show the pages in a grid" : "Show the pages one below another" }

    /// The tab's side padding, the gap between columns, and each cell's inset — the view's own.
    static let sidePadding: CGFloat = 12
    static let columnGap: CGFloat = 10
    static let cellInset: CGFloat = 4
    /// The narrowest a grid cell gets before the grid drops a column. Two columns always.
    static let minimumGridCell: CGFloat = 100

    /// Columns at a side column `railWidth` wide: two at the default 232pt, four at the widest.
    func columns(railWidth: CGFloat) -> Int {
        guard self == .grid else { return 1 }
        let inner = railWidth - 2 * Self.sidePadding
        return max(2, Int((inner + Self.columnGap) / (Self.minimumGridCell + Self.columnGap)))
    }

    /// The width a page image is drawn at, in points.
    func imageWidth(railWidth: CGFloat) -> CGFloat {
        let count = CGFloat(columns(railWidth: railWidth))
        let inner = railWidth - 2 * Self.sidePadding
        return max(1, (inner - (count - 1) * Self.columnGap) / count - 2 * Self.cellInset)
    }

    /// The long edge, in pixels, the thumbnails are asked for: a Letter page at ``imageWidth``, on
    /// a Retina screen, rounded up to a step of ``EditorPDFThumbnails/longEdge`` so a drag asks for
    /// a new size a handful of times rather than on every point. The default grid gets exactly the
    /// size it always had.
    func renderEdge(railWidth: CGFloat) -> CGFloat {
        let step = EditorPDFThumbnails.longEdge
        let needed = imageWidth(railWidth: railWidth) * 2 * 1.3
        return min(step * 6, max(step, (needed / step).rounded(.up) * step))
    }
}

// MARK: - The lane, as a value

/// **The turn-taker the reader's own lane work goes through — the thumbnails and the find — as a
/// value, so a test need not hold the process's lane.** Holding `PDFKitSerialAccess` to make a turn
/// wait blocks every PDF suite in the package, and a hold that then waits on the main actor — which
/// any test of a `@MainActor` pump must — lasts as long as the main actor is crowded: measured on CI
/// 2026-10-17, three such holds in the thumbnails' tests made a print test's 10 s budget run out
/// twice, on a run twice its usual length. Only `thumbnailsRenderThroughTheLane` and
/// `aFindPageRunsThroughTheLane` use the real lane, each holding it from a detached task.
///
/// **Type-erased to a `Void` turn**, so one seam serves turns that bring back different things:
/// ``perform(_:)`` carries the result out in a box.
struct EditorPDFLane: Sendable {
    let run: @Sendable (@escaping @Sendable () -> Void) async -> Void

    static let pdfKit = EditorPDFLane { body in await PDFKitSerialAccess.perform(body) }

    func perform<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        let box = OSAllocatedUnfairLock<T?>(initialState: nil)
        await run { let value = body(); box.withLock { $0 = value } }
        guard let value = box.withLock({ $0 }) else { preconditionFailure("a lane turn returned without running") }
        return value
    }
}

// MARK: - The thumbnails

/// **The Pages tab's thumbnails — rendered in the PDFKit lane, a page at a time, only for the pages
/// near the ones on screen, and released with the PDF.**
///
/// **Never `PDFThumbnailView`.** It draws its pages on AppKit's schedule, outside
/// `PDFKitSerialAccess`, and a parse outside the lane is what made 4.5–6.3% of fingerprints change
/// between runs. Each thumbnail here is one lane turn, drawn the way `PagePairRaster` draws a
/// compare raster: a bitmap context, a white ground, the page drawn into it.
///
/// **From a document of its own, not the reader's.** The page view draws the reader's document on
/// the main thread, on its own schedule — the lane's documented exception — so drawing that same
/// document here at the same moment would be two threads in one `PDFDocument`. This one is opened
/// in the lane on the first thumbnail and only ever touched there. A locked file's copy is
/// unlocked in the same lane turn as the reader's (``EditorPDFDocument/unlock(password:)``), so the
/// password is still used once and kept nowhere.
///
/// **One turn in flight at a time.** The lane is shared with a duplicate scan and a folder survey,
/// so a fast scroll through a 300-page scan must not queue 300 turns ahead of them. A single pump
/// asks for the most wanted page that has no image, waits for it, and asks again; a page scrolled
/// away before its turn is never asked for, and the one in flight is skipped at the head of its
/// turn if it is no longer wanted by then.
///
/// **Bounded.** At most ``capacity`` images are held; past that, those farthest from what is on
/// screen go first. ``detach()`` — every close, open and reload of the PDF — drops them all, and
/// the document with them.
@MainActor
public final class EditorPDFThumbnails: ObservableObject {

    /// The rendered pages, by zero-based index.
    @Published private(set) var images: [Int: SendableImage] = [:]
    /// Bumped by every ``attach``. **The Pages grid re-asks on it**: a PDF changed on disk reloads
    /// under a grid that stays mounted, so no cell appears again to say what is on screen, and the
    /// fresh document would otherwise draw nothing until the list was scrolled.
    @Published private(set) var attachments = 0

    /// The long edge a thumbnail is rendered to, in pixels, at the narrowest: twice the ~110pt a
    /// page gets in the rail's two columns, for a Retina screen. Wider cells ask for more — see
    /// ``renderEdge`` — in steps of this.
    nonisolated static let longEdge: CGFloat = 240
    /// How many pages either side of the visible ones are rendered ahead of a scroll, at
    /// ``longEdge``. Bigger pages look fewer ahead: ``margin(forEdge:)``.
    static let margin = 4
    /// The most images held at once at ``longEdge`` — about 10 MB. Bigger images, fewer held:
    /// ``capacity(forEdge:)``.
    static let capacity = 48

    /// The long edge the Pages tab's cells need now — ``longEdge`` until it says otherwise.
    private(set) var renderEdge: CGFloat = EditorPDFThumbnails.longEdge
    /// The edge each held image was drawn at, so a page drawn small is drawn again when its cell
    /// grows — and kept on screen, upscaled, until the sharper one lands.
    private var drawnEdge: [Int: CGFloat] = [:]

    /// **The image cap scales with the pixels in an image**, so the bytes held stay near the grid's
    /// ~10 MB — with a floor of 8, a list's window: a page or two on screen and two either side.
    /// At the widest list (1,440px) that floor is ~40 MB, held only while the list is.
    static func capacity(forEdge edge: CGFloat) -> Int {
        let ratio = longEdge / max(edge, longEdge)
        return max(8, Int(Double(capacity) * Double(ratio * ratio)))
    }

    /// Pages drawn ahead of a scroll: ``margin`` for grid-sized images, two for list-sized ones,
    /// where one page is most of the screen and each costs several times the lane time.
    static func margin(forEdge edge: CGFloat) -> Int {
        edge > longEdge * 2 ? 2 : margin
    }

    /// Sets the long edge the cells need. A bigger one redraws what is held, nearest first, and
    /// shows the smaller image until each lands; a smaller one keeps what is held, since a bigger
    /// image draws fine smaller, and lets the cap trim it.
    func setRenderEdge(_ edge: CGFloat) {
        guard edge != renderEdge else { return }
        renderEdge = edge
        evict()
        kick()
    }

    /// The document thumbnails are drawn from, created on the main actor and then touched only
    /// inside the lane — the box is how it crosses there.
    ///
    /// **Reopened every ``recycleEvery`` pages drawn.** A `PDFDocument` keeps what it decoded for
    /// every page it has drawn, so one document drawing a whole scan grows with it: measured
    /// 2026-10-17 on a 31 MB, 300-page scan, **56 MB** after all 300 pages from one document, and
    /// a flat **~25 MB** reopened every 48. The images are capped; this caps the document. A copy
    /// unlocked with a password cannot be reopened — the password is kept nowhere — so that one is
    /// kept, and pays the growth until the PDF closes.
    final class Source: @unchecked Sendable {
        let path: String
        /// Opened in the lane on the first render — or handed in already unlocked.
        var document: PDFDocument?
        var opened = false
        /// Whether ``document`` can be opened again from ``path`` — not a password-unlocked copy.
        let reopens: Bool
        /// Pages drawn from ``document`` since it was opened. Lane only.
        var drawnSinceOpen = 0
        /// Pages begun, counted inside the render itself — test instrumentation readable from any
        /// thread, so a test holding the lane can ask "did anything draw around it?" without
        /// waiting on the main actor while it holds.
        let draws = OSAllocatedUnfairLock(initialState: 0)
        /// Times ``document`` was opened from ``path``. Test instrumentation, as ``draws`` is.
        let opens = OSAllocatedUnfairLock(initialState: 0)
        init(path: String, unlocked: PDFDocument? = nil) {
            self.path = path
            self.document = unlocked
            self.opened = unlocked != nil
            self.reopens = unlocked == nil
        }
    }

    /// Pages drawn before the thumbnails' document is let go and reopened — see ``Source``.
    nonisolated static let recycleEvery = 48

    /// The pages wanted now, readable from inside the lane — so a turn that comes up for a page
    /// scrolled away since can skip itself before it draws anything.
    final class Wanted: Sendable {
        private let pages = OSAllocatedUnfairLock<Set<Int>>(initialState: [])
        func set(_ wanted: Set<Int>) { pages.withLock { $0 = wanted } }
        func contains(_ page: Int) -> Bool { pages.withLock { $0.contains(page) } }
    }

    /// What one lane turn did.
    enum Render: Sendable {
        case image(SendableImage)
        /// The page could not be drawn — not asked for again until the PDF is reopened.
        case failed
        /// No longer wanted when its turn came: nothing was drawn.
        case skipped
    }

    private var source: Source?
    private var pageCount = 0
    /// **One per attachment, never shared across them.** A turn still queued from the PDF before a
    /// reload holds the set it was given; if that were the live one, the new PDF's pages would make
    /// the old turn wanted again and it would draw from the old document for nothing.
    private var wanted = Wanted()
    /// The wanted pages in the order they are asked for: the visible ones from the top, then the
    /// margin pages nearest first.
    private var queue: [Int] = []
    private var failed: Set<Int> = []
    /// The pages kept on an eviction: the visible ones and their margin, as of the last ``show(_:)``.
    private var window: ClosedRange<Int>?
    private var pump: Task<Void, Never>?
    private var generation = 0

    /// Pages drawn in the lane since the last ``attach``, in the order they were drawn — test
    /// instrumentation; a cancelled page has no other outside signature.
    private(set) var drawn: [Int] = []
    /// Turns that came up for a page no longer wanted, and skipped. Test instrumentation.
    private(set) var skippedTurns = 0
    /// The page whose turn is out in the lane now, if any — so a test can know a turn is queued
    /// before it scrolls away from it.
    private(set) var asking: Int?
    /// Whether a document is held to draw from — none after ``detach()``.
    var holdsSource: Bool { source != nil }
    /// The source itself, for a test that reads ``Source/draws`` off the main actor.
    var currentSource: Source? { source }

    /// Where a turn runs. **Always the process-wide PDFKit lane in the app** (``Lane/pdfKit``); a
    /// test hands in a private one it can hold — see ``EditorPDFLane``.
    private let lane: Lane

    typealias Lane = EditorPDFLane

    public init() { lane = .pdfKit }

    init(lane: Lane) { self.lane = lane }

    /// Starts over for a newly opened (or reloaded, or unlocked) PDF of `pageCount` pages.
    func attach(path: String, pageCount: Int, unlocked: PDFDocument? = nil) {
        detach()
        source = Source(path: path, unlocked: unlocked)
        self.pageCount = pageCount
        attachments &+= 1
    }

    /// Drops every image and the document they were drawn from. A turn already in the lane finishes
    /// and is ignored; its hold on the document goes with it.
    func detach() {
        generation &+= 1
        pump?.cancel()
        pump = nil
        source = nil
        pageCount = 0
        queue = []
        failed = []
        window = nil
        // Emptied, so a turn already queued from before skips itself; then replaced (see `wanted`).
        wanted.set([])
        wanted = Wanted()
        asking = nil
        if !images.isEmpty { images = [:] }
        drawnEdge = [:]
        drawn = []
        skippedTurns = 0
    }

    /// The pages on screen now. Renders those and ``margin`` either side, nearest first, and lets
    /// go of what is no longer near. An empty set — the tab put away — stops asking for anything.
    func show(_ visible: Set<Int>) {
        let onScreen = visible.filter { $0 >= 0 && $0 < pageCount }.sorted()
        guard let first = onScreen.first, let last = onScreen.last else {
            queue = []
            wanted.set([])
            return
        }
        let margin = Self.margin(forEdge: renderEdge)
        let lower = max(first - margin, 0)
        let upper = min(last + margin, pageCount - 1)
        let around = (lower...upper).filter { !visible.contains($0) }
            .sorted { distance($0, first, last) < distance($1, first, last) }
        queue = onScreen + around
        wanted.set(Set(queue))
        window = lower...upper
        evict()
        kick()
    }

    private func distance(_ page: Int, _ first: Int, _ last: Int) -> Int {
        page < first ? first - page : page - last
    }

    /// Past the cap for ``renderEdge``, drops the images farthest from ``window``.
    private func evict() {
        let capacity = Self.capacity(forEdge: renderEdge)
        guard images.count > capacity, let window else { return }
        let far = images.keys.filter { !window.contains($0) }
            .sorted { distance($0, window.lowerBound, window.upperBound)
                      > distance($1, window.lowerBound, window.upperBound) }
        var next = images
        for page in far.prefix(images.count - capacity) { next[page] = nil; drawnEdge[page] = nil }
        images = next
    }

    private func nextPage() -> Int? {
        queue.first { (drawnEdge[$0] ?? 0) < renderEdge && !failed.contains($0) }
    }

    private func kick() {
        guard pump == nil, source != nil, nextPage() != nil else { return }
        let generation = self.generation
        pump = Task { [weak self] in
            // **`self` is held only between turns, never across one.** A turn can wait behind a
            // duplicate scan for minutes, and a strong reference held through that wait would keep
            // this object and its images alive past the model that owns them.
            while let ask = self?.nextAsk(generation) {
                let result = await Self.render(page: ask.page, source: ask.source, wanted: ask.wanted,
                                               longEdge: ask.edge, lane: ask.lane)
                guard let self, generation == self.generation else { return }
                self.land(result, page: ask.page, edge: ask.edge)
            }
            guard let self, generation == self.generation else { return }
            self.pump = nil
        }
    }

    /// The next turn to ask for in `generation`, or `nil` when there is none — and marks it asked.
    private func nextAsk(_ generation: Int) -> (page: Int, source: Source, wanted: Wanted, edge: CGFloat, lane: Lane)? {
        guard generation == self.generation, let page = nextPage(), let source else { return nil }
        asking = page
        return (page, source, wanted, renderEdge, lane)
    }

    /// What one turn brought back, applied.
    private func land(_ result: Render, page: Int, edge: CGFloat) {
        asking = nil
        switch result {
        case .image(let image):
            drawn.append(page)
            // Kept only if still near; drawn either way, so counted either way.
            if wanted.contains(page) {
                images[page] = image
                drawnEdge[page] = edge
                evict()
            }
        case .failed:
            drawn.append(page)
            failed.insert(page)
        case .skipped:
            skippedTurns += 1
            // Not wanted any more, so not next either — `queue` was replaced.
        }
    }

    /// One lane turn: open the source if this is its first, then draw one page.
    nonisolated static func render(page: Int, source: Source, wanted: Wanted,
                                   longEdge: CGFloat = EditorPDFThumbnails.longEdge,
                                   lane: Lane = .pdfKit) async -> Render {
        await lane.perform {
            guard wanted.contains(page) else { return .skipped }
            source.draws.withLock { $0 += 1 }
            if source.reopens, source.drawnSinceOpen >= recycleEvery {
                source.document = nil
                source.opened = false
            }
            if !source.opened {
                source.opened = true
                source.drawnSinceOpen = 0
                source.document = PDFDocument(url: URL(fileURLWithPath: source.path))
                source.opens.withLock { $0 += 1 }
            }
            source.drawnSinceOpen += 1
            guard let document = source.document, !document.isLocked,
                  let pdfPage = document.page(at: page),
                  let image = drawThumbnail(pdfPage, longEdge: longEdge)
            else { return .failed }
            return .image(image)
        }
    }

    /// A page's shape as the reader sees it: its crop box, turned by its rotation.
    nonisolated static func shownSize(of page: PDFPage) -> CGSize {
        let box = page.bounds(for: .cropBox)
        return (page.rotation / 90) % 2 != 0 ? CGSize(width: box.height, height: box.width) : box.size
    }

    /// One page as the reader sees it, at `longEdge`: the crop box, turned by the page's rotation.
    ///
    /// `PagePairRaster.render`'s drawing — a bitmap context, a white ground, the page drawn into
    /// it — with the two things a thumbnail must match the page view on and a compare raster need
    /// not: the box PDFKit displays (`cropBox`, the `PDFView` default) and the page's rotation.
    ///
    /// **`draw(with:to:)` applies both itself** — the rotation and the box's origin. This first
    /// shipped with `transform(for:)` concatenated before it as well, and measured 2026-10-17 with
    /// a page marked in one corner, that applied them TWICE: a quarter-turned page drew blank and a
    /// cropped one drew shifted. `aRotatedOrCroppedPageDrawsWhereTheReaderSeesIt` reads pixels.
    /// Called inside the lane only.
    nonisolated static func drawThumbnail(_ page: PDFPage, longEdge: CGFloat) -> SendableImage? {
        let shown = shownSize(of: page)
        guard shown.width > 1, shown.height > 1 else { return nil }
        let scale = longEdge / max(shown.width, shown.height)
        let size = CGSize(width: (shown.width * scale).rounded(), height: (shown.height * scale).rounded())
        guard size.width >= 1, size.height >= 1,
              let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .cropBox, to: context)
        return context.makeImage().map(SendableImage.init)
    }
}

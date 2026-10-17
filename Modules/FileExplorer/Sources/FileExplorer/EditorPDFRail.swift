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
    static func emptyCaption(phase: EditorPDFDocument.Phase) -> String {
        switch phase {
        case .open: return "This PDF has no bookmarks."
        case .loading: return "Reading the PDF…"
        case .locked: return "Unlock the PDF to see its bookmarks."
        case .refused: return "There is no outline to show for this file."
        }
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

    /// The long edge a thumbnail is rendered to, in pixels: twice the ~110pt a page gets in the
    /// rail's two columns, for a Retina screen.
    nonisolated static let longEdge: CGFloat = 240
    /// How many pages either side of the visible ones are rendered ahead of a scroll.
    static let margin = 4
    /// The most images held at once — about 10 MB at ``longEdge``.
    static let capacity = 48

    /// The document thumbnails are drawn from, created on the main actor and then touched only
    /// inside the lane — the box is how it crosses there.
    final class Source: @unchecked Sendable {
        let path: String
        /// Opened in the lane on the first render — or handed in already unlocked.
        var document: PDFDocument?
        var opened = false
        /// Pages begun, counted inside the render itself — test instrumentation readable from any
        /// thread, so a test holding the lane can ask "did anything draw around it?" without
        /// waiting on the main actor while it holds.
        let draws = OSAllocatedUnfairLock(initialState: 0)
        init(path: String, unlocked: PDFDocument? = nil) {
            self.path = path
            self.document = unlocked
            self.opened = unlocked != nil
        }
    }

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
    private let wanted = Wanted()
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

    public init() {}

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
        wanted.set([])
        asking = nil
        if !images.isEmpty { images = [:] }
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
        let lower = max(first - Self.margin, 0)
        let upper = min(last + Self.margin, pageCount - 1)
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

    /// Past ``capacity``, drops the images farthest from ``window``.
    private func evict() {
        guard images.count > Self.capacity, let window else { return }
        let far = images.keys.filter { !window.contains($0) }
            .sorted { distance($0, window.lowerBound, window.upperBound)
                      > distance($1, window.lowerBound, window.upperBound) }
        var next = images
        for page in far.prefix(images.count - Self.capacity) { next[page] = nil }
        images = next
    }

    private func nextPage() -> Int? {
        queue.first { images[$0] == nil && !failed.contains($0) }
    }

    private func kick() {
        guard pump == nil, source != nil, nextPage() != nil else { return }
        let generation = self.generation
        pump = Task { [weak self] in
            while let self, generation == self.generation, let page = self.nextPage(),
                  let source = self.source {
                self.asking = page
                let result = await Self.render(page: page, source: source, wanted: self.wanted)
                guard generation == self.generation else { return }
                self.asking = nil
                switch result {
                case .image(let image):
                    self.drawn.append(page)
                    // Kept only if still near; drawn either way, so counted either way.
                    if self.wanted.contains(page) {
                        self.images[page] = image
                        self.evict()
                    }
                case .failed:
                    self.drawn.append(page)
                    self.failed.insert(page)
                case .skipped:
                    self.skippedTurns += 1
                    // Not wanted any more, so not next either — `queue` was replaced.
                }
            }
            guard let self, generation == self.generation else { return }
            self.pump = nil
        }
    }

    /// One lane turn: open the source if this is its first, then draw one page.
    nonisolated static func render(page: Int, source: Source, wanted: Wanted) async -> Render {
        await PDFKitSerialAccess.perform {
            guard wanted.contains(page) else { return .skipped }
            source.draws.withLock { $0 += 1 }
            if !source.opened {
                source.opened = true
                source.document = PDFDocument(url: URL(fileURLWithPath: source.path))
            }
            guard let document = source.document, !document.isLocked,
                  let pdfPage = document.page(at: page),
                  let image = drawThumbnail(pdfPage, longEdge: longEdge)
            else { return .failed }
            return .image(image)
        }
    }

    /// One page as the reader sees it, at `longEdge`: the crop box, turned by the page's rotation.
    ///
    /// `PagePairRaster.render`'s drawing — a bitmap context, a white ground, the page drawn into
    /// it — with the two things a thumbnail must match the page view on and a compare raster need
    /// not: the box PDFKit displays (`cropBox`, the `PDFView` default) and the page's rotation, which
    /// `transform(for:)` applies along with the box's origin. Called inside the lane only.
    nonisolated static func drawThumbnail(_ page: PDFPage, longEdge: CGFloat) -> SendableImage? {
        let box = page.bounds(for: .cropBox)
        guard box.width > 1, box.height > 1 else { return nil }
        let quarterTurned = (page.rotation / 90) % 2 != 0
        let shown = quarterTurned ? CGSize(width: box.height, height: box.width) : box.size
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
        context.concatenate(page.transform(for: .cropBox))
        page.draw(with: .cropBox, to: context)
        return context.makeImage().map(SendableImage.init)
    }
}

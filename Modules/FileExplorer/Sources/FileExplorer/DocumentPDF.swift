import AppKit
import SwiftUI
import Design

/// The open document as PDF pages: the one render behind both File ▸ Print… and
/// File ▸ Export as PDF…, so Export writes exactly the bytes Print is handed and the two can't
/// disagree.
///
/// Markdown is drawn by ``MarkdownBlockView``, the preview's own arms, in `.page` medium. Plain
/// text is drawn by CoreText instead: it has no blocks, and `CTFramesetter` breaks at lines for
/// free. `ImageRenderer.render` draws into the PDF's `CGContext`, so the text stays vector,
/// selectable and searchable; `DocumentPDFTests` checks that by reading the text back.
@MainActor
public enum DocumentPDF {

    /// What to render: a document, and how the app is currently drawing it. A snapshot of the
    /// text, not the ``EditorDocument``, so the buffer can't move under the render and a test can
    /// render a document that was never opened.
    public struct Job: Sendable {
        /// The file's name, used for the print job and the export's suggested filename.
        public var name: String
        /// The document's text, exactly as the buffer holds it.
        public var text: String
        /// Whether to draw the Markdown render or the plain-text one.
        public var isMarkdown: Bool
        /// The folder the document lives in — what a relative image path resolves against.
        public var folder: String?
        /// Settings ▸ Text size, so the page is set in the type the reader chose.
        public var fontScale: CGFloat
        /// The window's accent, which links and quote bars are drawn in. Paper keeps it, so the
        /// page matches the preview.
        public var accent: Color

        public init(name: String, text: String, isMarkdown: Bool,
                    folder: String? = nil, fontScale: CGFloat = 1,
                    accent: Color = LiquidGlassHue.stored().accentColor) {
            self.name = name
            self.text = text
            self.isMarkdown = isMarkdown
            self.folder = folder
            self.fontScale = fontScale
            self.accent = accent
        }

        /// The name to suggest for an exported file: the document's, with `.pdf` for whatever it
        /// had. `notes.md` becomes `notes.pdf`; a file with no extension gains one.
        public var exportName: String {
            let base = (name as NSString).deletingPathExtension
            return (base.isEmpty ? "Document" : base) + ".pdf"
        }
    }

    /// The paper, and the box on it that content may occupy. Read off `NSPrintInfo`, so the
    /// reader's default paper decides the shape: a page laid out for A4 and printed on Letter
    /// loses a line at the foot.
    public struct PageGeometry: Equatable, Sendable {
        /// The whole sheet, in points.
        public var paper: CGSize
        /// The part of it that may be drawn on, in the PDF's own bottom-left origin.
        public var content: CGRect

        public init(paper: CGSize, content: CGRect) {
            self.paper = paper
            self.content = content
        }

        /// The geometry a print operation would use, from the print system's own numbers.
        ///
        /// `imageablePageBounds` rather than the margins: it is what the printer can reach within
        /// them, so a footer lands on the page rather than in the driver's clip.
        public static func from(_ info: NSPrintInfo) -> PageGeometry {
            let paper = info.paperSize
            var box = info.imageablePageBounds
            // With no printer configured the imageable box can be empty. Fall back to half an inch
            // all round, so an export still makes a readable page.
            if box.width <= 0 || box.height <= 0 {
                box = CGRect(x: 36, y: 36, width: paper.width - 72, height: paper.height - 72)
            }
            return PageGeometry(paper: paper, content: box)
        }

        /// US Letter with half-inch margins, for when no print system is involved (the tests).
        public static let letter = PageGeometry(
            paper: CGSize(width: 612, height: 792),
            content: CGRect(x: 36, y: 36, width: 540, height: 720))
    }

    /// The document as PDF bytes, or `nil` when the render produced nothing at all.
    public static func data(for job: Job, geometry: PageGeometry = .letter) -> Data? {
        job.isMarkdown ? markdown(job, geometry) : plainText(job, geometry)
    }

    // MARK: - Markdown: the preview's own arms, stacked and cut into pages

    private static func markdown(_ job: Job, _ geometry: PageGeometry) -> Data? {
        let blocks = MarkdownBlocks.blocks(from: job.text)
        let width = geometry.content.width
        let images = preloadImages(in: blocks, folder: job.folder)

        // Each block is measured, then pinned to that height, so the drawn stack matches the page
        // breaks exactly. Laid out freely it would drift a fraction of a point per block and,
        // forty blocks in, break inside a heading.
        let measured = blocks.map { measure($0, job: job, images: images, width: width) }
        let heights = measured.map(\.height)
        let total = heights.reduce(0, +)
        guard total > 0 else { return blankPage(geometry) }

        // Each page draws only its own blocks, found by these prefix sums. Drawing the whole
        // document clipped per page is quadratic, and near the editor's 4 MiB read cap it hangs.
        var tops: [CGFloat] = []
        tops.reserveCapacity(heights.count)
        var running: CGFloat = 0
        for height in heights { tops.append(running); running += height }

        let pages = DocumentPagination.pages(blockHeights: heights,
                                             pageHeight: geometry.content.height)
        return pdf(geometry: geometry) { context in
            for page in pages {
                context.beginPDFPage(nil)
                paintPaper(context, geometry)
                let bottom = page.start + page.height
                let shown = heights.indices.filter { index in
                    tops[index] < bottom && tops[index] + heights[index] > page.start
                }
                if let first = shown.first {
                    let slice = VStack(alignment: .leading, spacing: 0) {
                        ForEach(shown, id: \.self) { index in measured[index].view }
                    }
                    .frame(width: width, alignment: .topLeading)
                    // Light, whatever the app wears: the arms' semantic colours follow the scheme,
                    // and dark mode would print white on black.
                    .environment(\.colorScheme, .light)
                    .environment(\.appFontScale, job.fontScale)

                    let renderer = ImageRenderer(content: AnyView(slice))
                    renderer.proposedSize = ProposedViewSize(width: width, height: nil)
                    let sliceHeight = shown.reduce(CGFloat(0)) { $0 + heights[$1] }
                    // How far into the first drawn block this page begins; non-zero only for a
                    // block too tall for a page, the one case a block is cut.
                    let into = page.start - tops[first]

                    renderer.render { _, draw in
                        context.saveGState()
                        // Clipped to this page's slice, not the content box. A page that breaks
                        // early is shorter than the box, and clipping to the box would let the next
                        // block's first line bleed in and print on two pages
                        // (`noBlockIsSplitAcrossAPageBreak`).
                        context.clip(to: CGRect(x: geometry.content.minX,
                                                y: geometry.content.maxY - page.height,
                                                width: geometry.content.width,
                                                height: page.height))
                        // The slice is drawn from its own bottom-left, so its top lands at
                        // `maxY - sliceHeight`; `into` slides it up when the page starts partway
                        // through the first block.
                        context.translateBy(x: geometry.content.minX,
                                            y: geometry.content.maxY - sliceHeight + into)
                        draw(context)
                        context.restoreGState()
                    }
                }
                context.endPDFPage()
            }
        }
    }

    /// One block, and how tall it is at the page's content width.
    private struct Measured {
        var view: AnyView
        var height: CGFloat
    }

    /// Lays a block out at the page width and pins it to what it measured.
    ///
    /// A table too wide for the page is scaled down: it can't wrap like prose and code, and clipped
    /// columns vanish silently. Only tables are measured unbounded, since that gives a table its
    /// natural width but puts anything else on one line.
    private static func measure(_ block: MarkdownBlock, job: Job,
                                images: [String: MarkdownImageView.Preloaded],
                                width: CGFloat) -> Measured {
        let content = MarkdownBlockView(block: block, accent: job.accent, documentFolder: job.folder,
                                        medium: .page, preloadedImages: images)
            .environment(\.colorScheme, .light)
            .environment(\.appFontScale, job.fontScale)

        if case .table = block.kind {
            let natural = fittingSize(content, proposal: nil)
            if natural.width > width, natural.width > 0 {
                let scale = width / natural.width
                let scaled = content
                    .frame(width: natural.width, alignment: .topLeading)
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(width: width, height: natural.height * scale, alignment: .topLeading)
                return Measured(view: AnyView(scaled), height: natural.height * scale)
            }
        }

        let height = fittingSize(content, proposal: width).height
        let pinned = content.frame(width: width, height: height, alignment: .topLeading)
        return Measured(view: AnyView(pinned), height: height)
    }

    /// What a view measures at a proposed width, or unbounded when `proposal` is `nil`.
    ///
    /// A fresh hosting view per block: re-rooting one long-lived `NSHostingView` is several times
    /// slower (500 blocks: 345 ms vs 2,612 ms), because re-rooting invalidates more than building.
    /// Forced to Aqua so the numbers match the light render the pagination trusts.
    private static func fittingSize(_ view: some View, proposal: CGFloat?) -> CGSize {
        // The width goes on the view, not the hosting view's frame: `fittingSize` reports the
        // ideal size, which a host frame doesn't constrain, so a paragraph would measure one line
        // tall and print truncated with an ellipsis.
        let root = proposal.map { AnyView(view.frame(width: $0, alignment: .topLeading)) }
            ?? AnyView(view)
        let hosting = NSHostingView(rootView: root)
        hosting.appearance = NSAppearance(named: .aqua)
        let size = hosting.fittingSize
        // At least 1pt: a zero-height entry would let a page break land on the next block's first
        // line.
        return CGSize(width: size.width, height: max(size.height, 1))
    }

    /// Resolves and decodes every image the document names, before anything is drawn.
    /// ``MarkdownImageView`` loads in a `.task`, which never runs in an offscreen render, so
    /// otherwise every image would print as "Loading…". Same calls, in the same order, as that
    /// view, so a picture the preview refuses is refused on paper with the same row.
    ///
    /// Keyed by the raw source text, which is what the block carries and the view looks up.
    private static func preloadImages(in blocks: [MarkdownBlock],
                                      folder: String?) -> [String: MarkdownImageView.Preloaded] {
        var loaded: [String: MarkdownImageView.Preloaded] = [:]
        for block in blocks {
            guard case .image(let source, _) = block.kind, loaded[source] == nil else { continue }
            switch MarkdownImageSource.resolve(source, relativeTo: folder) {
            case .refused(let reason):
                loaded[source] = .refused(reason)
            case .local(let path):
                if let image = NSImage(contentsOfFile: path) {
                    loaded[source] = .image(image)
                } else {
                    loaded[source] = .refused("Couldn’t be read as an image.")
                }
            }
        }
        return loaded
    }

    // MARK: - Plain text: CoreText, breaking where the lines are

    /// A plain-text document, set in the editor's own monospaced face.
    ///
    /// `CTFramesetter` fills a page with whole lines and reports where it stopped, so a break never
    /// lands inside a line, far faster than measuring every line through SwiftUI.
    private static func plainText(_ job: Job, _ geometry: PageGeometry) -> Data? {
        guard !job.text.isEmpty else { return blankPage(geometry) }

        let paragraph = NSMutableParagraphStyle()
        // Always wrapped, whatever the Source pane's switch says: paper can't scroll sideways.
        paragraph.lineBreakMode = .byWordWrapping
        let attributed = NSAttributedString(string: job.text, attributes: [
            .font: PlainTextEditor.font(scale: job.fontScale),
            .foregroundColor: NSColor.black,
            .paragraphStyle: paragraph,
        ])

        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: geometry.content, transform: nil)
        let length = attributed.length

        return pdf(geometry: geometry) { context in
            var start = 0
            // A page that consumes nothing (a line taller than the content box) would spin
            // forever, so it gets one page and the loop moves on.
            repeat {
                context.beginPDFPage(nil)
                paintPaper(context, geometry)
                let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: start, length: 0),
                                                     path, nil)
                CTFrameDraw(frame, context)
                context.endPDFPage()
                let consumed = CTFrameGetVisibleStringRange(frame).length
                start += consumed > 0 ? consumed : length
            } while start < length
        }
    }

    // MARK: - The PDF context

    /// Runs `body` against a PDF context of this geometry and returns what it wrote.
    private static func pdf(geometry: PageGeometry, _ body: (CGContext) -> Void) -> Data? {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data) else { return nil }
        var media = CGRect(origin: .zero, size: geometry.paper)
        guard let context = CGContext(consumer: consumer, mediaBox: &media, nil) else { return nil }
        body(context)
        context.closePDF()
        return data.isEmpty ? nil : data as Data
    }

    /// Paints the page white. An unpainted PDF page is transparent, which some compositors show
    /// as black.
    private static func paintPaper(_ context: CGContext, _ geometry: PageGeometry) {
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(origin: .zero, size: geometry.paper))
    }

    /// One empty sheet — what an empty document exports as. See ``DocumentPagination/pages(blockHeights:pageHeight:)``.
    private static func blankPage(_ geometry: PageGeometry) -> Data? {
        pdf(geometry: geometry) { context in
            context.beginPDFPage(nil)
            paintPaper(context, geometry)
            context.endPDFPage()
        }
    }
}

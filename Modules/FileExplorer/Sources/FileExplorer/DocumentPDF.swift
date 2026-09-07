import AppKit
import SwiftUI
import Design

/// The open document as PDF pages — the one render behind both File ▸ Print… and
/// File ▸ Export as PDF… (roadmap RD9).
///
/// **One render, two destinations, and that is the design rather than an economy.** The menu says
/// Print prints what Preview shows and Export writes the same thing to a file; two rendering paths
/// would make that two claims that happen to agree today. Here the export writes exactly the bytes
/// the print operation is handed, so the only way for them to disagree is for the file to be
/// written wrong — which the atomic write path already checks.
///
/// **A Markdown document is drawn by ``MarkdownBlockView``**, the same arms the preview column
/// draws, in `.page` medium — see that type for the two differences paper forces. **A plain-text
/// document is drawn by CoreText**, not by this pipeline at all: it has no blocks to break between,
/// and `CTFramesetter` breaks at line boundaries for free where a block paginator would have to be
/// told what a line is. That is the roadmap's "a plain text file prints as text", and it is why the
/// two paths look nothing alike.
///
/// **Vector text, not a picture of text.** `ImageRenderer.render` hands over a `CGContext` and
/// draws into it, so the glyphs in the PDF are glyphs: the result is selectable, searchable, and
/// sharp at any zoom. `DocumentPDFTests` pins that by extracting the text back out of the rendered
/// bytes with PDFKit — a rasterising regression would return nothing and fail there rather than in
/// somebody's printer tray.
@MainActor
public enum DocumentPDF {

    /// What to render: a document, and how the app is currently drawing it.
    ///
    /// **The text, not the ``EditorDocument``.** The renderer takes a snapshot so it can be built
    /// on the main actor and reasoned about without the buffer moving underneath it — and so that
    /// a test can render a document that was never opened.
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
        /// The window's accent, which is what a link and a quote bar are drawn in on screen. Paper
        /// keeps it: the page is the preview, and a preview in one colour printed in another is a
        /// different document.
        public var accent: Color

        public init(name: String, text: String, isMarkdown: Bool,
                    folder: String? = nil, fontScale: CGFloat = 1,
                    accent: Color = .accentColor) {
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

    /// The paper, and the box on it that content may occupy.
    ///
    /// **Read off `NSPrintInfo`, so the reader's own default paper decides the shape.** A4 and US
    /// Letter differ by enough that a page laid out for one and printed on the other loses a line
    /// at the foot; taking the size from the print system means the common case — one default
    /// printer, one paper — is right without anybody choosing anything.
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
        /// `imageablePageBounds` rather than the four margins: it is the intersection of the
        /// margins with what the *printer* can actually reach, which is the smaller of the two and
        /// the one that decides whether a footer lands on the page or in the driver's clip.
        public static func from(_ info: NSPrintInfo) -> PageGeometry {
            let paper = info.paperSize
            var box = info.imageablePageBounds
            // A print system with no printers configured can report an empty imageable box. Half an
            // inch all round is the fallback, so an export still produces a readable page on a Mac
            // that has never been near a printer.
            if box.width <= 0 || box.height <= 0 {
                box = CGRect(x: 36, y: 36, width: paper.width - 72, height: paper.height - 72)
            }
            return PageGeometry(paper: paper, content: box)
        }

        /// US Letter with half-inch margins — the shape used when no print system is involved,
        /// which in practice means the tests.
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

        // Measured one block at a time, then each block PINNED to the height it measured.
        //
        // **The pin is what makes the pagination true rather than approximate.** The page breaks
        // below are arithmetic over these numbers, and the stack that gets drawn has to agree with
        // them exactly — a stack that laid each block out freely would drift from the model by a
        // fraction of a point per block and, forty blocks in, break in the middle of a heading.
        // Pinning cannot drift: the height in the model IS the height in the layout.
        let measured = blocks.map { measure($0, job: job, images: images, width: width) }
        let heights = measured.map(\.height)
        let total = heights.reduce(0, +)
        guard total > 0 else { return blankPage(geometry) }

        // **Each page draws only the blocks that appear on it**, rather than the whole document
        // clipped to a window onto it. Both are correct; only one is linear. The clipped-whole-
        // document form re-ran the entire render once per page — measured on a 2,000-block
        // document, 90 pages each drawing 2,000 blocks — which is quadratic in the document's
        // length and, on a file near the editor's 4 MiB read cap, is the difference between a
        // pause and a hang. The prefix sums below are what make a page's own blocks findable.
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
                    // **Light, whatever the app is wearing.** Every semantic colour in these arms —
                    // the secondary text of a quote, the fill behind a code fence — resolves against
                    // the ambient scheme, and a document printed in dark mode would be
                    // white-on-black: unreadable on paper and a cartridge's worth of ink.
                    .environment(\.colorScheme, .light)
                    .environment(\.appFontScale, job.fontScale)

                    let renderer = ImageRenderer(content: AnyView(slice))
                    renderer.proposedSize = ProposedViewSize(width: width, height: nil)
                    let sliceHeight = shown.reduce(CGFloat(0)) { $0 + heights[$1] }
                    // How far into the first drawn block this page begins — non-zero only for a
                    // block too tall to fit a page, which is the one case a block is cut.
                    let into = page.start - tops[first]

                    renderer.render { _, draw in
                        context.saveGState()
                        // **Clipped to this page's SLICE, not to the content box.** A page that
                        // breaks early — which is every page that moved a block down rather than
                        // cutting it — is shorter than the box it is drawn in, and clipping to the
                        // box let the next block's first line bleed into the space the break had
                        // just made for it. It showed up as the same paragraph printed on two
                        // consecutive pages, which is what `noBlockIsSplitAcrossAPageBreak` refuses.
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
    /// **A table is the one block that may be scaled**, and only when it is genuinely too wide.
    /// Everything else on a page either wraps (prose, and on paper, code) or is already bounded by
    /// the column (an image). A table can do neither — a `Grid` is as wide as its columns need —
    /// and the alternatives to scaling are both losses: clipped columns disappear with nothing to
    /// say they existed, and a wrapped cell turns a table into a paragraph. Measured against an
    /// unbounded proposal, which for a table is its natural width and for anything else would be
    /// the whole document on one line — which is why this asks only about tables.
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
    /// **A fresh hosting view per block, which is measured rather than assumed.** Re-rooting one
    /// long-lived `NSHostingView` and re-laying it out is the obvious economy and it is a loss:
    /// measured on this branch, 500 blocks went from 345ms to 2,612ms and 2,000 from 1.5s to 4.2s,
    /// because re-rooting invalidates more than building does. Left as it is, with the numbers, so
    /// the economy is not attempted a second time.
    ///
    /// The appearance is forced to Aqua for the reason the render forces a light colour scheme: a
    /// measurement taken in the app's dark appearance is not wrong, but it is a different one, and
    /// the numbers the pagination trusts must be the numbers the light render produces.
    private static func fittingSize(_ view: some View, proposal: CGFloat?) -> CGSize {
        // **The width is applied to the VIEW, not to the hosting view's frame**, and that
        // distinction is the whole measurement. `fittingSize` reports the content's *ideal* size,
        // which a frame on the host does not constrain — so a paragraph measured that way came back
        // one line tall, was pinned to one line, and printed as a sentence ending in an ellipsis.
        // Every prose block in a real document was truncated, and the page-break tests could not
        // see it: the words they look for are all on the first line.
        let root = proposal.map { AnyView(view.frame(width: $0, alignment: .topLeading)) }
            ?? AnyView(view)
        let hosting = NSHostingView(rootView: root)
        hosting.appearance = NSAppearance(named: .aqua)
        let size = hosting.fittingSize
        // A block that measures nothing still occupies its own row in the model, and a zero-height
        // entry would let the page break land on top of the next block's first line.
        return CGSize(width: size.width, height: max(size.height, 1))
    }

    /// Resolves and decodes every image the document names, before anything is drawn.
    ///
    /// **Because a page has no second frame.** ``MarkdownImageView`` loads in a `.task`, and tasks
    /// do not run inside an offscreen render — left to itself every image in the PDF would be the
    /// "Loading…" placeholder. The resolve and the decode here are the same two calls that view
    /// makes, in the same order, so a picture the preview refuses to draw (remote, cloud-only, too
    /// large) is refused on paper for the same reason and prints the same explanatory row.
    ///
    /// Keyed by the raw source text, which is what the block carries and what the view looks up.
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
    /// **`CTFramesetter` rather than the block pipeline**, for the reason the type's doc gives: it
    /// fills a page with as many whole lines as fit and reports where it stopped, so a page break
    /// can never land inside a line. Measuring a hundred thousand lines through SwiftUI to reach
    /// the same guarantee would take longer than the print.
    private static func plainText(_ job: Job, _ geometry: PageGeometry) -> Data? {
        guard !job.text.isEmpty else { return blankPage(geometry) }

        let paragraph = NSMutableParagraphStyle()
        // Wrapped, always — the Source pane's own wrap switch is about a column that can scroll
        // sideways, and paper cannot. An unwrapped page would clip every long line at the margin.
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
            // A page that consumes nothing would spin forever — a line taller than the whole
            // content box does exactly that. One page, then move on; the guard is the loop's, not
            // the format's.
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

    /// **White paper, drawn rather than assumed.** A PDF page has no background: left unpainted it
    /// is transparent, which every viewer shows as white and some compositors show as black — and
    /// printing it onto anything but white paper reads as a bug.
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

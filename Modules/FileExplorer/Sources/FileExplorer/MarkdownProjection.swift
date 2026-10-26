import AppKit
import Events
import Markdown

// MARK: - What the projection is made of

/// Why part of the editable preview cannot take a caret.
enum PreviewReadOnlyReason: String, Equatable, Sendable {
    case frontMatter
    case html
    case indentedCode
    /// The parser's positions for this block could not be lined up with its source, character for
    /// character. See ``MarkdownProjection`` — the block is shown, and left alone.
    case unalignable
    /// A table wider than the text column: tab stops cannot wrap a cell, and a wrapped row would
    /// break the grid, so it is drawn and left to Source (§3.8).
    case wideTable
    /// A code span that wraps a line: its newlines render as spaces, and v1 does not map them.
    case multilineCode
    case inlineHTML
    /// A node the walk does not model, shown as the library's own plain rendering.
    case unknown
}

/// One inline container the source wraps text in: `**…**`, `*…*`, `~~…~~`, `[…](…)`, `` `…` ``.
///
/// **The full source range, delimiters included.** The translator needs the delimiters to decide
/// what typing at an edge continues, and to delete them with the last character inside.
struct PreviewInlineSpan: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case strong, emphasis, strikethrough, code
        case link(destination: String?)
    }
    var kind: Kind
    var source: NSRange
}

/// One piece of the rendered preview, and the source it came from.
///
/// The segments are an ordered, gap-free cover of ``MarkdownProjection/rendered``. Source ranges
/// increase and never overlap, but they do **not** cover the source: the Markdown syntax between
/// them — a `**`, a `> `, a list marker, a `|` — is never inside a segment, which is why typing in
/// the preview cannot touch it.
struct PreviewSegment: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// Editable text. Rendered characters map onto source characters through ``charMap``.
        case content
        /// A single newline in a paragraph, rendered as a space.
        case softBreak
        /// A hard line break (`\` or two spaces, then a newline), rendered as U+2028.
        case hardBreak
        /// The newline between two lines of a fenced code block.
        case codeNewline
        /// The tab between two table cells. Its source is the `|` and the padding around it.
        case cellBreak
        /// The newline between two table rows. Its source includes the delimiter row.
        case rowBreak
        /// The newline between two blocks.
        case blockBreak
        /// Drawn but not text: a checkbox, an image, a rule. Rendered as U+FFFC.
        case decoration
        case readOnly(PreviewReadOnlyReason)
    }

    var kind: Kind
    /// UTF-16 range in ``MarkdownProjection/rendered``.
    var rendered: NSRange
    /// UTF-16 range in the source.
    var source: NSRange
    /// Index into ``MarkdownProjection/blocks``. A block break belongs to the block it precedes.
    var block: Int
    /// For `.content` only: rendered UTF-16 boundary *i* → source offset relative to
    /// `source.location`, `rendered.length + 1` entries. `nil` means identity — the common case,
    /// where every rendered unit is the source unit at the same distance. A boundary that falls
    /// inside an entity decoded to two units holds `-1`: there is no source position between them.
    var charMap: [Int]?
    /// For `.content` only: indices into ``MarkdownProjection/spans``, outermost first.
    var spans: [Int] = []

    /// The source offset of rendered boundary `index` (0...rendered.length), or `nil` inside an
    /// atomic entity or out of range.
    func sourceOffset(forRenderedBoundary index: Int) -> Int? {
        guard index >= 0, index <= rendered.length else { return nil }
        guard let charMap else { return source.location + index }
        let relative = charMap[index]
        return relative < 0 ? nil : source.location + relative
    }
}

/// One block of the editable preview: the same blocks, in the same order, as ``MarkdownBlocks``.
struct PreviewBlock: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case heading(level: Int)
        case paragraph
        case listItem(marker: MarkdownListMarker)
        case codeBlock(language: String?)
        case table(columns: Int)
        case thematicBreak
        case frontMatter
        case image(source: String, alt: String)
        case html
        case other
    }
    var kind: Kind
    var indent: Int
    var quoteDepth: Int
    /// The 1-based line in the **file** this block starts on, as ``MarkdownBlock/line``.
    var line: Int?
    /// UTF-16 range in the source. For a list item, the item's first line through its lead
    /// paragraph — not the nested blocks, which are blocks of their own.
    var source: NSRange
    /// UTF-16 range in the rendered string, without the block break before it.
    var rendered: NSRange
    /// Index of the document-level block this one sits in — the unit an edit re-parses.
    var topLevel: Int
    /// `nil` when the block takes a caret.
    var readOnly: PreviewReadOnlyReason?
    /// For a fenced code block, what a new line of it needs in front to stay inside: what stands
    /// before its opening fence — a list's indent, a quote's `> ` — with a list marker there turned
    /// to spaces. An empty line inside the block often has none of it in the file, and a character
    /// typed there without it would end the block, so the translator writes it first.
    var linePrefix = ""
}

extension NSAttributedString.Key {
    /// What block a rendered character belongs to: `paragraph`, `heading`, `listItem`, `code`,
    /// `table`, `rule`, `frontMatter`, `image`, `html`. The fragment delegate draws by it.
    static let previewBlock = NSAttributedString.Key("SyncCloud.preview.block")
    /// Where a bar is drawn for each `>` level that encloses the character and is drawn — from the
    /// text's left edge, outermost first, as `[CGFloat]`. Absent outside a quote.
    static let previewQuoteBars = NSAttributedString.Key("SyncCloud.preview.quoteBars")
    /// What a U+FFFC stands for: `task`, `taskDone`, `image`, `inlineImage`, `rule`, `frontMatter`.
    static let previewAttachment = NSAttributedString.Key("SyncCloud.preview.attachment")
    /// On a table's header row.
    static let previewTableHeader = NSAttributedString.Key("SyncCloud.preview.tableHeader")
    /// On a table's rows: where its columns start, and where the last ends, from the text's left
    /// edge — `[CGFloat]`, for the grid the fragment draws.
    static let previewTableColumns = NSAttributedString.Key("SyncCloud.preview.tableColumns")
    /// On every character of a block that cannot be edited here — for the arrow cursor over it,
    /// and its tooltip. Set by the projection, so a block that turns read-only, or back, differs
    /// in the rendering and is redrawn whole: a code block's other lines kept their old look when
    /// only the decoration knew (review, 2026-10-09).
    static let previewReadOnly = NSAttributedString.Key("SyncCloud.preview.readOnly")
    /// On a fenced code block's first line: its language, for the fragment to draw above the code —
    /// drawn, never text, so it cannot be typed into or selected.
    static let previewCodeLanguage = NSAttributedString.Key("SyncCloud.preview.codeLanguage")
    /// On an image block's U+FFFC: the image's source as written, for the view to load.
    static let previewImageSource = NSAttributedString.Key("SyncCloud.preview.imageSource")
    /// On an image's U+FFFC — a block's or one in a sentence — its alt text, as plain text. Its
    /// attachment carries the same (``PreviewImageAttachment``); this makes a changed alt a changed
    /// rendering.
    static let previewImageAlt = NSAttributedString.Key("SyncCloud.preview.imageAlt")
}

// MARK: - The projection

/// The editable preview's view of a Markdown source: what to draw, and which source characters
/// each drawn character came from.
///
/// **The source is the only document.** This is rebuilt from it, never edited on its own, and never
/// trusted on its own either: every piece of text it calls editable has been lined up with the
/// source character for character — escapes and entities included — and a block that does not line
/// up becomes ``PreviewReadOnlyReason/unalignable``, shown but not editable. A wrong map would turn a
/// keystroke into an edit somewhere else in the file; a missing one only sends the person to Source.
///
/// **The parser's inline positions are not used as given — two cases are wrong, both measured
/// against swift-markdown 0.8.0 on 2026-10-04:**
///
/// 1. *A continuation line with leading whitespace.* In `foo\n   bar`, `>   text`, or any paragraph
///    whose first line is indented, the parser reports columns as offsets into the paragraph's
///    content **after** each line's leading whitespace was stripped, measured from the paragraph's
///    own first column. So `bar` comes back at column 1 rather than 4, and `cont` under
///    `   indented` at column 4 rather than 3.
/// 2. *After a backslash hard break.* `foo\` + newline does not advance the parser's line count:
///    the next text is reported on the **same** line with a column past its end, and every later
///    line of the paragraph is one too high.
///
/// The walk models both — see ``InlineLines`` — and then aligns each piece of text against the
/// source from where the model says it starts. It never trusts a reported **end**: a table cell
/// holding `b \| c` reports five bytes for six.
struct MarkdownProjection {

    /// Styling the projection applies. The view adds colour; this carries only what decides layout.
    struct Style: Equatable {
        var scale: CGFloat = 1
        /// The text column's width, which a table must fit to be editable. `nil` lays tables out
        /// and calls none of them too wide — what a projection made with no view to fit has.
        var columnWidth: CGFloat? = nil
    }

    let source: String
    let style: Style
    let index: MarkdownSourceIndex
    let rendered: NSAttributedString
    let blocks: [PreviewBlock]
    let segments: [PreviewSegment]
    let spans: [PreviewInlineSpan]
    /// How this was made from the projection before it (MarkdownProjectionReuse).
    var lineage = Lineage()
    /// What is worked out from this projection once and asked of it again — every field above is a
    /// `let`, so a copy shares it rightly. Each projection made anew has its own.
    let memo = Memo()

    final class Memo {
        /// ``PreviewEditTranslator/readOnlyPieces(_:)``: the projection a translation starts from is
        /// asked once for every check it makes, up to three a keystroke (round 2, 2026-10-10).
        var readOnlyPieces: PreviewPieceCount?
    }

    var renderedString: String { rendered.string }

    /// What an entity reference decodes to, asked of cmark once per reference and kept: the walk
    /// met every `&amp;` in a document on every keystroke, and parsed a document for each.
    static func decodedEntity(_ reference: String) -> String {
        entityLock.lock()
        defer { entityLock.unlock() }
        if let known = entities[reference] { return known }
        let decoded = MarkdownBlocks.text(of: Document(parsing: reference)).plain
        entities[reference] = decoded
        return decoded
    }
    nonisolated(unsafe) private static var entities: [String: String] = [:]
    private static let entityLock = NSLock()

    /// **One projection at a time, in the whole process** (2026-10-17). AppKit uniques attribute
    /// dictionaries process-wide, so a run's `{font, previewReadOnly}` here is the very object
    /// every other projection's equal run holds, whatever thread it is on (measured: one pointer
    /// across two threads). A FileExplorer test process aborted with four projections building at
    /// once on the cooperative pool and one of those shared dictionaries freed under the run that
    /// held it, and this lock was taken to rule the other projections out. **It did not stop the
    /// abort**: it came back on 2026-10-26 inside this lock, with no other projection building —
    /// see "An attribute dictionary freed under a projection's own run — cause not found" in
    /// docs/flaky-tests.md. Kept because it costs the app nothing: the app projects on the main
    /// actor alone, so there it is never contended. Recursive: the re-read projects its part, or
    /// the whole.
    static func oneAtATime<T>(_ body: () -> T) -> T {
        building.lock()
        defer { building.unlock() }
        return body()
    }
    static let building = NSRecursiveLock()

    static func project(_ source: String, style: Style = Style()) -> MarkdownProjection {
        oneAtATime {
            var builder = Builder(source: source, style: style)
            builder.run()
            builder.logReadOnly(of: "note")
            return MarkdownProjection(source: source, style: style, index: builder.index,
                                      rendered: builder.out, blocks: builder.blocks,
                                      segments: builder.segments, spans: builder.spans)
        }
    }

    /// What one stretch of the body projects to, in the file's own positions — the re-read
    /// ``project(_:style:after:)`` makes in place of the whole document.
    struct Slice {
        var rendered: NSAttributedString
        var blocks: [PreviewBlock]
        var segments: [PreviewSegment]
        var spans: [PreviewInlineSpan]
        /// How many document-level blocks the stretch parsed to.
        var topLevelCount: Int
    }

    /// `range` of `source` — whole lines, outside any front matter — projected as if it were the
    /// document, with every position given in `source`: lines, source ranges and `topLevel` count
    /// from `topLevel` and the line `range` starts on. Rendered ranges, block indices and span
    /// indices start at 0.
    static func projectSlice(_ range: NSRange, of source: String, index: MarkdownSourceIndex, style: Style,
                             topLevel: Int, previousBlockSourceEnd: Int) -> Slice {
        oneAtATime {
            var builder = Builder(source: source, style: style, index: index)
            let body = (source as NSString).substring(with: range)
            builder.runSlice(body, firstLine: index.lineNumber(containing: range.location), topLevel: topLevel,
                             previousBlockSourceEnd: previousBlockSourceEnd)
            builder.logReadOnly(of: "part re-read")
            return Slice(rendered: builder.out, blocks: builder.blocks, segments: builder.segments,
                         spans: builder.spans, topLevelCount: builder.topLevel - topLevel)
        }
    }
}

// MARK: - The walk

private struct Builder {
    let index: MarkdownSourceIndex
    let style: MarkdownProjection.Style
    let source: String
    /// Body line *n* is file line *n + lineOffset* — front matter is cut off before parsing.
    var lineOffset = 0

    let out = NSMutableAttributedString()
    var segments: [PreviewSegment] = []
    var blocks: [PreviewBlock] = []
    var spans: [PreviewInlineSpan] = []

    private(set) var topLevel = 0
    private var previousBlockSourceEnd = 0
    /// The `NSTextList` of every list the walk is inside, outermost first.
    private var lists: [NSTextList] = []

    init(source: String, style: MarkdownProjection.Style, index: MarkdownSourceIndex? = nil) {
        self.source = source
        self.style = style
        self.index = index ?? MarkdownSourceIndex(source)
    }

    /// `body` — whole lines of ``source``, the first of them line `firstLine` — parsed as the
    /// document: no front matter, and the positions of the file around it.
    mutating func runSlice(_ body: String, firstLine: Int, topLevel: Int, previousBlockSourceEnd: Int) {
        lineOffset = firstLine - 1
        self.topLevel = topLevel
        self.previousBlockSourceEnd = previousBlockSourceEnd
        let document = Document(parsing: body)
        for child in document.children {
            append(child, indent: 0, quoteDepth: 0)
            self.topLevel += 1
        }
    }

    mutating func run() {
        // The same split, and the same parser options, as `MarkdownBlocks` — no
        // `.parseBlockDirectives`, for the reason its comment gives.
        let split = MarkdownFrontMatter.split(source)
        lineOffset = split.bodyStartLine - 1
        if split.frontMatter != nil {
            let bodyStart = index.line(split.bodyStartLine)?.start ?? index.length
            // The delimiters included: the whole block is the thing nobody types into here.
            let range = NSRange(location: 0, length: bodyStart)
            let block = beginBlock(.frontMatter, indent: 0, quoteDepth: 0, line: 1, source: range,
                                   tag: "frontMatter")
            appendAttachment("frontMatter", kind: .readOnly(.frontMatter), source: range,
                             block: block)
            endBlock(block, readOnly: .frontMatter)
            topLevel += 1
        }
        let document = Document(parsing: split.body)
        for child in document.children {
            append(child, indent: 0, quoteDepth: 0)
            topLevel += 1
        }
    }

    /// **One line a projection, when anything in it is read-only for want of a map** — a block
    /// that did not line up, a table too wide, a wrapped code span or tag, a node the walk does not
    /// model — with how many of each: what a report of "Preview won't let me type here" needs.
    /// Counts only, never the text. `.debug`, since a projection is made at every keystroke; nothing
    /// at all for a note that maps throughout. Front matter, HTML blocks and indented code are
    /// read-only by design, and not counted.
    func logReadOnly(of what: String) {
        var counts: [String: Int] = [:]
        for block in blocks {
            switch block.readOnly {
            case .unalignable?, .wideTable?, .unknown?, .multilineCode?, .inlineHTML?:
                counts[block.readOnly!.rawValue, default: 0] += 1
            default: break
            }
        }
        for segment in segments where blocks[segment.block].readOnly == nil {
            if case .readOnly(let reason) = segment.kind, reason == .multilineCode || reason == .inlineHTML {
                counts[reason.rawValue, default: 0] += 1
            }
        }
        guard !counts.isEmpty else { return }
        let list = counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        Logger.shared.debug("[edit] Preview projection (\(what), \(blocks.count) blocks) has read-only parts: \(list)")
    }

    // MARK: Positions

    /// The UTF-16 offset of a body-relative parser location, taken at its word.
    ///
    /// Right for **block** starts, which is all it is used for: the two wrong cases are inline.
    func offset(_ location: SourceLocation) -> Int? {
        index.utf16Offset(line: location.line + lineOffset, utf8Column: location.column)
    }

    func range(of markup: any Markup) -> NSRange? {
        guard let range = markup.range, let start = offset(range.lowerBound),
              let end = offset(range.upperBound), end >= start else { return nil }
        return NSRange(location: start, length: end - start)
    }

    // MARK: Blocks

    private mutating func beginBlock(_ kind: PreviewBlock.Kind, indent: Int, quoteDepth: Int,
                                     line: Int?, source: NSRange, tag: String) -> Int {
        let blockIndex = blocks.count
        if blockIndex > 0 {
            // The break's source is everything between the two blocks — blank lines, the next
            // block's marker. Clamped, so a nested block that starts inside its parent's range
            // still yields an increasing, non-overlapping cover.
            let start = min(previousBlockSourceEnd, source.location)
            // An empty block before it has no characters of its own: this break is its line, and
            // carries its look, or the line is drawn as nothing in particular (see `endBlock`).
            appendText("\n", attributes: emptyBlockAttributes ?? [:],
                       segment: (.blockBreak, NSRange(location: start,
                                                      length: max(0, source.location - start))),
                       block: blockIndex)
        }
        emptyBlockAttributes = nil
        blocks.append(PreviewBlock(kind: kind, indent: indent, quoteDepth: quoteDepth, line: line,
                                   source: source,
                                   rendered: NSRange(location: out.length, length: 0),
                                   topLevel: topLevel, readOnly: nil))
        currentTag = tag
        currentQuoteBars = quoteBars(depth: quoteDepth)
        currentParagraphStyle = paragraphStyle(for: kind, indent: indent, quoteDepth: quoteDepth)
        return blockIndex
    }

    private mutating func endBlock(_ blockIndex: Int, readOnly: PreviewReadOnlyReason? = nil) {
        let start = blocks[blockIndex].rendered.location
        blocks[blockIndex].rendered.length = out.length - start
        blocks[blockIndex].readOnly = readOnly
        let range = blocks[blockIndex].rendered
        var attributes: [NSAttributedString.Key: Any] = [.paragraphStyle: currentParagraphStyle,
                                                         .previewBlock: currentTag]
        if !currentQuoteBars.isEmpty { attributes[.previewQuoteBars] = currentQuoteBars }
        if readOnly != nil { attributes[.previewReadOnly] = true }
        if range.length > 0 {
            out.addAttributes(attributes, range: range)
        } else {
            // **An empty block is drawn on the next block's break** — the `\n` that ends its line.
            // Left plain, an item just made by Return showed no number and set the caret at the
            // margin, and the items after it counted from 1 again; an empty `## ` had no heading
            // size, an empty `> ` no bar (review, 2026-10-09). The last block has no break after
            // it, and its line is the view's to style.
            attributes[.font] = blockFont(blocks[blockIndex].kind)
            emptyBlockAttributes = attributes
        }
        lastBlockLists = currentParagraphStyle.textLists
        previousBlockSourceEnd = max(previousBlockSourceEnd, NSMaxRange(blocks[blockIndex].source))
    }

    private var currentTag = ""
    private var currentQuoteBars: [CGFloat] = []
    /// The list indent each `>` level the walk is inside opened at, outermost first: a quote in a
    /// list item has its bar at the item's text, not out at the bullet (review, 2026-10-09).
    private var quoteIndents: [Int] = []
    private var currentParagraphStyle = NSParagraphStyle()
    /// The lists of the block just ended — whether the next item continues TextKit's count.
    private var lastBlockLists: [NSTextList] = []
    /// The look of the block just ended, when it rendered nothing: for the break after it.
    private var emptyBlockAttributes: [NSAttributedString.Key: Any]?

    /// Takes back everything a block appended after `mark`, so it can be re-emitted read-only.
    private mutating func rollBack(to mark: (rendered: Int, segments: Int, spans: Int)) {
        out.deleteCharacters(in: NSRange(location: mark.rendered, length: out.length - mark.rendered))
        segments.removeSubrange(mark.segments...)
        spans.removeSubrange(mark.spans...)
    }

    private var mark: (rendered: Int, segments: Int, spans: Int) {
        (out.length, segments.count, spans.count)
    }

    private mutating func append(_ markup: any Markup, indent: Int, quoteDepth: Int) {
        let line = markup.range.map { $0.lowerBound.line + lineOffset }
        switch markup {
        case let heading as Heading:
            leafBlock(heading, kind: .heading(level: heading.level), indent: indent,
                      quoteDepth: quoteDepth, line: line, tag: "heading",
                      font: blockFont(.heading(level: heading.level)))

        case let paragraph as Paragraph:
            if let image = loneImage(in: paragraph), let source = range(of: paragraph) {
                let alt = MarkdownBlocks.text(of: image).plain
                let block = beginBlock(.image(source: image.source ?? "", alt: alt),
                                       indent: indent, quoteDepth: quoteDepth, line: line,
                                       source: source, tag: "image")
                appendAttachment("image", kind: .decoration, source: source, block: block, alt: alt)
                out.addAttribute(.previewImageSource, value: image.source ?? "",
                                 range: NSRange(location: out.length - 1, length: 1))
                endBlock(block)
                break
            }
            // An empty paragraph is dropped, as `MarkdownBlocks` drops it.
            guard !MarkdownBlocks.text(of: paragraph).isEmpty else { break }
            leafBlock(paragraph, kind: .paragraph, indent: indent, quoteDepth: quoteDepth,
                      line: line, tag: "paragraph", font: font(size: 13))

        case let list as UnorderedList:
            lists.append(NSTextList(markerFormat: .disc, options: 0))
            for item in list.listItems {
                listItem(item, marker: item.checkbox.map { .task(done: $0 == .checked) } ?? .bullet,
                         indent: indent, quoteDepth: quoteDepth)
            }
            lists.removeLast()

        case let list as OrderedList:
            let textList = NSTextList(markerFormat: NSTextList.MarkerFormat(rawValue: "{decimal}."),
                                      options: 0)
            textList.startingItemNumber = Int(list.startIndex)
            lists.append(textList)
            var number = Int(list.startIndex)
            for item in list.listItems {
                // **TextKit numbers an item by the unbroken run of paragraphs carrying its list**, so
                // anything between two items without it — a second paragraph, a code block, a task
                // item, which carries none — started the count again, and `2.` was drawn `1.`
                // (review, 2026-10-09). After such a break the list goes on as a new one, from the
                // number the parser gives the item.
                if number > Int(list.startIndex), !lastBlockLists.contains(where: { $0 === lists[lists.count - 1] }) {
                    let next = NSTextList(markerFormat: textList.markerFormat, options: 0)
                    next.startingItemNumber = number
                    lists[lists.count - 1] = next
                }
                listItem(item, marker: item.checkbox.map { .task(done: $0 == .checked) }
                            ?? .ordered(number),
                         indent: indent, quoteDepth: quoteDepth)
                number += 1
            }
            lists.removeLast()

        case let quote as BlockQuote:
            quoteIndents.append(indent)
            defer { quoteIndents.removeLast() }
            for child in quote.children {
                append(child, indent: indent, quoteDepth: quoteDepth + 1)
            }
            // An empty quote — `> ` just written by Quote on an opened paragraph — has no block to
            // type into, and the caret would map onto the paragraph above (review): give it one.
            if quote.childCount == 0, let source = range(of: quote) {
                let block = beginBlock(.paragraph, indent: indent, quoteDepth: quoteDepth + 1, line: line,
                                       source: source, tag: "paragraph")
                appendEmptyAnchor(atEndOfLineFrom: source.location, block: block, font: font(size: 13))
                endBlock(block)
            }

        case let code as CodeBlock:
            codeBlock(code, indent: indent, quoteDepth: quoteDepth, line: line)

        case let html as HTMLBlock:
            let source = range(of: html) ?? NSRange(location: previousBlockSourceEnd, length: 0)
            readOnlyBlock(.html, indent: indent, quoteDepth: quoteDepth, line: line, tag: "html",
                          source: source, text: Self.droppingFinalNewline(html.rawHTML), font: monoFont,
                          reason: .html)

        case is ThematicBreak:
            let source = range(of: markup) ?? NSRange(location: previousBlockSourceEnd, length: 0)
            let block = beginBlock(.thematicBreak, indent: indent, quoteDepth: quoteDepth,
                                   line: line, source: source, tag: "rule")
            appendAttachment("rule", kind: .decoration, source: source, block: block)
            endBlock(block)

        case let table as Table:
            tableBlock(table, indent: indent, quoteDepth: quoteDepth, line: line)

        default:
            let plain = markup.format().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !plain.isEmpty else { break }
            let source = range(of: markup) ?? NSRange(location: previousBlockSourceEnd, length: 0)
            readOnlyBlock(.other, indent: indent, quoteDepth: quoteDepth, line: line, tag: "paragraph",
                          source: source, text: plain, font: font(size: 13), reason: .unknown)
        }
    }

    /// A block whose content is inline text: a heading or a paragraph.
    private mutating func leafBlock(_ markup: any Markup, kind: PreviewBlock.Kind, indent: Int,
                                    quoteDepth: Int, line: Int?, tag: String, font: NSFont) {
        guard let source = range(of: markup) else {
            readOnlyBlock(kind, indent: indent, quoteDepth: quoteDepth, line: line, tag: tag,
                          source: NSRange(location: previousBlockSourceEnd, length: 0),
                          text: MarkdownBlocks.text(of: markup).plain, font: font, reason: .unalignable)
            return
        }
        let before = mark
        let block = beginBlock(kind, indent: indent, quoteDepth: quoteDepth, line: line,
                               source: source, tag: tag)
        if inlineContent(of: markup, block: block, font: font, inTable: false) == nil {
            readOnlyBlock(kind, indent: indent, quoteDepth: quoteDepth, line: line, tag: tag, source: source,
                          text: MarkdownBlocks.text(of: markup).plain, font: font, reason: .unalignable,
                          replacing: before)
            return
        }
        if markup.childCount == 0 {
            // A heading with no words yet — `## ` just written by a Heading verb: somewhere to type.
            appendEmptyAnchor(atEndOfLineFrom: source.location, block: block, font: font)
        }
        endBlock(block)
    }

    /// An insertion point at the end of the line holding `offset`, as an empty list item and an
    /// empty cell have one — but only after a space, so a word typed there stays part of the block
    /// (typed onto `##` it would make `##x`, which is no heading).
    private mutating func appendEmptyAnchor(atEndOfLineFrom offset: Int, block: Int, font: NSFont) {
        let end = index.line(index.lineNumber(containing: offset))?.end ?? offset
        guard end > offset, [0x20, 0x09].contains(index.units[end - 1]) else { return }
        appendText("", attributes: [.font: font], segment: (.content, NSRange(location: end, length: 0)),
                   block: block)
    }

    /// The block shown as `text` and not editable — **every read-only block, in one place.** There
    /// were four copies of this, and one of them, a list item's, kept neither its task box nor its
    /// text on one line (review, 2026-10-09).
    ///
    /// `replacing` takes back the editable attempt made since that mark, which did not line up.
    /// `box` is a task item's `[ ]`, which stays a box — ticking it is three characters the
    /// translator checks, whatever the words after it are. A newline in `text` is drawn as a line
    /// separator, so the block stays one paragraph — a second one would be another list item, with
    /// a bullet of its own — except where lines are the block's own: code, HTML, a table's rows.
    private mutating func readOnlyBlock(_ kind: PreviewBlock.Kind, indent: Int, quoteDepth: Int, line: Int?,
                                        tag: String, source: NSRange, text: String, font: NSFont,
                                        reason: PreviewReadOnlyReason, box: (what: String, source: NSRange)? = nil,
                                        replacing before: (rendered: Int, segments: Int, spans: Int)? = nil) {
        if let before {
            rollBack(to: before)
            blocks.removeLast()
        }
        let block = beginBlock(kind, indent: indent, quoteDepth: quoteDepth, line: line,
                               source: source, tag: tag)
        var source = source
        if let box {
            appendAttachment(box.what, kind: .decoration, source: box.source, block: block)
            // The words' source starts past the box, which has its own.
            let end = NSMaxRange(source)
            source = NSRange(location: min(end, NSMaxRange(box.source)), length: max(0, end - NSMaxRange(box.source)))
        }
        let shown: String
        switch kind {
        case .codeBlock, .html, .table: shown = text
        default: shown = Self.oneParagraph(text)
        }
        appendText(shown, attributes: [.font: font], segment: (.readOnly(reason), source), block: block)
        endBlock(block, readOnly: reason)
    }

    /// `text` with every paragraph separator — `\r\n`, `\n`, `\r`, U+2029, U+0085 — drawn as a line
    /// separator instead, and in a table cell every tab as a space (see ``drawn(_:inCell:)``).
    static func oneParagraph(_ text: String, inCell: Bool = false) -> String {
        let units = Array(text.replacingOccurrences(of: "\r\n", with: "\u{2028}").utf16).map { drawn($0, inCell: inCell) }
        return String(utf16CodeUnits: units, count: units.count)
    }

    /// What a unit of text is drawn as, where the text system would read it as layout:
    /// - U+2028 for a unit it ends a paragraph at — as `PreviewEditSession.endsParagraph` counts
    ///   them — which would make a second paragraph of one block;
    /// - in a table cell, a space for a tab, which would jump to the next column's stop, and which
    ///   the grid splits its rows at (review, 2026-10-09).
    ///
    /// One unit for one, so text drawn this way still maps unit for unit (see ``align``).
    static func drawn(_ unit: UInt16, inCell: Bool) -> UInt16 {
        if unit == 0x0A || unit == 0x0D || unit == 0x2029 || unit == 0x85 { return 0x2028 }
        return inCell && unit == 0x09 ? 0x20 : unit
    }

    private mutating func listItem(_ item: ListItem, marker: MarkdownListMarker, indent: Int,
                                   quoteDepth: Int) {
        var children = Array(item.children)
        let lead = children.first as? Paragraph
        if lead != nil { children.removeFirst() }
        let line = item.range.map { $0.lowerBound.line + lineOffset }
        let itemStart = item.range.flatMap { offset($0.lowerBound) } ?? previousBlockSourceEnd
        // The item's own extent: its first line through the lead paragraph. The nested blocks are
        // blocks of their own, and an item range that swallowed them would overlap theirs.
        let firstLineEnd = index.line(index.lineNumber(containing: itemStart))?.end ?? itemStart
        let leadEnd = lead.flatMap { range(of: $0) }.map(NSMaxRange) ?? firstLineEnd
        let source = NSRange(location: itemStart, length: max(0, leadEnd - itemStart))
        let bodyFont = font(size: 13)

        let before = mark
        let block = beginBlock(.listItem(marker: marker), indent: indent, quoteDepth: quoteDepth,
                               line: line, source: source, tag: "listItem")
        var aligned = true
        var box: (what: String, source: NSRange)?
        if case .task(let done) = marker {
            if let found = checkboxRange(from: itemStart,
                                         to: lead.flatMap { range(of: $0) }?.location ?? firstLineEnd) {
                box = (done ? "taskDone" : "task", found)
                appendAttachment(done ? "taskDone" : "task", kind: .decoration, source: found,
                                 block: block)
            } else {
                aligned = false
            }
        }
        if aligned, let lead {
            aligned = inlineContent(of: lead, block: block, font: bodyFont, inTable: false) != nil
        } else if aligned {
            // An item with no words yet — `- ` just written by Bullets, say: somewhere to type, at
            // the end of its marker line. Typed onto a bare `-`, a word would turn it into text.
            appendEmptyAnchor(atEndOfLineFrom: itemStart, block: block, font: bodyFont)
        }
        if !aligned {
            readOnlyBlock(.listItem(marker: marker), indent: indent, quoteDepth: quoteDepth, line: line,
                          tag: "listItem", source: source, text: lead.map { MarkdownBlocks.text(of: $0).plain } ?? "",
                          font: bodyFont, reason: .unalignable, box: box, replacing: before)
        } else {
            endBlock(block)
        }

        // Nested blocks sit one level deeper, inside this item's list.
        for child in children {
            append(child, indent: indent + 1, quoteDepth: quoteDepth)
        }
    }

    /// The `[ ]`, `[x]` or `[X]` of a task item, searched for between the marker and the text.
    private func checkboxRange(from start: Int, to end: Int) -> NSRange? {
        var offset = start
        while offset + 2 < min(end, index.length) {
            if index.units[offset] == 0x5B, index.units[offset + 2] == 0x5D,
               [0x20, 0x78, 0x58].contains(index.units[offset + 1]) {
                return NSRange(location: offset, length: 3)
            }
            offset += 1
        }
        return nil
    }

    // MARK: Code

    private mutating func codeBlock(_ code: CodeBlock, indent: Int, quoteDepth: Int, line: Int?) {
        let language = code.language.flatMap { $0.isEmpty ? nil : $0 }
        let source = range(of: code) ?? NSRange(location: previousBlockSourceEnd, length: 0)
        let text = Self.droppingFinalNewline(code.code)
        // **Fenced when its fence lines are not code.** Starting on a backtick is not enough: an
        // indented block whose first line is ```` ```foo ```` starts on one too, and was taken for a
        // fence and shown as unalignable (review, 2026-10-09). Every line of an indented block is
        // code; a fenced block's opening line never is.
        let lines = code.range.map { $0.upperBound.line - $0.lowerBound.line + 1 } ?? 0
        let codeLines = code.code.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
        let fence = source.length >= 3 && index.units.indices.contains(source.location)
            && [0x60, 0x7E].contains(index.units[source.location]) && codeLines < lines

        guard fence else {
            readOnlyBlock(.codeBlock(language: language), indent: indent, quoteDepth: quoteDepth, line: line,
                          tag: "code", source: source, text: text, font: monoFont, reason: .indentedCode)
            return
        }
        let before = mark
        let block = beginBlock(.codeBlock(language: language), indent: indent,
                               quoteDepth: quoteDepth, line: line, source: source, tag: "code")
        if let fenceLine = index.line(index.lineNumber(containing: source.location)) {
            blocks[block].linePrefix = Self.continuationPrefix(index.units[fenceLine.start..<source.location])
        }
        if fencedCodeLines(text, block: block, source: source, hasLine: !code.code.isEmpty) {
            endBlock(block)
            if let language { labelFirstLine(of: block, language: language) }
        } else {
            readOnlyBlock(.codeBlock(language: language), indent: indent, quoteDepth: quoteDepth, line: line,
                          tag: "code", source: source, text: text, font: monoFont, reason: .unalignable,
                          replacing: before)
        }
    }

    /// **The language over a code block, as the read-only Preview draws it** (review, 2026-10-09: the
    /// editable one dropped it). Room is made above the first line, and the fragment draws the name
    /// in it — an attribute, not characters, so it is never text anyone types into. A block with no
    /// characters has its line on the break after it (see `endBlock`), which is not in its range,
    /// and goes without.
    private mutating func labelFirstLine(of block: Int, language: String) {
        let range = blocks[block].rendered
        guard range.length > 0 else { return }
        let text = out.string as NSString
        // The first paragraph, its line break included: an empty first line is that break alone.
        let lineEnd = text.range(of: "\n", options: [], range: range).location
        let first = NSRange(location: range.location,
                            length: (lineEnd == NSNotFound ? NSMaxRange(range) : lineEnd + 1) - range.location)
        let paragraph = currentParagraphStyle.mutableCopy() as! NSMutableParagraphStyle
        paragraph.paragraphSpacingBefore = Self.languageLabelHeight * style.scale
        out.addAttributes([.paragraphStyle: paragraph, .previewCodeLanguage: language], range: first)
    }

    /// The room a code block's language takes above its first line.
    static let languageLabelHeight: CGFloat = 14

    /// What a later line of a block opened after `opening` — the fence line's text before its
    /// backticks — needs in front of it to stay in that block: the quote markers and whitespace as
    /// written, and a space for every other character.
    ///
    /// **A list marker becomes its own width in spaces.** Copied as written, a fence opened on the
    /// marker line — `- ```swift` — gave every new line a `- ` of its own, which is a new list item:
    /// Return in the code was refused, and so was typing on a blank line of it (review, 2026-10-09).
    static func continuationPrefix(_ opening: ArraySlice<UInt16>) -> String {
        let units = opening.map { [0x3E, 0x20, 0x09].contains($0) ? $0 : 0x20 }
        return String(utf16CodeUnits: units, count: units.count)
    }

    /// Maps each line of a fenced block onto its source line.
    ///
    /// **A code line is always the TAIL of its source line** — a quote's `> `, a list item's
    /// indentation and the fence's own indent are all prefixes the parser strips — so each line is
    /// found as a suffix rather than through the parser's columns. A line that is not a suffix (a
    /// tab the parser expanded to spaces) fails the whole block, which becomes read-only.
    ///
    /// `hasLine` says the parser gave the block a line: an empty one, ```` ```\n\n``` ````, as the
    /// Code Block verb writes it, has one to type on.
    private mutating func fencedCodeLines(_ text: String, block: Int, source: NSRange, hasLine: Bool) -> Bool {
        let startLine = index.lineNumber(containing: source.location)
        let codeLines = text.isEmpty ? [] : text.components(separatedBy: "\n")
        guard !codeLines.isEmpty else {
            // An empty block: an insertion point on the line after the fence, at its end — past any
            // quote marker or indent, which is where a code line's text goes. **Only where that line
            // is the block's own**: its one empty line, or the blank last line of a fence left open
            // at the end of the file. In ```` ```\n``` ```` it is the closing fence, and in an open
            // ```` ``` ```` with nothing after it there is none, so the point stood on a fence line —
            // typing went into the closing fence, or the language name, and every such edit was
            // refused once its re-read showed nothing typed (review, 2026-10-09). Now nothing is
            // built. Typing there would need a line ending written first, which is the translator's.
            if let line = index.line(startLine + 1),
               hasLine || (line.start..<line.end).allSatisfy({ [0x20, 0x09, 0x3E].contains(index.units[$0]) }) {
                appendText("", attributes: [:], segment: (.content, NSRange(location: line.end, length: 0)),
                           block: block)
            }
            return true
        }
        var previousEnd: Int?
        for (lineIndex, codeLine) in codeLines.enumerated() {
            guard let sourceLine = index.line(startLine + 1 + lineIndex) else { return false }
            let units = Array(codeLine.utf16)
            let contentStart = sourceLine.end - units.count
            guard contentStart >= sourceLine.start,
                  Array(index.units[contentStart..<sourceLine.end]) == units,
                  sourceLine.end <= NSMaxRange(source) else { return false }
            if let previousEnd {
                appendText("\n", attributes: [.font: monoFont],
                           segment: (.codeNewline,
                                     NSRange(location: previousEnd,
                                             length: contentStart - previousEnd)),
                           block: block)
            }
            appendText(codeLine, attributes: [.font: monoFont],
                       segment: (.content, NSRange(location: contentStart, length: units.count)),
                       block: block, spans: [])
            previousEnd = sourceLine.end
        }
        return true
    }

    // MARK: Tables

    private mutating func tableBlock(_ table: Table, indent: Int, quoteDepth: Int, line: Int?) {
        let source = range(of: table) ?? NSRange(location: previousBlockSourceEnd, length: 0)
        let columns = table.head.cells.reduce(0) { count, _ in count + 1 }
        let before = mark
        let block = beginBlock(.table(columns: columns), indent: indent, quoteDepth: quoteDepth,
                               line: line, source: source, tag: "table")
        let bodyFont = font(size: 12)
        var aligned = true
        var previousRowEnd: Int?
        let rows: [(cells: [Table.Cell], header: Bool)] =
            [(Array(table.head.cells), true)] + table.body.rows.map { (Array($0.cells), false) }

        rowLoop: for row in rows {
            let rowStart = out.length
            var previousCellEnd: Int?
            var cellIndex = 0
            for cell in row.cells {
                // A short row arrives padded by the parser with cells that have no range and no
                // content: shown as empty columns, with nothing there to type into.
                if cell.range == nil, cell.childCount == 0, let end = previousCellEnd {
                    appendText("\t", attributes: [:],
                               segment: (.cellBreak, NSRange(location: end, length: 0)),
                               block: block)
                    cellIndex += 1
                    continue
                }
                guard let cellRange = range(of: cell) else { aligned = false; break rowLoop }
                let cellFont = row.header ? font(size: 12, weight: .semibold) : bodyFont
                // The separator is appended first with a placeholder source; its true extent is
                // known only once this cell's first character has been placed.
                let separatorIndex: Int?
                if let previousCellEnd {
                    appendText("\t", attributes: [:],
                               segment: (.cellBreak, NSRange(location: previousCellEnd, length: 0)),
                               block: block)
                    separatorIndex = segments.count - 1
                } else if let previousRowEnd {
                    appendText("\n", attributes: [:],
                               segment: (.rowBreak, NSRange(location: previousRowEnd, length: 0)),
                               block: block)
                    separatorIndex = segments.count - 1
                } else {
                    separatorIndex = nil
                }
                let contentFrom = segments.count
                guard inlineContent(of: cell, block: block, font: cellFont, inTable: true) != nil
                else { aligned = false; break rowLoop }
                if segments.count == contentFrom {
                    let written = (cellRange.location..<NSMaxRange(cellRange)).filter {
                        ![0x20, 0x09, 0x7C].contains(index.units[$0])
                    }
                    if let first = written.first, let last = written.last {
                        // Written, and drawn as nothing — a `^` the parser takes for a row span:
                        // nowhere to type, since a character beside it ends the span (review,
                        // 2026-10-09: the point stood before the `^`, and every keystroke was refused).
                        appendText("", attributes: [:],
                                   segment: (.readOnly(.unknown), NSRange(location: first, length: last + 1 - first)),
                                   block: block)
                    } else {
                        // An empty cell: an insertion point one space in, inside its padding.
                        let pad = cellRange.length > 0 && index.units[cellRange.location] == 0x20 ? 1 : 0
                        appendText("", attributes: [:],
                                   segment: (.content, NSRange(location: cellRange.location + pad,
                                                               length: 0)),
                                   block: block)
                    }
                }
                let contentStart = segments[contentFrom].source.location
                if let separatorIndex {
                    let from = segments[separatorIndex].source.location
                    guard contentStart >= from else { aligned = false; break rowLoop }
                    segments[separatorIndex].source.length = contentStart - from
                }
                previousCellEnd = NSMaxRange(segments[segments.count - 1].source)
                cellIndex += 1
            }
            // A short row is padded to the header's width, as `MarkdownBlocks` pads it, with
            // separators that have no source: there is no cell there to type into.
            while cellIndex < columns, let end = previousCellEnd {
                appendText("\t", attributes: [:],
                           segment: (.cellBreak, NSRange(location: end, length: 0)), block: block)
                cellIndex += 1
            }
            if row.header, out.length > rowStart {
                out.addAttribute(.previewTableHeader, value: true,
                                 range: NSRange(location: rowStart, length: out.length - rowStart))
            }
            previousRowEnd = previousCellEnd
        }
        guard aligned else {
            let plain = rows.map { row in
                row.cells.map { Self.oneParagraph(MarkdownBlocks.text(of: $0).plain, inCell: true) }
                    .joined(separator: "\t")
            }.joined(separator: "\n")
            readOnlyBlock(.table(columns: columns), indent: indent, quoteDepth: quoteDepth, line: line, tag: "table",
                          source: source, text: plain, font: bodyFont, reason: .unalignable, replacing: before)
            return
        }
        endBlock(block)
        layOutColumns(of: block, alignments: table.columnAlignments, columns: columns)
    }

    /// **Tab stops per table** (§3.8): each column as wide as its widest cell plus padding, so the
    /// cells line up under one another, and `:---:` / `---:` honoured with centre and right tabs —
    /// the read-only preview ignores both. The first column is leading-aligned whatever it says: a
    /// row starts at the indent, not at a tab. A table that does not fit the column is read-only.
    private mutating func layOutColumns(of block: Int, alignments: [Table.ColumnAlignment?], columns: Int) {
        let range = blocks[block].rendered
        guard range.length > 0, columns > 0 else { return }
        let rows = (out.string as NSString).substring(with: range).components(separatedBy: "\n")
        var widths = Array(repeating: CGFloat(0), count: columns)
        var location = range.location
        for row in rows {
            var cellStart = location
            for (column, cell) in row.components(separatedBy: "\t").enumerated() where column < columns {
                let length = (cell as NSString).length
                widths[column] = max(widths[column], ceil(Self.width(of: out.attributedSubstring(
                    from: NSRange(location: cellStart, length: length)))))
                cellStart += length + 1
            }
            location += (row as NSString).length + 1
        }
        let pad = 18 * style.scale
        guard let base = out.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
        else { return }
        let lead = base.headIndent
        var edges = [lead]
        for width in widths { edges.append(edges[edges.count - 1] + width + pad) }
        let paragraph = base.mutableCopy() as! NSMutableParagraphStyle
        paragraph.tabStops = (1..<columns).map { column in
            let start = edges[column] + pad / 2
            switch alignments.indices.contains(column) ? alignments[column] : nil {
            case .center?: return NSTextTab(textAlignment: .center, location: start + widths[column] / 2)
            case .right?: return NSTextTab(textAlignment: .right, location: start + widths[column])
            default: return NSTextTab(textAlignment: .left, location: start)
            }
        }
        paragraph.defaultTabInterval = pad
        paragraph.lineSpacing = 6 * style.scale
        paragraph.paragraphSpacing = 0
        out.addAttribute(.paragraphStyle, value: paragraph, range: range)
        out.addAttribute(.previewTableWidth, value: edges[edges.count - 1], range: range)
        if let column = style.columnWidth, edges[edges.count - 1] > column {
            // Too wide: left to Source, and no grid — its cells wrap, and lines drawn at the stops
            // would cross them. Marked as `endBlock` marks a read-only block, which it was not yet
            // there: the pointer stayed an I-beam over it, with no tooltip (review, 2026-10-09).
            blocks[block].readOnly = .wideTable
            out.addAttribute(.previewReadOnly, value: true, range: range)
        } else {
            out.addAttribute(.previewTableColumns, value: edges.map { $0 - lead }, range: range)
        }
    }

    /// How wide `text` is drawn, an attachment at its bounds — which measuring the text leaves out
    /// while the attachment has no image, as every one the projection makes has none yet.
    private static func width(of text: NSAttributedString) -> CGFloat {
        let measured = NSMutableAttributedString(attributedString: text)
        var attachments: CGFloat = 0
        measured.enumerateAttribute(.attachment, in: NSRange(location: 0, length: measured.length),
                                    options: .reverse) { value, range, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            attachments += attachment.bounds.width * CGFloat(range.length)
            measured.deleteCharacters(in: range)
        }
        return measured.size().width + attachments
    }

    // MARK: Inline

    /// Walks a block's inline children into the rendered string, or returns `nil` — having appended
    /// a partial block the caller rolls back — when any piece fails to line up with the source.
    private mutating func inlineContent(of container: any Markup, block: Int, font: NSFont,
                                        inTable: Bool) -> Void? {
        guard let start = container.range?.lowerBound, let containerStart = offset(start) else {
            return container.childCount == 0 ? () : nil
        }
        var lines = InlineLines(index: index, firstBodyLine: start.line, lineOffset: lineOffset,
                                paragraphColumn: start.column, quoteDepth: blocks[block].quoteDepth)
        if inTable, let cell = range(of: container) {
            lines.pipeEscapes = (cell.location..<max(cell.location, NSMaxRange(cell) - 1)).filter {
                index.units[$0] == 0x5C && index.units[$0 + 1] == 0x7C
            }
        }
        var walker = InlineWalker(lines: lines, inTable: inTable, font: font)
        // Where the first piece of text would start if the parser gave it no position: past the
        // container's opening whitespace (a table cell's range includes its padding).
        var first = containerStart
        while first < index.length, index.units[first] == 0x20 || index.units[first] == 0x09 { first += 1 }
        walker.sourceEnd = containerStart
        walker.unpositionedStart = first
        for child in container.children {
            guard walk(child, walker: &walker, block: block) != nil else { return nil }
        }
        return ()
    }

    private struct InlineWalker {
        var lines: InlineLines
        let inTable: Bool
        let font: NSFont
        var bold = false
        var italic = false
        var struck = false
        var link: String?
        var spanStack: [Int] = []
        /// Source end of the last thing placed, so every next piece can be checked to come after it.
        var sourceEnd = 0
        /// Where text the parser gave no position starts: the container's first character until
        /// something is placed, then straight after the last thing placed.
        var unpositionedStart = 0
    }

    private mutating func walk(_ markup: any Markup, walker: inout InlineWalker,
                               block: Int) -> Void? {
        defer { walker.unpositionedStart = max(walker.unpositionedStart, walker.sourceEnd) }
        switch markup {
        case let text as Markdown.Text:
            // **A text node can arrive with no range** — measured: an unmatched `~~` in a table cell
            // comes back as text with none. It can only start where the last piece ended, and the
            // alignment below is what checks that it does.
            // An entity can decode to a newline — `&#10;` — and the file can hold a U+2029: each is
            // drawn as a line separator, unit for unit, so the block stays one paragraph. A tab in a
            // cell is drawn as a space.
            let units = text.string.utf16.map { Self.drawn($0, inCell: walker.inTable) }
            guard let start = text.range.map({ walker.lines.offset(of: $0.lowerBound) })
                      ?? walker.unpositionedStart,
                  start >= walker.sourceEnd,
                  let aligned = Self.align(units, in: index.units, at: start,
                                           limit: walker.lines.currentLimit,
                                           escapes: true, pipes: false, cells: walker.inTable)
            else { return nil }
            appendText(String(utf16CodeUnits: units, count: units.count), attributes: inlineAttributes(walker),
                       segment: (.content, NSRange(location: start, length: aligned.end - start)),
                       block: block, charMap: aligned.map, spans: walker.spanStack)
            walker.sourceEnd = aligned.end

        case let code as InlineCode:
            guard let location = code.range?.lowerBound,
                  let start = walker.lines.offset(of: location), start >= walker.sourceEnd,
                  let placed = codeSpan(code.code, at: start, inTable: walker.inTable)
            else { return nil }
            var attributes = inlineAttributes(walker)
            attributes[.font] = monoFont
            let spanIndex = spans.count
            spans.append(PreviewInlineSpan(kind: .code, source: placed.whole))
            if let content = placed.content {
                appendText(Self.oneParagraph(code.code, inCell: walker.inTable), attributes: attributes,
                           segment: (.content, NSRange(location: content.start,
                                                       length: content.end - content.start)),
                           block: block, charMap: content.map,
                           spans: walker.spanStack + [spanIndex])
            } else {
                appendText(code.code, attributes: attributes,
                           segment: (.readOnly(.multilineCode), placed.whole), block: block)
            }
            walker.sourceEnd = NSMaxRange(placed.whole)
            if let end = code.range?.upperBound, end.line > location.line {
                walker.lines.advanceReportedLines(to: end.line)
            }

        case is SoftBreak, is LineBreak:
            guard let placed = walker.lines.lineBreak(hard: markup is LineBreak, after: walker.sourceEnd)
            else { return nil }
            appendText(markup is LineBreak ? "\u{2028}" : " ", attributes: inlineAttributes(walker),
                       segment: (markup is LineBreak ? .hardBreak : .softBreak, placed),
                       block: block)
            walker.sourceEnd = NSMaxRange(placed)

        case let html as InlineHTML:
            let units = Array(html.rawHTML.utf16)
            guard let location = html.range?.lowerBound,
                  let start = walker.lines.offset(of: location), start >= walker.sourceEnd,
                  start + units.count <= index.length,
                  Array(index.units[start..<start + units.count]) == units
            else { return nil }
            var attributes = inlineAttributes(walker)
            attributes[.font] = monoFont
            let range = NSRange(location: start, length: units.count)
            // A tag can wrap a line — `<span\nclass=x>` — and its newline drawn as one would make a
            // second paragraph of the block: another bullet, in a list (review, 2026-10-09).
            appendText(Self.oneParagraph(html.rawHTML, inCell: walker.inTable), attributes: attributes,
                       segment: (.readOnly(.inlineHTML), range), block: block)
            walker.sourceEnd = NSMaxRange(range)
            if let end = html.range?.upperBound, end.line > location.line {
                walker.lines.advanceReportedLines(to: end.line)
            }

        case let image as Markdown.Image:
            guard let range = image.range,
                  let start = walker.lines.offset(of: range.lowerBound), start >= walker.sourceEnd,
                  start < index.length, index.units[start] == 0x21   // "!"
            else { return nil }
            if range.upperBound.line > range.lowerBound.line {
                walker.lines.advanceReportedLines(to: range.upperBound.line)
            }
            guard let end = walker.lines.offset(of: range.upperBound), end > start else { return nil }
            let placed = NSRange(location: start, length: end - start)
            appendAttachment("inlineImage", kind: .decoration, source: placed, block: block,
                             alt: MarkdownBlocks.text(of: image).plain)
            walker.sourceEnd = end

        case is Strong, is Emphasis, is Strikethrough, is Link:
            guard let range = markup.range,
                  let start = walker.lines.offset(of: range.lowerBound), start >= walker.sourceEnd
            else { return nil }
            let kind: PreviewInlineSpan.Kind
            let saved = (walker.bold, walker.italic, walker.struck, walker.link)
            switch markup {
            case is Strong: kind = .strong; walker.bold = true
            case is Emphasis: kind = .emphasis; walker.italic = true
            case is Strikethrough: kind = .strikethrough; walker.struck = true
            default:
                let destination = (markup as? Link)?.destination
                kind = .link(destination: destination)
                walker.link = destination ?? ""
            }
            let spanIndex = spans.count
            spans.append(PreviewInlineSpan(kind: kind, source: NSRange(location: start, length: 0)))
            walker.spanStack.append(spanIndex)
            walker.sourceEnd = start
            for child in markup.children {
                guard walk(child, walker: &walker, block: block) != nil else { return nil }
            }
            walker.spanStack.removeLast()
            (walker.bold, walker.italic, walker.struck, walker.link) = saved
            if range.upperBound.line > range.lowerBound.line {
                walker.lines.advanceReportedLines(to: range.upperBound.line)
            }
            guard let end = walker.lines.offset(of: range.upperBound), end >= walker.sourceEnd
            else { return nil }
            spans[spanIndex].source.length = end - start
            walker.sourceEnd = end

        default:
            // A node the walk has no map for. Refusing the block is the safe answer: anything
            // guessed here would be a guess about where the person's keystrokes land.
            return nil
        }
        return ()
    }

    /// Places a code span: its backtick runs, and the content between them.
    ///
    /// `content` is `nil` when the span wraps a line — its newline renders as a space, which v1
    /// does not map — and the span is then read-only.
    private func codeSpan(_ code: String, at start: Int, inTable: Bool)
        -> (whole: NSRange, content: (start: Int, end: Int, map: [Int]?)?)? {
        let units = index.units
        var run = 0
        while start + run < units.count, units[start + run] == 0x60 { run += 1 }
        guard run > 0 else { return nil }
        // The closing run: exactly as many backticks, not part of a longer run.
        var cursor = start + run
        var close: Int?
        while cursor < units.count {
            if units[cursor] == 0x60 {
                var length = 0
                while cursor + length < units.count, units[cursor + length] == 0x60 { length += 1 }
                if length == run { close = cursor; break }
                cursor += length
            } else {
                cursor += 1
            }
        }
        guard let close else { return nil }
        let whole = NSRange(location: start, length: close + run - start)
        let inner = start + run
        if units[inner..<close].contains(where: { $0 == 0x0A || $0 == 0x0D }) {
            return (whole, nil)
        }
        let rendered = code.utf16.map { Self.drawn($0, inCell: inTable) }
        // The content as written, then with the one space each side the parser strips.
        for (from, to) in [(inner, close), (inner + 1, close - 1)] where from <= to {
            if let aligned = Self.align(rendered, in: units, at: from, limit: to, escapes: false,
                                        pipes: inTable, cells: inTable), aligned.end == to {
                return (whole, (from, to, aligned.map))
            }
        }
        return nil
    }

    // MARK: Alignment

    /// Lines up `rendered` against `source` from `start`, consuming escapes and entities.
    ///
    /// Returns where the source run ends and the boundary map (`nil` when every unit matched its
    /// own). `nil` when the two cannot be lined up before `limit`.
    ///
    /// **Escape before literal, and that is the parser's own order:** `\*` in text is always an
    /// escaped asterisk, never a backslash followed by one. Escapes are off in code spans, where a
    /// backslash is literal — except `\|` in a table cell, which the table extension unescapes first.
    ///
    /// `rendered` is drawn as ``drawn(_:inCell:)`` draws it: a unit it changed matches the one it
    /// came from. `cells` says it was drawn for a table cell.
    static func align(_ rendered: [UInt16], in source: [UInt16], at start: Int, limit: Int,
                      escapes: Bool, pipes: Bool, cells: Bool = false) -> (end: Int, map: [Int]?)? {
        var map = [0]
        var identity = true
        var i = start
        var j = 0
        while j < rendered.count {
            guard i < limit else { return nil }
            let unit = source[i]
            if unit == 0x5C, i + 1 < limit, source[i + 1] == rendered[j],
               (escapes && isASCIIPunctuation(source[i + 1]) || pipes && source[i + 1] == 0x7C) {
                i += 2; j += 1
                map.append(i - start); identity = false
                continue
            }
            if escapes, unit == 0x26, let entity = entity(in: source, at: i, limit: limit),
               j + entity.decoded.count <= rendered.count,
               Array(rendered[j..<j + entity.decoded.count]) == entity.decoded.map({ drawn($0, inCell: cells) }) {
                // Interior boundaries of a two-unit decode have no source position.
                for _ in 1..<max(1, entity.decoded.count) { map.append(-1) }
                i = entity.end; j += entity.decoded.count
                map.append(i - start); identity = false
                continue
            }
            if escapes, let consumed = smartPunctuation(source, at: i, limit: limit,
                                                        rendered: rendered[j]) {
                i += consumed; j += 1
                map.append(i - start); identity = false
                continue
            }
            if unit != rendered[j], drawn(unit, inCell: cells) == rendered[j] {
                // A U+2029 or U+0085 in the file, drawn as a line separator; a tab in a cell, drawn
                // as a space (see `drawn`).
                i += 1; j += 1
                map.append(i - start); identity = false
                continue
            }
            guard unit == rendered[j] else { return nil }
            i += 1; j += 1
            map.append(i - start)
        }
        return (i, identity ? nil : map)
    }

    /// How many source units the parser's smart punctuation turned into `rendered`, or `nil`.
    ///
    /// **swift-markdown parses with smart punctuation on** — measured: `Don't "x" -- --- ...`
    /// renders `Don’t “x” – — …` — so the read-only preview has always shown curly quotes, and the
    /// projection has to line them up with the straight ones in the file. A run of hyphens is split
    /// by the parser into en and em dashes; matching one rendered dash at a time follows its split.
    private static func smartPunctuation(_ source: [UInt16], at offset: Int, limit: Int,
                                         rendered: UInt16) -> Int? {
        func run(_ unit: UInt16, _ count: Int) -> Bool {
            offset + count <= limit && source[offset..<offset + count].allSatisfy { $0 == unit }
        }
        switch rendered {
        case 0x2018, 0x2019: return source[offset] == 0x27 ? 1 : nil      // ‘ ’ from '
        case 0x201C, 0x201D: return source[offset] == 0x22 ? 1 : nil      // “ ” from "
        case 0x2026: return run(0x2E, 3) ? 3 : nil                        // … from ...
        case 0x2013: return run(0x2D, 2) ? 2 : nil                        // – from --
        case 0x2014: return run(0x2D, 3) ? 3 : nil                        // — from ---
        default: return nil
        }
    }

    private static func isASCIIPunctuation(_ unit: UInt16) -> Bool {
        (0x21...0x2F).contains(unit) || (0x3A...0x40).contains(unit)
            || (0x5B...0x60).contains(unit) || (0x7B...0x7E).contains(unit)
    }

    /// An entity reference at `offset` — `&name;`, `&#123;`, `&#x1F;` — decoded by the parser
    /// itself, so the table of two thousand HTML names is cmark's to be right about.
    private static func entity(in source: [UInt16], at offset: Int, limit: Int)
        -> (end: Int, decoded: [UInt16])? {
        var cursor = offset + 1
        while cursor < limit, cursor - offset <= 33 {
            let unit = source[cursor]
            if unit == 0x3B { break }
            guard unit == 0x23 || (0x30...0x39).contains(unit) || (0x41...0x5A).contains(unit)
                    || (0x61...0x7A).contains(unit) else { return nil }
            cursor += 1
        }
        guard cursor < limit, source[cursor] == 0x3B, cursor > offset + 1 else { return nil }
        let reference = String(utf16CodeUnits: Array(source[offset...cursor]),
                               count: cursor - offset + 1)
        let decoded = MarkdownProjection.decodedEntity(reference)
        guard decoded != reference, !decoded.isEmpty else { return nil }
        return (cursor + 1, Array(decoded.utf16))
    }

    // MARK: Output

    private mutating func appendText(_ text: String, attributes: [NSAttributedString.Key: Any],
                                     segment: (kind: PreviewSegment.Kind, source: NSRange),
                                     block: Int, charMap: [Int]? = nil, spans: [Int] = []) {
        let location = out.length
        out.append(NSAttributedString(string: text, attributes: attributes))
        if case .readOnly = segment.kind, out.length > location {
            // A read-only piece of an editable block — a code span or a tag that wraps a line — says
            // so under the pointer as a read-only block does (review, 2026-10-09).
            out.addAttribute(.previewReadOnly, value: true, range: NSRange(location: location, length: out.length - location))
        }
        segments.append(PreviewSegment(kind: segment.kind,
                                       rendered: NSRange(location: location,
                                                         length: out.length - location),
                                       source: segment.source, block: block,
                                       charMap: charMap, spans: spans))
    }

    /// `alt`, for an image: the attachment is a ``PreviewImageAttachment`` holding it.
    private mutating func appendAttachment(_ what: String, kind: PreviewSegment.Kind,
                                           source: NSRange, block: Int, alt: String? = nil) {
        let location = out.length
        let attachment: NSTextAttachment
        if let alt {
            let image = PreviewImageAttachment()
            image.alt = Self.oneParagraph(alt)
            image.bounds = PreviewAttachments.placeholderBounds(image.label, scale: style.scale)
            attachment = image
        } else {
            attachment = NSTextAttachment()
        }
        out.append(NSAttributedString(attachment: attachment))
        out.addAttribute(.previewAttachment, value: what,
                         range: NSRange(location: location, length: out.length - location))
        if let alt {
            out.addAttribute(.previewImageAlt, value: Self.oneParagraph(alt),
                             range: NSRange(location: location, length: out.length - location))
        }
        segments.append(PreviewSegment(kind: kind,
                                       rendered: NSRange(location: location,
                                                         length: out.length - location),
                                       source: source, block: block))
    }

    private func inlineAttributes(_ walker: InlineWalker) -> [NSAttributedString.Key: Any] {
        var traits: NSFontDescriptor.SymbolicTraits = []
        if walker.bold { traits.insert(.bold) }
        if walker.italic { traits.insert(.italic) }
        var font = walker.font
        if !traits.isEmpty {
            let descriptor = font.fontDescriptor.withSymbolicTraits(
                font.fontDescriptor.symbolicTraits.union(traits))
            font = NSFont(descriptor: descriptor, size: font.pointSize) ?? font
        }
        var attributes: [NSAttributedString.Key: Any] = [.font: font]
        if walker.struck { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if let link = walker.link { attributes[.link] = link }
        return attributes
    }

    private func font(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.systemFont(ofSize: size * style.scale, weight: weight)
    }

    /// The font a block's text is set in — for a block with no text, the line it would be on.
    private func blockFont(_ kind: PreviewBlock.Kind) -> NSFont {
        switch kind {
        case .heading(let level): return font(size: MarkdownBlockView.headingSize(level), weight: .semibold)
        case .codeBlock, .html: return monoFont
        case .table: return font(size: 12)
        default: return font(size: 13)
        }
    }

    private var monoFont: NSFont {
        NSFont.monospacedSystemFont(ofSize: 12 * style.scale, weight: .regular)
    }

    /// How far a quote level and a list level each push the text in.
    static let quoteStep: CGFloat = 14, indentStep: CGFloat = 22

    /// Each drawn quote level's bar: two points into the gap its level leaves, at the list indent
    /// the quote opened at.
    private func quoteBars(depth: Int) -> [CGFloat] {
        (0..<MarkdownBlockView.drawnDepth(depth)).map { level in
            let indent = quoteIndents.indices.contains(level) ? quoteIndents[level] : 0
            return (CGFloat(level) * Self.quoteStep + CGFloat(MarkdownBlockView.drawnDepth(indent)) * Self.indentStep + 2)
                * style.scale
        }
    }

    private func paragraphStyle(for kind: PreviewBlock.Kind, indent: Int,
                                quoteDepth: Int) -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        // Indentation as numbers, as the read-only preview carries it: a list level and a quote
        // level each push the text in. The fragment delegate draws the quote bar in the gap.
        // **Capped at the read-only Preview's depth** — a forwarded mail thread is eight to fifteen
        // `>` deep, and uncapped the words were squeezed to one a line (review, 2026-10-09).
        var lead = CGFloat(MarkdownBlockView.drawnDepth(quoteDepth)) * Self.quoteStep
            + CGFloat(MarkdownBlockView.drawnDepth(indent)) * Self.indentStep
        switch kind {
        case .heading(let level):
            paragraph.paragraphSpacingBefore = (level == 1 ? 4 : 14) * style.scale
            paragraph.paragraphSpacing = 4 * style.scale
        case .listItem(let marker):
            lead += Self.indentStep
            paragraph.lineSpacing = 3 * style.scale
            paragraph.paragraphSpacing = 2 * style.scale
            if case .task = marker {} else { paragraph.textLists = lists }
        case .codeBlock, .html:
            paragraph.paragraphSpacing = 0
        default:
            paragraph.lineSpacing = 3 * style.scale
            paragraph.paragraphSpacing = 8 * style.scale
        }
        paragraph.headIndent = lead * style.scale
        paragraph.firstLineHeadIndent = lead * style.scale
        return paragraph
    }

    static func droppingFinalNewline(_ text: String) -> String {
        text.hasSuffix("\n") ? String(text.dropLast()) : text
    }

    /// As `MarkdownBlocks`' rule of the same name: a paragraph that is one image and nothing else.
    private func loneImage(in paragraph: Paragraph) -> Markdown.Image? {
        var image: Markdown.Image?
        for child in paragraph.children {
            if let candidate = child as? Markdown.Image {
                guard image == nil else { return nil }
                image = candidate
            } else if let text = child as? Markdown.Text {
                guard text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return nil
                }
            } else if child is SoftBreak || child is LineBreak {
                continue
            } else {
                return nil
            }
        }
        return image
    }
}

// MARK: - The parser's inline positions, corrected

/// Turns the parser's inline positions into source offsets, correcting the two cases
/// ``MarkdownProjection`` documents.
///
/// **The model, which every measured case fits.** The parser numbers a paragraph's inline content in
/// *reported lines*. A reported line is one or more real lines — more when a backslash break joins
/// them, because that break does not advance the count. On the block's first reported line a column
/// is the real column; on every later one it is `paragraphColumn` plus a byte offset into the line's
/// content **after** its leading whitespace and quote markers are stripped. Within a reported line
/// that spans several real lines, the offset runs on through each stripped line in turn, its
/// terminator included — as one byte, whatever the terminator is.
struct InlineLines {
    private let index: MarkdownSourceIndex
    /// Body line *n* is file line *n + lineOffset*.
    private let lineOffset: Int
    let paragraphColumn: Int
    /// The real (file) lines that make up the current reported line, and where each one's content
    /// starts. More than one only after a backslash break.
    private var group: [(line: Int, contentStart: Int)]
    /// The current reported line, body-relative — the parser's own numbering.
    private var reportedLine: Int
    private var isFirstGroup = true
    /// How many `>` a continuation line can open with as quote markers: the paragraph's quote depth.
    private let quoteDepth: Int
    /// Where each `\|` in a table cell sits. The table extension unescapes the pipes before the
    /// inline parser runs, so every position after one is reported a unit early — measured: in
    /// `*x*\|*y*` the second emphasis comes back at the pipe, not after it.
    var pipeEscapes: [Int] = []

    init(index: MarkdownSourceIndex, firstBodyLine: Int, lineOffset: Int, paragraphColumn: Int, quoteDepth: Int = 0) {
        self.index = index
        self.quoteDepth = quoteDepth
        self.lineOffset = lineOffset
        self.paragraphColumn = paragraphColumn
        let fileLine = firstBodyLine + lineOffset
        group = [(fileLine, index.line(fileLine)?.start ?? 0)]
        reportedLine = firstBodyLine
    }

    /// The source offset of a parser location on the current reported line, or `nil` when the
    /// location is not on it.
    func offset(of location: SourceLocation) -> Int? {
        var remaining = location.column - (isFirstGroup ? 1 : paragraphColumn)
        guard remaining >= 0, location.line == reportedLine else { return nil }
        for (position, entry) in group.enumerated() {
            guard let line = index.line(entry.line) else { return nil }
            let last = position == group.count - 1
            // A line ending is one byte to the parser, `\r\n` included — measured 2026-10-09: after
            // `foo\` and a CRLF, every later column was a byte short of the model's.
            let width = index.utf8Count(from: entry.contentStart, to: line.end)
                + (last || line.terminatorLength == 0 ? 0 : 1)
            if last ? remaining <= width : remaining < width {
                guard var offset = index.advance(from: entry.contentStart, utf8Bytes: remaining,
                                                 limit: last ? line.end : line.next) else { return nil }
                for escape in pipeEscapes where escape < offset { offset += 1 }
                return offset
            }
            remaining -= width
        }
        return nil
    }

    /// The end of the line the next piece of text must fit in.
    var currentLimit: Int {
        index.line(group[group.count - 1].line)?.end ?? index.length
    }

    /// Places a soft or hard break after `after`, and moves on to the next real line.
    mutating func lineBreak(hard: Bool, after: Int) -> NSRange? {
        let current = group[group.count - 1].line
        guard let line = index.line(current), let next = index.line(current + 1) else { return nil }
        // Where the break starts: a backslash break at its `\`, any other at the trailing
        // whitespace the parser trims.
        var start = line.end
        var backslash = false
        if hard, start > line.start, index.units[start - 1] == 0x5C {
            start -= 1
            backslash = true
        } else {
            while start > max(line.start, after),
                  index.units[start - 1] == 0x20 || index.units[start - 1] == 0x09 { start -= 1 }
        }
        start = max(start, after)
        let contentStart = Self.contentStart(of: next, in: index, quoteDepth: quoteDepth)
        if backslash {
            group.append((current + 1, contentStart))
        } else {
            group = [(current + 1, contentStart)]
            reportedLine += 1
            isFirstGroup = false
        }
        return NSRange(location: start, length: contentStart - start)
    }

    /// Moves to a later reported line without a break node — a code span or raw HTML that wrapped.
    mutating func advanceReportedLines(to bodyLine: Int) {
        let delta = bodyLine - reportedLine
        guard delta > 0 else { return }
        let line = group[group.count - 1].line + delta
        guard let next = index.line(line) else { return }
        group = [(line, Self.contentStart(of: next, in: index, quoteDepth: quoteDepth))]
        reportedLine += delta
        isFirstGroup = false
    }

    /// Where a continuation line's content starts: after its quote markers and leading whitespace.
    ///
    /// **At most `quoteDepth` `>` are markers.** A paragraph line cannot begin with a `>` that would
    /// open a quote — but one after four spaces opens nothing, and is text: `a` then `    >b` is a
    /// paragraph reading "a >b", and skipping that `>` with the markers made it read-only (review,
    /// 2026-10-09). Outside a quote, no `>` is a marker.
    static func contentStart(of line: MarkdownSourceIndex.Line, in index: MarkdownSourceIndex,
                             quoteDepth: Int) -> Int {
        var offset = line.start
        var markers = quoteDepth
        while offset < line.end {
            let unit = index.units[offset]
            if unit == 0x3E, markers > 0 {
                markers -= 1
            } else if unit != 0x20, unit != 0x09 {
                break
            }
            offset += 1
        }
        return offset
    }
}

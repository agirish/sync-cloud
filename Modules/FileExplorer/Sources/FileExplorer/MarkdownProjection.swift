import AppKit
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
    /// For a fenced code block, what stands before its opening fence on that line — a list's
    /// indent, a quote's `> `. An empty line inside the block often has none of it in the file, and
    /// a character typed there without it would end the block, so the translator writes it first.
    var linePrefix = ""
}

extension NSAttributedString.Key {
    /// What block a rendered character belongs to: `paragraph`, `heading`, `listItem`, `code`,
    /// `table`, `rule`, `frontMatter`, `image`, `html`. The fragment delegate draws by it.
    static let previewBlock = NSAttributedString.Key("SyncCloud.preview.block")
    /// How many `>` levels enclose the character, as an `Int`. Absent at 0.
    static let previewQuoteDepth = NSAttributedString.Key("SyncCloud.preview.quoteDepth")
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
    /// On an image block's U+FFFC: the image's source as written, for the view to load.
    static let previewImageSource = NSAttributedString.Key("SyncCloud.preview.imageSource")
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

    static func project(_ source: String, style: Style = Style()) -> MarkdownProjection {
        var builder = Builder(source: source, style: style)
        builder.run()
        return MarkdownProjection(source: source, style: style, index: builder.index,
                                  rendered: builder.out, blocks: builder.blocks,
                                  segments: builder.segments, spans: builder.spans)
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
        var builder = Builder(source: source, style: style, index: index)
        let body = (source as NSString).substring(with: range)
        builder.runSlice(body, firstLine: index.lineNumber(containing: range.location), topLevel: topLevel,
                         previousBlockSourceEnd: previousBlockSourceEnd)
        return Slice(rendered: builder.out, blocks: builder.blocks, segments: builder.segments,
                     spans: builder.spans, topLevelCount: builder.topLevel - topLevel)
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
            appendText("\n", attributes: [:],
                       segment: (.blockBreak, NSRange(location: start,
                                                      length: max(0, source.location - start))),
                       block: blockIndex)
        }
        blocks.append(PreviewBlock(kind: kind, indent: indent, quoteDepth: quoteDepth, line: line,
                                   source: source,
                                   rendered: NSRange(location: out.length, length: 0),
                                   topLevel: topLevel, readOnly: nil))
        currentTag = tag
        currentQuoteDepth = quoteDepth
        currentParagraphStyle = paragraphStyle(for: kind, indent: indent, quoteDepth: quoteDepth)
        return blockIndex
    }

    private mutating func endBlock(_ blockIndex: Int, readOnly: PreviewReadOnlyReason? = nil) {
        let start = blocks[blockIndex].rendered.location
        blocks[blockIndex].rendered.length = out.length - start
        blocks[blockIndex].readOnly = readOnly
        let range = blocks[blockIndex].rendered
        if range.length > 0 {
            out.addAttribute(.paragraphStyle, value: currentParagraphStyle, range: range)
            out.addAttribute(.previewBlock, value: currentTag, range: range)
            if currentQuoteDepth > 0 {
                out.addAttribute(.previewQuoteDepth, value: currentQuoteDepth, range: range)
            }
            if readOnly != nil {
                out.addAttribute(.previewReadOnly, value: true, range: range)
            }
        }
        previousBlockSourceEnd = max(previousBlockSourceEnd, NSMaxRange(blocks[blockIndex].source))
    }

    private var currentTag = ""
    private var currentQuoteDepth = 0
    private var currentParagraphStyle = NSParagraphStyle()

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
                      font: font(size: MarkdownBlockView.headingSize(heading.level), weight: .semibold))

        case let paragraph as Paragraph:
            if let image = loneImage(in: paragraph), let source = range(of: paragraph) {
                let block = beginBlock(.image(source: image.source ?? "",
                                              alt: MarkdownBlocks.text(of: image).plain),
                                       indent: indent, quoteDepth: quoteDepth, line: line,
                                       source: source, tag: "image")
                appendAttachment("image", kind: .decoration, source: source, block: block)
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
                listItem(item, marker: item.checkbox.map { .task(done: $0 == .checked) }
                            ?? .ordered(number),
                         indent: indent, quoteDepth: quoteDepth)
                number += 1
            }
            lists.removeLast()

        case let quote as BlockQuote:
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
            let block = beginBlock(.html, indent: indent, quoteDepth: quoteDepth, line: line,
                                   source: source, tag: "html")
            appendText(Self.droppingFinalNewline(html.rawHTML), attributes: [.font: monoFont],
                       segment: (.readOnly(.html), source), block: block)
            endBlock(block, readOnly: .html)

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
            let block = beginBlock(.other, indent: indent, quoteDepth: quoteDepth, line: line,
                                   source: source, tag: "paragraph")
            appendText(plain, attributes: [.font: font(size: 13)],
                       segment: (.readOnly(.unknown), source), block: block)
            endBlock(block, readOnly: .unknown)
        }
    }

    /// A block whose content is inline text: a heading or a paragraph.
    private mutating func leafBlock(_ markup: any Markup, kind: PreviewBlock.Kind, indent: Int,
                                    quoteDepth: Int, line: Int?, tag: String, font: NSFont) {
        guard let source = range(of: markup) else {
            unalignableBlock(markup, kind: kind, indent: indent, quoteDepth: quoteDepth,
                             line: line, tag: tag, font: font,
                             source: NSRange(location: previousBlockSourceEnd, length: 0))
            return
        }
        let before = mark
        let block = beginBlock(kind, indent: indent, quoteDepth: quoteDepth, line: line,
                               source: source, tag: tag)
        if inlineContent(of: markup, block: block, font: font, inTable: false) == nil {
            rollBack(to: before)
            blocks.removeLast()
            unalignableBlock(markup, kind: kind, indent: indent, quoteDepth: quoteDepth,
                             line: line, tag: tag, font: font, source: source)
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

    /// The block, shown as its plain text and not editable, because its positions did not line up.
    private mutating func unalignableBlock(_ markup: any Markup, kind: PreviewBlock.Kind,
                                           indent: Int, quoteDepth: Int, line: Int?, tag: String,
                                           font: NSFont, source: NSRange) {
        let block = beginBlock(kind, indent: indent, quoteDepth: quoteDepth, line: line,
                               source: source, tag: tag)
        let plain = MarkdownBlocks.text(of: markup).plain
            .replacingOccurrences(of: "\n", with: "\u{2028}")
        appendText(plain, attributes: [.font: font],
                   segment: (.readOnly(.unalignable), source), block: block)
        endBlock(block, readOnly: .unalignable)
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
        var block = beginBlock(.listItem(marker: marker), indent: indent, quoteDepth: quoteDepth,
                               line: line, source: source, tag: "listItem")
        var aligned = true
        if case .task(let done) = marker {
            if let box = checkboxRange(from: itemStart,
                                       to: lead.flatMap { range(of: $0) }?.location ?? firstLineEnd) {
                appendAttachment(done ? "taskDone" : "task", kind: .decoration, source: box,
                                 block: block)
            } else {
                aligned = false
            }
        }
        if aligned, let lead {
            aligned = inlineContent(of: lead, block: block, font: bodyFont, inTable: false) != nil
        } else if aligned, firstLineEnd > itemStart,
                  [0x20, 0x09].contains(index.units[firstLineEnd - 1]) {
            // An item with no words yet — `- ` just written by Bullets, say: an insertion point at
            // the end of its marker line, as an empty cell has one, so what is typed goes into it.
            // Only after a space: typed onto a bare `-`, a word would turn the item into text.
            appendText("", attributes: [.font: bodyFont],
                       segment: (.content, NSRange(location: firstLineEnd, length: 0)), block: block)
        }
        if !aligned {
            rollBack(to: before)
            blocks.removeLast()
            block = beginBlock(.listItem(marker: marker), indent: indent, quoteDepth: quoteDepth,
                               line: line, source: source, tag: "listItem")
            let plain = lead.map { MarkdownBlocks.text(of: $0).plain } ?? ""
            appendText(plain, attributes: [.font: bodyFont],
                       segment: (.readOnly(.unalignable), source), block: block)
            endBlock(block, readOnly: .unalignable)
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
        let fence = source.length >= 3 && index.units.indices.contains(source.location)
            && [0x60, 0x7E].contains(index.units[source.location])

        let before = mark
        let block = beginBlock(.codeBlock(language: language), indent: indent,
                               quoteDepth: quoteDepth, line: line, source: source, tag: "code")
        guard fence else {
            appendText(text, attributes: [.font: monoFont],
                       segment: (.readOnly(.indentedCode), source), block: block)
            endBlock(block, readOnly: .indentedCode)
            return
        }
        if let fenceLine = index.line(index.lineNumber(containing: source.location)) {
            blocks[block].linePrefix = String(utf16CodeUnits: Array(index.units[fenceLine.start..<source.location]),
                                              count: source.location - fenceLine.start)
        }
        if fencedCodeLines(text, block: block, source: source) {
            endBlock(block)
        } else {
            rollBack(to: before)
            blocks.removeLast()
            let again = beginBlock(.codeBlock(language: language), indent: indent,
                                   quoteDepth: quoteDepth, line: line, source: source, tag: "code")
            appendText(text, attributes: [.font: monoFont],
                       segment: (.readOnly(.unalignable), source), block: again)
            endBlock(again, readOnly: .unalignable)
        }
    }

    /// Maps each line of a fenced block onto its source line.
    ///
    /// **A code line is always the TAIL of its source line** — a quote's `> `, a list item's
    /// indentation and the fence's own indent are all prefixes the parser strips — so each line is
    /// found as a suffix rather than through the parser's columns. A line that is not a suffix (a
    /// tab the parser expanded to spaces) fails the whole block, which becomes read-only.
    private mutating func fencedCodeLines(_ text: String, block: Int, source: NSRange) -> Bool {
        let startLine = index.lineNumber(containing: source.location)
        let codeLines = text.isEmpty ? [] : text.components(separatedBy: "\n")
        guard !codeLines.isEmpty else {
            // An empty block: an insertion point at the start of the line after the fence.
            let anchor = index.line(startLine + 1)?.start ?? NSMaxRange(source)
            appendText("", attributes: [:], segment: (.content, NSRange(location: anchor, length: 0)),
                       block: block)
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
                    // An empty cell: an insertion point one space in, inside its padding.
                    let pad = cellRange.length > 0 && index.units[cellRange.location] == 0x20 ? 1 : 0
                    appendText("", attributes: [:],
                               segment: (.content, NSRange(location: cellRange.location + pad,
                                                           length: 0)),
                               block: block)
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
            rollBack(to: before)
            blocks.removeLast()
            let again = beginBlock(.table(columns: columns), indent: indent, quoteDepth: quoteDepth,
                                   line: line, source: source, tag: "table")
            let plain = rows.map { row in
                row.cells.map { MarkdownBlocks.text(of: $0).plain }.joined(separator: "\t")
            }.joined(separator: "\n")
            appendText(plain, attributes: [.font: bodyFont],
                       segment: (.readOnly(.unalignable), source), block: again)
            endBlock(again, readOnly: .unalignable)
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
                let width = out.attributedSubstring(from: NSRange(location: cellStart, length: length)).size().width
                widths[column] = max(widths[column], ceil(width))
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
        if let column = style.columnWidth, edges[edges.count - 1] > column {
            // Too wide: left to Source, and no grid — its cells wrap, and lines drawn at the stops
            // would cross them.
            blocks[block].readOnly = .wideTable
        } else {
            out.addAttribute(.previewTableColumns, value: edges.map { $0 - lead }, range: range)
        }
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
                                paragraphColumn: start.column)
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
            guard let start = text.range.map({ walker.lines.offset(of: $0.lowerBound) })
                      ?? walker.unpositionedStart,
                  start >= walker.sourceEnd,
                  let aligned = Self.align(Array(text.string.utf16), in: index.units, at: start,
                                           limit: walker.lines.currentLimit(index: index),
                                           escapes: true, pipes: false)
            else { return nil }
            appendText(text.string, attributes: inlineAttributes(walker),
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
                appendText(code.code, attributes: attributes,
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
                walker.lines.advanceReportedLines(to: end.line, index: index)
            }

        case is SoftBreak, is LineBreak:
            guard let placed = walker.lines.lineBreak(hard: markup is LineBreak, index: index,
                                                      after: walker.sourceEnd)
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
            appendText(html.rawHTML, attributes: attributes, segment: (.readOnly(.inlineHTML), range),
                       block: block)
            walker.sourceEnd = NSMaxRange(range)
            if let end = html.range?.upperBound, end.line > location.line {
                walker.lines.advanceReportedLines(to: end.line, index: index)
            }

        case let image as Markdown.Image:
            guard let range = image.range,
                  let start = walker.lines.offset(of: range.lowerBound), start >= walker.sourceEnd,
                  start < index.length, index.units[start] == 0x21   // "!"
            else { return nil }
            if range.upperBound.line > range.lowerBound.line {
                walker.lines.advanceReportedLines(to: range.upperBound.line, index: index)
            }
            guard let end = walker.lines.offset(of: range.upperBound), end > start else { return nil }
            let placed = NSRange(location: start, length: end - start)
            appendAttachment("inlineImage", kind: .decoration, source: placed, block: block)
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
                walker.lines.advanceReportedLines(to: range.upperBound.line, index: index)
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
        let rendered = Array(code.utf16)
        // The content as written, then with the one space each side the parser strips.
        for (from, to) in [(inner, close), (inner + 1, close - 1)] where from <= to {
            if let aligned = Self.align(rendered, in: units, at: from, limit: to, escapes: false,
                                        pipes: inTable), aligned.end == to {
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
    static func align(_ rendered: [UInt16], in source: [UInt16], at start: Int, limit: Int,
                      escapes: Bool, pipes: Bool) -> (end: Int, map: [Int]?)? {
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
               Array(rendered[j..<j + entity.decoded.count]) == entity.decoded {
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
        segments.append(PreviewSegment(kind: segment.kind,
                                       rendered: NSRange(location: location,
                                                         length: out.length - location),
                                       source: segment.source, block: block,
                                       charMap: charMap, spans: spans))
    }

    private mutating func appendAttachment(_ what: String, kind: PreviewSegment.Kind,
                                           source: NSRange, block: Int) {
        let location = out.length
        out.append(NSAttributedString(attachment: NSTextAttachment()))
        out.addAttribute(.previewAttachment, value: what,
                         range: NSRange(location: location, length: out.length - location))
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

    private var monoFont: NSFont {
        NSFont.monospacedSystemFont(ofSize: 12 * style.scale, weight: .regular)
    }

    private func paragraphStyle(for kind: PreviewBlock.Kind, indent: Int,
                                quoteDepth: Int) -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        // Indentation as numbers, as the read-only preview carries it: a list level and a quote
        // level each push the text in. The fragment delegate draws the quote bar in the gap.
        var lead = CGFloat(quoteDepth) * 14 + CGFloat(indent) * 22
        switch kind {
        case .heading(let level):
            paragraph.paragraphSpacingBefore = (level == 1 ? 4 : 14) * style.scale
            paragraph.paragraphSpacing = 4 * style.scale
        case .listItem(let marker):
            lead += 22
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
/// terminator included.
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
    /// Where each `\|` in a table cell sits. The table extension unescapes the pipes before the
    /// inline parser runs, so every position after one is reported a unit early — measured: in
    /// `*x*\|*y*` the second emphasis comes back at the pipe, not after it.
    var pipeEscapes: [Int] = []

    init(index: MarkdownSourceIndex, firstBodyLine: Int, lineOffset: Int, paragraphColumn: Int) {
        self.index = index
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
            let width = index.utf8Count(from: entry.contentStart, to: last ? line.end : line.next)
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
    func currentLimit(index: MarkdownSourceIndex) -> Int {
        index.line(group[group.count - 1].line)?.end ?? index.length
    }

    /// Places a soft or hard break after `after`, and moves on to the next real line.
    mutating func lineBreak(hard: Bool, index: MarkdownSourceIndex, after: Int) -> NSRange? {
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
        let contentStart = Self.contentStart(of: next, in: index)
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
    mutating func advanceReportedLines(to bodyLine: Int, index: MarkdownSourceIndex) {
        let delta = bodyLine - reportedLine
        guard delta > 0 else { return }
        let line = group[group.count - 1].line + delta
        guard let next = index.line(line) else { return }
        group = [(line, Self.contentStart(of: next, in: index))]
        reportedLine += delta
        isFirstGroup = false
    }

    /// Where a continuation line's content starts: after its quote markers and leading whitespace.
    ///
    /// **`>` is safe to skip:** a paragraph line cannot begin with an unescaped `>`, because that
    /// line would open a block quote instead.
    static func contentStart(of line: MarkdownSourceIndex.Line, in index: MarkdownSourceIndex) -> Int {
        var offset = line.start
        while offset < line.end, [0x20, 0x09, 0x3E].contains(index.units[offset]) { offset += 1 }
        return offset
    }
}

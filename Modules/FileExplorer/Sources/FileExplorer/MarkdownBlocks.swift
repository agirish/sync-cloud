import Foundation
import Markdown

/// A run of text in the preview, and what is true of it.
///
/// Flat, not nested: Markdown's inline tree nests (emphasis in a link in strong) but the rendered
/// line is one flat `AttributedString`, so the walk collapses the tree into runs carrying the
/// accumulated style. Bold inside a link arrives as one run that is both.
struct MarkdownRun: Equatable, Sendable {
    var text: String
    var isBold = false
    var isItalic = false
    var isCode = false
    var isStruck = false
    /// The destination, when this run is part of a link.
    var link: String?
    /// Raw inline HTML: drawn as code, like ``isCode``, but no part of a heading's name, so the
    /// outline and the status line leave it out (``MarkdownOutline/title(of:)``).
    var isHTML = false
}

/// A line of styled text — one paragraph, one heading, one table cell.
struct MarkdownText: Equatable, Sendable {
    var runs: [MarkdownRun]

    /// The plain characters, every style dropped: what an accessibility label reads, and what a
    /// test asserts when styling isn't under test.
    var plain: String { runs.map(\.text).joined() }

    var isEmpty: Bool { plain.isEmpty }
}

/// What a list row is marked with.
enum MarkdownListMarker: Equatable, Sendable {
    case bullet
    case ordered(Int)
    /// A GFM task item, read from the parser rather than by pattern-matching `- [ ]`, which would
    /// also match a bracket pair someone typed on purpose.
    case task(done: Bool)
}

/// One block in the rendered preview: what it is, and where the document put it.
///
/// A flat array with the nesting carried as data, so the preview lays out in one stack instead of
/// re-deriving spacing at every level of a nested view tree. `indent` and `quoteDepth` live on the
/// wrapper, not on particular cases, because every kind can be nested: a list inside a `>` needs
/// its quote bar, and a fenced block under a bullet needs its indent.
struct MarkdownBlock: Equatable, Sendable {
    var kind: Kind
    /// List nesting, 0 at the document's own margin.
    var indent: Int = 0
    /// How many `>` levels enclose this block. 0 when it is not quoted.
    var quoteDepth: Int = 0
    /// The 1-based source line this block starts on, or `nil` when the parser reported no range.
    ///
    /// A line, not a character offset: every caller asks a line's question (scroll to this heading,
    /// find this task's `[ ]`, keep the preview level with the caret), and a line survives edits
    /// between parses that shift every offset after them. `nil` is a real case: a synthesised node
    /// has no line, and treating it as line 1 would scroll somewhere nobody asked for.
    var line: Int?

    enum Kind: Equatable, Sendable {
        case heading(level: Int, text: MarkdownText)
        case paragraph(MarkdownText)
        case listItem(marker: MarkdownListMarker, text: MarkdownText)
        case codeBlock(language: String?, code: String)
        case table(header: [MarkdownText], rows: [[MarkdownText]])
        case thematicBreak
        /// The YAML block the file opened with, held as its raw text. See ``MarkdownFrontMatter``.
        case frontMatter(String)
        /// A paragraph that is nothing but one image. See ``MarkdownImageSource``.
        ///
        /// Only when it is the whole paragraph, which is how notes write images: `![alt](shot.png)`
        /// on its own line. An image mid-sentence stays an inline run showing its alt text, because
        /// a sentence is drawn as one `Text` and a picture is not a `Text`.
        case image(source: String, alt: String)
    }

    init(_ kind: Kind, indent: Int = 0, quoteDepth: Int = 0, line: Int? = nil) {
        self.kind = kind
        self.indent = indent
        self.quoteDepth = quoteDepth
        self.line = line
    }
}

/// Turns Markdown source into the preview's block list.
///
/// `swift-markdown`, not a hand-rolled parser, for the long tail: setext headings, lazy
/// continuation lines, reference links, tables with escaped pipes, a `#` inside a fenced block.
enum MarkdownBlocks {

    /// Parses `source` and walks it into blocks.
    ///
    /// Never throws and never returns `nil`: every byte sequence is some Markdown document. A shape
    /// the walk doesn't know becomes its plain text rather than disappearing.
    static func blocks(from source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        // No `.parseBlockDirectives`: directives are a DocC extension, and the parser opens one on
        // any bare `@name` at a line's start (`@channel`, `@media`, `@2x`). The walk's fallback
        // would then print it with parentheses the file doesn't contain and drop its styling.
        // Front matter comes off the top first; `MarkdownFrontMatter` says why.
    let split = MarkdownFrontMatter.split(source)
    let document = Document(parsing: split.body)
        for child in document.children {
            append(child, indent: 0, quoteDepth: 0, into: &blocks)
        }
        // Back into the file's numbering, not the body's: these lines count from below the front
        // matter, and the outline, task toggle and split sync all name lines in the buffer.
        if split.bodyStartLine > 1 {
            let offset = split.bodyStartLine - 1
            for index in blocks.indices {
                blocks[index].line = blocks[index].line.map { $0 + offset }
            }
        }
        if let matter = split.frontMatter {
            blocks.insert(MarkdownBlock(.frontMatter(matter), line: 1), at: 0)
        }
        return blocks
    }

    private static func append(_ markup: any Markup, indent: Int, quoteDepth: Int,
                               into blocks: inout [MarkdownBlock]) {
        // Read once, here: every arm that emits does so for this node, and an arm that recurses (a
        // quote, a list) passes its children's own ranges down instead.
        let line = self.line(of: markup)
        func emit(_ kind: MarkdownBlock.Kind) {
            blocks.append(MarkdownBlock(kind, indent: indent, quoteDepth: quoteDepth, line: line))
        }

        switch markup {
        case let heading as Heading:
            emit(.heading(level: heading.level, text: text(of: heading)))

        case let paragraph as Paragraph:
            // A paragraph holding one image and nothing else is a picture, not a sentence.
            if let image = loneImage(in: paragraph) {
                emit(.image(source: image.source ?? "", alt: text(of: image).plain))
                break
            }
            let content = text(of: paragraph)
            // An empty paragraph is a blank the source didn't really contain; dropping it leaves
            // spacing to the stack.
            guard !content.isEmpty else { break }
            emit(.paragraph(content))

        case let list as UnorderedList:
            for item in list.listItems {
                appendListItem(item, indent: indent, quoteDepth: quoteDepth,
                               marker: item.checkbox.map { .task(done: $0 == .checked) } ?? .bullet,
                               into: &blocks)
            }

        case let list as OrderedList:
            // `startIndex` is a `UInt`, and a list starting at 0 is legal Markdown.
            var number = Int(list.startIndex)
            for item in list.listItems {
                let marker: MarkdownListMarker = item.checkbox.map { .task(done: $0 == .checked) }
                    ?? .ordered(number)
                appendListItem(item, indent: indent, quoteDepth: quoteDepth, marker: marker,
                               into: &blocks)
                number += 1
            }

        case let quote as BlockQuote:
            for child in quote.children {
                append(child, indent: indent, quoteDepth: quoteDepth + 1, into: &blocks)
            }

        case let code as CodeBlock:
            // A bare ``` gives an empty language tag; treat it as absent.
            let language = code.language.flatMap { $0.isEmpty ? nil : $0 }
            emit(.codeBlock(language: language, code: code.code))

        case let html as HTMLBlock:
            // Raw HTML is shown as source, not rendered: the preview is the app's own type, not a
            // web view, and dropping a block the file contains would be worse.
            emit(.codeBlock(language: "html", code: html.rawHTML))

        case is ThematicBreak:
            emit(.thematicBreak)

        case let table as Table:
            appendTable(table, indent: indent, quoteDepth: quoteDepth, into: &blocks)

        default:
            // Anything the walk doesn't model, such as a footnote definition, lands as its plain
            // text rather than vanishing. `format()` is the library's own round-trip.
            let plain = markup.format().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !plain.isEmpty else { break }
            emit(.paragraph(MarkdownText(runs: [MarkdownRun(text: plain)])))
        }
    }

    /// The image a paragraph consists of, or `nil` when it holds anything else.
    ///
    /// Whitespace-only text doesn't count: `![a](b.png)` and a newline parse as an image plus an
    /// empty text node, and calling that mixed would show every image as its alt text.
    private static func loneImage(in paragraph: Paragraph) -> Markdown.Image? {
        var image: Markdown.Image?
        for child in paragraph.children {
            if let candidate = child as? Markdown.Image {
                guard image == nil else { return nil }   // two images: a row, not a picture
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

    /// The 1-based line a node begins on, or `nil` when the parser reported no range.
    ///
    /// `swift-markdown` gives ranges only to nodes it read from the source, not ones it
    /// synthesised (see ``MarkdownBlock/line``). Asked in one place so the walk has one answer.
    static func line(of markup: any Markup) -> Int? {
        markup.range?.lowerBound.line
    }

    /// A list item: its own line, then anything nested under it one level deeper.
    private static func appendListItem(_ item: ListItem, indent: Int, quoteDepth: Int,
                                       marker: MarkdownListMarker,
                                       into blocks: inout [MarkdownBlock]) {
        // The lead is the first child or nothing: an item that opens with a fenced block keeps
        // its later paragraph below the code, not promoted above it.
        var children = Array(item.children)
        var lead: MarkdownText?
        if let paragraph = children.first as? Paragraph {
            lead = text(of: paragraph)
            children.removeFirst()
        }
        let nested = children
        blocks.append(MarkdownBlock(.listItem(marker: marker, text: lead ?? MarkdownText(runs: [])),
                                    indent: indent, quoteDepth: quoteDepth, line: line(of: item)))
        for child in nested {
            append(child, indent: indent + 1, quoteDepth: quoteDepth, into: &blocks)
        }
    }

    private static func appendTable(_ table: Table, indent: Int, quoteDepth: Int,
                                    into blocks: inout [MarkdownBlock]) {
        let header = Array(table.head.cells.map { text(of: $0) })
        var rows: [[MarkdownText]] = []
        for row in table.body.rows {
            var cells = Array(row.cells.map { text(of: $0) })
            // Padded to the header's width, so every row has a cell in every column. Markdown
            // allows a ragged row, and its cells are the leading columns, so the padding goes last.
            while cells.count < header.count { cells.append(MarkdownText(runs: [])) }
            rows.append(cells)
        }
        blocks.append(MarkdownBlock(.table(header: header, rows: rows),
                                    indent: indent, quoteDepth: quoteDepth, line: line(of: table)))
    }

    // MARK: - Inline

    /// Flattens a container's inline children into styled runs.
    static func text(of markup: any Markup) -> MarkdownText {
        var runs: [MarkdownRun] = []
        for child in markup.children {
            collect(child, style: MarkdownRun(text: ""), into: &runs)
        }
        return MarkdownText(runs: merged(runs))
    }

    /// Walks one inline node, carrying the styles accumulated on the way down.
    private static func collect(_ markup: any Markup, style: MarkdownRun,
                                into runs: inout [MarkdownRun]) {
        switch markup {
        case let text as Markdown.Text:
            var run = style
            run.text = text.string
            runs.append(run)

        case let code as InlineCode:
            var run = style
            run.text = code.code
            run.isCode = true
            runs.append(run)

        case is SoftBreak:
            // A single newline is a space in the rendered paragraph, so hard-wrapped Markdown reads
            // as prose.
            var run = style
            run.text = " "
            runs.append(run)

        case is LineBreak:
            var run = style
            run.text = "\n"
            runs.append(run)

        case let html as InlineHTML:
            var run = style
            run.text = html.rawHTML
            run.isCode = true
            run.isHTML = true
            runs.append(run)

        case let image as Image:
            // An image inside a sentence is its alt text; only a paragraph that is one image is
            // drawn as a picture (`.image`, see `loneImage(in:)`).
            var run = style
            let label = text(of: image).plain
            run.text = label.isEmpty ? "🖼" : "🖼 \(label)"
            runs.append(run)

        default:
            var inherited = style
            switch markup {
            case is Strong: inherited.isBold = true
            case is Emphasis: inherited.isItalic = true
            case is Strikethrough: inherited.isStruck = true
            case let link as Link: inherited.link = link.destination
            default: break
            }
            for child in markup.children {
                collect(child, style: inherited, into: &runs)
            }
        }
    }

    /// Joins neighbouring runs that carry identical styling.
    ///
    /// The walk emits one run per inline node, so plain prose arrives as runs that differ in
    /// nothing; merging keeps a paragraph a few attributed runs rather than thirty.
    private static func merged(_ runs: [MarkdownRun]) -> [MarkdownRun] {
        var merged: [MarkdownRun] = []
        for run in runs where !run.text.isEmpty {
            if var last = merged.last, sameStyle(last, run) {
                last.text += run.text
                merged[merged.count - 1] = last
            } else {
                merged.append(run)
            }
        }
        return merged
    }

    private static func sameStyle(_ a: MarkdownRun, _ b: MarkdownRun) -> Bool {
        a.isBold == b.isBold && a.isItalic == b.isItalic && a.isCode == b.isCode
            && a.isStruck == b.isStruck && a.link == b.link && a.isHTML == b.isHTML
    }
}

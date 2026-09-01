import Foundation
import Markdown

/// A run of text in the preview, and what is true of it.
///
/// **Flattened rather than nested.** Markdown's inline tree nests — emphasis inside a link inside
/// strong — and SwiftUI's `Text` concatenation is flat, so the walk collapses the tree into runs
/// carrying the accumulated style. Nesting is preserved as *combination*: bold-inside-a-link
/// arrives as one run that is both.
struct MarkdownRun: Equatable, Sendable {
    var text: String
    var isBold = false
    var isItalic = false
    var isCode = false
    var isStruck = false
    /// The destination, when this run is part of a link.
    var link: String?
}

/// A line of styled text — one paragraph, one heading, one table cell.
struct MarkdownText: Equatable, Sendable {
    var runs: [MarkdownRun]

    /// The plain characters, with every style dropped. What an accessibility label reads, and what
    /// a test asserts when the styling is not the thing under test.
    var plain: String { runs.map(\.text).joined() }

    var isEmpty: Bool { plain.isEmpty }
}

/// What a list row is marked with.
enum MarkdownListMarker: Equatable, Sendable {
    case bullet
    case ordered(Int)
    /// A GFM task item. **Native, not a pre-pass** — this is the whole reason the preview parses
    /// real GFM rather than pattern-matching `- [ ]` out of the line, which would also have matched
    /// a literal bracket pair someone typed on purpose.
    case task(done: Bool)
}

/// One block in the rendered preview: what it is, and where the document put it.
///
/// **A flat array, with the nesting carried as data on every block.** The document tree is nested,
/// and a nested SwiftUI view hierarchy would have to re-derive spacing at every level; a flat list
/// lays out in one stack with the indentation as numbers.
///
/// **`indent` and `quoteDepth` are on the wrapper, not on individual cases**, and that is a
/// correction. They started as associated values on `.listItem` and a separate `.quote` case, which
/// meant only those two kinds could say where they were: a bulleted list inside a `>` drew no quote
/// bar and read as ordinary body text, and a fenced block nested under a bullet rendered flush left,
/// visually detached from the item it belongs to. Every block can be nested, so every block carries
/// the answer.
struct MarkdownBlock: Equatable, Sendable {
    var kind: Kind
    /// List nesting, 0 at the document's own margin.
    var indent: Int = 0
    /// How many `>` levels enclose this block. 0 when it is not quoted.
    var quoteDepth: Int = 0
    /// The **1-based source line** this block starts on, or `nil` when the parser reported no range.
    ///
    /// **A line, not a character offset, and that is the cheaper of two correct answers.** Every
    /// caller asks a question a line answers: scroll the text view to where this heading is, find
    /// the `[ ]` belonging to this task, keep the preview level with the caret. A character range
    /// would have to be re-derived into a line for each of them, and — because the buffer is edited
    /// between parses — would be stale in a way a line number survives: inserting a word does not
    /// move the line, it moves every offset after it.
    ///
    /// `nil` is a real case rather than a defensive default. Blocks the walk synthesises rather
    /// than reads — a padded table cell, the plain-text fallback for a shape it does not model —
    /// have no single line to name, and a caller that treats `nil` as "line 1" would scroll
    /// somewhere it was never told to go.
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
        /// **Only when it is the whole paragraph**, which is how images are written in notes —
        /// `![alt](shot.png)` on its own line. An image in the middle of a sentence stays an inline
        /// run showing its alt text, because SwiftUI's `Text` concatenation is what draws a
        /// sentence and a picture is not a `Text`.
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
/// **`swift-markdown`, not a hand-rolled parser** — settled as a design decision, and the reason is
/// the long tail: setext headings, lazy continuation lines, reference links, tables with escaped
/// pipes, a `#` inside a fenced block. Each is a rule somebody would otherwise have to rediscover
/// by being wrong about it in a file of his that mattered.
enum MarkdownBlocks {

    /// Parses `source` and walks it into blocks.
    ///
    /// Never throws and never returns `nil`: Markdown has no invalid input — every byte sequence is
    /// *some* document — so the failure this has to survive is not a parse error but a shape the
    /// walk does not know, which becomes its plain text rather than disappearing.
    static func blocks(from source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        // **No `.parseBlockDirectives`.** Block directives are a DocC extension, not Markdown, and
    // the parser opens one on a bare `@` followed by a name — no parentheses and no braces
    // required, with "garbage after the opening" explicitly accepted. A note containing
    // `@channel ping me about **the invoice**` therefore parsed as a directive, and the fallback
    // arm of the walk renders an unrecognised node with `markup.format()`, which prints a directive
    // by wrapping its arguments in PARENTHESES the file does not contain and dropping the styling.
    // The preview was rewriting the user's line. `@media` in an unfenced CSS snippet, `@2x`, and an
    // `@username` at the start of a line all did the same. Nothing in the walk needs the option.
    // Front matter is taken off the top first — see `MarkdownFrontMatter` for why leaving it in
    // turns a YAML key into a heading.
    let split = MarkdownFrontMatter.split(source)
    let document = Document(parsing: split.body)
        for child in document.children {
            append(child, indent: 0, quoteDepth: 0, into: &blocks)
        }
        // **Put back into the FILE's numbering, not the body's.** Every line here was measured
        // against a string that starts below the front matter, and the outline, the task toggle and
        // the split sync all name lines in the buffer — so a document with six lines of front
        // matter would send every one of them six lines too high.
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
        // Read once, here, rather than inside `emit` — every arm that emits does so for THIS node,
        // and an arm that recurses (a quote, a list) passes its children's own ranges down instead.
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
            // An empty paragraph is a blank the source did not really contain — dropping it keeps
            // the preview's spacing the stack's business rather than the document's.
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
            // The language tag can be present and empty (a bare ```), which is not the same as
            // absent for anything that might one day highlight it.
            let language = code.language.flatMap { $0.isEmpty ? nil : $0 }
            emit(.codeBlock(language: language, code: code.code))

        case let html as HTMLBlock:
            // Raw HTML is shown as what it is rather than rendered. The preview is the app's own
            // type ramp, not a web view — and silently dropping a block the file contains would be
            // the worse answer.
            emit(.codeBlock(language: "html", code: html.rawHTML))

        case is ThematicBreak:
            emit(.thematicBreak)

        case let table as Table:
            appendTable(table, indent: indent, quoteDepth: quoteDepth, into: &blocks)

        default:
            // Anything the walk does not model — a block directive, a footnote definition — lands
            // as its plain text rather than vanishing. `format()` is the library's own round-trip.
            let plain = markup.format().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !plain.isEmpty else { break }
            emit(.paragraph(MarkdownText(runs: [MarkdownRun(text: plain)])))
        }
    }

    /// The image a paragraph consists of, or `nil` when it holds anything else.
    ///
    /// **Whitespace-only text around it does not count as "anything else".** `![a](b.png)` followed
    /// by a newline parses as an image plus an empty text node, and treating that as a mixed
    /// paragraph would send every image in every file back to the alt-text placeholder.
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
    /// **Not every node has one.** `swift-markdown` populates ranges for what it read out of the
    /// source, and leaves them empty for nodes it synthesised — which is exactly the set
    /// ``MarkdownBlock/line`` documents as legitimately `nil`. Asked in one place so the walk never
    /// grows a second opinion about what an absent range means.
    static func line(of markup: any Markup) -> Int? {
        markup.range?.lowerBound.line
    }

    /// A list item: its own line, then anything nested under it one level deeper.
    private static func appendListItem(_ item: ListItem, indent: Int, quoteDepth: Int,
                                       marker: MarkdownListMarker,
                                       into blocks: inout [MarkdownBlock]) {
        // **The lead is the FIRST child or nothing**, which the `lead == nil` form did not say.
        // For an item that opens with a fenced block and then explains it, that condition promoted
        // the *later* paragraph to the item's own line and pushed the code block after it — the
        // preview showed the explanation above the code it explained.
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
            // **Padded to the header's width.** A short row left-packs otherwise, so a missing
            // middle cell shifts every cell after it one column left and the absence appears at the
            // END of the row — the one place it is not. Markdown allows the ragged row; the table
            // has to render it in the right columns anyway.
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
            // A single newline in the source is a space in the rendered paragraph — the reflow rule
            // that makes hard-wrapped Markdown read as prose rather than as short lines.
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
            runs.append(run)

        case let image as Image:
            // No image loading in the preview: this renders the app's own type, and a preview that
            // reached out to fetch a remote file would be doing something the editor does not.
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
    /// The walk emits one run per inline node, so ordinary prose arrives as a handful of runs that
    /// differ in nothing — and each run becomes its own `Text` in the rendered line. Merging is
    /// what keeps a paragraph one `Text` rather than thirty, which matters because concatenated
    /// `Text` is what lets the line wrap as a single paragraph.
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
            && a.isStruck == b.isStruck && a.link == b.link
    }
}

import Foundation

/// The editable preview's boundary and structure rules (TE67 §3.5): where a keystroke at an inline
/// edge lands, and what a new line has to start with.
///
/// **Pure, over a ``MarkdownProjection``.** Nothing here edits; ``PreviewEditTranslator`` asks
/// these questions, builds the edit, and checks the result by re-rendering.
enum PreviewEditRules {

    /// Where typing at a rendered caret lands in the source, and which inline spans it lands in.
    struct InsertionPoint: Equatable {
        var source: Int
        /// Indices into ``MarkdownProjection/spans``, outermost first.
        var spans: [Int]
        var block: Int
    }

    /// Where text typed at rendered `caret` goes.
    ///
    /// **Typing inherits the style of the character before it**, the way Pages and Word do: at the
    /// end of bold, italic or strikethrough it continues the span; at the start of a span it stays
    /// outside; **at the end of a link or a code span it goes outside**, because nobody typing after
    /// a link means to lengthen it. With nothing before the caret in its block — the block's start,
    /// or just after a line break — it takes the style of what follows, minus the spans opening there.
    ///
    /// `nil` when the caret is not somewhere text can go: inside an entity, in a read-only block, on
    /// a decoration, in an empty list item.
    static func insertionPoint(at caret: Int, in p: MarkdownProjection) -> InsertionPoint? {
        let segments = p.segments
        // Inside a content segment, strictly: no edge to decide.
        if let index = segments.firstIndex(where: {
            $0.kind == .content && $0.rendered.location < caret && caret < NSMaxRange($0.rendered)
        }) {
            let segment = segments[index]
            guard isEditable(segment, in: p),
                  let source = segment.sourceOffset(forRenderedBoundary: caret - segment.rendered.location)
            else { return nil }
            return InsertionPoint(source: source, spans: segment.spans, block: segment.block)
        }
        // An empty insertion point — an empty cell, an empty code block — is its own answer.
        if let anchor = segments.first(where: {
            $0.kind == .content && $0.rendered.length == 0 && $0.rendered.location == caret
        }), isEditable(anchor, in: p) {
            return InsertionPoint(source: anchor.source.location, spans: anchor.spans,
                                  block: anchor.block)
        }
        let left = segments.lastIndex { NSMaxRange($0.rendered) == caret && $0.rendered.length > 0 }
        if let left, segments[left].kind == .content {
            let segment = segments[left]
            guard isEditable(segment, in: p) else { return nil }
            let closing = closingSpans(of: left, in: p)
            // The outermost span closing here that does not extend: step outside it.
            if let stop = segment.spans.firstIndex(where: { closing.contains($0) && !extends(p.spans[$0].kind) }) {
                return InsertionPoint(source: NSMaxRange(p.spans[segment.spans[stop]].source),
                                      spans: Array(segment.spans[..<stop]), block: segment.block)
            }
            return InsertionPoint(source: NSMaxRange(segment.source), spans: segment.spans,
                                  block: segment.block)
        }
        // Nothing to inherit from on the left: take the right, outside the spans it opens.
        guard let right = segments.firstIndex(where: {
            $0.kind == .content && $0.rendered.location == caret && $0.rendered.length > 0
        }) else { return nil }
        let segment = segments[right]
        guard isEditable(segment, in: p) else { return nil }
        let opening = openingSpans(of: right, in: p)
        if let first = segment.spans.firstIndex(where: { opening.contains($0) }) {
            return InsertionPoint(source: p.spans[segment.spans[first]].source.location,
                                  spans: Array(segment.spans[..<first]), block: segment.block)
        }
        return InsertionPoint(source: segment.source.location, spans: segment.spans,
                              block: segment.block)
    }

    /// Whether typing at a span's closing edge continues it.
    static func extends(_ kind: PreviewInlineSpan.Kind) -> Bool {
        switch kind {
        case .strong, .emphasis, .strikethrough: return true
        case .code, .link: return false
        }
    }

    static func isEditable(_ segment: PreviewSegment, in p: MarkdownProjection) -> Bool {
        segment.kind == .content && p.blocks[segment.block].readOnly == nil
    }

    /// The spans of content segment `index` that hold no later content — the ones closing after it.
    static func closingSpans(of index: Int, in p: MarkdownProjection) -> Set<Int> {
        let segment = p.segments[index]
        var open = Set(segment.spans)
        for later in p.segments[(index + 1)...] where later.block == segment.block {
            open.subtract(later.spans)
        }
        return open
    }

    /// The spans of content segment `index` that hold no earlier content — the ones opening before it.
    static func openingSpans(of index: Int, in p: MarkdownProjection) -> Set<Int> {
        let segment = p.segments[index]
        var opening = Set(segment.spans)
        for earlier in p.segments[..<index] where earlier.block == segment.block {
            opening.subtract(earlier.spans)
        }
        return opening
    }

    // MARK: Lines

    /// The line ending Preview writes: LF, always — Edit writes LF only (``EditorLineEndings``,
    /// §4 C31). A CRLF or CR file is converted before its first edit is measured, so the source a
    /// translation sees holds no carriage return.
    static let lineEnding = "\n"

    /// What a new line inside block `block` starts with, so it stays in that block: a quote's `>`
    /// markers kept, everything else before the block's first character turned to spaces — so a
    /// list item's continuation lines up under its words.
    static func continuationPrefix(of block: Int, in p: MarkdownProjection) -> String {
        let start = p.segments.first { $0.block == block && $0.kind == .content }?.source.location
            ?? p.blocks[block].source.location
        return prefix(before: start, in: p)
    }

    /// What a new paragraph after block `block` starts with: the quote markers and indent before the
    /// block itself — not before its words, which for a list item would be inside the item.
    static func paragraphPrefix(of block: Int, in p: MarkdownProjection) -> String {
        prefix(before: p.blocks[block].source.location, in: p)
    }

    /// A blank line that keeps a quote open: `prefix` without its trailing whitespace.
    static func blankLine(for prefix: String) -> String {
        String(prefix.reversed().drop { $0 == " " || $0 == "\t" }.reversed())
    }

    private static func prefix(before offset: Int, in p: MarkdownProjection) -> String {
        guard let line = p.index.line(p.index.lineNumber(containing: offset)) else { return "" }
        let units = p.index.units[line.start..<max(line.start, offset)]
        return String(units.map { unit -> Character in
            switch unit {
            case 0x3E: return ">"
            case 0x09: return "\t"
            default: return " "
            }
        })
    }

    // MARK: Positions

    /// The block whose rendered range holds `caret`, its end included.
    static func block(at caret: Int, in p: MarkdownProjection) -> Int? {
        p.blocks.firstIndex { $0.rendered.location <= caret && caret <= NSMaxRange($0.rendered) }
    }

    /// The rendered offset a source offset maps to — where a caret placed in Source would sit in the
    /// preview. In a content segment, the boundary at that source offset; in the syntax between
    /// segments, the start of the next piece of text.
    static func renderedOffset(forSource offset: Int, in p: MarkdownProjection) -> Int {
        for segment in p.segments where segment.kind == .content {
            guard segment.source.location <= offset, offset <= NSMaxRange(segment.source) else { continue }
            for boundary in 0...segment.rendered.length {
                if let source = segment.sourceOffset(forRenderedBoundary: boundary), source >= offset {
                    return segment.rendered.location + boundary
                }
            }
        }
        // In syntax: where the separator holding it is drawn, else the first piece after it. A break — between blocks, rows,
        // cells or lines — is drawn exactly where the text before it ends, so a closing `*` at a
        // paragraph's end keeps the caret on that paragraph, and a list item emptied of its words
        // keeps it on that item.
        if let holder = p.segments.first(where: {
            $0.kind != .content && $0.source.location <= offset && offset < NSMaxRange($0.source)
        }) {
            return holder.rendered.location
        }
        if let next = p.segments.first(where: { $0.source.location >= offset }) {
            return next.rendered.location
        }
        return (p.renderedString as NSString).length
    }
}

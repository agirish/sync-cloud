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
        }) else { return beside(caret, left: left, in: p) }
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

    /// **Text beside a piece that is not text**, with no text on either side: an inline picture or
    /// inline HTML at a line's end or start — `see ![i](a)` could take nothing at its end (review,
    /// 2026-10-09). Typed just past its source, or just before it, in the spans it sits in. A
    /// task's box is no such piece: an item with only a box is empty, and has its own anchor.
    private static func beside(_ caret: Int, left: Int?, in p: MarkdownProjection) -> InsertionPoint? {
        let piece = { (segment: PreviewSegment) in
            p.blocks[segment.block].readOnly == nil && isInlinePiece(segment, in: p)
        }
        let found: (segment: PreviewSegment, source: Int)?
        if let left, piece(p.segments[left]) {
            found = (p.segments[left], NSMaxRange(p.segments[left].source))
        } else if let right = p.segments.first(where: { $0.rendered.location == caret && $0.rendered.length > 0 }),
                  piece(right) {
            found = (right, right.source.location)
        } else {
            found = nil
        }
        guard let found else { return nil }
        // The spans holding the piece, outermost first — the order they were opened in.
        let spans = p.spans.indices.filter {
            p.spans[$0].source.location < found.segment.source.location
                && NSMaxRange(found.segment.source) < NSMaxRange(p.spans[$0].source)
        }
        return InsertionPoint(source: found.source, spans: spans, block: found.segment.block)
    }

    /// An inline piece of a line that is not text: a picture, or inline HTML or another read-only run.
    static func isInlinePiece(_ segment: PreviewSegment, in p: MarkdownProjection) -> Bool {
        switch segment.kind {
        case .readOnly: return true
        case .decoration:
            // "!", a picture — in a line of text: a picture block takes Return, not typing; a
            // task's box is the item's, not a piece of its words.
            if case .image = p.blocks[segment.block].kind { return false }
            return p.index.units[segment.source.location] == 0x21
        default: return false
        }
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

    // MARK: Deleting

    /// What deleting rendered `range` really takes, once Markdown's rule for spaces is applied.
    ///
    /// **Spaces left at a line's edge go too, on whichever side touches it** — the text's start or
    /// end, a block's, a soft or hard line break's, a table cell's or row's — because Markdown draws
    /// them as nothing, so they could never be what the rendering shows. "hello w" ⌫ was refused for
    /// the space it left last (review, 2026-10-05), "Hello world" ⌫ from after "Hello" for the one it
    /// left first, and so was the first or last word beside any break (2026-10-09).
    ///
    /// **A line of a paragraph emptied takes one of its breaks with it**, or the two left side by
    /// side would split the paragraph there. **Never in code**, whose spaces are its text.
    static func deletionRange(_ range: NSRange, in p: MarkdownProjection) -> NSRange {
        let length = (p.renderedString as NSString).length
        var start = range.location, end = NSMaxRange(range)
        if endsLine(at: end, in: p) { while start > 0, isLooseSpace(start - 1, in: p) { start -= 1 } }
        if startsLine(at: start, in: p) { while end < length, isLooseSpace(end, in: p) { end += 1 } }
        if start < end, startsLine(at: start, in: p), endsLine(at: end, in: p) {
            if start > 0, let before = segment(containing: start - 1, in: p), isLineBreak(before) {
                start = before.rendered.location
            } else if let after = segment(containing: end, in: p), isLineBreak(after) {
                end = NSMaxRange(after.rendered)
            }
        }
        return NSRange(location: start, length: end - start)
    }

    /// Whether rendered `offset` begins a line: the text's start, or just after a break of any kind.
    /// A task's box counts as the start: the words after it are where its line's text begins.
    static func startsLine(at offset: Int, in p: MarkdownProjection) -> Bool {
        guard offset > 0 else { return true }
        guard let before = segment(containing: offset - 1, in: p) else { return true }
        return isBreak(before) || before.kind == .decoration && p.index.units[before.source.location] == 0x5B
    }

    /// Whether rendered `offset` ends a line: the text's end, or just before a break of any kind.
    static func endsLine(at offset: Int, in p: MarkdownProjection) -> Bool {
        segment(containing: offset, in: p).map(isBreak) ?? true
    }

    /// A space Markdown would drop at a line's edge: prose, not code.
    private static func isLooseSpace(_ offset: Int, in p: MarkdownProjection) -> Bool {
        guard (p.renderedString as NSString).character(at: offset) == 0x20,
              let segment = segment(containing: offset, in: p), segment.kind == .content else { return false }
        return !p.blocks[segment.block].kind.isCode && !segment.spans.contains { p.spans[$0].kind == .code }
    }

    private static func isBreak(_ segment: PreviewSegment) -> Bool {
        switch segment.kind {
        case .softBreak, .hardBreak, .codeNewline, .cellBreak, .rowBreak, .blockBreak: true
        case .content, .decoration, .readOnly: false
        }
    }

    /// A soft or hard break: one line of a paragraph ending and the next beginning.
    private static func isLineBreak(_ segment: PreviewSegment) -> Bool {
        segment.kind == .softBreak || segment.kind == .hardBreak
    }

    /// The segment drawing rendered character `offset`.
    ///
    /// **By halving** (round 2, 2026-10-10): the segments are the rendering's ordered, gap-free
    /// cover, so the one drawing `offset` is the last to start at or before it. Where that is an
    /// empty one, nothing draws `offset`: in a gap-free cover the segment before it ends where it
    /// starts (stepping back past it changed nothing — measured on the property test's random
    /// documents). A walk from the first was a keystroke's cost on a long note, for every question
    /// about a line's edges.
    static func segment(containing offset: Int, in p: MarkdownProjection) -> PreviewSegment? {
        let segments = p.segments
        var low = 0, high = segments.count
        while low < high {
            let mid = (low + high) / 2
            if segments[mid].rendered.location <= offset { low = mid + 1 } else { high = mid }
        }
        let at = low - 1
        guard at >= 0, offset < NSMaxRange(segments[at].rendered) else { return nil }
        return segments[at]
    }

    // MARK: Lines

    /// The line ending Preview writes: LF, always — Edit writes LF only (``EditorLineEndings``,
    /// §4 C31). A CRLF or CR file is converted before its first edit is measured, so the source a
    /// translation sees holds no carriage return.
    static let lineEnding = "\n"

    /// What a new line inside block `block` starts with, so it stays in that block: a quote's `>`
    /// markers kept, everything else before the block's first character turned to spaces — so a
    /// list item's continuation lines up under its words.
    ///
    /// The words start where their first piece does — a box, a picture — and **before the markers of
    /// any span opening there**: ⇧Return in `**Note** text` indented the new line by the width of
    /// the `**` (found 2026-10-09).
    static func continuationPrefix(of block: Int, in p: MarkdownProjection) -> String {
        let first = p.segments.first { $0.block == block && !isBreak($0) }
        let start = first.map { segment in
            segment.spans.map { p.spans[$0].source.location }.reduce(segment.source.location, min)
        } ?? p.blocks[block].source.location
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

    /// Whether the line after the one source `offset` is on holds text — anything but spaces, tabs
    /// and quote markers — so that a paragraph written in between would run on into it.
    static func nextLineHoldsText(after offset: Int, in p: MarkdownProjection) -> Bool {
        let number = p.index.lineNumber(containing: offset)
        guard let next = p.index.line(number + 1) else { return false }
        return p.index.units[next.start..<next.end].contains { $0 != 0x20 && $0 != 0x09 && $0 != 0x3E }
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

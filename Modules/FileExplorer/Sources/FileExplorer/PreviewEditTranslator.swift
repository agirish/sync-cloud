import Foundation

/// What the preview's text view asked for: replace `range` of the rendered text with `text`.
struct RenderedEdit: Equatable {
    enum Action: Equatable {
        case typing
        case paste
        /// Backspace, Delete, or cutting a selection: `text` is empty.
        case delete
        case returnKey
        /// ⇧Return.
        case lineBreak
        case tab
        case backtab
        case format(MarkupVerb)
        /// A click on a task box; `range` is the box's U+FFFC.
        case tickTask
    }
    var range: NSRange
    var text: String = ""
    var action: Action
}

/// Inline styles waiting for the next character (A4): ⌘B with nothing selected lights Bold and
/// writes nothing, because Preview would draw an empty `****` as four asterisks.
///
/// **Toggled against the style at the caret**: in bold, ⌘B means "not bold" for what is typed next.
struct PreviewPendingStyle: OptionSet, Hashable {
    let rawValue: Int
    static let bold = PreviewPendingStyle(rawValue: 1)
    static let italic = PreviewPendingStyle(rawValue: 2)
    static let strikethrough = PreviewPendingStyle(rawValue: 4)
    static let code = PreviewPendingStyle(rawValue: 8)
}

/// What the view knows that the projection does not.
struct PreviewEditContext: Equatable {
    var pending: PreviewPendingStyle = []
    /// A Return at the end of this block opened an empty paragraph the source does not have yet
    /// (§3.5): the next character typed is what writes it.
    var phantomAfterBlock: Int?
    /// Whether an edit in a tidy table re-pads it (decision T). Off for each match of a Replace All,
    /// whose re-paddings would overlap; the whole is re-padded once instead.
    var realignsTables = true
}

/// Read-only pieces counted by what they are and what they say (``PreviewEditTranslator/check``).
///
/// **What they say is a hash of their source, with its length** (round 2, 2026-10-10): a copy of
/// each piece's text, for both projections at every check, was a keystroke's cost on a note full
/// of HTML. Two pieces that differ and still collide in 64 bits, at the same length and reason,
/// would compare as one.
struct PreviewPieceCount {
    private struct Piece: Hashable {
        var reason: PreviewReadOnlyReason
        var length: Int
        var hash: Int
    }
    private var counts: [Piece: Int] = [:]

    mutating func add(_ reason: PreviewReadOnlyReason, _ range: NSRange, of units: [UInt16]) {
        var hasher = Hasher()
        for unit in units[range.location..<NSMaxRange(range)] { hasher.combine(unit) }
        counts[Piece(reason: reason, length: range.length, hash: hasher.finalize()), default: 0] += 1
    }

    /// Whether every piece here is one `other` has, as often.
    func isSubset(of other: PreviewPieceCount) -> Bool {
        counts.allSatisfy { other.counts[$0.key, default: 0] >= $0.value }
    }
}

/// One replacement in the source.
struct PreviewSourceEdit: Equatable {
    var range: NSRange
    var text: String
}

/// How an accepted edit joins the undo stack.
enum PreviewUndoStep: Equatable {
    /// Joins neighbouring typing in the same block into one "Undo Typing", as `NSTextView` does.
    case typing
    /// Its own ⌘Z step, never merged with typing on either side: every verb, Return, Tab, paste and
    /// tick — the rule Markup verbs follow in Source (`MarkupVerbUndoTests`).
    case own
}

/// Why an edit was not made. The hint says "That change needs Source." for every one of them except
/// ``PreviewEditOutcome/ignore``; the reason goes to the `.debug` log.
enum PreviewRefusal: Equatable, Error {
    /// The selection crosses from one block into another.
    case crossesBlocks
    /// It would join two blocks — Backspace at a block's start, Delete at its end.
    case joinsBlocks
    case readOnly(PreviewReadOnlyReason)
    /// On something that is not text: a checkbox, an image, a rule.
    case notText
    /// Several lines pasted outside a code block, or a Return or Tab where v1 has no rule.
    case notSupported
    /// The edit was built, and the re-render did not show what was typed — even escaped.
    case unverified
    /// One of a Replace All's matches could not be made, so none were.
    case replaceAll(failed: Int, of: Int)
}

/// What the translator decided.
enum PreviewEditOutcome {
    case apply(PreviewEditApplication)
    /// Move the caret without touching the source — Return or Tab in a table.
    case moveCaret(Int)
    /// Return at the end of a paragraph or heading: show an empty paragraph after `afterBlock`, and
    /// change nothing in the file until a character is typed into it.
    case openPhantom(afterBlock: Int)
    /// ⌘B, ⌘I and friends with nothing selected: the new pending set.
    case setPending(PreviewPendingStyle)
    /// `line` is where in this file it was refused — the site the log names, which a refusal's
    /// reason alone does not: a dozen places say `.notSupported` (review, 2026-10-09).
    case refuse(PreviewRefusal, line: Int = #line, unverified: PreviewEditTranslator.Unverified? = nil)
    /// The key is taken and nothing happens, without the hint — Tab outside a list, table or code,
    /// where nothing the person wrote was lost.
    case ignore
}

struct PreviewEditApplication {
    /// Non-overlapping, in increasing order of location, each against the source BEFORE any of them.
    var edits: [PreviewSourceEdit]
    var undo: PreviewUndoStep
    /// The source after the edits, and its projection.
    var source: String
    var projection: MarkdownProjection
    /// Where the selection goes, in the new source and in the new rendering.
    var sourceSelection: NSRange
    var renderedSelection: NSRange
    /// A deletion emptied a paragraph, which Markdown cannot hold: its line went, and an empty
    /// paragraph is opened after this block (§3.5), the caret in it — where the person left it.
    var opensParagraphAfter: Int?
}

/// Turns one edit in the preview into the smallest edit to the Markdown source that renders as
/// what the person did — or refuses it (TE67 §3.4).
///
/// **Refuse unless verified.** Every text edit is applied to a copy of the source and re-projected,
/// and accepted only when the new rendering is the old one with exactly the person's change made:
/// the same characters (allowing for the parser's curly quotes and dashes, §2.1), and the typed
/// characters in the style they were typed in. A `*` typed into prose first goes in bare; it
/// renders as emphasis, the check fails, and it goes in again as `\*`. `snake_case` passes bare.
/// Nothing guesses which characters need escaping — the parser is asked.
enum PreviewEditTranslator {

    static func translate(_ edit: RenderedEdit, in p: MarkdownProjection,
                          context: PreviewEditContext = PreviewEditContext()) -> PreviewEditOutcome {
        let length = (p.renderedString as NSString).length
        guard edit.range.location >= 0, NSMaxRange(edit.range) <= length else {
            return .refuse(.notSupported)
        }
        switch edit.action {
        case .typing, .paste, .delete:
            if let phantom = context.phantomAfterBlock, !edit.text.isEmpty {
                return phantomParagraph(after: phantom, typing: edit.text, pending: context.pending, in: p)
            }
            return text(edit, in: p, context: context)
        case .returnKey: return returnKey(at: edit.range, in: p)
        case .lineBreak:
            // With `text`: the break the session held at a paragraph's end, and what is typed after it.
            return lineBreak(at: edit.range, typing: edit.text, pending: context.pending, in: p)
        case .tab, .backtab: return tab(at: edit.range, outdent: edit.action == .backtab, in: p)
        case .format(let verb): return format(verb, over: edit.range, in: p, context: context)
        case .tickTask: return tickTask(at: edit.range, in: p)
        }
    }

    /// Replace All (A11): every match or none, one undo step.
    static func translateAll(_ edits: [RenderedEdit], in p: MarkdownProjection) -> PreviewEditOutcome {
        // Each match as its own edit would take it — a match replaced with nothing at a line's edge
        // takes the spaces beside it, so the whole is expected without them too (review, 2026-10-09:
        // refused whenever a match was followed by a line break).
        let edits = edits.map { edit -> RenderedEdit in
            guard edit.text.isEmpty, edit.range.length > 0 else { return edit }
            var each = edit
            each.range = PreviewEditRules.deletionRange(edit.range, in: p)
            return each
        }
        var source: [PreviewSourceEdit] = []
        var failed = 0
        var each = PreviewEditContext()
        each.realignsTables = false
        for edit in edits {
            guard case .apply(let one) = translate(edit, in: p, context: each) else { failed += 1; continue }
            source += one.edits
        }
        guard failed == 0 else { return .refuse(.replaceAll(failed: failed, of: edits.count)) }
        source.sort { $0.range.location < $1.range.location }
        for (a, b) in zip(source, source.dropFirst()) where NSMaxRange(a.range) > b.range.location {
            return .refuse(.replaceAll(failed: edits.count, of: edits.count))
        }
        let ordered = edits.sorted { $0.range.location < $1.range.location }
        let expected = ordered.reversed()
            .reduce(p.renderedString as NSString) { text, edit in
                text.replacingCharacters(in: edit.range, with: edit.text) as NSString
            } as String
        guard var after = verified(source, expected: expected, in: p) else {
            return .refuse(.replaceAll(failed: edits.count, of: edits.count))
        }
        // Decision T, once for the whole: each tidy table a match fell in is re-padded around all
        // of its matches together (review: per match, the re-paddings overlapped and all failed).
        let tables = Set(edits.compactMap { edit -> Int? in
            guard let b = PreviewEditRules.block(at: edit.range.location, in: p), case .table = p.blocks[b].kind,
                  let before = MarkdownTables.locate(in: p.source as NSString, at: p.blocks[b].source.location),
                  realignsAsYouType(p.source, table: before.table) else { return nil }
            return b
        })
        var tidied = after.source
        for b in tables.sorted(by: >) {
            let start = p.blocks[b].source.location
            let shift = source.filter { NSMaxRange($0.range) <= start }
                .reduce(0) { $0 + ($1.text as NSString).length - $1.range.length }
            guard let here = MarkdownTables.locate(in: tidied as NSString, at: start + shift),
                  let tidy = MarkdownTables.tidy(source: tidied, table: here.table) else { continue }
            tidied = tidy.text
        }
        if let retidied = retidied(tidied, as: after, from: p) {
            source = retidied.edits
            after = retidied.projection
        }
        // The caret after the last replacement, as `NSTextView`'s Replace All leaves it — not at
        // the top of the note (review, 2026-10-09).
        let caret = ordered.last.map { last in
            NSMaxRange(last.range) + ordered.reduce(0) { $0 + ($1.text as NSString).length - $1.range.length }
        } ?? 0
        let rendered = NSRange(location: min(caret, (after.renderedString as NSString).length), length: 0)
        return .apply(PreviewEditApplication(edits: source, undo: .own, source: after.source,
                                             projection: after,
                                             sourceSelection: sourceSelection(for: rendered, in: after)
                                                ?? NSRange(location: 0, length: 0),
                                             renderedSelection: rendered))
    }

    /// The source re-padded as `tidied`, as the edits from `p` and their projection — when it
    /// renders exactly as `after` did, which re-padding always should; otherwise `nil`.
    private static func retidied(_ tidied: String, as after: MarkdownProjection,
                                 from p: MarkdownProjection) -> (edits: [PreviewSourceEdit], projection: MarkdownProjection)? {
        guard tidied != after.source else { return nil }
        let realigned = MarkdownProjection.project(tidied, style: p.style, after: p)
        guard realigned.renderedString == after.renderedString else { return nil }
        let change = MarkdownEdits.minimalReplacement(from: p.source, to: tidied)
        return ([PreviewSourceEdit(range: change.range, text: change.text)], realigned)
    }

    // MARK: Text

    private static func text(_ edit: RenderedEdit, in p: MarkdownProjection,
                             context: PreviewEditContext) -> PreviewEditOutcome {
        var edit = edit
        // One line copied with its line break is one line: the break is not a paragraph's worth.
        // `last`, not `hasSuffix("\n")`: a CRLF is one Character, which "\n" is not (review).
        if edit.action == .paste, edit.text.last?.isNewline == true,
           !edit.text.dropLast().contains(where: { $0.isNewline }) {
            edit.text.removeLast()
        }
        if edit.range.length > 0 {
            // A triple-click's selection ends with the line break the next block starts with. Typed
            // over or bolded, the paragraph is meant and the break stays; deleted, the paragraph
            // goes, line and all, as it would in any text editor (review, 2026-10-09: refused).
            if edit.text.isEmpty, let whole = wholeBlock(edit.range, in: p) { return whole }
            edit.range = withoutTrailingBlockBreak(edit.range, in: p)
        }
        if edit.text.isEmpty, edit.range.length > 0 {
            edit.range = PreviewEditRules.deletionRange(edit.range, in: p)
            if let emptied = emptiedParagraph(edit.range, in: p) { return emptied }
        }
        if edit.text.contains(where: { $0.isNewline }) {
            // Several lines pasted: verbatim in fenced code (A10), refused anywhere else.
            return multilinePaste(edit, in: p)
        }
        let undo: PreviewUndoStep = edit.action == .paste ? .own : .typing
        let expected = (p.renderedString as NSString)
            .replacingCharacters(in: edit.range, with: edit.text)

        // Where the typed text goes, and what it removes.
        var removals: [NSRange] = []
        let point: PreviewEditRules.InsertionPoint
        if edit.range.length == 0 {
            guard !edit.text.isEmpty else { return .ignore }
            if p.blocks.isEmpty {
                return emptyDocument(typing: edit.text, in: p)
            }
            guard let found = PreviewEditRules.insertionPoint(at: edit.range.location, in: p) else {
                return .refuse(refusalAt(edit.range.location, in: p))
            }
            point = found
        } else {
            // Typed over: a span the selection covers from inside its start keeps its style for the
            // new text; one it covers from before its start is replaced whole (review: ` docs`
            // over a link left an empty `[](…)` behind).
            switch removalRanges(edit.range, in: p, keepingSpansAt: edit.text.isEmpty ? nil : edit.range.location) {
            case .failure(let refusal): return .refuse(refusal)
            case .success(let found):
                removals = found.ranges
                point = found.start
            }
            if !edit.text.isEmpty, PreviewEditRules.segment(containing: edit.range.location, in: p)?.kind != .content {
                // Typing over a line break: v1 has no rule for what that should keep.
                return .refuse(.notSupported)
            }
        }

        // A blank line of fenced code inside a list or quote holds no prefix in the file: the first
        // character typed there brings it, or the line would fall out of the block (review).
        var linePrefix = ""
        if edit.range.length == 0, p.blocks[point.block].kind.isCode, !p.blocks[point.block].linePrefix.isEmpty,
           let line = p.index.line(p.index.lineNumber(containing: point.source)),
           line.start == point.source, line.end == point.source {
            linePrefix = p.blocks[point.block].linePrefix
        }
        let inCode = p.blocks[point.block].kind.isCode
            || point.spans.contains { p.spans[$0].kind == .code }
        let pending = inCode ? [] : context.pending
        guard let place = placement(at: point, toggling: pending, in: p) else {
            return .refuse(.notSupported)   // a style turned off inside a link or code, which cannot be split
        }
        let (open, close) = delimiters(for: place.adding)
        // **Spaces leading the text go before the markers it is styled with** — `** x**` is no
        // bold. A space held at a line's end, then ⌘B and a letter, came here as ` x` (round 2).
        let lead = open.isEmpty ? 0 : edit.text.prefix(while: { $0 == " " }).count
        let found = firstVerified(inCode ? [edit.text] : escapeAttempts(edit.text), expected: expected, in: p) { typed in
            let styled = typed.dropFirst(lead)
            let inserted = typed.isEmpty ? ""
                : linePrefix + place.before + typed.prefix(lead) + (styled.isEmpty ? "" : open + styled + close) + place.after
            return merged(removals: removals, insertion: inserted, at: place.at)
        } accepting: { typed, after in
            // Typed in the style it was typed in: the spans it lands in, and the pending styles.
            typed.count == lead || styleAt(edit.range.location + lead, in: after)
                == (place.spans.map { p.spans[$0].kind } + kinds(for: place.adding)).map(normalizedKind)
        }
        let made: (attempt: String, edits: [PreviewSourceEdit], after: MarkdownProjection)
        switch found {
        case .success(let success): made = success
        case .failure(let why): return .refuse(.unverified, unverified: why)
        }
        // A deletion leaves the caret where it started — before any markers it took with it.
        let caret = made.attempt.isEmpty
            ? (made.edits.first?.range.location ?? point.source)
            : sourceCaret(after: made.edits, insertionAt: place.at,
                          typedLength: (linePrefix + place.before + (made.attempt.count == lead ? "" : open)
                                        + made.attempt).utf16.count)
        var result = application(made.edits, undo: undo, caret: caret, after: made.after)
        // When the rendering is exactly the old one with the edit made, the caret's place in it
        // is known without mapping: after what was typed. Mapping is the fallback for when the
        // parser's smart punctuation changed the length — a separator's source runs on through
        // the next text's opening markers, so a caret there cannot say which side it is on.
        if made.after.renderedString == expected {
            let rendered = edit.range.location + (edit.text as NSString).length
            result.renderedSelection = NSRange(location: rendered, length: 0)
        }
        return .apply((context.realignsTables ? realigned(result, typedInto: point, in: p) : nil) ?? result)
    }

    /// Where text typed at `point` goes, given the styles ⌘B, ⌘I and friends toggled for it (A4).
    /// A style the caret is not in is ADDED, by markers around the text; one it
    /// is in is TURNED OFF: at the span's end the text goes after its closing marker, and inside
    /// it the span is closed before the text and opened again after — `**bo**x**ld**`. Both used to
    /// add the style again, which wrote `**bold****x**` and refused it (review, 2026-10-09).
    private static func placement(at point: PreviewEditRules.InsertionPoint, toggling pending: PreviewPendingStyle,
                                  in p: MarkdownProjection) -> Placement? {
        // The outermost span the caret is in whose style is toggled: the typed text leaves it.
        guard let off = point.spans.firstIndex(where: { !style(of: [$0], in: p).isDisjoint(with: pending) }) else {
            return Placement(at: point.source, spans: point.spans, adding: pending)
        }
        let x = point.spans[off]
        let outside = Array(point.spans[..<off])
        // Added: the toggled styles the caret is not in, and those of the spans inside the one it
        // leaves that were not toggled — italic inside bold stays italic when ⌘B turns bold off.
        let adding = pending.subtracting(style(of: point.spans, in: p))
            .union(style(of: Array(point.spans[(off + 1)...]), in: p).subtracting(pending))
        // At the span's end — no more of its text after the caret — the text goes after its marker.
        if let last = p.segments.last(where: { $0.kind == .content && $0.spans.contains(x) }),
           NSMaxRange(last.source) == point.source {
            return Placement(at: NSMaxRange(p.spans[x].source), spans: outside, adding: adding)
        }
        // Inside it: closed from the innermost out, opened again from the outermost in.
        var closers = "", openers = ""
        for span in point.spans[off...].reversed() {
            guard let marker = marker(of: span, in: p) else { return nil }
            closers += marker
            openers = marker + openers
        }
        return Placement(at: point.source, before: closers, after: openers, spans: outside, adding: adding)
    }

    struct Placement {
        var at: Int
        /// Written before the typed text and its pending markers, and after them.
        var before = "", after = ""
        /// The spans the typed text is in, outermost first.
        var spans: [Int]
        var adding: PreviewPendingStyle
    }

    /// The pending styles spans `indices` are — a link or code is none.
    private static func style(of indices: [Int], in p: MarkdownProjection) -> PreviewPendingStyle {
        indices.reduce(into: []) { style, index in
            switch p.spans[index].kind {
            case .strong: style.insert(.bold)
            case .emphasis: style.insert(.italic)
            case .strikethrough: style.insert(.strikethrough)
            case .code, .link: break
            }
        }
    }

    /// The marker span `index` closes with, as written — `**` or `__`, `*` or `_`, `~~` or `~`;
    /// `nil` for a link or code, which are not closed and opened again around typing.
    private static func marker(of index: Int, in p: MarkdownProjection) -> String? {
        let span = p.spans[index]
        let length: Int
        switch span.kind {
        case .strong: length = 2
        case .emphasis: length = 1
        case .strikethrough:
            length = p.index.units[span.source.location..<NSMaxRange(span.source)].prefix { $0 == 0x7E }.count
        case .code, .link: return nil
        }
        guard length > 0, span.source.length >= 2 * length else { return nil }
        return (p.source as NSString).substring(with: NSRange(location: NSMaxRange(span.source) - length, length: length))
    }

    /// **Decision T — re-align as you type** (the user's choice, 2026-10-05): an edit in a cell of a
    /// table whose pipes lined up leaves them lined up, the whole table re-padded around it, the
    /// caret kept at its place in its cell. A ragged table keeps its own spacing, as the Table
    /// menu's edits keep it (TE66). `nil` when there is nothing to re-pad — or when the re-padded
    /// table would not render exactly as the edit did, which it always should.
    private static func realigned(_ result: PreviewEditApplication, typedInto point: PreviewEditRules.InsertionPoint,
                                  in p: MarkdownProjection) -> PreviewEditApplication? {
        guard case .table = p.blocks[point.block].kind,
              let before = MarkdownTables.locate(in: p.source as NSString, at: point.source),
              realignsAsYouType(p.source, table: before.table),
              let here = MarkdownTables.locate(in: result.source as NSString, at: result.sourceSelection.location),
              let tidy = MarkdownTables.edit(.tidy, source: result.source, table: here.table, row: here.row,
                                             column: here.column, offsetInCell: here.offsetInCell),
              let retidied = retidied(tidy.text, as: result.projection, from: p) else { return nil }
        return PreviewEditApplication(edits: retidied.edits, undo: result.undo, source: tidy.text,
                                      projection: retidied.projection, sourceSelection: tidy.selection,
                                      renderedSelection: result.renderedSelection)
    }

    /// **Which tables decision T re-pads:** those whose pipes line up AND are written padded —
    /// `| a | b |`, the way Format Table writes them. A compact `|a|b|` or a pipe-less `a | b` can
    /// line up too, but re-padding would rewrite the author's style on the first keystroke
    /// (review, 2026-10-05); those keep it, as a ragged table does. **The Table menu's rule too**
    /// (TBL-4) — ``MarkdownTables/keepsLinedUp(source:table:)``, one predicate, so a row added from
    /// the menu and a word typed in a cell treat a table the same way.
    static func realignsAsYouType(_ source: String, table range: NSRange) -> Bool {
        MarkdownTables.keepsLinedUp(source: source, table: range)
    }

    /// The source ranges a rendered selection removes, and where text typed over it goes.
    ///
    /// **Markers survive (A2):** deleting "nty of" across `**plenty** of` deletes the characters and
    /// keeps the `**`. **A span left with no text loses its markers too**, so no `****` is left
    /// behind — but only when nothing replaces the text: typing over a whole bold word keeps it bold.
    private static func removalRanges(_ range: NSRange, in p: MarkdownProjection,
                                      keepingSpansAt keep: Int?)
        -> Result<(ranges: [NSRange], start: PreviewEditRules.InsertionPoint), PreviewRefusal> {
        let touched = p.segments.enumerated().filter {
            NSIntersectionRange($0.element.rendered, range).length > 0
        }
        guard let first = touched.first else { return .failure(.notText) }
        let block = first.element.block
        guard touched.allSatisfy({ $0.element.block == block }) else { return .failure(.crossesBlocks) }
        if let reason = p.blocks[block].readOnly { return .failure(.readOnly(reason)) }

        var ranges: [NSRange] = []
        var fullyRemoved = Set<Int>()
        for (index, segment) in touched {
            switch segment.kind {
            case .content:
                let from = max(range.location, segment.rendered.location) - segment.rendered.location
                let to = min(NSMaxRange(range), NSMaxRange(segment.rendered)) - segment.rendered.location
                guard let start = segment.sourceOffset(forRenderedBoundary: from),
                      let end = segment.sourceOffset(forRenderedBoundary: to) else {
                    return .failure(.notSupported)   // half an entity
                }
                ranges.append(NSRange(location: start, length: end - start))
                if from == 0, to == segment.rendered.length { fullyRemoved.insert(index) }
            case .softBreak, .hardBreak, .codeNewline:
                ranges.append(segment.source)
            case .blockBreak, .rowBreak, .cellBreak:
                return .failure(.joinsBlocks)
            case .decoration:
                return .failure(.notText)
            case .readOnly(let reason):
                return .failure(.readOnly(reason))
            }
        }
        // A span whose every piece of text is going takes its delimiters with it — unless what is
        // typed is to take its place, from where the span starts.
        let candidates = Set(touched.flatMap { $0.element.spans })
        for span in candidates {
            let holders = p.segments.indices.filter {
                p.segments[$0].kind == .content && p.segments[$0].spans.contains(span)
            }
            guard !holders.isEmpty, holders.allSatisfy(fullyRemoved.contains) else { continue }
            if let keep, p.segments[holders[0]].rendered.location == keep { continue }
            ranges.append(p.spans[span].source)
        }
        let start = first.element
        let startOffset = start.kind == .content
            ? start.sourceOffset(forRenderedBoundary: max(0, range.location - start.rendered.location))
                ?? start.source.location
            : start.source.location
        return .success((union(ranges),
                         PreviewEditRules.InsertionPoint(source: startOffset, spans: start.spans,
                                                         block: block)))
    }

    /// `range` without the block break it ends on, if it ends on one — what a triple-click adds.
    private static func withoutTrailingBlockBreak(_ range: NSRange, in p: MarkdownProjection) -> NSRange {
        guard range.length > 1, let last = PreviewEditRules.segment(containing: NSMaxRange(range) - 1, in: p),
              last.kind == .blockBreak else { return range }
        return NSRange(location: range.location, length: range.length - last.rendered.length)
    }

    /// A deletion of exactly one block and the break after it — a triple-clicked paragraph, heading
    /// or list item — removes it whole: its lines, and the blank lines after them.
    ///
    /// **The first item of a numbered list hands its number on** (round 2, 2026-10-10): the list
    /// starts at the number its first item is written with, so `1. a` deleted over `2. b` left a
    /// list that started at 2. The next item is written with the deleted one's number, in the same
    /// step — and only where its number on screen would change: a middle item's going renumbers
    /// nothing in the file.
    private static func wholeBlock(_ range: NSRange, in p: MarkdownProjection) -> PreviewEditOutcome? {
        guard let index = p.blocks.firstIndex(where: { $0.rendered.location == range.location }),
              p.blocks[index].rendered.length > 0, index + 1 < p.blocks.count,
              p.blocks[index + 1].rendered.location == NSMaxRange(range), p.blocks[index].readOnly == nil
        else { return nil }
        switch p.blocks[index].kind {
        case .paragraph, .heading, .listItem: break
        default: return nil
        }
        let block = p.blocks[index], next = p.blocks[index + 1]
        let removed = lines(of: block, upTo: next, in: p)
        let outcome = removal(removed, rendered: range, blocks: index...index, in: p)
        guard case .listItem(.ordered(let number)) = block.kind, case .apply(let result) = outcome,
              case .listItem(.ordered(let shown)) = result.projection.blocks[index].kind, shown != number,
              shape(next) == shape(block),
              let digits = markerNumber(of: next, in: p) else { return outcome }
        let renumbered = removal(removed, rendered: range, blocks: index...index, in: p,
                                 also: [PreviewSourceEdit(range: digits, text: "\(number)")])
        guard case .apply(let made) = renumbered,
              made.projection.blocks[index].kind == block.kind else {
            return .refuse(.unverified, unverified: .movesBlocks)
        }
        return renumbered
    }

    /// Where list item `block`'s number is written — the digits of its `1.` — or `nil`.
    private static func markerNumber(of block: PreviewBlock, in p: MarkdownProjection) -> NSRange? {
        let units = p.index.units
        var end = block.source.location
        while end < units.count, (0x30...0x39).contains(units[end]) { end += 1 }
        return end > block.source.location ? NSRange(location: block.source.location, length: end - block.source.location) : nil
    }

    /// Block `block`'s lines whole — a quote's markers too — and the blank lines after them, up to
    /// the line `next` starts on.
    ///
    /// **Up to the first line that holds anything, which stays** (round 2, 2026-10-10). A link
    /// reference definition makes no block, so it sits between two blocks unseen — and so does the
    /// comment written as one, `[//]: # (note)`. Deleting the paragraph before it took it too, and
    /// nothing on screen could tell: it draws nothing either way.
    private static func lines(of block: PreviewBlock, upTo next: PreviewBlock, in p: MarkdownProjection) -> NSRange {
        let start = lineStart(block.source.location, in: p)
        let limit = lineStart(next.source.location, in: p)
        let last = p.index.lineNumber(containing: max(block.source.location, NSMaxRange(block.source) - 1))
        var number = last + 1
        while let line = p.index.line(number), line.start < limit, !holdsText(line, in: p) { number += 1 }
        let end = p.index.line(number).map { min($0.start, limit) } ?? limit
        return NSRange(location: start, length: max(start, end) - start)
    }

    /// Whether source line `line` holds anything but spaces, tabs and quote markers.
    private static func holdsText(_ line: MarkdownSourceIndex.Line, in p: MarkdownProjection) -> Bool {
        p.index.units[line.start..<line.end].contains { $0 != 0x20 && $0 != 0x09 && $0 != 0x3E }
    }

    /// **A deletion that empties a paragraph takes its line too** — Markdown has no empty
    /// paragraph, so what was left was two blank lines and a refusal (review, 2026-10-09). The line
    /// goes with the blank line before it, and the session opens an empty paragraph where it was
    /// (§3.5), the caret in it, as a text editor leaves an emptied line: the next character typed
    /// writes it, and ⌫ there closes it. Headings, items, cells and code can stand empty, and keep
    /// their place.
    ///
    /// The first block has nothing above it to open a paragraph after: it goes with the blank line
    /// after it, and the caret is at the next block's start. Nor does one that was not at the level
    /// of the block above — the paragraph after a sub-list is the outer list's: it goes, and the
    /// caret is at the end of the block above.
    private static func emptiedParagraph(_ range: NSRange, in p: MarkdownProjection) -> PreviewEditOutcome? {
        guard let index = p.blocks.firstIndex(where: { $0.rendered == range && range.length > 0 }),
              case .paragraph = p.blocks[index].kind, p.blocks[index].readOnly == nil else { return nil }
        let block = p.blocks[index]
        if index > 0 {
            let above = p.blocks[index - 1]
            // From the end of the last line above it that holds anything — the block above's, or a
            // reference definition's between them, which stays (round 2, see `lines(of:upTo:)`).
            var from = NSMaxRange(above.source)
            let aboveLast = p.index.lineNumber(containing: max(above.source.location, NSMaxRange(above.source) - 1))
            var number = p.index.lineNumber(containing: block.source.location) - 1
            while number > aboveLast, let line = p.index.line(number), !holdsText(line, in: p) { number -= 1 }
            if number > aboveLast, let line = p.index.line(number) { from = max(from, line.end) }
            let removed = NSRange(location: from, length: NSMaxRange(block.source) - from)
            let rendered = NSRange(location: NSMaxRange(above.rendered),
                                   length: NSMaxRange(block.rendered) - NSMaxRange(above.rendered))
            if case .apply(var application) = removal(removed, rendered: rendered, blocks: index...index, in: p) {
                if above.quoteDepth == block.quoteDepth, above.indent == block.indent {
                    application.opensParagraphAfter = index - 1
                }
                return .apply(application)
            }
        }
        // Its lines whole — a quote's markers too, or the next block would move into the quote.
        let start = lineStart(block.source.location, in: p)
        guard index + 1 < p.blocks.count else {
            // The only block: the file is left as empty as it looks.
            return removal(NSRange(location: start, length: NSMaxRange(block.source) - start),
                           rendered: block.rendered, blocks: index...index, in: p)
        }
        let next = p.blocks[index + 1]
        return removal(lines(of: block, upTo: next, in: p),
                       rendered: NSRange(location: block.rendered.location,
                                         length: next.rendered.location - block.rendered.location),
                       blocks: index...index, in: p)
    }

    /// Source `range` removed, taking `blocks` with it: checked to render as the old rendering
    /// without `rendered`, **and to leave every other block as it was** — of its kind, at its
    /// indent, in its quote. The characters alone could not tell a list item pulled into the quote
    /// above, when a quote's paragraph went without its `> ` (found 2026-10-09, by the property test).
    private static func removal(_ range: NSRange, rendered: NSRange, blocks: ClosedRange<Int>,
                                in p: MarkdownProjection, also: [PreviewSourceEdit] = []) -> PreviewEditOutcome {
        let expected = (p.renderedString as NSString).replacingCharacters(in: rendered, with: "")
        // One edit where two touch — a removal up to the number it rewrites — so no two edits
        // share an offset, and undoing them is exact.
        let edits = ([PreviewSourceEdit(range: range, text: "")] + also).sorted { $0.range.location < $1.range.location }
            .reduce(into: [PreviewSourceEdit]()) { edits, edit in
                if let last = edits.last, NSMaxRange(last.range) == edit.range.location {
                    edits[edits.count - 1] = PreviewSourceEdit(range: NSUnionRange(last.range, edit.range),
                                                               text: last.text + edit.text)
                } else {
                    edits.append(edit)
                }
            }
        let outcome = verifying(edits, expected: expected, in: p) { after in
            var result = application(edits, undo: .typing, caret: range.location, after: after)
            result.renderedSelection = NSRange(location: rendered.location, length: 0)
            return result
        }
        guard case .apply(let result) = outcome else { return outcome }
        let kept = p.blocks.indices.filter { !blocks.contains($0) }.map { shape(p.blocks[$0]) }
        guard result.projection.blocks.map(shape) == kept else { return .refuse(.unverified, unverified: .movesBlocks) }
        return outcome
    }

    /// What a block is, for telling whether a removal moved it: its kind — an ordered item without
    /// its number, which a removal above it changes — its indent and its quote.
    private static func shape(_ block: PreviewBlock) -> String {
        let kind: String = switch block.kind {
        case .listItem(.ordered): "ordered item"
        default: "\(block.kind)"
        }
        return "\(kind) \(block.indent) \(block.quoteDepth)"
    }

    /// The start of the source line holding `offset`.
    private static func lineStart(_ offset: Int, in p: MarkdownProjection) -> Int {
        p.index.line(p.index.lineNumber(containing: offset))?.start ?? offset
    }

    private static func multilinePaste(_ edit: RenderedEdit, in p: MarkdownProjection) -> PreviewEditOutcome {
        guard edit.action == .paste, edit.range.length == 0,
              let point = PreviewEditRules.insertionPoint(at: edit.range.location, in: p),
              p.blocks[point.block].kind.isCode, point.spans.isEmpty else {
            return .refuse(.notSupported)
        }
        // Each pasted line after the first starts with the block's prefix, in the file's endings.
        let ending = PreviewEditRules.lineEnding
        let prefix = p.blocks[point.block].linePrefix
        let lines = edit.text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let text = lines.map(String.init).joined(separator: ending + prefix)
        let rendered = lines.map(String.init).joined(separator: "\n")
        let expected = (p.renderedString as NSString).replacingCharacters(in: edit.range, with: rendered)
        let edits = [PreviewSourceEdit(range: NSRange(location: point.source, length: 0), text: text)]
        return verifying(edits, expected: expected, in: p) {
            application(edits, undo: .own, caret: point.source + text.utf16.count, after: $0)
        }
    }

    // MARK: Return, ⇧Return, Tab

    private static func returnKey(at range: NSRange, in p: MarkdownProjection) -> PreviewEditOutcome {
        guard range.length == 0 else { return .refuse(.notSupported) }
        let caret = range.location
        guard let blockIndex = PreviewEditRules.block(at: caret, in: p) else { return .refuse(.notText) }
        let block = p.blocks[blockIndex]
        let atEnd = caret == NSMaxRange(block.rendered)
        // After a picture, a rule, HTML, front matter — anything not text — Return at its end opens
        // a paragraph after it, which leaves it alone: a note ending in one could not grow (review,
        // 2026-10-09). So does Return anywhere in a table's last row, which has no row below to move to.
        switch block.kind {
        case .image, .thematicBreak, .html, .frontMatter, .other:
            if atEnd { return .openPhantom(afterBlock: blockIndex) }
        case .table:
            if block.readOnly == nil, cell(from: caret, in: blockIndex, rows: 1, p: p) == nil {
                return .openPhantom(afterBlock: blockIndex)
            }
        default: break
        }
        if let reason = block.readOnly { return .refuse(.readOnly(reason)) }

        switch block.kind {
        case .codeBlock:
            guard let point = PreviewEditRules.insertionPoint(at: caret, in: p) else {
                return .refuse(.notText)
            }
            let text = PreviewEditRules.lineEnding + block.linePrefix
            let edits = [PreviewSourceEdit(range: NSRange(location: point.source, length: 0), text: text)]
            let expected = (p.renderedString as NSString).replacingCharacters(in: range, with: "\n")
            return verifying(edits, expected: expected, in: p) {
                application(edits, undo: .own, caret: point.source + text.utf16.count, after: $0)
            }

        case .table:
            return cell(from: caret, in: blockIndex, rows: 1, p: p).map(PreviewEditOutcome.moveCaret)
                ?? .refuse(.notSupported)

        case .listItem:
            return listReturn(at: caret, block: blockIndex, atEnd: atEnd, in: p)

        case .paragraph, .heading:
            if atEnd { return .openPhantom(afterBlock: blockIndex) }
            guard case .paragraph = block.kind, caret > block.rendered.location,
                  let point = PreviewEditRules.insertionPoint(at: caret, in: p) else {
                return .refuse(.notSupported)
            }
            // Split the paragraph: a blank line, kept inside any quote, then the same prefix.
            let ending = PreviewEditRules.lineEnding
            let prefix = PreviewEditRules.paragraphPrefix(of: blockIndex, in: p)
            let text = ending + PreviewEditRules.blankLine(for: prefix) + ending + prefix
            let expected = (p.renderedString as NSString).replacingCharacters(in: range, with: "\n")
            switch firstVerified(splits(at: point, in: p), expected: expected, in: p, structural: true, {
                [PreviewSourceEdit(range: NSRange(location: $0, length: 0), text: text)]
            }) {
            case .success(let made):
                return .apply(application(made.edits, undo: .own, caret: made.attempt + text.utf16.count,
                                          after: made.after))
            case .failure(let why):
                return .refuse(.unverified, unverified: why)
            }

        default:
            return .refuse(.notSupported)
        }
    }

    /// Return in a list item: TE54's rule, byte for byte what Return does there in Source (C11).
    private static func listReturn(at renderedCaret: Int, block: Int, atEnd: Bool,
                                   in p: MarkdownProjection) -> PreviewEditOutcome {
        guard atEnd else { return .refuse(.notSupported) }
        let ns = p.source as NSString
        // The end of the item's line in the source: after its words, or after its marker when empty.
        // A picture or inline HTML ending the item counts as its words (review, 2026-10-09).
        let words = p.segments.last {
            $0.block == block && ($0.kind == .content || PreviewEditRules.isInlinePiece($0, in: p))
        }
        // Past any span closing on the last words — `- **done**` ends after its `**` (review).
        let wordsEnd = words.map { segment in
            segment.spans.map { NSMaxRange(p.spans[$0].source) }.reduce(NSMaxRange(segment.source), max)
        } ?? NSMaxRange(p.blocks[block].source)
        guard let line = p.index.line(p.index.lineNumber(containing: wordsEnd)) else {
            return .refuse(.notSupported)
        }
        let tail = ns.substring(with: NSRange(location: wordsEnd, length: max(0, line.end - wordsEnd)))
        guard tail.allSatisfy({ $0 == " " || $0 == "\t" }) else { return .refuse(.notSupported) }
        let sourceCaret = line.end
        let ending = PreviewEditRules.lineEnding
        let edits: [PreviewSourceEdit]
        let caret: Int
        switch MarkdownListEdits.returnEdit(in: ns, selection: NSRange(location: sourceCaret, length: 0)) {
        case .continueWith(let opening):
            edits = [PreviewSourceEdit(range: NSRange(location: sourceCaret, length: 0),
                                       text: ending + opening)]
            caret = sourceCaret + (ending + opening).utf16.count
            // **A new item is one more line, empty — or holding a box — and nothing else changes.**
            // At the end of an item with a sub-list under it the opening is the sub-list's, written
            // straight under the item's words, where `  - ` is a setext underline: the words became a
            // heading (found 2026-10-09, by the property test's rendering check; Source's Return
            // writes the same). Refused, rather than written.
            let rendered = p.renderedString as NSString
            let added = ["\n", "\n\u{FFFC}"].map { rendered.replacingCharacters(in: NSRange(location: renderedCaret, length: 0), with: $0) }
            let after = MarkdownProjection.project(applied(edits, to: p.source), style: p.style, after: p)
            guard added.contains(where: { sameComparable(after.renderedString, $0, structural: true) }),
                  after.blocks.count == p.blocks.count + 1,
                  zip(p.blocks, after.blocks).prefix(block + 1).allSatisfy({ $0.kind == $1.kind }) else {
                return .refuse(.unverified, unverified: .renders(differingBy: difference(after.renderedString, added[0])))
            }
            return .apply(application(edits, undo: .own, caret: caret, after: after))
        case .endList(let line, let indent, let separatesNext):
            // As `carryOnList` does it in Source, in one step: the empty item's line emptied, the
            // Return, the item's own indent in a sub-list, and — when a written line follows — a
            // second break after the caret, which stays on the line to type on. The one difference
            // is deliberate: the file's own line ending (C31), where Source's `insertNewline`
            // always writes `\n`.
            let text = ending + indent + (separatesNext ? ending : "")
            edits = [PreviewSourceEdit(range: line, text: text)]
            caret = line.location + (ending + indent).utf16.count
        case nil:
            return .refuse(.notSupported)
        }
        // Ending a list is not checked against an expected rendering: the empty item goes, and
        // what the line it leaves becomes is TE54's rule, verified by the parser itself.
        let source = applied(edits, to: p.source)
        return .apply(application(edits, undo: .own, caret: caret,
                                  after: MarkdownProjection.project(source, style: p.style, after: p)))
    }

    /// ⇧Return: a hard line break, written as two trailing spaces and a newline (decision U) — the
    /// form that keeps the parser's line count right. Never the backslash form (§2.1, case 2).
    ///
    /// **At a paragraph's end it is not written yet**, because Markdown ignores a hard break with
    /// nothing after it: the session holds it in the display, as it holds a trailing space, and
    /// hands it back with the next character typed — `typed` — which writes both.
    ///
    /// Spaces after the caret would start the new line, where they render as nothing: they go.
    ///
    /// **What is typed after it is one line, in the styles chosen for it** (round 2, 2026-10-10): a
    /// second line break in it was written as itself, a U+2028 the preview draws as a line and
    /// Markdown reads as none; and ⌘B before the character that writes the break was lost.
    private static func lineBreak(at range: NSRange, typing typed: String = "", pending: PreviewPendingStyle = [],
                                  in p: MarkdownProjection) -> PreviewEditOutcome {
        guard range.length == 0, !typed.contains(where: \.isNewline),
              let point = PreviewEditRules.insertionPoint(at: range.location, in: p) else {
            return .refuse(.notSupported)
        }
        switch p.blocks[point.block].kind {
        case .paragraph, .listItem: break
        default: return .refuse(.notSupported)
        }
        let units = p.index.units
        let prefix = "  " + PreviewEditRules.lineEnding + PreviewEditRules.continuationPrefix(of: point.block, in: p)
        let expected = (p.renderedString as NSString).replacingCharacters(in: range, with: "\u{2028}" + typed)
        // The styles the typed text is to have: the caret's, with the pending ones toggled. A split
        // inside a span keeps it open for the new line; one after it does not — so each split adds
        // what it lacks, and the style is checked.
        let inCode = point.spans.contains { p.spans[$0].kind == .code }
        let pending = typed.isEmpty || inCode ? [] : pending
        let wanted = style(of: point.spans, in: p).symmetricDifference(pending)
        let attempts = splits(at: point, in: p).flatMap { split in escapeAttempts(typed).map { (split, $0) } }
        let found = firstVerified(attempts, expected: expected, in: p, structural: true) { split, typed in
            var end = split
            while end < units.count, units[end] == 0x20 { end += 1 }
            let open = style(of: point.spans.filter { NSMaxRange(p.spans[$0].source) > split }, in: p)
            let (opening, closing) = pending.isEmpty ? ("", "") : delimiters(for: wanted.subtracting(open))
            return [PreviewSourceEdit(range: NSRange(location: split, length: end - split),
                                      text: prefix + opening + typed + closing)]
        } accepting: { _, after in
            pending.isEmpty || style(at: range.location + 1, in: after) == wanted
        }
        switch found {
        case .success(let made):
            return .apply(application(made.edits, undo: typed.isEmpty ? .own : .typing,
                                      caret: made.attempt.0 + made.edits[0].text.utf16.count, after: made.after))
        case .failure(let why):
            return .refuse(.unverified, unverified: why)
        }
    }

    /// Where a break at `point` can go: inside the spans the caret is in first; failing that,
    /// after each span that closes there — a Return or ⇧Return just after bold breaks after its
    /// `**`, not between them (review: `**Note  \n  ** text` was refused).
    private static func splits(at point: PreviewEditRules.InsertionPoint, in p: MarkdownProjection) -> [Int] {
        [point.source] + point.spans.reversed().map { NSMaxRange(p.spans[$0].source) }
    }

    private static func tab(at range: NSRange, outdent: Bool, in p: MarkdownProjection) -> PreviewEditOutcome {
        let range = withoutTrailingBlockBreak(range, in: p)
        guard let blockIndex = PreviewEditRules.block(at: range.location, in: p) else { return .ignore }
        let block = p.blocks[blockIndex]
        guard block.readOnly == nil else { return .ignore }
        switch block.kind {
        case .listItem:
            // Over several items, nothing: TE54 moves one item, and Source's Tab replaces such a
            // selection with a tab — moving only the first was half the edit (review, 2026-10-09).
            if NSMaxRange(range) > NSMaxRange(block.rendered) { return .refuse(.crossesBlocks) }
            // The whole item moves, by TE54's rule, from anywhere on its line.
            let caretSource = PreviewEditRules.insertionPoint(at: range.location, in: p)?.source
                ?? NSMaxRange(block.source)
            switch MarkdownListEdits.tabEdit(in: p.source as NSString,
                                             selection: NSRange(location: caretSource, length: 0),
                                             outdent: outdent) {
            case .rewrite(let rewritten, let text, let selection):
                let edits = [PreviewSourceEdit(range: rewritten, text: text)]
                let source = applied(edits, to: p.source)
                return .apply(application(edits, undo: .own, caret: selection.location,
                                          after: MarkdownProjection.project(source, style: p.style, after: p)))
            case .unchanged, nil:
                return .ignore
            }
        case .table:
            guard range.length == 0 else { return .ignore }
            return cell(from: range.location, in: blockIndex, columns: outdent ? -1 : 1, p: p)
                .map(PreviewEditOutcome.moveCaret) ?? .ignore
        case .codeBlock:
            guard !outdent else { return .ignore }
            return translate(RenderedEdit(range: range, text: "\t", action: .typing), in: p)
        default:
            return .ignore
        }
    }

    /// The caret `rows` down or `columns` across from `caret` in a table, at the end of that cell's
    /// text; across the end of a row it wraps to the next row's first cell. `nil` off the table.
    private static func cell(from caret: Int, in block: Int, rows: Int = 0, columns: Int = 0,
                             p: MarkdownProjection) -> Int? {
        let range = p.blocks[block].rendered
        let text = (p.renderedString as NSString).substring(with: range)
        let grid = text.components(separatedBy: "\n").map { $0.components(separatedBy: "\t") }
        // Where the caret is.
        var offset = range.location
        var at: (row: Int, column: Int)?
        rowLoop: for (r, cells) in grid.enumerated() {
            for (c, cell) in cells.enumerated() {
                let length = (cell as NSString).length
                if caret >= offset, caret <= offset + length { at = (r, c); break rowLoop }
                offset += length + 1
            }
        }
        guard var target = at else { return nil }
        target.row += rows
        target.column += columns
        if target.column >= grid[min(target.row, grid.count - 1)].count { target.row += 1; target.column = 0 }
        if target.column < 0 {
            target.row -= 1
            guard target.row >= 0 else { return nil }
            target.column = grid[target.row].count - 1
        }
        guard target.row >= 0, target.row < grid.count, target.column < grid[target.row].count else {
            return nil
        }
        var end = range.location
        for r in 0..<target.row { end += (grid[r].joined(separator: "\t") as NSString).length + 1 }
        for c in 0...target.column { end += (grid[target.row][c] as NSString).length + (c > 0 ? 1 : 0) }
        return end
    }

    // MARK: Formatting

    private static func format(_ verb: MarkupVerb, over range: NSRange, in p: MarkdownProjection,
                               context: PreviewEditContext) -> PreviewEditOutcome {
        let inline: PreviewPendingStyle? = switch verb {
        case .bold: .bold
        case .italic: .italic
        case .strikethrough: .strikethrough
        case .inlineCode: .code
        default: nil
        }
        if range.length == 0, let inline {
            // A4: nothing selected — light the style for what is typed next, write nothing.
            return .setPending(context.pending.symmetricDifference(inline))
        }
        // A line verb on the empty paragraph Return opened (§3.5): the paragraph is not in the file
        // yet, so write the blank line it stands for and let the verb start its list, heading or
        // quote there — never on the block above, which is where its caret maps in the source.
        let lineVerb: Bool = switch verb {
        case .heading, .bulletList, .numberedList, .taskItem, .blockQuote: true
        default: false
        }
        var base = p.source
        var selection: NSRange
        var opened: Int?
        if lineVerb, let phantom = context.phantomAfterBlock, p.blocks.indices.contains(phantom) {
            opened = phantom
            let opening = phantomOpening(after: phantom, in: p)
            base = (p.source as NSString).replacingCharacters(in: NSRange(location: opening.at, length: 0),
                                                              with: opening.before + opening.after)
            selection = NSRange(location: opening.at + opening.before.utf16.count, length: 0)
        } else {
            // A triple-click's line break is the next block's: the paragraph is what was meant.
            let range = withoutTrailingBlockBreak(range, in: p)
            guard let mapped = sourceSelection(for: range, in: p) ?? (lineVerb ? acrossBlocks(range, in: p) : nil)
            else {
                let blocks = p.blocks.filter { NSIntersectionRange($0.rendered, range).length > 0 }
                return .refuse(blocks.count > 1 ? .crossesBlocks : .notText)
            }
            selection = mapped
        }
        guard let edit = MarkdownEdits.apply(verb, to: base, selection: selection) else {
            return .refuse(.notSupported)
        }
        let change = MarkdownEdits.minimalReplacement(from: p.source, to: edit.text)
        let edits = [PreviewSourceEdit(range: change.range, text: change.text)]
        let after: MarkdownProjection
        if inline != nil {
            // An inline verb changes styling, never characters: the rendering must read the same.
            switch check(edits, expected: p.renderedString, in: p) {
            case .success(let checked): after = checked
            case .failure(let why): return .refuse(.unverified, unverified: why)
            }
        } else {
            after = MarkdownProjection.project(edit.text, style: p.style, after: p)
            // **On an opened paragraph, checked: one new block, there, and nothing else changed**
            // (round 2, 2026-10-10). Opened after HTML that runs on — `<pre>` to its `</pre>` — the
            // heading went into the HTML and was written all the same.
            if let opened, !opensOneBlock(after: opened, from: p, to: after) {
                return .refuse(.unverified, unverified: .movesBlocks)
            }
        }
        let start = PreviewEditRules.renderedOffset(forSource: edit.selection.location, in: after)
        let end = PreviewEditRules.renderedOffset(forSource: NSMaxRange(edit.selection), in: after)
        return .apply(PreviewEditApplication(edits: edits, undo: .own, source: edit.text,
                                             projection: after, sourceSelection: edit.selection,
                                             renderedSelection: NSRange(location: start,
                                                                        length: max(0, end - start))))
    }

    /// Whether `after` is `p` with one new block straight after block `block`, editable, and every
    /// other block — and everything else on screen — as it was.
    private static func opensOneBlock(after block: Int, from p: MarkdownProjection, to after: MarkdownProjection) -> Bool {
        let new = block + 1
        guard after.blocks.count == p.blocks.count + 1, after.blocks[new].readOnly == nil,
              after.blocks.indices.filter({ $0 != new }).map({ shape(after.blocks[$0]) }) == p.blocks.map(shape),
              readOnlyPieces(after).isSubset(of: readOnlyPieces(p)) else { return false }
        // Without the new block and the break before it, the rendering is the old one.
        let from = NSMaxRange(after.blocks[block].rendered)
        let rest = (after.renderedString as NSString).replacingCharacters(
            in: NSRange(location: from, length: NSMaxRange(after.blocks[new].rendered) - from), with: "")
        return rest == p.renderedString
    }

    /// A selection reaching over several blocks, for the line verbs — Bullets over three paragraphs
    /// makes three items (review: refused). From the first character's place to the last's, none of
    /// the blocks it crosses read-only.
    private static func acrossBlocks(_ range: NSRange, in p: MarkdownProjection) -> NSRange? {
        guard range.length > 0 else { return nil }
        let crossed = p.blocks.filter { NSIntersectionRange($0.rendered, range).length > 0 }
        guard !crossed.isEmpty, crossed.allSatisfy({ $0.readOnly == nil }),
              let first = p.segments.first(where: { $0.kind == .content && NSMaxRange($0.rendered) > range.location }),
              let last = p.segments.last(where: { $0.kind == .content && $0.rendered.location < NSMaxRange(range) }),
              let start = first.sourceOffset(forRenderedBoundary: max(0, range.location - first.rendered.location)),
              let end = last.sourceOffset(forRenderedBoundary: min(last.rendered.length,
                                                                   NSMaxRange(range) - last.rendered.location)),
              end >= start else { return nil }
        return NSRange(location: start, length: end - start)
    }

    /// **The source selection Preview reports for a rendered one** (FMT-14) — the one a verb would
    /// act on: as ``sourceSelection(for:in:)`` maps it, else with a triple-click's trailing block
    /// break left out, else — over several blocks — from the first selected character's place to
    /// the last's. A triple-click selects a paragraph AND the break after it, which maps to no
    /// single block, so it was never reported: the format bar kept the last caret's lit state, dark
    /// over a bold paragraph whose Bold press then took the bold off.
    static func reportedSelection(for range: NSRange, in p: MarkdownProjection) -> NSRange? {
        if let exact = sourceSelection(for: range, in: p) { return exact }
        let trimmed = withoutTrailingBlockBreak(range, in: p)
        if trimmed != range, let mapped = sourceSelection(for: trimmed, in: p) { return mapped }
        return acrossBlocks(range, in: p)
    }

    /// A rendered selection as a source selection, for the verbs (§3.6): its start where the first
    /// selected character is, its end after the last — so a selection of exactly a bold word maps to
    /// the word between its asterisks, which is what makes ⌘B there take the bold off.
    static func sourceSelection(for range: NSRange, in p: MarkdownProjection) -> NSRange? {
        if range.length == 0 {
            return PreviewEditRules.insertionPoint(at: range.location, in: p)
                .map { NSRange(location: $0.source, length: 0) }
        }
        guard let first = p.segments.first(where: {
                  $0.kind == .content && $0.rendered.location <= range.location
                      && range.location < NSMaxRange($0.rendered) }),
              let last = p.segments.first(where: {
                  $0.kind == .content && $0.rendered.location < NSMaxRange(range)
                      && NSMaxRange(range) <= NSMaxRange($0.rendered) }),
              first.block == last.block, p.blocks[first.block].readOnly == nil,
              let start = first.sourceOffset(forRenderedBoundary: range.location - first.rendered.location),
              let end = last.sourceOffset(forRenderedBoundary: NSMaxRange(range) - last.rendered.location),
              end >= start
        else { return nil }
        return NSRange(location: start, length: end - start)
    }

    // MARK: Tasks and phantoms

    /// A8: the box's three characters, ticked or unticked — now an undo step of its own (F6).
    private static func tickTask(at range: NSRange, in p: MarkdownProjection) -> PreviewEditOutcome {
        guard let box = p.segments.first(where: {
                  $0.kind == .decoration && $0.rendered == range && $0.source.length == 3 }),
              case .listItem(.task(let done)) = p.blocks[box.block].kind else { return .refuse(.notText) }
        let edits = [PreviewSourceEdit(range: box.source, text: done ? "[ ]" : "[x]")]
        let source = applied(edits, to: p.source)
        let after = MarkdownProjection.project(source, style: p.style, after: p)
        guard after.blocks.indices.contains(box.block),
              after.blocks[box.block].kind == .listItem(marker: .task(done: !done)) else {
            return .refuse(.unverified)
        }
        return .apply(application(edits, undo: .own, caret: box.source.location, after: after))
    }

    /// The first character typed into a phantom paragraph writes it: a blank line, the prefix that
    /// keeps it in the same quote, and the character (§3.5). Until then the file is untouched (C9).
    ///
    /// **In the styles chosen for it** — Return, ⌘B, typing is bold (review, 2026-10-09: the bold
    /// text went on the end of the paragraph above). **And kept apart from what follows**: when the
    /// next line holds text, a blank line goes after the character too — `# Title` straight over
    /// `Some text` took the new paragraph into that one (review, 2026-10-09).
    private static func phantomParagraph(after block: Int, typing text: String, pending: PreviewPendingStyle,
                                         in p: MarkdownProjection) -> PreviewEditOutcome {
        guard p.blocks.indices.contains(block) else { return .refuse(.notSupported) }
        guard !text.contains(where: \.isNewline) else { return .refuse(.notSupported) }
        let opening = phantomOpening(after: block, in: p)
        let rendered = NSMaxRange(p.blocks[block].rendered)
        let expected = (p.renderedString as NSString)
            .replacingCharacters(in: NSRange(location: rendered, length: 0), with: "\n" + text)
        let (open, close) = delimiters(for: pending)
        let found = firstVerified(escapeAttempts(text), expected: expected, in: p) { typed in
            [PreviewSourceEdit(range: NSRange(location: opening.at, length: 0),
                               text: opening.before + open + typed + close + opening.after)]
        } accepting: { _, after in
            styleAt(rendered + 1, in: after) == kinds(for: pending)
        }
        switch found {
        case .success(let made):
            let caret = opening.at + (opening.before + open + made.attempt).utf16.count
            return .apply(application(made.edits, undo: .typing, caret: caret, after: made.after))
        case .failure(let why):
            return .refuse(.unverified, unverified: why)
        }
    }

    /// What opens a paragraph after block `block` in the source: where, what goes before its first
    /// character — a line break, a blank line kept inside any quote, the quote's prefix — and what
    /// goes after, which is a second blank line when the next line holds text, or nothing.
    private static func phantomOpening(after block: Int, in p: MarkdownProjection)
        -> (at: Int, before: String, after: String) {
        let end = NSMaxRange(p.blocks[block].source)
        let ending = PreviewEditRules.lineEnding
        let prefix = PreviewEditRules.paragraphPrefix(of: block, in: p)
        let blank = PreviewEditRules.blankLine(for: prefix)
        let after = PreviewEditRules.nextLineHoldsText(after: end, in: p) ? ending + blank : ""
        return (end, ending + blank + ending + prefix, after)
    }

    /// The first characters of an empty file — or of one that is only blank lines.
    private static func emptyDocument(typing text: String, in p: MarkdownProjection) -> PreviewEditOutcome {
        let end = p.index.length
        let found = firstVerified(escapeAttempts(text), expected: text, in: p) { typed in
            [PreviewSourceEdit(range: NSRange(location: end, length: 0), text: typed)]
        }
        switch found {
        case .success(let made):
            return .apply(application(made.edits, undo: .typing, caret: end + made.attempt.utf16.count,
                                      after: made.after))
        case .failure(let why):
            return .refuse(.unverified, unverified: why)
        }
    }

    // MARK: Verification

    /// The edits applied and re-projected, when the new rendering is `expected`; otherwise `nil`.
    static func verified(_ edits: [PreviewSourceEdit], expected: String, in p: MarkdownProjection,
                         structural: Bool = false) -> MarkdownProjection? {
        try? check(edits, expected: expected, in: p, structural: structural).get()
    }

    /// Why an edit was not verified, for the log — never what it said.
    enum Unverified: Error, Equatable {
        /// The new rendering was not what was expected, over this many characters.
        case renders(differingBy: Int)
        /// It read right, and made something Preview cannot edit.
        case makesReadOnly
        /// It read right, and moved or changed a block it should have left alone.
        case movesBlocks
        /// It read right, and the typed text was not in the style it was typed in.
        case wrongStyle

        /// What the log says.
        var detail: String {
            switch self {
            case .renders(let count): "rendering off by \(count)"
            case .makesReadOnly: "would make text read-only"
            case .movesBlocks: "would move the blocks around it"
            case .wrongStyle: "typed text would take another style"
            }
        }
    }

    /// The edits applied and re-projected, and the projection when the new rendering is `expected`.
    ///
    /// **Compared through the parser's smart punctuation** (`'` and ’, `--` and –), because a
    /// typed straight quote renders curly and that is the file being right, not wrong.
    /// `structural` also forgives whitespace beside a new line or break, which the parser trims.
    static func check(_ edits: [PreviewSourceEdit], expected: String, in p: MarkdownProjection,
                      structural: Bool = false) -> Result<MarkdownProjection, Unverified> {
        let after = MarkdownProjection.project(applied(edits, to: p.source), style: p.style, after: p)
        guard sameComparable(after.renderedString, expected, structural: structural) else {
            return .failure(.renders(differingBy: difference(after.renderedString, expected)))
        }
        // An edit that renders right but leaves the projection unable to map a block it could map
        // before would strand the caret — and every keystroke after it — so it is refused too.
        //
        // **And so is one that renders right but MEANS something else** — typed text that the
        // parser took for HTML (`Vec<T` + `>` is a tag, and dropped by every other renderer), or a
        // table pushed too wide to edit. Each shows up as a read-only piece the source did not have
        // (review, 2026-10-05); the escaped retry is what gets written instead. **Which pieces, not
        // how many**: a paste that turned one tag into text and its own `<i>` into a tag kept the
        // count, and was written (review, 2026-10-09).
        guard readOnlyPieces(after).isSubset(of: readOnlyPieces(p)) else { return .failure(.makesReadOnly) }
        return .success(after)
    }

    /// Every piece of `q` Preview cannot edit — read-only blocks and segments — by what it is and
    /// what it says, counted: an edit never touches one, so after it each is one that was there.
    static func readOnlyPieces(_ q: MarkdownProjection) -> PreviewPieceCount {
        if let known = q.memo.readOnlyPieces { return known }
        let units = q.index.units
        var pieces = PreviewPieceCount()
        for block in q.blocks { if let reason = block.readOnly { pieces.add(reason, block.source, of: units) } }
        for segment in q.segments {
            if case .readOnly(let reason) = segment.kind { pieces.add(reason, segment.source, of: units) }
        }
        q.memo.readOnlyPieces = pieces
        return pieces
    }

    /// How many UTF-16 units lie between what `a` and `b` share at their two ends.
    private static func difference(_ a: String, _ b: String) -> Int {
        let x = Array(a.utf16), y = Array(b.utf16)
        var prefix = 0
        while prefix < min(x.count, y.count), x[prefix] == y[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(x.count, y.count) - prefix, x[x.count - 1 - suffix] == y[y.count - 1 - suffix] { suffix += 1 }
        return max(x.count, y.count) - prefix - suffix
    }

    /// The first of `attempts` whose edits verify — and, when `accepting` is given, are accepted
    /// by it — with the attempt and its edits; otherwise why the last did not.
    ///
    /// The attempts are what is typed, bare and then escaped (§3.4), and where a break goes: one
    /// loop, for each place something is written — typing, the opened paragraph, an empty file,
    /// Return and ⇧Return.
    private static func firstVerified<Attempt>(_ attempts: [Attempt], expected: String, in p: MarkdownProjection,
                                               structural: Bool = false,
                                               _ edits: (Attempt) -> [PreviewSourceEdit],
                                               accepting: (Attempt, MarkdownProjection) -> Bool = { _, _ in true })
        -> Result<(attempt: Attempt, edits: [PreviewSourceEdit], after: MarkdownProjection), Unverified> {
        var failure = Unverified.renders(differingBy: 0)
        for attempt in attempts {
            let made = edits(attempt)
            switch check(made, expected: expected, in: p, structural: structural) {
            case .success(let after) where accepting(attempt, after):
                return .success((attempt, made, after))
            case .success:
                failure = .wrongStyle
            case .failure(let why):
                failure = why
            }
        }
        return .failure(failure)
    }

    /// The application `make` builds, once `edits` are checked to render as `expected` — or the
    /// refusal that says why not. `line` is the caller's, for the log.
    private static func verifying(_ edits: [PreviewSourceEdit], expected: String, in p: MarkdownProjection,
                                  structural: Bool = false, line: Int = #line,
                                  _ make: (MarkdownProjection) -> PreviewEditApplication) -> PreviewEditOutcome {
        switch check(edits, expected: expected, in: p, structural: structural) {
        case .success(let after): return .apply(make(after))
        case .failure(let why): return .refuse(.unverified, line: line, unverified: why)
        }
    }

    /// `comparable(a) == comparable(b)`, without making either of a long note's two copies: the
    /// part they share as written is the same either way, so only what lies between is compared.
    ///
    /// Cut where two ASCII letters or digits meet — always a character boundary, and never beside
    /// the spaces and breaks `structural` trims, or inside a `--` or `...` the parser joined.
    static func sameComparable(_ a: String, _ b: String, structural: Bool) -> Bool {
        let x = a as NSString, y = b as NSString
        if x.isEqual(to: b) { return true }
        let left = MarkdownSourceIndex.units(of: x), right = MarkdownSourceIndex.units(of: y)
        let shorter = min(left.count, right.count)
        var prefix = 0
        while prefix < shorter, left[prefix] == right[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < shorter - prefix, left[left.count - 1 - suffix] == right[right.count - 1 - suffix] { suffix += 1 }
        func plain(_ unit: UInt16) -> Bool {
            (0x30...0x39).contains(unit) || (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit)
        }
        // A cut is a boundary in both strings: the units either side of it are plain in each.
        func cuts(_ units: [unichar], at offset: Int) -> Bool {
            offset > 0 && offset < units.count && plain(units[offset - 1]) && plain(units[offset])
        }
        while prefix > 0, !(cuts(left, at: prefix) && cuts(right, at: prefix)) { prefix -= 1 }
        while suffix > 0, !(cuts(left, at: left.count - suffix) && cuts(right, at: right.count - suffix)) { suffix -= 1 }
        let middle = { (s: NSString, count: Int) in
            s.substring(with: NSRange(location: prefix, length: count - prefix - suffix))
        }
        return comparable(middle(x, left.count), structural: structural)
            == comparable(middle(y, right.count), structural: structural)
    }

    static func comparable(_ text: String, structural: Bool) -> String {
        var out = ""
        for character in text {
            switch character {
            case "’", "‘": out.append("'")
            case "“", "”": out.append("\"")
            case "–": out.append("--")
            case "—": out.append("---")
            case "…": out.append("...")
            default: out.append(character)
            }
        }
        guard structural else { return out }
        var trimmed = ""
        for character in out {
            if character == "\n" || character == "\u{2028}" {
                while trimmed.last == " " || trimmed.last == "\t" { trimmed.removeLast() }
            }
            if character == " " || character == "\t",
               trimmed.last == "\n" || trimmed.last == "\u{2028}" { continue }
            trimmed.append(character)
        }
        return trimmed
    }

    /// The inline styles at rendered `offset` in `p`, outermost first.
    private static func styleAt(_ offset: Int, in p: MarkdownProjection) -> [PreviewInlineSpan.Kind] {
        guard let segment = p.segments.first(where: {
            $0.kind == .content && $0.rendered.location <= offset && offset < NSMaxRange($0.rendered)
        }) else { return [] }
        return segment.spans.map { normalizedKind(p.spans[$0].kind) }
    }

    /// The pending styles of the text at rendered `offset` in `p` — ``style(of:in:)`` of its spans.
    private static func style(at offset: Int, in p: MarkdownProjection) -> PreviewPendingStyle {
        guard let segment = p.segments.first(where: {
            $0.kind == .content && $0.rendered.location <= offset && offset < NSMaxRange($0.rendered)
        }) else { return [] }
        return style(of: segment.spans, in: p)
    }

    /// A link compared by being a link: typing next to one never changes where it goes.
    private static func normalizedKind(_ kind: PreviewInlineSpan.Kind) -> PreviewInlineSpan.Kind {
        if case .link = kind { return .link(destination: nil) }
        return kind
    }

    // MARK: Building blocks

    /// What is tried for typed `text`, in turn: as typed; with only what can START Markdown
    /// inline escaped — the emphasis, code, link, HTML and table characters; and with every ASCII
    /// punctuation character escaped, the escape that always renders as the character itself, for
    /// what only means something at a line's start (`#`, `-`, `1.`). One `*` in a pasted sentence
    /// escaped its every `'`, `,` and `.` too — `Don\'t` stays straight where the note shows curly
    /// quotes (review, 2026-10-09).
    static func escapeAttempts(_ text: String) -> [String] {
        guard !text.isEmpty else { return [text] }
        var attempts = [text]
        for escaped in [escaped(text, only: inlineMarkup), escaped(text)] where !attempts.contains(escaped) {
            attempts.append(escaped)
        }
        return attempts
    }

    /// The characters that open or close inline Markdown anywhere on a line.
    private static let inlineMarkup = Set<Character>(["\\", "`", "*", "_", "[", "]", "<", ">", "&", "~", "|", "!"])

    /// Every ASCII punctuation character in `text` — or only those in `only` — backslash-escaped:
    /// CommonMark's escape, which renders as the character itself in prose and in a table cell.
    static func escaped(_ text: String, only: Set<Character>? = nil) -> String {
        var out = ""
        for character in text {
            if let ascii = character.asciiValue, (0x21...0x2F).contains(ascii) || (0x3A...0x40).contains(ascii)
                || (0x5B...0x60).contains(ascii) || (0x7B...0x7E).contains(ascii),
               only?.contains(character) ?? true {
                out.append("\\")
            }
            out.append(character)
        }
        return out
    }

    private static func delimiters(for pending: PreviewPendingStyle) -> (String, String) {
        var open = ""
        if pending.contains(.strikethrough) { open += "~~" }
        if pending.contains(.bold) { open += "**" }
        if pending.contains(.italic) { open += "*" }
        if pending.contains(.code) { open += "`" }
        return (open, String(open.reversed()))
    }

    private static func kinds(for pending: PreviewPendingStyle) -> [PreviewInlineSpan.Kind] {
        var kinds: [PreviewInlineSpan.Kind] = []
        if pending.contains(.strikethrough) { kinds.append(.strikethrough) }
        if pending.contains(.bold) { kinds.append(.strong) }
        if pending.contains(.italic) { kinds.append(.emphasis) }
        if pending.contains(.code) { kinds.append(.code) }
        return kinds
    }

    /// The removals, with the insertion folded into the one starting where it goes.
    private static func merged(removals: [NSRange], insertion: String, at offset: Int) -> [PreviewSourceEdit] {
        var edits = removals.map { PreviewSourceEdit(range: $0, text: "") }
        if let index = edits.firstIndex(where: { $0.range.location == offset }) {
            edits[index].text = insertion
        } else if !insertion.isEmpty {
            edits.append(PreviewSourceEdit(range: NSRange(location: offset, length: 0), text: insertion))
        }
        return edits.sorted { $0.range.location < $1.range.location }
    }

    private static func union(_ ranges: [NSRange]) -> [NSRange] {
        var out: [NSRange] = []
        for range in ranges.sorted(by: { $0.location < $1.location }) {
            if let last = out.last, range.location <= NSMaxRange(last) {
                out[out.count - 1] = NSUnionRange(last, range)
            } else {
                out.append(range)
            }
        }
        return out
    }

    static func applied(_ edits: [PreviewSourceEdit], to source: String) -> String {
        edits.sorted { $0.range.location > $1.range.location }
            .reduce(source as NSString) { $0.replacingCharacters(in: $1.range, with: $1.text) as NSString }
            as String
    }

    /// The caret in the new source: after the typed text, before any closing delimiters.
    private static func sourceCaret(after edits: [PreviewSourceEdit], insertionAt offset: Int,
                                    typedLength: Int) -> Int {
        // Edits before the insertion point move it.
        let shift = edits.filter { NSMaxRange($0.range) <= offset && $0.range.location < offset }
            .reduce(0) { $0 + $1.text.utf16.count - $1.range.length }
        return offset + shift + typedLength
    }

    private static func application(_ edits: [PreviewSourceEdit], undo: PreviewUndoStep, caret: Int,
                                    after: MarkdownProjection) -> PreviewEditApplication {
        let rendered = PreviewEditRules.renderedOffset(forSource: caret, in: after)
        return PreviewEditApplication(edits: edits, undo: undo, source: after.source, projection: after,
                                      sourceSelection: NSRange(location: caret, length: 0),
                                      renderedSelection: NSRange(location: rendered, length: 0))
    }

    /// Why nothing can be typed at `caret`.
    private static func refusalAt(_ caret: Int, in p: MarkdownProjection) -> PreviewRefusal {
        if let block = PreviewEditRules.block(at: caret, in: p), let reason = p.blocks[block].readOnly {
            return .readOnly(reason)
        }
        if let found = PreviewEditRules.segment(containing: caret, in: p), case .readOnly(let reason) = found.kind {
            return .readOnly(reason)
        }
        return .notText
    }
}

extension PreviewBlock.Kind {
    var isCode: Bool { if case .codeBlock = self { true } else { false } }
}

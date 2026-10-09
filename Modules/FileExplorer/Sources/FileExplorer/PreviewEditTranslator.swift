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
    case refuse(PreviewRefusal)
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
                return phantomParagraph(after: phantom, typing: edit.text, in: p)
            }
            return text(edit, in: p, context: context)
        case .returnKey: return returnKey(at: edit.range, in: p)
        case .lineBreak: return lineBreak(at: edit.range, in: p)
        case .tab, .backtab: return tab(at: edit.range, outdent: edit.action == .backtab, in: p)
        case .format(let verb): return format(verb, over: edit.range, in: p, context: context)
        case .tickTask: return tickTask(at: edit.range, in: p)
        }
    }

    /// Replace All (A11): every match or none, one undo step.
    static func translateAll(_ edits: [RenderedEdit], in p: MarkdownProjection) -> PreviewEditOutcome {
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
        let expected = edits.sorted { $0.range.location > $1.range.location }
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
        if tidied != after.source {
            let realigned = MarkdownProjection.project(tidied, style: p.style, after: p)
            if realigned.renderedString == after.renderedString {
                let change = MarkdownEdits.minimalReplacement(from: p.source, to: tidied)
                source = [PreviewSourceEdit(range: change.range, text: change.text)]
                after = realigned
            }
        }
        return .apply(PreviewEditApplication(edits: source, undo: .own, source: after.source,
                                             projection: after,
                                             sourceSelection: NSRange(location: 0, length: 0),
                                             renderedSelection: NSRange(location: 0, length: 0)))
    }

    // MARK: Text

    private static func text(_ edit: RenderedEdit, in p: MarkdownProjection,
                             context: PreviewEditContext) -> PreviewEditOutcome {
        var edit = edit
        // One line copied with its line break is one line: the break is not a paragraph's worth.
        if edit.action == .paste, edit.text.hasSuffix("\n"),
           !edit.text.dropLast().contains(where: { $0.isNewline }) {
            edit.text.removeLast()
        }
        // A deletion that would leave spaces at a line's end takes them too: Markdown draws them as
        // nothing, so they could never be what the rendering shows — "hello w" ⌫ was refused (review).
        if edit.text.isEmpty, edit.range.length > 0 {
            let rendered = p.renderedString as NSString
            let end = NSMaxRange(edit.range)
            if end == rendered.length || rendered.character(at: end) == 0x0A {
                var start = edit.range.location
                while start > 0, rendered.character(at: start - 1) == 0x20 { start -= 1 }
                edit.range = NSRange(location: start, length: end - start)
            }
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
            if !edit.text.isEmpty, segment(at: edit.range.location, in: p)?.kind != .content {
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
        let attempts = inCode || edit.text.isEmpty ? [edit.text] : [edit.text, escaped(edit.text)]
        for typed in attempts {
            let (open, close) = delimiters(for: pending)
            let inserted = typed.isEmpty ? "" : linePrefix + open + typed + close
            let edits = merged(removals: removals, insertion: inserted, at: point.source)
            guard let after = verified(edits, expected: expected, in: p) else { continue }
            if !typed.isEmpty {
                let wanted = point.spans.map { p.spans[$0].kind } + kinds(for: pending)
                let at = edit.range.location
                guard styleAt(at, in: after) == wanted.map(normalizedKind) else { continue }
            }
            // A deletion leaves the caret where it started — before any markers it took with it.
            let caret = typed.isEmpty
                ? (edits.first?.range.location ?? point.source)
                : sourceCaret(after: edits, insertionAt: point.source,
                              typedLength: (linePrefix + open + typed).utf16.count)
            var result = application(edits, undo: undo, caret: caret, after: after)
            // When the rendering is exactly the old one with the edit made, the caret's place in it
            // is known without mapping: after what was typed. Mapping is the fallback for when the
            // parser's smart punctuation changed the length — a separator's source runs on through
            // the next text's opening markers, so a caret there cannot say which side it is on.
            if after.renderedString == expected {
                let rendered = edit.range.location + (edit.text as NSString).length
                result.renderedSelection = NSRange(location: rendered, length: 0)
            }
            return .apply((context.realignsTables ? realigned(result, typedInto: point, in: p) : nil) ?? result)
        }
        return .refuse(.unverified)
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
              tidy.text != result.source else { return nil }
        let after = MarkdownProjection.project(tidy.text, style: p.style, after: p)
        guard after.renderedString == result.projection.renderedString else { return nil }
        let change = MarkdownEdits.minimalReplacement(from: p.source, to: tidy.text)
        return PreviewEditApplication(edits: [PreviewSourceEdit(range: change.range, text: change.text)],
                                      undo: result.undo, source: tidy.text, projection: after,
                                      sourceSelection: tidy.selection, renderedSelection: result.renderedSelection)
    }

    /// **Which tables decision T re-pads:** those whose pipes line up AND are written padded —
    /// `| a | b |`, the way Format Table writes them. A compact `|a|b|` or a pipe-less `a | b` can
    /// line up too, but re-padding would rewrite the author's style on the first keystroke
    /// (review, 2026-10-05); those keep it, as a ragged table does.
    static func realignsAsYouType(_ source: String, table range: NSRange) -> Bool {
        guard MarkdownTables.isAligned(source: source, table: range),
              let header = MarkdownTables.lines(of: source as NSString, in: range).lines.first else { return false }
        return header.drop(while: { $0 == " " || $0 == "\t" }).hasPrefix("| ")
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
        guard let after = verified(edits, expected: expected, in: p) else { return .refuse(.unverified) }
        return .apply(application(edits, undo: .own, caret: point.source + text.utf16.count,
                                  after: after))
    }

    // MARK: Return, ⇧Return, Tab

    private static func returnKey(at range: NSRange, in p: MarkdownProjection) -> PreviewEditOutcome {
        guard range.length == 0 else { return .refuse(.notSupported) }
        let caret = range.location
        guard let blockIndex = PreviewEditRules.block(at: caret, in: p) else { return .refuse(.notText) }
        let block = p.blocks[blockIndex]
        if let reason = block.readOnly { return .refuse(.readOnly(reason)) }
        let atEnd = caret == NSMaxRange(block.rendered)

        switch block.kind {
        case .codeBlock:
            guard let point = PreviewEditRules.insertionPoint(at: caret, in: p) else {
                return .refuse(.notText)
            }
            let text = PreviewEditRules.lineEnding + block.linePrefix
            let edits = [PreviewSourceEdit(range: NSRange(location: point.source, length: 0), text: text)]
            let expected = (p.renderedString as NSString).replacingCharacters(in: range, with: "\n")
            guard let after = verified(edits, expected: expected, in: p) else {
                return .refuse(.unverified)
            }
            return .apply(application(edits, undo: .own, caret: point.source + text.utf16.count,
                                      after: after))

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
            // Inside the span the caret is in first; failing that, after each span that closes
            // there — a Return just after bold splits after its `**`, not between them (review).
            let splits = [point.source] + point.spans.reversed().map { NSMaxRange(p.spans[$0].source) }
            for split in splits {
                let edits = [PreviewSourceEdit(range: NSRange(location: split, length: 0), text: text)]
                guard let after = verified(edits, expected: expected, in: p, structural: true) else { continue }
                return .apply(application(edits, undo: .own, caret: split + text.utf16.count, after: after))
            }
            return .refuse(.unverified)

        default:
            return .refuse(.notSupported)
        }
    }

    /// Return in a list item: TE54's rule, byte for byte what Return does there in Source (C11).
    private static func listReturn(at caret: Int, block: Int, atEnd: Bool,
                                   in p: MarkdownProjection) -> PreviewEditOutcome {
        guard atEnd else { return .refuse(.notSupported) }
        let ns = p.source as NSString
        // The end of the item's line in the source: after its words, or after its marker when empty.
        let words = p.segments.last { $0.block == block && $0.kind == .content }
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
        // Not checked against an expected rendering: a new item adds a block, which a character
        // comparison cannot describe. TE54's rules are verified by the parser themselves.
        let source = applied(edits, to: p.source)
        return .apply(application(edits, undo: .own, caret: caret,
                                  after: MarkdownProjection.project(source, style: p.style, after: p)))
    }

    /// ⇧Return: a hard line break, written as two trailing spaces and a newline (decision U) — the
    /// form that keeps the parser's line count right. Never the backslash form (§2.1, case 2).
    private static func lineBreak(at range: NSRange, in p: MarkdownProjection) -> PreviewEditOutcome {
        guard range.length == 0,
              let point = PreviewEditRules.insertionPoint(at: range.location, in: p) else {
            return .refuse(.notSupported)
        }
        switch p.blocks[point.block].kind {
        case .paragraph, .listItem: break
        default: return .refuse(.notSupported)
        }
        let ending = PreviewEditRules.lineEnding
        let text = "  " + ending + PreviewEditRules.continuationPrefix(of: point.block, in: p)
        let edits = [PreviewSourceEdit(range: NSRange(location: point.source, length: 0), text: text)]
        let expected = (p.renderedString as NSString).replacingCharacters(in: range, with: "\u{2028}")
        guard let after = verified(edits, expected: expected, in: p, structural: true) else {
            return .refuse(.unverified)
        }
        return .apply(application(edits, undo: .own, caret: point.source + text.utf16.count,
                                  after: after))
    }

    private static func tab(at range: NSRange, outdent: Bool, in p: MarkdownProjection) -> PreviewEditOutcome {
        guard let blockIndex = PreviewEditRules.block(at: range.location, in: p) else { return .ignore }
        let block = p.blocks[blockIndex]
        guard block.readOnly == nil else { return .ignore }
        switch block.kind {
        case .listItem:
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
        if lineVerb, let phantom = context.phantomAfterBlock, p.blocks.indices.contains(phantom),
           p.blocks[phantom].readOnly == nil {
            let end = NSMaxRange(p.blocks[phantom].source)
            let prefix = PreviewEditRules.paragraphPrefix(of: phantom, in: p)
            let ending = PreviewEditRules.lineEnding
            let line = ending + PreviewEditRules.blankLine(for: prefix) + ending + prefix
            base = (p.source as NSString).replacingCharacters(in: NSRange(location: end, length: 0), with: line)
            selection = NSRange(location: end + line.utf16.count, length: 0)
        } else {
            guard let mapped = sourceSelection(for: range, in: p) ?? (lineVerb ? acrossBlocks(range, in: p) : nil)
            else { return .refuse(.notText) }
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
            guard let checked = verified(edits, expected: p.renderedString, in: p) else {
                return .refuse(.unverified)
            }
            after = checked
        } else {
            after = MarkdownProjection.project(edit.text, style: p.style, after: p)
        }
        let start = PreviewEditRules.renderedOffset(forSource: edit.selection.location, in: after)
        let end = PreviewEditRules.renderedOffset(forSource: NSMaxRange(edit.selection), in: after)
        return .apply(PreviewEditApplication(edits: edits, undo: .own, source: edit.text,
                                             projection: after, sourceSelection: edit.selection,
                                             renderedSelection: NSRange(location: start,
                                                                        length: max(0, end - start))))
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
    private static func phantomParagraph(after block: Int, typing text: String,
                                         in p: MarkdownProjection) -> PreviewEditOutcome {
        guard p.blocks.indices.contains(block), p.blocks[block].readOnly == nil else {
            return .refuse(.notSupported)
        }
        guard !text.contains(where: \.isNewline) else { return .refuse(.notSupported) }
        let end = NSMaxRange(p.blocks[block].source)
        let ending = PreviewEditRules.lineEnding
        let prefix = PreviewEditRules.paragraphPrefix(of: block, in: p)
        let rendered = NSMaxRange(p.blocks[block].rendered)
        let expected = (p.renderedString as NSString)
            .replacingCharacters(in: NSRange(location: rendered, length: 0), with: "\n" + text)
        for typed in [text, escaped(text)] {
            let inserted = ending + PreviewEditRules.blankLine(for: prefix) + ending + prefix + typed
            let edits = [PreviewSourceEdit(range: NSRange(location: end, length: 0), text: inserted)]
            guard let after = verified(edits, expected: expected, in: p) else { continue }
            return .apply(application(edits, undo: .typing, caret: end + inserted.utf16.count,
                                      after: after))
        }
        return .refuse(.unverified)
    }

    /// The first characters of an empty file — or of one that is only blank lines.
    private static func emptyDocument(typing text: String, in p: MarkdownProjection) -> PreviewEditOutcome {
        let end = p.index.length
        for typed in [text, escaped(text)] {
            let edits = [PreviewSourceEdit(range: NSRange(location: end, length: 0), text: typed)]
            guard let after = verified(edits, expected: text, in: p) else { continue }
            return .apply(application(edits, undo: .typing, caret: end + typed.utf16.count, after: after))
        }
        return .refuse(.unverified)
    }

    // MARK: Verification

    /// The edits applied and re-projected, when the new rendering is `expected`; otherwise `nil`.
    ///
    /// **Compared through the parser's smart punctuation** (`'` and ’, `--` and –), because a
    /// typed straight quote renders curly and that is the file being right, not wrong.
    /// `structural` also forgives whitespace beside a new line or break, which the parser trims.
    static func verified(_ edits: [PreviewSourceEdit], expected: String, in p: MarkdownProjection,
                         structural: Bool = false) -> MarkdownProjection? {
        let after = MarkdownProjection.project(applied(edits, to: p.source), style: p.style, after: p)
        guard sameComparable(after.renderedString, expected, structural: structural) else { return nil }
        // An edit that renders right but leaves the projection unable to map a block it could map
        // before would strand the caret — and every keystroke after it — so it is refused too.
        //
        // **And so is one that renders right but MEANS something else** — typed text that the
        // parser took for HTML (`Vec<T` + `>` is a tag, and dropped by every other renderer), or a
        // table pushed too wide to edit. Each shows up as a read-only piece the source did not have
        // (review, 2026-10-05); the escaped retry is what gets written instead.
        func stranded(_ q: MarkdownProjection) -> Int {
            q.blocks.filter { $0.readOnly != nil }.count
                + q.segments.filter { if case .readOnly = $0.kind { true } else { false } }.count
        }
        guard stranded(after) <= stranded(p) else { return nil }
        return after
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

    /// A link compared by being a link: typing next to one never changes where it goes.
    private static func normalizedKind(_ kind: PreviewInlineSpan.Kind) -> PreviewInlineSpan.Kind {
        if case .link = kind { return .link(destination: nil) }
        return kind
    }

    // MARK: Building blocks

    /// Every ASCII punctuation character backslash-escaped — CommonMark's escape, which renders as
    /// the character itself in prose and in a table cell.
    static func escaped(_ text: String) -> String {
        var out = ""
        for character in text {
            if let ascii = character.asciiValue, (0x21...0x2F).contains(ascii) || (0x3A...0x40).contains(ascii)
                || (0x5B...0x60).contains(ascii) || (0x7B...0x7E).contains(ascii) {
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

    private static func segment(at offset: Int, in p: MarkdownProjection) -> PreviewSegment? {
        p.segments.first { $0.rendered.location <= offset && offset < NSMaxRange($0.rendered) }
    }

    /// Why nothing can be typed at `caret`.
    private static func refusalAt(_ caret: Int, in p: MarkdownProjection) -> PreviewRefusal {
        if let block = PreviewEditRules.block(at: caret, in: p), let reason = p.blocks[block].readOnly {
            return .readOnly(reason)
        }
        if let found = segment(at: caret, in: p), case .readOnly(let reason) = found.kind {
            return .readOnly(reason)
        }
        return .notText
    }
}

extension PreviewBlock.Kind {
    var isCode: Bool { if case .codeBlock = self { true } else { false } }
}

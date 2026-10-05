import Foundation

/// One replacement in a buffer, and the selection after it — what the paste and drop edits hand the
/// text view, so it can splice exactly the range that changes instead of diffing the whole buffer.
struct MarkdownSplice: Equatable, Sendable {
    var range: NSRange
    var text: String
    /// In the buffer AFTER the replacement.
    var selection: NSRange
}

/// What a paste or a drop writes into Markdown source when it is not plain text being pasted
/// (TE55, TE56) — pure functions over a buffer, as ``MarkdownEdits`` is.
enum MarkdownPasteEdits {

    // MARK: - TE55: a link pasted onto words

    /// The words in `selection` made a link to `pasted`, or `nil` for "paste as it always pasted".
    ///
    /// **Every condition is a reason the plain paste is the better answer**, and each one falls back
    /// to it rather than refusing:
    /// - nothing selected — there are no words to make a link of;
    /// - the clipboard is anything but ONE `http`/`https` address, alone (``webAddress(_:)``);
    /// - the selection crosses a line, is only whitespace, or is itself an address (pasting one
    ///   address over another is replacing it);
    /// - it holds a bracket or a backtick, ends in a backslash, or follows a `!` or a `\` — each
    ///   would end the link text early, nest a link in a link, make an image, or escape the `[`;
    /// - **it sits inside a link already** — in its words, its address or a reference definition,
    ///   anywhere in the paragraph (link text wraps). Markup ▸ Link… leaves `url` selected in
    ///   `[words](url)` for exactly this paste, and the paste must REPLACE it;
    /// - it sits in code, raw HTML or the front matter — a code block by the parser, a code span by
    ///   CommonMark's backtick-run rule — where `[words](url)` would be literal characters.
    ///
    /// **Whitespace at either end of the selection stays outside the link**, every space character
    /// as it was — a drag that took the space after a word makes `[word](url) `. So does the line
    /// break at the end of a line selected whole (a triple-click takes it). So do the line's own
    /// markers, whatever part of them the selection covers — every one of them, `> - ` included,
    /// and a list marker after a quote's `> ` — and a heading's closing `#`s: `- [milk](url)`, not
    /// `[- milk](url)`, and `1. [milk](url)` from a selection that started on the `.`.
    ///
    /// The returned selection is a caret after the link, where a plain paste leaves it.
    static func linkPaste(_ pasted: String, over whole: NSRange, in ns: NSString) -> MarkdownSplice? {
        guard whole.length > 0, MarkdownEdits.isValid(whole, in: ns),
              let url = webAddress(pasted) else { return nil }
        // A line selected whole ends in its line break, which is not a word: it stays after the link.
        var selection = whole
        let last = ns.character(at: NSMaxRange(whole) - 1)
        if last == 0x0A || last == 0x0D {
            let crlf = last == 0x0A && whole.length > 1 && ns.character(at: NSMaxRange(whole) - 2) == 0x0D
            selection.length -= crlf ? 2 : 1
        }
        let terminator = ns.substring(with: NSRange(location: NSMaxRange(selection),
                                                    length: NSMaxRange(whole) - NSMaxRange(selection)))
        guard selection.length > 0 else { return nil }
        let selected = ns.substring(with: selection)
        guard selected.rangeOfCharacter(from: .newlines) == nil else { return nil }

        // The line's markers — indent, `>`s, list marker and box, heading `#`s: whatever of them the
        // selection covers stays outside the link.
        let line = MarkdownSourceLines.line(containing: selection.location, in: ns)
        let lineText = ns.substring(with: line.content)
        let markers = markerPrefix(of: lineText)
        let covered = max(0, min(line.content.location + markers.length, NSMaxRange(selection)) - selection.location)
        var leading = (selected as NSString).substring(to: covered)

        // Then whitespace at either end, scalar for scalar, so nothing in the selection is dropped
        // on the way.
        let scalars = Array((selected as NSString).substring(from: covered).unicodeScalars)
        var front = 0
        while front < scalars.count, CharacterSet.whitespaces.contains(scalars[front]) { front += 1 }
        var back = scalars.count
        while back > front, CharacterSet.whitespaces.contains(scalars[back - 1]) { back -= 1 }
        leading += String(String.UnicodeScalarView(scalars[0..<front]))
        var core = String(String.UnicodeScalarView(scalars[front..<back]))
        var trailing = String(String.UnicodeScalarView(scalars[back...]))
        if markers.isHeading, let closing = core.range(of: "[ \t]+#+$", options: .regularExpression) {
            trailing = String(core[closing]) + trailing
            core.removeSubrange(closing)
        }
        // A table cell ends at a `|`: words holding one, on a line with others, cross into the next cell.
        let outside = (lineText as NSString).replacingCharacters(
            in: NSRange(location: selection.location - line.content.location, length: selection.length), with: "")
        guard !core.isEmpty, !core.contains("://"),
              core.rangeOfCharacter(from: linkBreakers) == nil, !core.hasSuffix("\\"),
              !(core.contains("|") && outside.contains("|")) else { return nil }
        // The character before the link's `[`: `!` would make it an image, `\` would escape it.
        let lead = selection.location + (leading as NSString).length
        if lead > 0, [UInt16(0x21), UInt16(0x5C)].contains(ns.character(at: lead - 1)) { return nil }
        guard !MarkdownSourceContext.isLiteral(at: selection.location, in: ns),
              !isInsideLinkOrCode(selection, in: ns) else { return nil }

        let link = "[\(core)](\(destination(url)))"
        let replacement = leading + link + trailing + terminator
        let caret = selection.location + ((leading + link) as NSString).length
        return MarkdownSplice(range: whole, text: replacement,
                              selection: NSRange(location: caret, length: 0))
    }

    /// `string` as ONE `http` or `https` address and nothing else, or `nil`.
    ///
    /// Surrounding whitespace is forgiven — a copied address often carries a trailing newline — and
    /// nothing else is: any space, line break or control character inside means two things, or
    /// prose; a backslash or `<`/`>` cannot be written into a link destination as it is. **A second
    /// address glued on** (`https://a.comhttps://b.com`, or joined by `,`/`;`) is two; one carried
    /// inside the path or query (`…/web/2020/https://…`, `…?q=https://…`) is still one.
    static func webAddress(_ string: String) -> String? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines
                                        .union(.controlCharacters)
                                        .union(CharacterSet(charactersIn: "\\<>"))) == nil,
              !hasGluedSecondAddress(trimmed),
              let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return trimmed
    }

    /// Whether a second `http://` or `https://` starts right after a letter, a digit, `,`, `;` or
    /// `|` — two addresses run together — rather than after a `/`, `=`, `?` or `&` inside one.
    private static func hasGluedSecondAddress(_ text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: "(https?)://", options: .caseInsensitive) else { return false }
        let ns = text as NSString
        // The first match is the address's own scheme, at the start; any other starts past it.
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).dropFirst() {
            let start = match.range(at: 1).location
            let before = ns.substring(with: NSRange(location: start - 1, length: 1))
            if before.rangeOfCharacter(from: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ",;|"))) != nil {
                return true
            }
        }
        return false
    }

    /// Characters that end link text early, or nest a link: brackets, and a backtick that could
    /// open a code span across the link's own `]`.
    private static let linkBreakers = CharacterSet(charactersIn: "[]`")

    /// The link's destination as written: bare, or in `<…>` when its parentheses do not balance —
    /// CommonMark ends a bare destination at the first unmatched `)`.
    ///
    /// **A `|` is written `\|`**: in a table it would end the cell, and GFM takes the escape out of a
    /// cell before reading the link; anywhere else a backslash before punctuation in a destination
    /// is that punctuation. Either way the address is the one pasted.
    private static func destination(_ url: String) -> String {
        var depth = 0
        for character in url {
            if character == "(" { depth += 1 }
            if character == ")" { depth -= 1; if depth < 0 { break } }
        }
        let escaped = url.replacingOccurrences(of: "|", with: "\\|")
        return depth == 0 ? escaped : "<\(escaped)>"
    }

    /// The markers a line opens with — its indent, every quote `>`, a list marker and its task box,
    /// heading `#`s — each with the whitespace after it: how many UTF-16 units they take, and whether
    /// one was a heading's. Read by UTF-16 offset, as the selection is: a combining mark after a
    /// marker's space is the first character of the words, not part of the space.
    private static func markerPrefix(of line: String) -> (length: Int, isHeading: Bool) {
        let ns = line as NSString
        var at = 0
        func skipIndent() {
            while at < ns.length, ns.character(at: at) == 0x20 || ns.character(at: at) == 0x09 { at += 1 }
        }
        skipIndent()
        var heading = false
        // Every marker, in order: `> > - [ ] ` is four.
        markers: for _ in 0..<8 {
            for regex in markerPatterns {
                guard let match = regex.firstMatch(in: line, options: .anchored,
                                                   range: NSRange(location: at, length: ns.length - at)),
                      match.range.length > 0 else { continue }
                heading = heading || ns.character(at: at) == 0x23
                at = NSMaxRange(match.range)
                skipIndent()
                continue markers
            }
            break
        }
        return (at, heading)
    }

    private static let markerPatterns: [NSRegularExpression] = [
        "#{1,6}(?:[ \\t]|$)", ">[ \\t]?", "(?:[-*+]|[0-9]{1,9}[.)])(?:[ \\t]|$)(?:[ \\t]*\\[[ xX]\\](?:[ \\t]|$))?",
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    /// **Whether the selection is already inside a link or a code span, anywhere in its paragraph**
    /// — the lines around it up to a blank line, because link text and code spans both wrap.
    ///
    /// - A code span by CommonMark's rule: a run of backticks closed by the next run of the SAME
    ///   length, so ``` ``a ` b`` ``` is one span. The selection touching one is inside.
    /// - With the spans blanked out, link text is an unclosed `[` before the selection; an address
    ///   is a `](` whose parentheses have not closed by the selection; an autolink is a `<scheme:`
    ///   with no `>` yet; a reference definition is its line's `[label]:`, after any list or quote
    ///   markers. Each has an answer already, and it is the plain paste.
    /// - Inside angle brackets — an autolink (`<me@example.com>` too) or an HTML tag's attribute —
    ///   and between an HTML `<a …>` and its `</a>`, which is a link written in HTML.
    private static func isInsideLinkOrCode(_ selection: NSRange, in ns: NSString) -> Bool {
        let (paragraph, offset) = Self.paragraph(around: selection, in: ns)
        let chars = Array(paragraph.utf16)
        let start = selection.location - offset
        let end = NSMaxRange(selection) - offset
        var masked = chars
        for span in codeSpans(in: chars) {
            if span.lowerBound < end && start < span.upperBound { return true }
            for index in span { masked[index] = 0x20 }
        }

        let before = String(utf16CodeUnits: Array(masked[0..<start]), count: start)
        let lineStart = before.range(of: "[\n\r][^\n\r]*$", options: .regularExpression).map {
            before.index(after: $0.lowerBound)
        } ?? before.startIndex
        let line = String(before[lineStart...])
        if line.range(of: "^ {0,3}(?:(?:[-*+]|[0-9]{1,9}[.)])[ \t]+|>[ \t]?)*\\[[^\\]]+\\]:", options: .regularExpression) != nil {
            return true
        }
        var depth = 0
        var escaped = false
        for character in before {
            if character == "\\" && !escaped { escaped = true; continue }
            if !escaped {
                if character == "[" { depth += 1 }
                if character == "]" { depth = max(depth - 1, 0) }
            }
            escaped = false
        }
        if depth > 0 { return true }
        if let open = before.range(of: "](", options: .backwards) {
            var parens = 1
            for character in before[open.upperBound...] {
                if character == "(" { parens += 1 }
                if character == ")" { parens -= 1; if parens == 0 { break } }
            }
            if parens > 0 { return true }
        }
        if let open = before.range(of: "<", options: .backwards),
           before[open.upperBound...].range(of: "^[A-Za-z][A-Za-z0-9+.-]{1,31}:[^\\s<>]*$",
                                             options: .regularExpression) != nil {
            return true
        }
        // Between `<` and `>` with neither in between: a tag, a comment or an autolink.
        let after = String(utf16CodeUnits: Array(masked[end...]), count: masked.count - end)
        if let open = before.range(of: "<", options: .backwards),
           !before[open.upperBound...].contains(">"),
           before[open.upperBound...].first.map({ $0.isLetter || "/!?".contains($0) }) == true,
           let close = after.firstIndex(of: ">"), !after[..<close].contains("<") {
            return true
        }
        // Inside an HTML link: an `<a>` opened before the selection and not yet closed.
        func last(_ pattern: String) -> Int? {
            let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
            return regex?.matches(in: before, range: NSRange(location: 0, length: (before as NSString).length))
                .last?.range.location
        }
        if let opened = last("<a(?:\\s[^>]*)?>"), (last("</a\\s*>") ?? -1) < opened { return true }
        return false
    }

    /// The selection's paragraph — its lines back and forward to a blank line, at most 50 each way
    /// — and where it starts in the buffer.
    private static func paragraph(around selection: NSRange, in ns: NSString) -> (String, Int) {
        func blank(_ line: MarkdownSourceLines.Line) -> Bool {
            ns.substring(with: line.content).allSatisfy { $0 == " " || $0 == "\t" }
        }
        var first = MarkdownSourceLines.line(containing: selection.location, in: ns)
        for _ in 0..<50 {
            guard let above = MarkdownSourceLines.line(before: first, in: ns), !blank(above) else { break }
            first = above
        }
        var last = MarkdownSourceLines.line(containing: NSMaxRange(selection), in: ns)
        for _ in 0..<50 {
            guard let below = MarkdownSourceLines.line(after: last, in: ns), !blank(below) else { break }
            last = below
        }
        let range = NSRange(location: first.content.location, length: NSMaxRange(last.content) - first.content.location)
        return (ns.substring(with: range), range.location)
    }

    /// Code spans in `chars` by CommonMark's backtick-run rule: an unescaped run of N backticks
    /// opens one, closed by the next run of exactly N; a run with no such closer is literal.
    private static func codeSpans(in chars: [UInt16]) -> [Range<Int>] {
        var spans: [Range<Int>] = []
        var index = 0
        func run(at start: Int) -> Int {
            var end = start
            while end < chars.count, chars[end] == 0x60 { end += 1 }
            return end - start
        }
        while index < chars.count {
            if chars[index] == 0x5C { index += 2; continue }
            guard chars[index] == 0x60 else { index += 1; continue }
            let length = run(at: index)
            var probe = index + length
            var closed: Int?
            while probe < chars.count {
                if chars[probe] == 0x60 {
                    let other = run(at: probe)
                    if other == length { closed = probe + other; break }
                    probe += other
                } else {
                    probe += 1
                }
            }
            if let closed {
                spans.append(index..<closed)
                index = closed
            } else {
                index += length
            }
        }
        return spans
    }

    // MARK: - TE56: an image on its own line

    /// `![](link)` for each link, replacing `range`, **on lines of their own with a blank line on
    /// each side** — the only shape ``MarkdownBlocks`` draws as a picture (an image paragraph that
    /// holds nothing else). Blank lines already there are used rather than doubled, and nothing is
    /// added at the very start or end of the buffer.
    ///
    /// **Where**: at `range` on a blank line; on a line with anything on it, after the block that
    /// line is in, indented to stay in its list item — see
    /// ``MarkdownSourceContext/imageSpot(at:in:)``. A selection is replaced as a paste replaces one,
    /// and the image goes where the caret then is. `nil` where no image may go: inside code, raw
    /// HTML, a link definition or the front matter.
    ///
    /// Several images are separate paragraphs, so each one draws. The caret lands after the last
    /// link — on its line, where it would be after typing it.
    static func imageBlock(_ links: [String], replacing range: NSRange, in ns: NSString) -> MarkdownSplice? {
        guard !links.isEmpty, MarkdownEdits.isValid(range, in: ns) else { return nil }
        // The buffer as it reads with the selection gone — the same as `ns` up to `range.location`.
        let rest = range.length > 0 ? ns.replacingCharacters(in: range, with: "") as NSString : ns
        guard let spot = MarkdownSourceContext.imageSpot(at: range.location, in: rest) else { return nil }
        let spotLine = MarkdownSourceLines.line(containing: spot.location, in: rest)
        // On a blank line — only ever the one it was dropped on: a spot after a block is the end of
        // its last written line — that line's own spaces go: kept, four of them would make the
        // image code.
        let blank = rest.substring(with: spotLine.content).allSatisfy { $0 == " " || $0 == "\t" }
        let start = blank ? min(spotLine.content.location, range.location) : range.location
        let end = blank ? NSMaxRange(spotLine.content) : spot.location
        let between = blank ? "" : rest.substring(with: NSRange(location: range.location,
                                                                length: spot.location - range.location))
        let newline = lineEnding(of: ns)
        let lead = String(repeating: newline, count: blankLinesBefore(blank ? start : end, in: rest))
        let trail = String(repeating: newline, count: blankLinesAfter(end, in: rest))
        let indent = String(repeating: " ", count: spot.indent)
        let images = links.map { indent + "![](\($0))" }.joined(separator: newline + newline)
        let caret = start + ((between + lead + images) as NSString).length
        return MarkdownSplice(range: NSRange(location: start, length: end - start + range.length),
                              text: between + lead + images + trail,
                              selection: NSRange(location: caret, length: 0))
    }

    /// How many line breaks to put before an image inserted at `location`: none at the start of the
    /// buffer or after a blank line, one at the start of a line that follows text, two mid-line.
    private static func blankLinesBefore(_ location: Int, in ns: NSString) -> Int {
        guard location > 0 else { return 0 }
        let line = MarkdownSourceLines.line(containing: location, in: ns)
        let beforeOnLine = ns.substring(with: NSRange(location: line.content.location,
                                                      length: location - line.content.location))
        guard beforeOnLine.trimmingCharacters(in: .whitespaces).isEmpty else { return 2 }
        // At the start of a line (give or take spaces): blank already above it, or the top?
        guard let above = MarkdownSourceLines.line(before: line, in: ns) else { return 0 }
        return ns.substring(with: above.content).trimmingCharacters(in: .whitespaces).isEmpty ? 0 : 1
    }

    /// How many line breaks to put after: none at the end of the buffer or before a blank line, one
    /// at the end of a line that has text below it, two mid-line.
    private static func blankLinesAfter(_ location: Int, in ns: NSString) -> Int {
        let line = MarkdownSourceLines.line(containing: location, in: ns)
        let afterOnLine = ns.substring(with: NSRange(location: location,
                                                     length: NSMaxRange(line.content) - location))
        guard afterOnLine.trimmingCharacters(in: .whitespaces).isEmpty else { return 2 }
        guard let below = MarkdownSourceLines.line(after: line, in: ns) else { return 0 }
        return ns.substring(with: below.content).trimmingCharacters(in: .whitespaces).isEmpty ? 0 : 1
    }

    /// The buffer's own line ending — `\r\n` in a file that came from Windows — so an inserted block
    /// does not leave it with two kinds.
    private static func lineEnding(of ns: NSString) -> String {
        let first = ns.rangeOfCharacter(from: CharacterSet(charactersIn: "\r\n"))
        guard first.location != NSNotFound, ns.character(at: first.location) == 0x0D else { return "\n" }
        return first.location + 1 < ns.length && ns.character(at: first.location + 1) == 0x0A ? "\r\n" : "\r"
    }
}

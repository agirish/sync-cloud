import Foundation

/// One replacement in a buffer, and the selection after it — what the paste and drop edits hand the
/// text view, so it can splice exactly the range that changes instead of diffing the whole buffer.
struct MarkdownSplice: Equatable, Sendable {
    var range: NSRange
    var text: String
    /// In the buffer AFTER the replacement.
    var selection: NSRange

    /// The buffer with the replacement made — what the tests read character for character.
    func applied(to buffer: String) -> String {
        (buffer as NSString).replacingCharacters(in: range, with: text)
    }
}

/// What a paste or a drop writes into Markdown source when it is not plain text being pasted
/// (TE55, TE56) — pure functions over a buffer, as ``MarkdownEdits`` is.
enum MarkdownPasteEdits {

    // MARK: - TE55: a link pasted onto words

    static func linkPaste(_ pasted: String, over selection: NSRange, in text: String) -> MarkdownSplice? {
        linkPaste(pasted, over: selection, in: text as NSString)
    }

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
    /// as it was — a drag that took the space after a word makes `[word](url) `. So do the line's
    /// own markers when the selection starts the line — every one of them, `> - ` included — and a
    /// heading's closing `#`s: `- [milk](url)`, not `[- milk](url)`.
    ///
    /// The returned selection is a caret after the link, where a plain paste leaves it.
    static func linkPaste(_ pasted: String, over selection: NSRange, in ns: NSString) -> MarkdownSplice? {
        guard selection.length > 0, MarkdownEdits.isValid(selection, in: ns),
              let url = webAddress(pasted) else { return nil }
        let selected = ns.substring(with: selection)
        guard selected.rangeOfCharacter(from: lineBreaks) == nil else { return nil }

        // Split into what stays outside the link and the words, scalar for scalar, so nothing in the
        // selection is dropped on the way.
        let scalars = Array(selected.unicodeScalars)
        var front = 0
        while front < scalars.count, CharacterSet.whitespaces.contains(scalars[front]) { front += 1 }
        var back = scalars.count
        while back > front, CharacterSet.whitespaces.contains(scalars[back - 1]) { back -= 1 }
        var leading = String(String.UnicodeScalarView(scalars[0..<front]))
        var core = String(String.UnicodeScalarView(scalars[front..<back]))
        var trailing = String(String.UnicodeScalarView(scalars[back...]))

        let line = MarkdownSourceLines.line(containing: selection.location, in: ns)
        let lineBefore = ns.substring(with: NSRange(location: line.content.location,
                                                    length: selection.location - line.content.location))
        if lineBefore.unicodeScalars.allSatisfy(CharacterSet.whitespaces.contains) {
            var heading = false
            // Every marker, in order: `> > - [ ] ` is four.
            for _ in 0..<8 {
                guard let marker = blockMarker(at: core) else { break }
                heading = heading || marker.hasPrefix("#")
                leading += marker
                core = (core as NSString).substring(from: (marker as NSString).length)
            }
            if heading, let closing = core.range(of: "[ \t]+#+$", options: .regularExpression) {
                trailing = String(core[closing]) + trailing
                core.removeSubrange(closing)
            }
        }
        guard !core.isEmpty, webAddress(core) == nil, !core.contains("://"),
              core.rangeOfCharacter(from: linkBreakers) == nil, !core.hasSuffix("\\") else { return nil }
        // The character before the link's `[`: `!` would make it an image, `\` would escape it.
        let lead = selection.location + (leading as NSString).length
        if lead > 0, [UInt16(0x21), UInt16(0x5C)].contains(ns.character(at: lead - 1)) { return nil }
        guard !MarkdownSourceContext.isLiteral(at: selection.location, in: ns),
              !isInsideLinkOrCode(selection, in: ns) else { return nil }

        let link = "[\(core)](\(destination(url)))"
        let replacement = leading + link + trailing
        let caret = selection.location + ((leading + link) as NSString).length
        return MarkdownSplice(range: selection, text: replacement,
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
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).dropFirst() {
            let start = match.range(at: 1).location
            guard start > 0 else { continue }
            let before = ns.substring(with: NSRange(location: start - 1, length: 1))
            if before.rangeOfCharacter(from: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ",;|"))) != nil {
                return true
            }
        }
        return false
    }

    /// Line breaks of every kind — a link's words stay on one line.
    private static let lineBreaks = CharacterSet.newlines.union(CharacterSet(charactersIn: "\u{2028}\u{2029}\u{0085}"))

    /// Characters that end link text early, or nest a link: brackets, and a backtick that could
    /// open a code span across the link's own `]`.
    private static let linkBreakers = CharacterSet(charactersIn: "[]`")

    /// The link's destination as written: bare, or in `<…>` when its parentheses do not balance —
    /// CommonMark ends a bare destination at the first unmatched `)`.
    private static func destination(_ url: String) -> String {
        var depth = 0
        for character in url {
            if character == "(" { depth += 1 }
            if character == ")" { depth -= 1; if depth < 0 { break } }
        }
        return depth == 0 ? url : "<\(url)>"
    }

    /// The list, task, heading or quote marker opening `text`, or `nil`.
    private static func blockMarker(at text: String) -> String? {
        let patterns = ["^#{1,6}[ \t]+", "^>[ \t]?",
                        "^(?:[-*+]|[0-9]{1,9}[.)])[ \t]+(?:\\[[ xX]\\][ \t]+)?"]
        let ns = text as NSString
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { continue }
            return ns.substring(with: match.range)
        }
        return nil
    }

    /// **Whether the selection is already inside a link or a code span, anywhere in its paragraph**
    /// — the lines around it up to a blank line, because link text and code spans both wrap.
    ///
    /// - A code span by CommonMark's rule: a run of backticks closed by the next run of the SAME
    ///   length, so ``` ``a ` b`` ``` is one span. The selection touching one is inside.
    /// - With the spans blanked out, link text is an unclosed `[` before the selection; an address
    ///   is a `](` whose parentheses have not closed by the selection; an autolink is a `<scheme:`
    ///   with no `>` yet; a reference definition is its line's `[label]:`, after any list or quote
    ///   markers. Each has an answer already, and it is the plain paste.
    private static func isInsideLinkOrCode(_ selection: NSRange, in ns: NSString) -> Bool {
        let (paragraph, offset) = Self.paragraph(around: selection, in: ns)
        let chars = Array((paragraph as NSString).length == 0 ? [] : (0..<(paragraph as NSString).length)
            .map { (paragraph as NSString).character(at: $0) })
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

    /// `![](link)` for each link, at `range`, **on lines of their own with a blank line on each
    /// side** — the only shape ``MarkdownBlocks`` draws as a picture (an image paragraph that holds
    /// nothing else). Blank lines already there are used rather than doubled, and nothing is added at
    /// the very start or end of the buffer.
    ///
    /// Several images are separate paragraphs, so each one draws. The caret lands after the last
    /// link — on its line, where it would be after typing it.
    static func imageBlock(_ links: [String], at range: NSRange, in text: String) -> MarkdownSplice? {
        imageBlock(links, at: range, in: text as NSString)
    }

    static func imageBlock(_ links: [String], at range: NSRange, in ns: NSString) -> MarkdownSplice? {
        guard !links.isEmpty, MarkdownEdits.isValid(range, in: ns) else { return nil }
        let newline = lineEnding(of: ns)
        let before = blankLinesBefore(range.location, in: ns)
        let after = blankLinesAfter(NSMaxRange(range), in: ns)
        let lead = String(repeating: newline, count: before)
        let trail = String(repeating: newline, count: after)
        let images = links.map { "![](\($0))" }.joined(separator: newline + newline)
        let inserted = lead + images + trail
        let caret = range.location + ((lead + images) as NSString).length
        return MarkdownSplice(range: range, text: inserted, selection: NSRange(location: caret, length: 0))
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

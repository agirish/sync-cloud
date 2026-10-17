import Foundation

/// The YAML block some Markdown files open with, and what is left after it.
///
/// **Split off before parsing, not rendered as Markdown, and this is a correctness fix rather than
/// a nicety.** A file opening
///
/// ```
/// ---
/// title: Release plan
/// ---
/// ```
///
/// parses as a thematic break, then a paragraph, then — because a paragraph followed by a line of
/// dashes is a **setext heading** — `title: Release plan` becomes an H2. So the preview opened on a
/// rule and a large heading nobody wrote, and the outline listed a YAML key as a section of the
/// document. Every note in a folder that uses front matter had a wrong outline.
enum MarkdownFrontMatter {

    struct Split: Equatable, Sendable {
        /// The block's contents without its delimiters, or `nil` when the file has none.
        var frontMatter: String?
        /// What the Markdown parser should see.
        var body: String
        /// The 1-based line of the whole file that ``body`` starts on, so block lines can be put
        /// back into the file's own numbering.
        var bodyStartLine: Int
    }

    /// The delimiters a block may close with. YAML allows both; a file in the wild uses `---`.
    private static let closers: Set<String> = ["---", "..."]

    /// Splits `source` into its front matter and its body.
    ///
    /// **Only at the very top, and only when it closes.** A `---` in the middle of a document is a
    /// thematic break and stays one; an opening `---` with no closing delimiter anywhere is also a
    /// thematic break, because a file that begins with a horizontal rule is a real file and reading
    /// the whole of it as unterminated front matter would make its entire text disappear from the
    /// preview.
    ///
    /// **Lines end at `\r\n`, `\n` and `\r` alike** (CHR-5) — the three the parser and
    /// `EditorCaret` count. It split on `\n` alone, so a file with classic Mac line endings had one
    /// line, its front matter went unrecognised, and the last YAML key became a setext heading in the
    /// outline and in the status line's "in …". The block's text and the body are cut from the file
    /// as written, so an LF or CRLF file gets back exactly what it did.
    static func split(_ source: String) -> Split {
        let ns = source as NSString
        guard let found = block(in: ns) else {
            return Split(frontMatter: nil, body: source, bodyStartLine: 1)
        }
        // The block's lines as written, less the one character that ended the last of them: its
        // `\n` — what rejoining the lines on `\n` produced, so a CRLF block still ends in its `\r`,
        // as it always did — or a CR-only file's `\r`.
        let written = ns.substring(with: found.matter) as NSString
        let last = written.length > 0 ? written.character(at: written.length - 1) : 0
        let matter = last == newline || last == carriageReturn
            ? written.substring(to: written.length - 1) : written as String
        return Split(frontMatter: matter, body: ns.substring(from: found.bodyOffset),
                     bodyStartLine: found.bodyStartLine)
    }

    /// Where ``split(_:)``'s body begins, as a line and as a UTF-16 offset into `ns` — **the same
    /// answer, without splitting the buffer.** This is asked on a keystroke
    /// (``MarkdownSourceContext``), and it walks only as far as the closer. `bodyStartIsSplitsAnswer`
    /// holds the two together.
    static func bodyStart(in ns: NSString) -> (line: Int, offset: Int) {
        guard let found = block(in: ns) else { return (1, 0) }
        return (found.bodyStartLine, found.bodyOffset)
    }

    /// The one walk both answers take: the first line trimmed to `---`, the block closed by the
    /// first later line trimmed to `---` or `...`, and nothing when there is no second line or no
    /// closer. UTF-16 throughout, with `.literal` matching: a line ending followed by a combining
    /// mark is still the line ending the parser cuts at.
    private static func block(in ns: NSString) -> (matter: NSRange, bodyOffset: Int, bodyStartLine: Int)? {
        let first = line(in: ns, from: 0)
        guard trimmed(ns.substring(with: first.content)) == "---", let matterStart = first.next else { return nil }
        var start = matterStart
        var index = 1
        while true {
            let current = line(in: ns, from: start)
            if closers.contains(trimmed(ns.substring(with: current.content))) {
                return (NSRange(location: matterStart, length: current.content.location - matterStart),
                        current.next ?? ns.length, index + 2)
            }
            guard let next = current.next else { return nil }
            start = next
            index += 1
        }
    }

    /// The line starting at `start`, without its ending, and where the next one starts — `nil` for
    /// the last line, which has no ending.
    private static func line(in ns: NSString, from start: Int) -> (content: NSRange, next: Int?) {
        let rest = NSRange(location: start, length: ns.length - start)
        let end = ns.rangeOfCharacter(from: lineEndings, options: .literal, range: rest)
        guard end.location != NSNotFound else { return (rest, nil) }
        let content = NSRange(location: start, length: end.location - start)
        let isCRLF = ns.character(at: end.location) == carriageReturn
            && end.location + 1 < ns.length && ns.character(at: end.location + 1) == newline
        return (content, end.location + (isCRLF ? 2 : 1))
    }

    private static let lineEndings = CharacterSet(charactersIn: "\r\n")
    private static let newline: unichar = 0x0A
    private static let carriageReturn: unichar = 0x0D

    /// A line with its trailing carriage return and spaces gone.
    ///
    /// **CR included, and that is not defensive.** Splitting on `"\n"` alone leaves the `\r` of a
    /// CRLF file on the end of every line, so `"---\r" == "---"` is false and front matter in a
    /// file that came from Windows went entirely unrecognised.
    private static func trimmed(_ line: some StringProtocol) -> String {
        line.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
    }

    /// How many `key:` lines the block holds, for the chip that stands in for it.
    ///
    /// A count rather than the keys themselves: the chip is one line in a document view, and the
    /// block is one click away when somebody wants to read it.
    static func keyCount(in matter: String) -> Int {
        // Every line ending ``split(_:)`` cuts at — a CR-only block is one string with no `\n` in it.
        matter.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n").reduce(into: 0) { count, line in
            let text = line.trimmingCharacters(in: .whitespaces)
            // A nested value (`  - one`) is not a key, and neither is a blank line or a comment.
            guard !text.isEmpty, !text.hasPrefix("#"), !text.hasPrefix("-") else { return }
            guard line.first?.isWhitespace != true else { return }
            guard text.contains(":") else { return }
            count += 1
        }
    }
}

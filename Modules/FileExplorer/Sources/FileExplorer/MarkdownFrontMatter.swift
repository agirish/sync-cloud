import Foundation

/// The YAML block some Markdown files open with, and what is left after it.
///
/// Split off before parsing, not rendered as Markdown. A file opening
///
/// ```
/// ---
/// title: Release plan
/// ---
/// ```
///
/// parses as a thematic break and then a setext heading (a paragraph over a line of dashes), so
/// `title: Release plan` would become an H2 in the preview and a section in the outline.
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

    /// The delimiters a block may close with. YAML allows both; files in the wild use `---`.
    private static let closers: Set<String> = ["---", "..."]

    /// Splits `source` into its front matter and its body.
    ///
    /// Only at the very top, and only when it closes. A `---` mid-document is a thematic break, and
    /// so is an opening `---` with no closer: a file may begin with a rule, and reading it all as
    /// unterminated front matter would blank the preview.
    ///
    /// Lines end at `\r\n`, `\n` and `\r` alike, the three the parser and `EditorCaret` count, so a
    /// CR-only file's front matter is found too. The block and the body are cut from the file as
    /// written.
    static func split(_ source: String) -> Split {
        let ns = source as NSString
        guard let found = block(in: ns) else {
            return Split(frontMatter: nil, body: source, bodyStartLine: 1)
        }
        // The block's lines as written, less the one character that ended the last of them: its
        // `\n` (so a CRLF block still ends in its `\r`), or a CR-only file's `\r`.
        let written = ns.substring(with: found.matter) as NSString
        let last = written.length > 0 ? written.character(at: written.length - 1) : 0
        let matter = last == newline || last == carriageReturn
            ? written.substring(to: written.length - 1) : written as String
        return Split(frontMatter: matter, body: ns.substring(from: found.bodyOffset),
                     bodyStartLine: found.bodyStartLine)
    }

    /// Where ``split(_:)``'s body begins, as a line and a UTF-16 offset into `ns`: the same answer
    /// without splitting the buffer. Asked on a keystroke (``MarkdownSourceContext``), it walks
    /// only as far as the closer. `bodyStartIsSplitsAnswer` holds the two together.
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
    /// The CR matters: a line cut at `"\n"` alone keeps a CRLF file's `\r`, and `"---\r"` would not
    /// match `"---"`.
    private static func trimmed(_ line: some StringProtocol) -> String {
        line.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
    }

    /// How many `key:` lines the block holds, for the chip that stands in for it.
    ///
    /// A count, not the keys: the chip is one line, and the block is one click away.
    static func keyCount(in matter: String) -> Int {
        // Every line ending ``split(_:)`` cuts at: a CR-only block has no `\n` in it.
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

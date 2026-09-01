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
    static func split(_ source: String) -> Split {
        // Kept as substrings and rejoined only on the path that finds a block, so a file without
        // front matter — which is most of them — is handed to the parser untouched.
        let lines = source.components(separatedBy: "\n")
        guard let first = lines.first,
              trimmed(first) == "---",
              lines.count > 1 else {
            return Split(frontMatter: nil, body: source, bodyStartLine: 1)
        }
        guard let closing = lines.dropFirst().firstIndex(where: { closers.contains(trimmed($0)) })
        else {
            return Split(frontMatter: nil, body: source, bodyStartLine: 1)
        }
        let matter = lines[1..<closing].joined(separator: "\n")
        let body = lines[(closing + 1)...].joined(separator: "\n")
        // `closing` is a 0-based index, so the closing delimiter is on line `closing + 1` and the
        // body starts on the line after that.
        return Split(frontMatter: matter, body: body, bodyStartLine: closing + 2)
    }

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
        matter.components(separatedBy: "\n").reduce(into: 0) { count, line in
            let text = line.trimmingCharacters(in: .whitespaces)
            // A nested value (`  - one`) is not a key, and neither is a blank line or a comment.
            guard !text.isEmpty, !text.hasPrefix("#"), !text.hasPrefix("-") else { return }
            guard line.first?.isWhitespace != true else { return }
            guard text.contains(":") else { return }
            count += 1
        }
    }
}

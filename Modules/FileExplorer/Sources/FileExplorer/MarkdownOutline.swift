import Foundation

/// One row of the document's outline.
struct MarkdownOutlineEntry: Identifiable, Equatable, Sendable {
    /// The 1-based source line the heading is on. Also the identity: two headings cannot share one.
    var line: Int
    /// The heading's own level, 1–6, exactly as written.
    var level: Int
    /// How far in the row is drawn, relative to the shallowest heading in this document.
    var depth: Int
    var title: String

    var id: Int { line }
}

/// The heading outline, derived from the blocks the preview already parses.
///
/// **Nothing is parsed twice.** The outline is a projection of ``MarkdownBlocks``' output, so a
/// document is walked once per edit and both surfaces read the same answer — which also means the
/// outline cannot disagree with the preview about what a heading is.
enum MarkdownOutline {

    /// The deepest indent the rail will draw. Past this the rows keep their level and stop moving
    /// right, for the reason ``MarkdownPreview/drawnDepth(_:)`` clamps quote bars: the rail is
    /// 232pt wide, and a sixth-level heading indented six times has no room left for its words.
    static let maxDepthDrawn = 3

    static func drawnDepth(_ depth: Int) -> Int { min(max(depth, 0), maxDepthDrawn) }

    /// The headings in `blocks`, in document order.
    ///
    /// **Headings with no source line are left out**, and that is the one exclusion. Every row here
    /// exists to be clicked, a click scrolls to a line, and a row that cannot answer where it is
    /// would be a row that does nothing — see ``MarkdownBlock/line`` for when that happens.
    static func entries(from blocks: [MarkdownBlock]) -> [MarkdownOutlineEntry] {
        var found: [(line: Int, level: Int, title: String)] = []
        for block in blocks {
            guard case .heading(let level, let text) = block.kind, let line = block.line else {
                continue
            }
            found.append((line, level, title(of: text)))
        }
        // **Relative to the shallowest heading in THIS document, not to level 1.** A note whose
        // headings start at `##` — every file in a folder of notes that reserves `#` for the title
        // — would otherwise draw its whole outline one step in from the margin, with nothing at the
        // margin to be indented from.
        let shallowest = found.map(\.level).min() ?? 1
        return found.map {
            MarkdownOutlineEntry(line: $0.line, level: $0.level,
                                 depth: drawnDepth($0.level - shallowest), title: $0.title)
        }
    }

    /// **A heading's name: its words, without any inline HTML** (CHR-6).
    ///
    /// `## Setup <a id="setup"></a>` is the usual way to pin an anchor on a heading, and the name
    /// read "Setup <a id="setup"></a>" — in the rail's outline, in the status line's "in …" and in
    /// its menu, where the markup also spent the room the name truncates into. Inline code stays:
    /// `` ## The `<div>` element `` is about a `<div>`. Where markup was taken out, the spaces it
    /// stood between close up, so the name does not keep a gap or a trailing space.
    static func title(of text: MarkdownText) -> String {
        guard text.runs.contains(where: \.isHTML) else { return text.plain }
        let words = text.runs.filter { !$0.isHTML }.map(\.text).joined()
        return words.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
    }

    /// Which outline row a given source line sits under, or `nil` when it is above the first one.
    ///
    /// **The last heading at or before the line**, which is what "the section I am in" means. `nil`
    /// is a real answer rather than a fallback to the first row: text above the first heading is
    /// genuinely in no section, and marking the first row would follow the caret into a preamble it
    /// does not describe.
    static func currentEntry(forLine line: Int, in entries: [MarkdownOutlineEntry]) -> Int? {
        var found: Int?
        for (index, entry) in entries.enumerated() {
            guard entry.line <= line else { break }
            found = index
        }
        return found
    }

    /// The block to scroll the preview to for a given source line.
    ///
    /// **The last block at or before the line, and the FIRST block when there is none.** The two
    /// halves are different questions: reading down from a heading, the block you want is the one
    /// you are inside; scrolled above the first block that reported a line, the preview should be
    /// at its top rather than nowhere.
    static func blockIndex(forLine line: Int, in blocks: [MarkdownBlock]) -> Int? {
        guard !blocks.isEmpty else { return nil }
        var found: Int?
        for (index, block) in blocks.enumerated() {
            guard let blockLine = block.line else { continue }
            guard blockLine <= line else { break }
            found = index
        }
        return found ?? 0
    }

    /// The anchor a `#link` in the same document points at.
    ///
    /// **GitHub's rule, because that is the one his files are written against**: lowercased, spaces
    /// to hyphens, and everything that is not a letter, a digit, a hyphen or an underscore dropped.
    /// It is not a standard — CommonMark has no anchors at all — so this is a convention, and the
    /// only honest thing to do when a link matches nothing is to leave it to the system rather than
    /// scroll somewhere arbitrary.
    static func anchor(for title: String) -> String {
        var slug = ""
        for character in title.lowercased() {
            if character.isLetter || character.isNumber || character == "-" || character == "_" {
                slug.append(character)
            } else if character == " " {
                slug.append("-")
            }
        }
        return slug
    }

    /// The line a `#fragment` names, or `nil` when no heading matches it.
    static func line(forAnchor fragment: String, in entries: [MarkdownOutlineEntry]) -> Int? {
        let wanted = fragment.hasPrefix("#") ? String(fragment.dropFirst()) : fragment
        let normalised = anchor(for: wanted.replacingOccurrences(of: "-", with: " "))
        return entries.first { anchor(for: $0.title) == wanted || anchor(for: $0.title) == normalised }?.line
    }

    // MARK: Where a heading is now

    /// **The line `entry`'s heading is on in `text` as it stands** — for a jump chosen from an
    /// outline taken before the latest edits (CHR-4).
    ///
    /// The outline is re-derived after the typing settles and the parse returns — over a second for
    /// a 256 KB note in a debug build — and a heading chosen in that window named the line it USED to
    /// be on: paste a paragraph above it, choose it, and the caret landed a paragraph short. So the
    /// jump looks for the heading itself, nearest the line it was on: that line first, which is the
    /// answer whenever nothing moved, then one line further each way, below first, since text
    /// typed above a heading pushes it down. A heading that is gone, or one too unusual for the look
    /// below to recognise (a setext heading over several lines, say), keeps the line it had.
    ///
    /// **A cheap look, then a parse of one or two lines.** Only a line that could open a heading of
    /// that level is parsed — `#` × level then a space, or a line underlined `===` / `---` for the
    /// two setext levels — so a line of prose costs a regular-expression test, and the parse is of
    /// that line alone (with its underline). The match is on level and on the name the outline
    /// gives it (``title(of:)``), so `## **Bold** move` is found by "Bold move".
    static func line(of entry: MarkdownOutlineEntry, in text: String) -> Int {
        let lines = sourceLines(text as NSString)
        let target = entry.line - 1
        // Compiled once per jump, and asked only of a line the character test lets through.
        let atx = try? NSRegularExpression(
            pattern: "^[ \\t>]*(?:(?:[-*+]|[0-9]{1,9}[.)])[ \\t]+)?[ \\t>]*#{\(entry.level)}(?:[ \\t]|$)")
        let setext = entry.level <= 2
            ? try? NSRegularExpression(pattern: "^ {0,3}\(entry.level == 1 ? "=" : "-")+[ \\t]*$") : nil
        func matches(_ regex: NSRegularExpression?, _ line: String) -> Bool {
            guard let regex else { return false }
            return regex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
        }
        func holds(_ index: Int) -> Bool {
            guard lines.indices.contains(index) else { return false }
            let line = lines[index]
            var snippet: String?
            if line.contains("#"), matches(atx, line) {
                snippet = line
            } else if lines.indices.contains(index + 1), matches(setext, lines[index + 1]),
                      !line.trimmingCharacters(in: .whitespaces).isEmpty {
                snippet = line + "\n" + lines[index + 1]
            }
            guard let snippet else { return false }
            return entries(from: MarkdownBlocks.blocks(from: snippet)).contains {
                $0.line == 1 && $0.level == entry.level && $0.title == entry.title
            }
        }
        if holds(target) { return entry.line }
        let reach = max(target, lines.count - 1 - target)
        guard reach >= 1 else { return entry.line }
        for distance in 1...reach {
            if holds(target + distance) { return target + distance + 1 }
            if holds(target - distance) { return target - distance + 1 }
        }
        return entry.line
    }

    /// The file's lines without their endings, cut where the parser and `EditorCaret` cut them: at
    /// `\r\n`, `\n` and `\r`.
    static func sourceLines(_ ns: NSString) -> [String] {
        var lines: [String] = []
        var start = 0
        let endings = CharacterSet(charactersIn: "\r\n")
        while true {
            let rest = NSRange(location: start, length: ns.length - start)
            let end = ns.rangeOfCharacter(from: endings, options: .literal, range: rest)
            guard end.location != NSNotFound else {
                lines.append(ns.substring(with: rest))
                return lines
            }
            lines.append(ns.substring(with: NSRange(location: start, length: end.location - start)))
            let isCRLF = ns.character(at: end.location) == 0x0D
                && end.location + 1 < ns.length && ns.character(at: end.location + 1) == 0x0A
            start = end.location + (isCRLF ? 2 : 1)
        }
    }
}

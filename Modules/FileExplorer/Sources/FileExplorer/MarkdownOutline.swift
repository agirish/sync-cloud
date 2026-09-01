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
            found.append((line, level, text.plain))
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
}

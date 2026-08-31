import Foundation

/// A line-by-line diff of two text files, aligned into rows a side-by-side pane can draw.
///
/// **Swift's own `CollectionDifference` does the diffing — no dependency, and it is Myers.**
/// `difference(from:)` gives removals and insertions by offset; what it does not give is the
/// *alignment* a side-by-side pane needs, which is what this type builds: a removal and an
/// insertion at the same place are one CHANGED row with both texts on it, not a deleted row above
/// an added one. That distinction is the whole readability of the pane — a one-word edit shows as
/// one row with the word picked out, rather than as two rows the reader has to line up by eye.
struct TextPairDiff: Equatable {

    enum RowKind: Equatable {
        /// Present and equal on both sides.
        case same
        /// On the left only.
        case removed
        /// On the right only.
        case added
        /// On both, and different.
        case changed
    }

    /// One rendered line-pair. A side is nil where that side has no line at all.
    struct Row: Equatable, Identifiable {
        let id: Int
        let kind: RowKind
        /// 1-based line numbers in each file, nil where that side has no line.
        let leftNumber: Int?
        let rightNumber: Int?
        let left: String?
        let right: String?
        /// The left text split into runs, with the runs that differ marked — nil for a row where
        /// the whole line is one state.
        let leftSegments: [Segment]?
        let rightSegments: [Segment]?
    }

    /// A run of a line, marked as changed or not — the intra-line pass.
    struct Segment: Equatable {
        let text: String
        let changed: Bool
    }

    let rows: [Row]
    /// Contiguous runs of non-`same` rows, as ranges into `rows` — what ↑/↓ step between. A reader
    /// stepping through a diff means "the next thing that changed", which is a region, not a line:
    /// a twelve-line replacement is one thing that happened, and twelve stops for it is twelve
    /// presses to get past one edit.
    let regions: [Range<Int>]

    var isIdentical: Bool { regions.isEmpty }

    var changedLineCount: Int { rows.filter { $0.kind != .same }.count }

    /// The pane's summary line. Counts regions AND lines, because they answer different questions:
    /// how many separate edits, and how much text they touched.
    var summary: String {
        guard !isIdentical else { return "The text is identical." }
        let regionWord = regions.count == 1 ? "change" : "changes"
        let lineWord = changedLineCount == 1 ? "line" : "lines"
        return "\(regions.count) \(regionWord), \(changedLineCount) \(lineWord)."
    }

    // MARK: Stepping

    /// Where a ↑/↓ press lands, given where the reader is now.
    ///
    /// **From nowhere, a step goes to an END rather than past one.** `nil` means nothing has been
    /// stepped to yet — the pane is showing the top of the file, not a change — so ↓ lands on the
    /// FIRST change and ↑ on the last. It used to start at region 0 and add one, which skipped the
    /// first change on the way in: with the pane freshly opened, the first ↓ scrolled to the
    /// second change, and the first was reachable only by wrapping the whole way round or by ↑.
    ///
    /// A value, and shared by the key handler and the on-screen stepper, so the two cannot come to
    /// disagree about where "next" is.
    static func steppedRegion(from current: Int?, direction: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return direction > 0 ? 0 : count - 1 }
        return (current + direction + count) % count
    }

    // MARK: Building

    static func make(left: [String], right: [String]) -> TextPairDiff {
        let difference = right.difference(from: left)
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }

        var rows: [Row] = []
        var l = 0, r = 0
        while l < left.count || r < right.count {
            let leftIsRemoved = l < left.count && removed.contains(l)
            let rightIsInserted = r < right.count && inserted.contains(r)
            if leftIsRemoved && rightIsInserted {
                // **The alignment that `CollectionDifference` does not give.** A removal facing an
                // insertion is one edited line, not a delete above an add.
                let (ls, rs) = segments(left[l], right[r])
                rows.append(Row(id: rows.count, kind: .changed, leftNumber: l + 1,
                                rightNumber: r + 1, left: left[l], right: right[r],
                                leftSegments: ls, rightSegments: rs))
                l += 1; r += 1
            } else if leftIsRemoved {
                rows.append(Row(id: rows.count, kind: .removed, leftNumber: l + 1,
                                rightNumber: nil, left: left[l], right: nil,
                                leftSegments: nil, rightSegments: nil))
                l += 1
            } else if rightIsInserted {
                rows.append(Row(id: rows.count, kind: .added, leftNumber: nil,
                                rightNumber: r + 1, left: nil, right: right[r],
                                leftSegments: nil, rightSegments: nil))
                r += 1
            } else if l < left.count && r < right.count {
                rows.append(Row(id: rows.count, kind: .same, leftNumber: l + 1,
                                rightNumber: r + 1, left: left[l], right: right[r],
                                leftSegments: nil, rightSegments: nil))
                l += 1; r += 1
            } else if l < left.count {
                // Reachable only if the difference and the arrays disagree, which they cannot for
                // a difference computed from these very arrays. Emitting the line rather than
                // trapping: a pane that showed one line fewer than the file has would be worse
                // than one that showed a line as unchanged.
                rows.append(Row(id: rows.count, kind: .removed, leftNumber: l + 1,
                                rightNumber: nil, left: left[l], right: nil,
                                leftSegments: nil, rightSegments: nil))
                l += 1
            } else {
                rows.append(Row(id: rows.count, kind: .added, leftNumber: nil,
                                rightNumber: r + 1, left: nil, right: right[r],
                                leftSegments: nil, rightSegments: nil))
                r += 1
            }
        }

        var regions: [Range<Int>] = []
        var start: Int?
        for (index, row) in rows.enumerated() {
            if row.kind == .same {
                if let s = start { regions.append(s..<index); start = nil }
            } else if start == nil {
                start = index
            }
        }
        if let s = start { regions.append(s..<rows.count) }

        return TextPairDiff(rows: rows, regions: regions)
    }

    /// The intra-line pass: which WORDS of a changed line changed.
    ///
    /// Word-level rather than character-level, deliberately. A character diff of a reflowed
    /// sentence marks nearly every character, which is visually the same as marking none; word
    /// runs are what a reader's eye follows, and they are what makes a one-word edit in a long
    /// line findable at all. Whitespace is carried inside the runs so the two sides still line up
    /// when rendered.
    static func segments(_ left: String, _ right: String) -> ([Segment], [Segment]) {
        let lw = words(left), rw = words(right)
        let difference = rw.difference(from: lw)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        return (merge(lw, marked: removed), merge(rw, marked: inserted))
    }

    /// Splits into words plus the whitespace that follows each, so joining the runs reproduces the
    /// line exactly — a pane that rendered its own reconstruction of a line would be showing the
    /// reader something the file does not contain.
    static func words(_ line: String) -> [String] {
        var out: [String] = []
        var current = ""
        var inWhitespace: Bool?
        for character in line {
            let isSpace = character.isWhitespace
            if let was = inWhitespace, was != isSpace, !isSpace {
                out.append(current)
                current = ""
            }
            inWhitespace = isSpace
            current.append(character)
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// Collapses adjacent runs of the same state, so a changed phrase is one highlight rather than
    /// five touching ones.
    private static func merge(_ words: [String], marked: Set<Int>) -> [Segment] {
        var out: [Segment] = []
        for (index, word) in words.enumerated() {
            let changed = marked.contains(index)
            if let last = out.last, last.changed == changed {
                out[out.count - 1] = Segment(text: last.text + word, changed: changed)
            } else {
                out.append(Segment(text: word, changed: changed))
            }
        }
        return out
    }
}

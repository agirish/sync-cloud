import Foundation

/// A line-by-line diff of two text files, aligned into rows a side-by-side pane can draw.
///
/// The Myers walk is written out rather than delegated to `CollectionDifference`, which can't be
/// stopped: it takes no budget and ignores cancellation, and the only bound before it starts is
/// an estimate that prices reordered lines at zero, though their cost is quadratic in the edit
/// distance (minutes for a shuffled 100k-line log). The walk here compares interned integers
/// (``interned(_:_:)``), counts its work against a ceiling, and checks `Task.isCancelled` on every
/// step of the outer loop.
///
/// Linear space, which lets the ceiling be generous: Myers' middle-snake refinement keeps two
/// O(N+M) frontiers instead of the O(D²) traceback, in the same O((N+M)·D) time.
///
/// On top of the edit script, a removal facing an insertion becomes one changed row with both
/// texts, so a one-word edit reads as one row with the word marked, not two rows to line up.
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

    /// The largest line number either side shows — what the view sizes its number column for.
    /// Each side's numbers rise down the rows, so the last row that has one has the largest; read
    /// from the end, it stops after a few rows rather than walking a long file.
    var largestLineNumber: Int {
        let left = rows.last { $0.leftNumber != nil }?.leftNumber ?? 0
        let right = rows.last { $0.rightNumber != nil }?.rightNumber ?? 0
        return max(left, right)
    }
    /// Contiguous runs of non-`same` rows, as ranges into `rows`: what ↑/↓ step between, so a
    /// twelve-line replacement is one stop, not twelve.
    let regions: [Range<Int>]
    /// Changed rows whose intra-line pass was skipped to stay inside ``maxIntraLineWork``, so
    /// their text is marked whole. Reported, because such a row looks like one where every word
    /// changed.
    let coarseRows: Int
    /// How many rows are not `.same`. Counted once when the rows are assembled, because `summary`
    /// reads it on every render of the pane's header.
    let changedLineCount: Int

    var isIdentical: Bool { regions.isEmpty }

    /// The pane's summary line. Counts regions AND lines, because they answer different questions:
    /// how many separate edits, and how much text they touched.
    var summary: String {
        guard !isIdentical else { return "The text is identical." }
        let regionWord = regions.count == 1 ? "change" : "changes"
        let lineWord = changedLineCount == 1 ? "line" : "lines"
        return "\(regions.count) \(regionWord), \(changedLineCount) \(lineWord)."
    }

    // MARK: Stepping

    /// Where a ↑/↓ press lands, given where the reader is now. From `nil` (nothing stepped to
    /// yet), ↓ lands on the first change and ↑ on the last, so the first change is never skipped.
    /// Shared by the key handler and the on-screen stepper, so they agree on "next".
    static func steppedRegion(from current: Int?, direction: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return direction > 0 ? 0 : count - 1 }
        return (current + direction + count) % count
    }

    // MARK: What a bounded diff can answer

    /// What asking for a diff produced. A refusal is a finding about the files and goes on screen
    /// beside the size and encoding notes; a cancellation is the surface going away and must land
    /// nowhere.
    enum Attempt: Equatable {
        case diffed(TextPairDiff)
        /// The walk passed ``maxDiffWork`` before it finished — see ``refusalCaption``.
        case tooDifferent
        /// The task was cancelled. Nothing is known about the pair, and nothing may be drawn.
        case cancelled
    }

    // MARK: Cost

    /// The most work one line diff may do, in ``LineDiffWalker``'s units: one step of one diagonal
    /// of the edit graph. A ceiling counted inside the walk, so it holds for any shape of input,
    /// including the shuffled files ``estimatedCost(left:right:)`` prices at zero.
    ///
    /// About two seconds of walk: steps ran at a steady ~230 million a second (M4, Release) across
    /// every shape measured. That admits 15,000 shuffled lines a side and refuses 20,000. A refused
    /// pair spends the full ~2s finding out, on a background task the reader can close; a ceiling
    /// low enough to refuse fast would refuse diffs worth having.
    static let maxDiffWork = 450_000_000

    /// A cheap estimate of what the Myers pass will cost on these two line arrays. Myers runs in
    /// O((N+M)·D), so cost turns on how different the files are, not how big.
    ///
    /// D is estimated from the multiset difference (lines one side has more often than the other),
    /// in one O(N+M) pass. That is a lower bound, so shuffled files estimate 0: this is only a
    /// pre-filter that refuses the huge, entirely different pair before anything is interned. The
    /// real bound is ``maxDiffWork``.
    static func estimatedCost(left: [String], right: [String]) -> Int {
        var counts: [String: Int] = [:]
        counts.reserveCapacity(left.count + right.count)
        for line in left { counts[line, default: 0] += 1 }
        for line in right { counts[line, default: 0] -= 1 }
        // Each unmatched line on either side is at least one edit.
        let distance = counts.values.reduce(0) { $0 + abs($1) }
        return (left.count + right.count) * distance
    }

    /// The most estimated work the pre-filter lets through (``estimatedCost(left:right:)``).
    /// Four times ``maxDiffWork`` because the two count different things: for files with nothing
    /// in common the estimate is exactly 4× the steps the walk takes, so the pre-filter refuses
    /// only pairs the walk would refuse too.
    static let maxEstimatedCost = 4 * maxDiffWork

    /// Why these two files won't be diffed, or nil when the estimate has no objection. A refusal
    /// here is final; nil is no promise, since the walk may still refuse (``maxDiffWork``), in the
    /// same words.
    ///
    /// Worded like `BoundedTextRead.Outcome.caption`, since it joins the same notes list, and it
    /// names the finding, not the number exceeded.
    static func refusalNote(left: [String], right: [String]) -> String? {
        guard estimatedCost(left: left, right: right) > maxEstimatedCost else { return nil }
        return refusalCaption
    }

    /// The one sentence a refused pair gets, whichever of the two bounds refused it.
    static let refusalCaption =
        "These two files are too large and too different to diff line by line — "
        + "the comparison would take minutes. The other modes still work."

    /// The budget for the intra-line passes, spent across the whole diff, in ``maxDiffWork``'s
    /// units. Needed because the line ceiling doesn't reach them: a 4 MiB file with no newlines
    /// (minified JavaScript, one-line JSON) is one changed row of ~800,000 words a side.
    ///
    /// Spent across rows rather than capped per row, so neither one huge line nor thousands of
    /// small ones can run away. Rows are served in order and the rest render whole, so the budget
    /// lands at the top of the pane, where the reader is looking.
    static let maxIntraLineWork = 100_000_000

    /// The most words a row may hold and still get a word pass. A gate on tokenising, which the
    /// diff's budget can't be: `words(_:)` allocates a String per word (~158ms a side on a 4 MiB
    /// line) before anything could decline the row. So ``wordCount(_:)`` prices it first.
    ///
    /// 10,000 words is a ~60 KB line, and its worst case is exactly ``maxIntraLineWork``, so one
    /// pathological row can spend the whole budget but never exceed it.
    static let maxWordsForIntraLine = 10_000

    // MARK: Building

    /// The diff of two line arrays, bounded and cancellable — what the surface calls.
    ///
    /// - Parameters:
    ///   - maxWork: the ceiling, in the walker's units. `.max` is unbounded, only for a caller
    ///     that has bounded its input.
    ///   - isCancelled: asked once per step of the outer loop. Pass `Task.isCancelled`, so closing
    ///     the surface stops the walk rather than discarding its result.
    static func bounded(left: [String], right: [String],
                        maxWork: Int = maxDiffWork,
                        isCancelled: @escaping () -> Bool = { false }) -> Attempt {
        let ids = interned(left, right)
        var walker = LineDiffWalker(a: ids.left, b: ids.right, maxWork: maxWork,
                                    isCancelled: isCancelled)
        switch walker.run() {
        case .refused: return .tooDifferent
        case .cancelled: return .cancelled
        case .completed: break
        }
        return .diffed(assemble(left: left, right: right,
                                removed: walker.removed, inserted: walker.inserted))
    }

    /// The unbounded diff, for callers whose input is already small, and for tests. With no
    /// ceiling it can run away; production paths use ``bounded(left:right:maxWork:isCancelled:)``.
    static func make(left: [String], right: [String]) -> TextPairDiff {
        guard case .diffed(let diff) = bounded(left: left, right: right, maxWork: .max) else {
            // Unreachable with no ceiling and no cancellation. An empty diff, not a trap: a blank
            // pane is survivable, a crash on the user's files is not.
            return TextPairDiff(rows: [], regions: [], coarseRows: 0, changedLineCount: 0)
        }
        return diff
    }

    /// Turns an edit script into the aligned rows the pane draws.
    private static func assemble(left: [String], right: [String],
                                 removed: [Bool], inserted: [Bool]) -> TextPairDiff {
        var rows: [Row] = []
        rows.reserveCapacity(max(left.count, right.count))
        var intraLineBudget = maxIntraLineWork
        var coarse = 0
        var changed = 0
        var l = 0, r = 0
        while l < left.count || r < right.count {
            let leftIsRemoved = l < left.count && removed[l]
            let rightIsInserted = r < right.count && inserted[r]
            if leftIsRemoved && rightIsInserted {
                // A removal facing an insertion is one edited line, not a delete above an add.
                let (ls, rs) = segmentsWithinBudget(left[l], right[r],
                                                    budget: &intraLineBudget, coarse: &coarse)
                rows.append(Row(id: rows.count, kind: .changed, leftNumber: l + 1,
                                rightNumber: r + 1, left: left[l], right: right[r],
                                leftSegments: ls, rightSegments: rs))
                changed += 1
                l += 1; r += 1
            } else if leftIsRemoved {
                rows.append(Row(id: rows.count, kind: .removed, leftNumber: l + 1,
                                rightNumber: nil, left: left[l], right: nil,
                                leftSegments: nil, rightSegments: nil))
                changed += 1
                l += 1
            } else if rightIsInserted {
                rows.append(Row(id: rows.count, kind: .added, leftNumber: nil,
                                rightNumber: r + 1, left: nil, right: right[r],
                                leftSegments: nil, rightSegments: nil))
                changed += 1
                r += 1
            } else if l < left.count && r < right.count {
                rows.append(Row(id: rows.count, kind: .same, leftNumber: l + 1,
                                rightNumber: r + 1, left: left[l], right: right[r],
                                leftSegments: nil, rightSegments: nil))
                l += 1; r += 1
            } else if l < left.count {
                // Reachable only if the script and the arrays disagree, which can't happen for a
                // script computed from them. Emits the line rather than trapping or dropping it.
                rows.append(Row(id: rows.count, kind: .removed, leftNumber: l + 1,
                                rightNumber: nil, left: left[l], right: nil,
                                leftSegments: nil, rightSegments: nil))
                changed += 1
                l += 1
            } else {
                rows.append(Row(id: rows.count, kind: .added, leftNumber: nil,
                                rightNumber: r + 1, left: nil, right: right[r],
                                leftSegments: nil, rightSegments: nil))
                changed += 1
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

        return TextPairDiff(rows: rows, regions: regions, coarseRows: coarse,
                            changedLineCount: changed)
    }

    /// Numbers two arrays of strings so the walk can compare machine words. Interned, not hashed:
    /// the dictionary compares keys, so equal ids mean equal strings and no collision can report
    /// two different lines as one. One pass over each side.
    static func interned(_ left: [String], _ right: [String]) -> (left: [Int], right: [Int]) {
        var table: [String: Int] = [:]
        table.reserveCapacity(left.count + right.count)
        func number(_ lines: [String]) -> [Int] {
            var out: [Int] = []
            out.reserveCapacity(lines.count)
            for line in lines {
                if let id = table[line] {
                    out.append(id)
                } else {
                    let id = table.count
                    table[line] = id
                    out.append(id)
                }
            }
            return out
        }
        return (number(left), number(right))
    }

    /// The intra-line pass, if the budget can still pay for it: which words of a changed line
    /// changed. Words, not characters: a character diff of a reflowed sentence marks nearly
    /// everything. Whitespace rides inside the runs so the two sides still line up. Otherwise
    /// `(nil, nil)`, which renders the row changed with no word runs. Priced before tokenising
    /// (``maxWordsForIntraLine``), then bounded by the walk's own ceiling, so the budget is charged
    /// the work actually done.
    private static func segmentsWithinBudget(_ left: String, _ right: String,
                                             budget: inout Int, coarse: inout Int)
        -> ([Segment]?, [Segment]?) {
        let leftCount = wordCount(left), rightCount = wordCount(right)
        let words = leftCount + rightCount
        // Any walk costs at least one step per element, so a row this long can't be afforded and
        // is refused before either line is split.
        guard words <= maxWordsForIntraLine, words <= budget else {
            coarse += 1
            return (nil, nil)
        }
        let leftWords = self.words(left), rightWords = self.words(right)
        let ids = interned(leftWords, rightWords)
        var walker = LineDiffWalker(a: ids.left, b: ids.right, maxWork: budget,
                                    isCancelled: { false })
        guard case .completed = walker.run() else {
            coarse += 1
            return (nil, nil)
        }
        budget -= walker.work
        return (merge(leftWords, marked: walker.removed),
                merge(rightWords, marked: walker.inserted))
    }

    /// The note when rows were marked whole, or nil when every changed row got its words. Joins the
    /// same list the size, encoding and refusal notes use, in the same voice.
    static func coarseNote(rows: Int) -> String? {
        guard rows > 0 else { return nil }
        return rows == 1
            ? "One line was too long to compare word by word — it is marked whole."
            : "\(rows) lines were too long to compare word by word — they are marked whole."
    }

    /// Splits into words plus the whitespace that follows each, so joining the runs reproduces the
    /// line exactly.
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

    /// How many runs ``words(_:)`` would produce, counted over the UTF-8 without allocating, so a
    /// huge line can be priced cheaply.
    ///
    /// ASCII whitespace only, where `words` uses `Character.isWhitespace`, so exotic separators
    /// (NBSP, U+2028) undercount. Safe: this only picks a word pass or a whole-line mark, and the
    /// walk it gates has its own ceiling.
    static func wordCount(_ line: String) -> Int {
        // `words` starts a run at the first character and at every non-space after a space, so a
        // leading indent is its own run and an all-space line is one run.
        var count = 0
        var previousWasSpace = false
        for byte in line.utf8 {
            let isSpace = byte == 0x20 || (byte >= 0x09 && byte <= 0x0D)
            if count == 0 {
                count = 1
            } else if previousWasSpace && !isSpace {
                count += 1
            }
            previousWasSpace = isSpace
        }
        return count
    }

    /// Collapses adjacent runs of the same state, so a changed phrase is one highlight rather than
    /// five touching ones.
    private static func merge(_ words: [String], marked: [Bool]) -> [Segment] {
        var out: [Segment] = []
        for (index, word) in words.enumerated() {
            let changed = marked[index]
            if let last = out.last, last.changed == changed {
                out[out.count - 1] = Segment(text: last.text + word, changed: changed)
            } else {
                out.append(Segment(text: word, changed: changed))
            }
        }
        return out
    }
}

// MARK: - The walk

/// Myers' O(ND) difference algorithm over two arrays of interned ids, in linear space, with a work
/// ceiling and a cancellation check. ``TextPairDiff`` says why it is written out.
///
/// The divide-and-conquer refinement from §4b of Myers' paper: forward and reverse frontiers
/// advance together until they overlap on a snake of the optimal path, and the problem splits
/// around it. Two O(N+M) frontiers are the whole memory, where a textbook traceback needs O(D²).
///
/// An explicit stack, not recursion: the split can nest as deep as the edit distance, and this
/// runs on a task's stack, which is smaller than the main thread's.
///
/// The output is two flag arrays, removed offsets of `a` and inserted offsets of `b`.
struct LineDiffWalker {

    enum Outcome: Equatable {
        case completed
        /// `work` passed `maxWork`. Nothing partial is offered: half a diff is not a diff.
        case refused
        case cancelled
    }

    private let a: [Int]
    private let b: [Int]
    private let maxWork: Int
    private let isCancelled: () -> Bool

    /// Offsets of `a` with no counterpart in `b`.
    private(set) var removed: [Bool]
    /// Offsets of `b` with no counterpart in `a`.
    private(set) var inserted: [Bool]
    /// Steps taken — one per diagonal advanced by one edit, on either frontier. What ``maxWork``
    /// bounds, and what a caller subtracts from a shared budget.
    private(set) var work = 0

    /// The forward and reverse frontiers, indexed by diagonal plus ``offset``. Allocated once for
    /// the whole walk and reused by every split.
    private var vf: [Int]
    private var vr: [Int]
    private let offset: Int

    init(a: [Int], b: [Int], maxWork: Int, isCancelled: @escaping () -> Bool) {
        self.a = a
        self.b = b
        self.maxWork = maxWork
        self.isCancelled = isCancelled
        self.removed = [Bool](repeating: false, count: a.count)
        self.inserted = [Bool](repeating: false, count: b.count)
        // Diagonals run over [-M, N] and the frontier reads one either side of the band it wrote.
        let span = a.count + b.count + 3
        self.vf = [Int](repeating: 0, count: 2 * span + 1)
        self.vr = [Int](repeating: 0, count: 2 * span + 1)
        self.offset = span
    }

    /// The snake the optimal path passes through, in the region's own coordinates.
    private struct Snake {
        let x0: Int, y0: Int
        let x1: Int, y1: Int
        /// The edit distance of the whole region, which is what decides whether it splits.
        let distance: Int
    }

    private enum Halt: Error { case refused, cancelled }

    mutating func run() -> Outcome {
        do {
            // Regions still to solve. `popLast` order is irrelevant to the result — every region
            // writes into disjoint parts of the two flag arrays.
            var pending: [(Int, Int, Int, Int)] = [(0, a.count, 0, b.count)]
            while let region = pending.popLast() {
                var (aLo, aHi, bLo, bHi) = region
                // Trim the shared prefix and suffix at every level: most real pairs are mostly
                // the same, so the walk and its counted work cover only the middle.
                while aLo < aHi, bLo < bHi, a[aLo] == b[bLo] { aLo += 1; bLo += 1 }
                while aLo < aHi, bLo < bHi, a[aHi - 1] == b[bHi - 1] { aHi -= 1; bHi -= 1 }
                if aLo == aHi {
                    for index in bLo..<bHi { inserted[index] = true }
                    continue
                }
                if bLo == bHi {
                    for index in aLo..<aHi { removed[index] = true }
                    continue
                }
                let snake = try middleSnake(aLo, aHi, bLo, bHi)
                if snake.distance > 1 {
                    pending.append((aLo + snake.x1, aHi, bLo + snake.y1, bHi))
                    pending.append((aLo, aLo + snake.x0, bLo, bLo + snake.y0))
                } else {
                    // Exactly one edit with the ends trimmed: the sides differ by one element.
                    // Naming it directly is cheaper than splitting around the snake.
                    let n = aHi - aLo, m = bHi - bLo
                    if n > m {
                        var i = 0
                        while i < m, a[aLo + i] == b[bLo + i] { i += 1 }
                        removed[aLo + i] = true
                    } else {
                        var i = 0
                        while i < n, a[aLo + i] == b[bLo + i] { i += 1 }
                        inserted[bLo + i] = true
                    }
                }
            }
            return .completed
        } catch Halt.cancelled {
            return .cancelled
        } catch {
            return .refused
        }
    }

    /// The middle snake of the optimal path through `a[aLo..<aHi]` against `b[bLo..<bHi]`.
    ///
    /// Coordinates are local to the region: x along `a` from `aLo`, y along `b` from `bLo`. The
    /// reverse frontier walks in from the far corner, so its own diagonal `c` relates to a forward
    /// diagonal `k` by `k = delta - c`, where `delta = N - M`.
    private mutating func middleSnake(_ aLo: Int, _ aHi: Int,
                                      _ bLo: Int, _ bHi: Int) throws -> Snake {
        let n = aHi - aLo, m = bHi - bLo
        let delta = n - m
        let isOdd = delta % 2 != 0
        vf[offset + 1] = 0
        vr[offset + 1] = 0
        let maxDistance = (n + m + 1) / 2
        var d = 0
        while d <= maxDistance {
            if isCancelled() { throw Halt.cancelled }

            // The band a frontier can reach: diagonals outside [-M, N] leave the grid. Clamping
            // keeps the walk O((N+M)·D), and the entries just outside are poisoned so the
            // neighbour rule can't read a value left by an earlier region.
            var kLow = max(-d, -m), kHigh = min(d, n)
            if (kLow + d) % 2 != 0 { kLow += 1 }
            if (kHigh + d) % 2 != 0 { kHigh -= 1 }
            if kLow > -d { vf[offset + kLow - 1] = -1 }
            if kHigh < d { vf[offset + kHigh + 1] = -1 }
            try spend((kHigh - kLow) / 2 + 1)

            var k = kLow
            while k <= kHigh {
                var x: Int
                if k == -d || (k != d && vf[offset + k - 1] < vf[offset + k + 1]) {
                    x = vf[offset + k + 1]            // a step down: an insertion
                } else {
                    x = vf[offset + k - 1] + 1        // a step right: a removal
                }
                var y = x - k
                let x0 = x, y0 = y
                while x < n, y < m, a[aLo + x] == b[bLo + y] { x += 1; y += 1 }
                vf[offset + k] = x
                // The reverse frontier reached diagonal `delta - k` one step ago; if the two now
                // overlap on it, this snake is on an optimal path.
                if isOdd, k >= delta - (d - 1), k <= delta + (d - 1),
                   x + vr[offset + delta - k] >= n {
                    return Snake(x0: x0, y0: y0, x1: x, y1: y, distance: 2 * d - 1)
                }
                k += 2
            }

            var cLow = max(-d, -m), cHigh = min(d, n)
            if (cLow + d) % 2 != 0 { cLow += 1 }
            if (cHigh + d) % 2 != 0 { cHigh -= 1 }
            if cLow > -d { vr[offset + cLow - 1] = -1 }
            if cHigh < d { vr[offset + cHigh + 1] = -1 }
            try spend((cHigh - cLow) / 2 + 1)

            var c = cLow
            while c <= cHigh {
                var u: Int
                if c == -d || (c != d && vr[offset + c - 1] < vr[offset + c + 1]) {
                    u = vr[offset + c + 1]
                } else {
                    u = vr[offset + c - 1] + 1
                }
                var v = u - c
                let u0 = u, v0 = v
                while u < n, v < m, a[aHi - 1 - u] == b[bHi - 1 - v] { u += 1; v += 1 }
                vr[offset + c] = u
                if !isOdd, c >= delta - d, c <= delta + d,
                   u + vf[offset + delta - c] >= n {
                    // Back into forward coordinates: the snake runs from the far end inwards.
                    return Snake(x0: n - u, y0: m - v, x1: n - u0, y1: m - v0, distance: 2 * d)
                }
                c += 2
            }
            d += 1
        }
        // Unreachable: the frontiers must meet by `maxDistance`. Refusing rather than trapping
        // tells the reader the pair wasn't diffed instead of crashing the app.
        throw Halt.refused
    }

    private mutating func spend(_ steps: Int) throws {
        work += steps
        if work > maxWork { throw Halt.refused }
    }
}

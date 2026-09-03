import Foundation

/// A line-by-line diff of two text files, aligned into rows a side-by-side pane can draw.
///
/// **The Myers walk is here rather than delegated to `CollectionDifference`, and that is a
/// correction.** `difference(from:)` is Myers too, and it was the right first answer — no
/// dependency, and correct. What it cannot do is stop: it takes no budget and observes no
/// cancellation, so the only bound available was an ESTIMATE taken before it started, and the
/// estimate is a lower bound (see ``estimatedCost(left:right:)``). Two files holding the same lines
/// in a different order — an export sorted differently, a log interleaved by two writers, a CSV
/// re-sorted in a spreadsheet — estimate ZERO and then run for as long as they run. Measured on
/// this machine with that shape: 5,000 lines a side, 0.96s; 10,000, 3.86s; 20,000, 16.5s; time is
/// quadratic in the edit distance, so a 100k-line log is minutes of a pinned core under a spinner,
/// with closing the surface no help at all.
///
/// So the walk is written out, and what it buys is the three things a delegated call could not
/// have: it compares INTEGERS rather than Strings (each distinct line is interned once — see
/// ``interned(_:_:)`` — so a comparison is one machine word and hash collisions cannot exist), it
/// counts its own work against a ceiling and refuses the moment it is passed, and it asks
/// `Task.isCancelled` on every step of the outer loop.
///
/// **Linear space, which is why the ceiling can be generous.** The textbook O(ND) walk keeps every
/// step's frontier to trace the path back, which is O(D²) memory — 400 MB at the distance an
/// ordinary 5,000-line rewrite reaches. This is Myers' own refinement: find the MIDDLE snake of the
/// optimal path with a forward and a reverse frontier, then split the problem around it. Two
/// frontiers, O(N+M) of them, and the same O((N+M)·D) time.
///
/// What this type adds on top of the edit script is the *alignment* a side-by-side pane needs: a
/// removal and an insertion at the same place are one CHANGED row with both texts on it, not a
/// deleted row above an added one. That distinction is the whole readability of the pane — a
/// one-word edit shows as one row with the word picked out, rather than as two rows the reader has
/// to line up by eye.
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
    /// Changed rows whose intra-line pass was skipped to stay inside ``maxIntraLineWork`` — their
    /// text is marked whole instead of word by word.
    /// Reported rather than silent: a row with no word runs looks exactly like a row where every
    /// word changed, and the reader would have no way to tell the two apart.
    let coarseRows: Int
    /// How many rows are not `.same`.
    ///
    /// **Counted once, in ``make(left:right:)``, rather than on every read.** It was a filter over
    /// every row, and `summary` is read on each render of the pane's header — on a 100,000-row diff
    /// that is a walk of the whole diff per frame, for a number that cannot change: the rows are
    /// `let`.
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

    // MARK: What a bounded diff can answer

    /// What asking for a diff produced.
    ///
    /// **Three outcomes, because "we stopped" and "we refused" are different things to tell a
    /// reader.** A refusal is a finding about the two files and belongs on screen beside the size
    /// and encoding notes; a cancellation is the surface going away, and must land nowhere at all.
    enum Attempt: Equatable {
        case diffed(TextPairDiff)
        /// The walk passed ``maxDiffWork`` before it finished — see ``refusalCaption``.
        case tooDifferent
        /// The task was cancelled. Nothing is known about the pair, and nothing may be drawn.
        case cancelled
    }

    // MARK: Cost

    /// The most work one line diff may do, in the units ``LineDiffWalker`` counts — one step of one
    /// diagonal of the edit graph.
    ///
    /// **A CEILING, not an estimate, and that is the whole change.** The walk counts as it goes and
    /// stops the moment it passes this, so the bound holds whatever shape the two files are in —
    /// including the shuffled ones ``estimatedCost(left:right:)`` prices at zero.
    ///
    /// **Calibrated to about two seconds of walk: 450,000,000 steps at a measured 230,000,000
    /// steps a second, on an Apple M4 (Mac16,13), Release build.** The number is stated in steps
    /// rather than seconds because that is what can be counted inside the loop — but a step bound
    /// is only worth having if steps and seconds are related, and here they are: the measured rate
    /// held between 222 and 238 million steps a second across every shape tried — 5,000 to 30,000
    /// lines a side, files with nothing in common, files shuffled end to end, and files half
    /// shared and reordered. A 7% spread over a 37× range of work is what makes "450 million steps"
    /// mean "about two seconds" rather than meaning nothing.
    ///
    /// What that budget buys, measured on the same machine: 15,000 shuffled lines a side diff in
    /// 1.87s, 20,000 lines with nothing in common in 1.72s, 10,000 shuffled in 0.83s. What it
    /// refuses: 20,000 shuffled (3.35s), 30,000 shuffled (7.37s), and everything above.
    ///
    /// **The cost of a ceiling this high is that a refusal takes it to reach.** A pair that is
    /// going to be refused spends the full ~2s finding that out, where a lower ceiling would have
    /// said so sooner. That is the right way round: the pair being refused is the rare one, and it
    /// is only refused after two seconds of genuine work on a background task the reader can close
    /// out from under. A ceiling low enough to refuse quickly refuses diffs worth having.
    static let maxDiffWork = 450_000_000

    /// A cheap estimate of what the Myers pass will cost on these two line arrays.
    ///
    /// Myers runs in O((N+M)·D), where D is the edit distance — so the cost turns on how DIFFERENT
    /// the files are, not how big they are. Two 100k-line files with fifty changed lines diff
    /// instantly; two 100k-line files with nothing in common do not. A cap on size alone would
    /// refuse the first and admit the second, which is backwards.
    ///
    /// D is estimated from the multiset difference — lines that appear on one side more often than
    /// on the other must each be edited — in one O(N+M) pass over two dictionaries.
    ///
    /// **A lower bound on D, so this is an ESTIMATE and not a bound on the cost** — a file with its
    /// paragraphs shuffled estimates 0 and is not free. It is kept as a PRE-FILTER only: the real
    /// bound is ``maxDiffWork``, counted inside the walk. What this still earns is refusing the
    /// enormous, entirely-different pair in one linear pass, before anything is interned or
    /// allocated — and it names the same finding, in the same words, that the ceiling does.
    static func estimatedCost(left: [String], right: [String]) -> Int {
        var counts: [String: Int] = [:]
        counts.reserveCapacity(left.count + right.count)
        for line in left { counts[line, default: 0] += 1 }
        for line in right { counts[line, default: 0] -= 1 }
        // Each unmatched line on either side is at least one edit.
        let distance = counts.values.reduce(0) { $0 + abs($1) }
        return (left.count + right.count) * distance
    }

    /// The most estimated work the pre-filter will wave through — see ``estimatedCost(left:right:)``
    /// and ``maxDiffWork``, which is the bound this only approximates.
    ///
    /// **Four times the real ceiling, and the factor is measured rather than chosen.** The two
    /// numbers count different things — this one is (N+M) times a lower bound on the edit distance,
    /// the other is steps actually taken — so a shared threshold would have one bound refusing what
    /// the other would happily finish. For the family this pre-filter exists to catch, files with
    /// little in common, the ratio is not approximate: at 5,000, 7,000, 10,000 and 20,000 lines a
    /// side of entirely different text, the estimate came to exactly 4.0× the steps the walk then
    /// took. So scaling by four is what makes the pre-filter refuse only pairs the walk would also
    /// refuse, instead of pre-empting it.
    ///
    /// It went unnoticed that this was the binding limit of the two: before the ceiling existed,
    /// this refused two 7,100-line files with nothing in common — 0.2s of work under the walk this
    /// now fronts.
    static let maxEstimatedCost = 4 * maxDiffWork

    /// Why these two files will not be diffed, or nil when the ESTIMATE has no objection.
    ///
    /// **A pre-filter, and a refusal here is final; a nil here is not a promise.** The walk itself
    /// may still refuse — see ``maxDiffWork`` — and says so in these same words, because it is the
    /// same finding: too different to be worth the wait.
    ///
    /// In the reader's words and in `BoundedTextRead.Outcome.caption`'s voice — it joins the same
    /// notes list, so a refusal here reads like the size and encoding refusals it sits beside.
    /// It names what it did instead of the number it exceeded: "too different" is the finding, and
    /// a reader given "estimated cost 4.1e10" learns nothing they can act on.
    static func refusalNote(left: [String], right: [String]) -> String? {
        guard estimatedCost(left: left, right: right) > maxEstimatedCost else { return nil }
        return refusalCaption
    }

    /// The one sentence a refused pair gets, whichever of the two bounds refused it.
    static let refusalCaption =
        "These two files are too large and too different to diff line by line — "
        + "the comparison would take minutes. The other modes still work."

    /// The budget for the INTRA-LINE passes, spent across the whole diff, in ``maxDiffWork``'s
    /// units.
    ///
    /// **The line ceiling above does not reach this one, and a single line is enough to prove it.**
    /// A 4 MiB file with no newlines in it — minified JavaScript, JSON saved in one line, a log
    /// whose writer never flushed one — is ONE line, so the line walk finishes in nothing flat and
    /// the row is then a changed row whose WORDS go through the same Myers: measured, that file
    /// holds ~800,000 words a side, where 8,000 already costs a second.
    ///
    /// Spent per row rather than capped per row, because both shapes run away: one enormous line,
    /// and thousands of ordinary changed lines each paying a little. Rows are served in order and
    /// what is left renders whole, so the budget lands where the reader is looking — the top of the
    /// pane — rather than being spread thin across a diff nobody scrolls to the end of.
    static let maxIntraLineWork = 100_000_000

    /// The most words a row may hold and still be offered a word pass.
    ///
    /// **A gate on the TOKENISING, not on the diff — and the diff's own budget cannot be it.**
    /// `words(_:)` allocates one String per word and is O(characters); on a 4 MiB single line that
    /// is ~800,000 allocations a side and ~158ms each way, spent BEFORE anything could look at the
    /// arrays and decline them. So the row is priced first, by counting whitespace runs over the
    /// UTF-8 without allocating anything (``wordCount(_:)``), and a line past this never becomes
    /// two String arrays at all.
    ///
    /// 10,000 words is a ~60 KB line — far past any line a person reads, and its worst case
    /// (everything changed) is exactly ``maxIntraLineWork``, so one pathological row can spend the
    /// whole budget but can never exceed it.
    static let maxWordsForIntraLine = 10_000

    // MARK: Building

    /// The diff of two line arrays, bounded and cancellable — what the surface calls.
    ///
    /// - Parameters:
    ///   - maxWork: the ceiling, in the walker's units. Passing `.max` asks for an unbounded walk,
    ///     which only a caller that has already bounded its input should do.
    ///   - isCancelled: asked once per step of the outer loop. `Task.isCancelled` at the call site,
    ///     so closing the surface stops the walk rather than merely discarding what it produces.
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

    /// The unbounded diff — for callers whose input is already small, and for tests.
    ///
    /// **Not what the surface calls.** With no ceiling this is the runaway H6 is about; every
    /// production path goes through ``bounded(left:right:maxWork:isCancelled:)``.
    static func make(left: [String], right: [String]) -> TextPairDiff {
        guard case .diffed(let diff) = bounded(left: left, right: right, maxWork: .max) else {
            // Unreachable: with no ceiling and no cancellation the walk has no other exit. An empty
            // diff rather than a trap, because a pane drawing nothing is survivable and a crash on
            // the user's own files is not.
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
                // **The alignment an edit script does not give.** A removal facing an insertion is
                // one edited line, not a delete above an add.
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
                // Reachable only if the script and the arrays disagree, which they cannot for a
                // script computed from these very arrays. Emitting the line rather than trapping:
                // a pane that showed one line fewer than the file has would be worse than one that
                // showed a line as unchanged.
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

    /// Numbers two arrays of strings so the walk can compare machine words.
    ///
    /// **Interning rather than hashing, and that is what makes collisions unwriteable.** A 64-bit
    /// hash of each line would be the obvious speed-up and would need every match re-checked
    /// against the strings themselves, because two different lines that hash alike would be
    /// reported as one. A dictionary already resolves collisions correctly — it compares the keys —
    /// so equal ids mean equal strings by construction, and the walk never touches a String again.
    ///
    /// One pass over each side, which is the same shape ``estimatedCost(left:right:)`` already pays.
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

    /// The intra-line pass, if the budget can still pay for it — otherwise `(nil, nil)`, which
    /// renders the row as changed with no word runs.
    ///
    /// **Priced before it is tokenised**, for the reason ``maxWordsForIntraLine`` gives, and then
    /// bounded by the same ceiling the line walk uses, so what is subtracted from the budget is the
    /// work actually done rather than an estimate of it.
    private static func segmentsWithinBudget(_ left: String, _ right: String,
                                             budget: inout Int, coarse: inout Int)
        -> ([Segment]?, [Segment]?) {
        let leftCount = wordCount(left), rightCount = wordCount(right)
        let words = leftCount + rightCount
        // The floor on any walk is one step per element, so a row this long cannot be afforded at
        // any edit distance — and it is refused without either line being split.
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

    /// The intra-line pass: which WORDS of a changed line changed.
    ///
    /// Word-level rather than character-level, deliberately. A character diff of a reflowed
    /// sentence marks nearly every character, which is visually the same as marking none; word
    /// runs are what a reader's eye follows, and they are what makes a one-word edit in a long
    /// line findable at all. Whitespace is carried inside the runs so the two sides still line up
    /// when rendered.
    static func segments(_ left: String, _ right: String) -> ([Segment], [Segment]) {
        segments(leftWords: words(left), rightWords: words(right))
    }

    /// The same pass over lines already tokenised — unbounded, so only for callers that have
    /// bounded the input themselves.
    static func segments(leftWords lw: [String], rightWords rw: [String])
        -> ([Segment], [Segment]) {
        let ids = interned(lw, rw)
        var walker = LineDiffWalker(a: ids.left, b: ids.right, maxWork: .max,
                                    isCancelled: { false })
        _ = walker.run()
        return (merge(lw, marked: walker.removed), merge(rw, marked: walker.inserted))
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

    /// How many runs ``words(_:)`` would produce, without producing any of them.
    ///
    /// **The point is the allocations it does not make.** `words` builds one String per word;
    /// counting is what prices a row, and pricing a 4 MiB line by tokenising it costs ~158ms a side
    /// before anything can decline the row. This walks the UTF-8 and allocates nothing.
    ///
    /// **ASCII whitespace, where `words` asks `Character.isWhitespace`** — so a line whose only
    /// separators are exotic (NBSP, U+2028) is counted as fewer runs than it has. That is a
    /// deliberate approximation and it is safe in both directions: this number only chooses between
    /// a word pass and a whole-line mark, and the walk it gates carries its own ceiling. Splitting
    /// graphemes to count them would be the cost this exists to avoid.
    static func wordCount(_ line: String) -> Int {
        // `words` starts a run at the first character and opens a new one at every non-space that
        // follows a space — so a leading indent is a run of its own, and a line of nothing but
        // spaces is one run. Counting split points reproduces that exactly.
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
/// ceiling and a cancellation check.
///
/// **Why it is written out here** is in ``TextPairDiff``'s own doc: `CollectionDifference` cannot
/// be stopped, and an estimate taken before it starts is a lower bound on a quantity that decides
/// minutes.
///
/// **The shape is the divide-and-conquer refinement from §4b of Myers' paper.** A forward frontier
/// from (0,0) and a reverse frontier from (N,M) are advanced together; the first time they overlap
/// they have found a snake that the optimal path passes through, and the problem splits around it.
/// Each half is solved the same way. Two frontiers of O(N+M) each is the whole memory, against the
/// O(D²) a traceback of the textbook version needs — 400 MB at the distance an ordinary 5,000-line
/// rewrite reaches, which is why the ceiling could not otherwise be set anywhere useful.
///
/// **An explicit stack rather than recursion.** The split can nest as deep as the edit distance,
/// and this runs on a task's stack, which is not the main thread's.
///
/// The output is two flag arrays — which offsets of `a` are removed, which offsets of `b` are
/// inserted — the same script `CollectionDifference` reports, in the form the row builder reads.
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
                // **The prefix and suffix come off first, at every level.** Most real pairs are
                // mostly the same file, and what is left after this is the small middle the walk
                // actually has to think about. It is also what makes the ceiling generous enough to
                // be worth having: the work counted is the work on the middle.
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
                    // Exactly one edit, and the ends have already been trimmed, so the sides differ
                    // in length by one and the shorter is the longer with one element taken out.
                    // Splitting around the snake would work too; naming the edit is cheaper and
                    // ends the recursion where it would otherwise be deepest.
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

            // The band a frontier can reach: diagonals outside [-M, N] leave the grid. Clamping it
            // is what keeps the walk O((N+M)·D) rather than O(D²), and the entries just outside are
            // poisoned so the "which neighbour did this path come from" rule cannot read a value
            // from an earlier region.
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
        // Unreachable: the two frontiers must meet by `maxDistance`, which is why the loop is
        // bounded by it. Refusing rather than trapping is the safe direction — the reader is told
        // the pair could not be diffed, which is true, instead of losing the app.
        throw Halt.refused
    }

    private mutating func spend(_ steps: Int) throws {
        work += steps
        if work > maxWork { throw Halt.refused }
    }
}

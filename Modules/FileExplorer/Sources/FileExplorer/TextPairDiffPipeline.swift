import Foundation

/// The one order in which two sides become a line diff, or a reason there is none.
///
/// **Lifted out of `CompareCopiesSheet.refreshTextDiff` so a second surface can use it rather than
/// copy it.** The editor's "what changed on disk?" overlay asks the same question about a buffer
/// and a file that the compare sheet asks about two files, and the ordering below is not
/// incidental — it is the stall guard:
///
/// 1. **Refuse a side that has no text at all**, naming which side and why, before anything is
///    split into lines.
/// 2. **The reading notes**, which are about how the bytes were decoded rather than what they say.
/// 3. **The cheap pre-filter** — one linear pass over two dictionaries — so an enormous pair with
///    nothing in common is refused *before* a line of either is interned. See
///    ``TextPairDiff/refusalNote(left:right:)``.
/// 4. **The bounded, cancellable walk**, and only then.
/// 5. **The coarse note**, which is a fact about the diff that was produced.
///
/// A copy of that sequence with steps 3 and 4 the other way round is a two-second stall on files
/// the pre-filter exists to wave off in microseconds, and nothing would fail — which is exactly why
/// it is one function now instead of two similar ones.
enum TextPairDiffPipeline {

    /// One pass's answer.
    ///
    /// **A CANCELLED pass is a fourth state and lands nowhere**: it knows nothing about the pair,
    /// so writing its empty notes would replace a real answer with silence.
    struct Outcome: Equatable {
        var diff: TextPairDiff?
        var notes: [String] = []
        var cancelled = false
    }

    /// The default names the refusals use for the two sides.
    ///
    /// **Parameters rather than literals, because the second caller's sides are not "left" and
    /// "right" in the reader's head.** The compare sheet is looking at two files side by side and
    /// "Left: too large to diff" is exactly right; the editor is looking at its own buffer beside
    /// the file on disk, where the same sentence would name a column instead of a thing.
    static let defaultLeftLabel = "Left"
    static let defaultRightLabel = "Right"

    /// Diffs two already-read sides. **Runs wherever it is called** — every production caller runs
    /// it inside a `Task.detached`, because the walk is real work and has no business on the actor
    /// that draws the window.
    ///
    /// - Parameter isCancelled: asked once per step of the outer loop, so closing the surface stops
    ///   the walk rather than merely discarding what it produces.
    static func diff(left: BoundedTextRead.Outcome,
                     right: BoundedTextRead.Outcome,
                     leftLabel: String = defaultLeftLabel,
                     rightLabel: String = defaultRightLabel,
                     isCancelled: @escaping () -> Bool) -> Outcome {
        var notes: [String] = []
        guard let leftText = left.string, let rightText = right.string else {
            if let caption = left.caption { notes.append("\(leftLabel): \(caption)") }
            if let caption = right.caption { notes.append("\(rightLabel): \(caption)") }
            return Outcome(diff: nil, notes: notes)
        }
        notes += BoundedTextRead.readingNotes(left: left, right: right)
        let leftLines = BoundedTextRead.lines(leftText)
        let rightLines = BoundedTextRead.lines(rightText)
        // The cheap pre-filter: two enormous files with nothing in common are refused in one
        // linear pass, before a line of either is interned. See ``TextPairDiff/refusalNote``.
        if let refusal = TextPairDiff.refusalNote(left: leftLines, right: rightLines) {
            notes.append(refusal)
            return Outcome(diff: nil, notes: notes)
        }
        // **The walk is bounded and it stops when the caller's task is cancelled**, which is what
        // the handles at the call sites exist for: closing the surface ends the work rather than
        // only discarding what it produced. See ``TextPairDiff/maxDiffWork``.
        switch TextPairDiff.bounded(left: leftLines, right: rightLines, isCancelled: isCancelled) {
        case .cancelled:
            return Outcome(diff: nil, cancelled: true)
        case .tooDifferent:
            // The same finding, in the same words, as the pre-filter's — the estimate is a lower
            // bound, so this is the one that catches a reordered file.
            notes.append(TextPairDiff.refusalCaption)
            return Outcome(diff: nil, notes: notes)
        case .diffed(let diff):
            // Rows the intra-line budget could not pay for are marked whole, and say so — see
            // ``TextPairDiff/maxIntraLineWork``.
            if let note = TextPairDiff.coarseNote(rows: diff.coarseRows) { notes.append(note) }
            return Outcome(diff: diff, notes: notes)
        }
    }
}

import Foundation

/// The one order in which two sides become a line diff, or a reason there is none. Shared by the
/// compare sheet and the editor's "what changed on disk?" overlay, because the order is the stall
/// guard:
///
/// 1. Refuse a side with no text, naming which and why, before anything is split into lines.
/// 2. The reading notes, about how the bytes were decoded.
/// 3. The cheap pre-filter, so a huge pair with nothing in common is refused before a line is
///    interned. See ``TextPairDiff/refusalNote(left:right:)``.
/// 4. The bounded, cancellable walk, only then.
/// 5. The coarse note, a fact about the diff produced.
///
/// Swapping steps 3 and 4 would stall two seconds on files the pre-filter waves off in
/// microseconds, and no test would fail.
enum TextPairDiffPipeline {

    /// One pass's answer. A cancelled pass lands nowhere: it knows nothing about the pair, so
    /// writing its empty notes would replace a real answer with silence.
    struct Outcome: Equatable {
        var diff: TextPairDiff?
        var notes: [String] = []
        var cancelled = false
    }

    /// The default names the refusals use for the two sides. Parameters, because the editor's
    /// sides are its buffer and the file on disk, not "Left" and "Right".
    static let defaultLeftLabel = "Left"
    static let defaultRightLabel = "Right"

    /// Diffs two already-read sides on the calling thread. Call it from a `Task.detached`, as every
    /// production caller does: the walk is real work and must stay off the main actor.
    ///
    /// - Parameter isCancelled: asked once per step of the outer loop, so closing the surface stops
    ///   the walk rather than discarding its result.
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
        // The cheap pre-filter: two huge files with nothing in common are refused in one linear
        // pass, before a line is interned. See ``TextPairDiff/refusalNote(left:right:)``.
        if let refusal = TextPairDiff.refusalNote(left: leftLines, right: rightLines) {
            notes.append(refusal)
            return Outcome(diff: nil, notes: notes)
        }
        // Bounded, and stops when the caller's task is cancelled, so closing the surface ends the
        // work. See ``TextPairDiff/maxDiffWork``.
        switch TextPairDiff.bounded(left: leftLines, right: rightLines, isCancelled: isCancelled) {
        case .cancelled:
            return Outcome(diff: nil, cancelled: true)
        case .tooDifferent:
            // The pre-filter's finding in its words. The estimate is a lower bound, so this is
            // what catches a reordered file.
            notes.append(TextPairDiff.refusalCaption)
            return Outcome(diff: nil, notes: notes)
        case .diffed(let diff):
            // Rows the intra-line budget couldn't pay for are marked whole, and say so. See
            // ``TextPairDiff/maxIntraLineWork``.
            if let note = TextPairDiff.coarseNote(rows: diff.coarseRows) { notes.append(note) }
            return Outcome(diff: diff, notes: notes)
        }
    }
}

import CoreGraphics
import Foundation

// MARK: - Modes

/// How the two sides are shown against each other. `1`–`4` pick them by position in the list the
/// surface is offering (see `digit(in:)`), which is derived from the pair's kind, so a digit can't
/// reach a segment that isn't on screen.
enum ComparePairMode: String, CaseIterable, Identifiable, Equatable {
    /// Both pages, side by side. The only mode a kind with no raster gets.
    case sideBySide
    /// One page over the other, revealed by a draggable divider.
    case swipe
    /// One page over the other, revealed by opacity.
    case onion
    /// The per-channel distance, light on black: identical is black, and any glow is a change.
    case difference
    /// The line diff, side by side — text pairs only, where the pixel modes have no meaning.
    case textDiff

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sideBySide: return "Side by side"
        case .swipe: return "Swipe"
        case .onion: return "Onion"
        case .difference: return "Difference"
        case .textDiff: return "Diff"
        }
    }

    var symbol: String {
        switch self {
        case .sideBySide: return "rectangle.split.2x1"
        case .swipe: return "square.righthalf.filled"
        case .onion: return "circle.lefthalf.filled"
        case .difference: return "square.on.square.dashed"
        case .textDiff: return "text.alignleft"
        }
    }

    /// The mode's position in the list the surface is offering, not in the declaration. A text pair
    /// offers two modes, so `2` there must mean the second of those, or the keyboard reaches a
    /// segment that isn't on screen.
    func digit(in available: [ComparePairMode]) -> Int? {
        available.firstIndex(of: self).map { $0 + 1 }
    }

    /// The mode a digit selects out of what is offered, or nil for a digit past the end.
    static func forDigit(_ digit: Int, in available: [ComparePairMode]) -> ComparePairMode? {
        guard digit >= 1, digit <= available.count else { return nil }
        return available[digit - 1]
    }

    /// The modes available for a pair kind. A kind with neither a raster nor lines gets exactly
    /// one, and then the segmented control isn't drawn at all.
    static func available(for kind: PairContentKind) -> [ComparePairMode] {
        switch kind {
        case .pdf, .image: return [.sideBySide, .swipe, .onion, .difference]
        case .text: return [.sideBySide, .textDiff]
        case .other: return [.sideBySide]
        }
    }

    /// The caveat a mode owes the reader. `.difference` always carries one: two scans of the same
    /// sheet glow everywhere from scanner noise, which without the line reads as content.
    var caveat: String? {
        switch self {
        case .difference:
            return "Compared at pixel level, with no alignment — two scans of the same page will glow all over."
        case .sideBySide, .swipe, .onion, .textDiff:
            return nil
        }
    }
}

// MARK: - Pairing two documents of different lengths

/// How two documents' pages line up when they have different numbers of them.
///
/// The strip is as long as the longer side, and the shorter side pins at its last page. Truncating
/// to the shorter side would hide the pages only one document has, often the most interesting part
/// of a "versions" pair; a blank pane past the end would read as a failed render. A pinned page
/// plus a chip that says so states what is true.
struct PagePairing: Equatable {
    let leftPages: Int
    let rightPages: Int

    /// How many entries the strip has.
    var stripLength: Int { max(0, max(leftPages, rightPages)) }

    var lengthsDiffer: Bool { leftPages != rightPages }

    /// The page index to render on the left for strip position `index`, clamped to its last page.
    func leftIndex(at index: Int) -> Int { Self.clamp(index, pages: leftPages) }
    func rightIndex(at index: Int) -> Int { Self.clamp(index, pages: rightPages) }

    /// True when this side has run out of pages and is showing its last one again.
    func leftIsPinned(at index: Int) -> Bool { index >= leftPages && leftPages > 0 }
    func rightIsPinned(at index: Int) -> Bool { index >= rightPages && rightPages > 0 }

    /// Whether a diff at this strip position compares two real pages. A pinned side is the same
    /// page measured against a different one, not a comparison, so its dot must not claim "changed"
    /// or "same".
    func isComparable(at index: Int) -> Bool {
        !leftIsPinned(at: index) && !rightIsPinned(at: index)
            && leftPages > 0 && rightPages > 0
    }

    private static func clamp(_ index: Int, pages: Int) -> Int {
        guard pages > 0 else { return 0 }
        return min(max(0, index), pages - 1)
    }

    /// The line the strip prints when the two documents are different lengths, or nil when they
    /// aren't. Named counts, not "different lengths": the number is the finding.
    var lengthNote: String? {
        guard lengthsDiffer else { return nil }
        return "\(leftPages) page\(leftPages == 1 ? "" : "s") on the left, "
            + "\(rightPages) on the right — the shorter side stops at its last page."
    }
}

// MARK: - Whether there is anything to draw

/// Which side of the pair a message is about.
enum PairSide: Equatable {
    case left, right
}

/// Whether the current page's two rasters could be built at all.
///
/// "Not yet" and "not ever" are separate states. A raster that can't be built (a corrupt JPEG, an
/// encrypted PDF, a page that won't draw) must end the wait with a message, or the pixel modes spin
/// for the life of the surface while the page strip below already shows the page as
/// `.unrenderable`. Every decodable format has corrupt files, so this case is real.
enum PairRenderOutcome: Equatable {
    /// No answer yet — a render is in flight, or none has been asked for.
    case rendering
    /// Both sides produced a raster.
    case ready
    /// At least one side could not be rendered. Both flags false is not representable in practice
    /// and would read as `.ready`; ``failed(left:right:)`` is only built where one of them is true.
    case failed(left: Bool, right: Bool)

    var didFail: Bool {
        if case .failed = self { return true }
        return false
    }

    /// Whether this particular side is the one that could not be rendered.
    func failed(_ side: PairSide) -> Bool {
        guard case .failed(let left, let right) = self else { return false }
        return side == .left ? left : right
    }

    /// What a pane with no image should draw: keep waiting, or say why the wait is over. The message
    /// names the file, not the side: the reader is looking at two similarly named files, and "the
    /// left copy" doesn't say which one won't open.
    func fallback(for side: PairSide, name: String) -> PairPaneFallback {
        failed(side) ? .message("“\(name)” could not be rendered.") : .spinner
    }

    /// The line the difference view draws instead of a picture, or nil while it should still wait.
    /// A comparison needs both sides, so one unrenderable side ends it, and the sentence says so
    /// rather than leaving an empty black field.
    func differenceMessage(leftName: String, rightName: String) -> String? {
        guard case .failed(let left, let right) = self else { return nil }
        switch (left, right) {
        case (true, true):
            return "Neither copy could be rendered, so there is nothing to compare."
        case (true, false):
            return "“\(leftName)” could not be rendered, so there is nothing to compare."
        default:
            return "“\(rightName)” could not be rendered, so there is nothing to compare."
        }
    }
}

/// What a pane draws when it has no image.
enum PairPaneFallback: Equatable {
    case spinner
    case message(String)
}

// MARK: - Whether the typed viewer can be mounted yet

/// Whether a pair that earns a typed viewer is still waiting on the facts that decide it.
///
/// A rule rather than a `body` expression, because getting it wrong shows as a permanent spinner.
/// Each kind waits on something different: a PDF on its page counts, an image on its first raster.
/// A side that isn't downloaded isn't waiting at all: it has a placeholder pane with a Download
/// button, and a spinner over it would hide the only control that fixes it.
enum TypedViewerReadiness {

    /// - Parameters:
    ///   - sidesClassified: both sides have been probed (cloud-only, missing, or readable).
    ///   - pageCountsResolved: the PDF page counts have landed. Meaningless for other kinds.
    ///   - bothSidesReadable: both sides have content on disk to render.
    ///   - outcome: whether the current page's rasters are in flight, up, or never coming.
    ///   - hasRasters: both sides already have an image to draw, whatever the outcome says now.
    static func isStillResolving(kind: PairContentKind,
                                 sidesClassified: Bool,
                                 pageCountsResolved: Bool,
                                 bothSidesReadable: Bool,
                                 outcome: PairRenderOutcome,
                                 hasRasters: Bool) -> Bool {
        guard sidesClassified else { return true }
        switch kind {
        case .pdf:
            return !pageCountsResolved
        case .image:
            // Waiting and with nothing to show. Leaving a pixel mode re-keys the raster task, so the
            // outcome drops back to `.rendering` for a decode of the same file; on the outcome alone
            // the pane would blank to a spinner on every `1`–`4` press.
            //
            // `bothSidesReadable` because the raster refresh bails without it, leaving the outcome
            // at `.rendering` for ever: a cloud-only side would spin here instead of falling through
            // to the pane that offers to download it.
            return bothSidesReadable && outcome == .rendering && !hasRasters
        case .text, .other:
            // No typed viewer to wait for. The caller gates on `hasSyncedViewer`, so this isn't
            // asked; answered rather than trapped, so a kind gaining a viewer can't crash here.
            return false
        }
    }
}

// MARK: - One strip entry's verdict

/// What the page strip knows about one position.
///
/// `.pending` is a state, not a missing `.same`. A position whose comparison hasn't run draws no dot
/// at all (see ``dot``): showing "same" while the render is still queued would be an unchecked claim,
/// on a surface whose next button trashes a file.
enum PageDiffState: Equatable {
    /// Not compared yet.
    case pending
    /// Compared, and nothing changed beyond the anti-alias tolerance.
    case same
    /// Compared, and this fraction of the page changed.
    case changed(fraction: Double)
    /// Only one side has this page — nothing to compare.
    case oneSided
    /// A side could not be rendered at all.
    case unrenderable

    var isResolved: Bool { self != .pending }

    /// Which of the strip's four dot meanings this state carries, or nil where no dot is drawn.
    ///
    /// `.pending` has no dot, by rule. A grey dot under every page, as in side-by-side mode where no
    /// comparison runs, would read as "checked, and unremarkable" rather than "not checked". The
    /// number alone is the resting state, so a dot appearing is a real event.
    ///
    /// A value rather than a colour chosen in the chip's `body`, so `PageStrip`'s tooltip can switch
    /// on the same four meanings for a reader who can't tell the colours apart.
    var dot: Dot? {
        switch self {
        case .pending: return nil
        case .same: return .same
        case .changed: return .changed
        case .oneSided: return .oneSided
        case .unrenderable: return .unrenderable
        }
    }

    /// The dot's four meanings. Named here, each with its own shape; `PageStrip` adds the colour
    /// (`tint`, beside the view), so the meaning and the paint stay separable.
    enum Dot: Equatable, CaseIterable {
        case same, changed, oneSided, unrenderable

        /// A shape of its own for each meaning, so the strip doesn't rely on colour alone: a tick
        /// for "no visible difference", the dot for "changed" (the one worth stopping at), half a
        /// circle for "only one side has it", and a cross for "couldn't be rendered".
        var symbol: String {
            switch self {
            case .same: return "checkmark"
            case .changed: return "circle.fill"
            case .oneSided: return "circle.lefthalf.filled"
            case .unrenderable: return "xmark"
            }
        }
    }

    static func from(_ result: BitmapDiffResult?) -> PageDiffState {
        guard let result else { return .unrenderable }
        return result.isIdentical ? .same : .changed(fraction: result.changedFraction)
    }
}

// MARK: - Reusing a page comparison across a mode change

/// Whether the page comparison already in hand answers what the mode on screen is asking.
///
/// A value, because a key alone gets this wrong. A mode change re-runs the render task, but the
/// comparison depends only on the page and whether the de-skew was applied. An equality key on both
/// would recompute in both directions, and going down is the harmful one: leaving the difference
/// mode for swipe would replace an aligned answer with a weaker one, and the page's dot could
/// change colour under a mode press.
///
/// So: same page, and either what is held is already aligned or this mode doesn't want alignment.
enum PageComparisonReuse {

    /// - Parameters:
    ///   - held: the decode the comparison in hand was made from, or nil when there is none.
    ///   - decode: the decode on screen now.
    ///   - heldAligned: whether the comparison in hand had the de-skew applied.
    ///   - wantsAligned: whether the mode on screen wants it.
    static func isEnough(held: String?, decode: String,
                         heldAligned: Bool, wantsAligned: Bool) -> Bool {
        guard let held, held == decode else { return false }
        return heldAligned || !wantsAligned
    }
}

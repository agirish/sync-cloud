import CoreGraphics
import Foundation

// MARK: - Modes

/// How the two sides are shown against each other.
///
/// `1`–`4` select them from the keyboard, by position in the list the surface is OFFERING — see
/// `digit(in:)`. The offered list is derived from the pair's kind, so a digit can never reach a
/// segment that is not on screen.
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

    /// **The digit is the mode's position in the list the surface is OFFERING, not its position in
    /// the declaration.** A text pair offers two modes; `2` there has to mean the second of those
    /// two, not the second of the four a PDF gets — otherwise the keyboard reaches a segment that
    /// is not on screen, or skips one that is.
    func digit(in available: [ComparePairMode]) -> Int? {
        available.firstIndex(of: self).map { $0 + 1 }
    }

    /// The mode a digit selects out of what is offered, or nil for a digit past the end.
    static func forDigit(_ digit: Int, in available: [ComparePairMode]) -> ComparePairMode? {
        guard digit >= 1, digit <= available.count else { return nil }
        return available[digit - 1]
    }

    /// The modes available for a pair kind. A kind with neither a raster nor lines gets exactly
    /// one, and the segmented control is then not drawn at all rather than drawn with one segment.
    static func available(for kind: PairContentKind) -> [ComparePairMode] {
        switch kind {
        case .pdf, .image: return [.sideBySide, .swipe, .onion, .difference]
        case .text: return [.sideBySide, .textDiff]
        case .other: return [.sideBySide]
        }
    }

    /// The caveat a mode owes the reader. **`.difference` always carries one**: two scans of the
    /// same sheet of paper glow everywhere from scanner noise, and without the line that reads as
    /// content.
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
/// **The strip is as long as the longer side, and the shorter side pins at its last page.** The
/// alternatives are worse in ways worth naming: truncating the strip to the shorter side hides the
/// pages that exist on only one document — which for a "versions" pair is the most interesting
/// thing about it — and showing a blank pane past the end reads as a failed render rather than as
/// the end of the document. A pinned page plus a chip that says so is the only one of the three
/// that states what is true.
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

    /// Whether a diff at this strip position compares two real pages. **A pinned side is not a
    /// comparison** — it is the same page measured against a different one — so a strip dot there
    /// must not claim "changed" or "same".
    func isComparable(at index: Int) -> Bool {
        !leftIsPinned(at: index) && !rightIsPinned(at: index)
            && leftPages > 0 && rightPages > 0
    }

    private static func clamp(_ index: Int, pages: Int) -> Int {
        guard pages > 0 else { return 0 }
        return min(max(0, index), pages - 1)
    }

    /// The line the strip prints when the two documents are different lengths, or nil when they
    /// are not. Named counts rather than "different lengths": the number IS the finding.
    var lengthNote: String? {
        guard lengthsDiffer else { return nil }
        return "\(leftPages) page\(leftPages == 1 ? "" : "s") on the left, "
            + "\(rightPages) on the right — the shorter side stops at its last page."
    }
}

// MARK: - One strip entry's verdict

/// What the page strip knows about one position.
///
/// **`.pending` is a state, not a missing `.same`.** A dot that renders grey until its diff lands
/// and green afterwards is honest; one that renders "same" while the render is still queued behind
/// a scan is a claim nobody has checked, on a surface whose next button trashes a file.
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

    static func from(_ result: BitmapDiffResult?) -> PageDiffState {
        guard let result else { return .unrenderable }
        return result.isIdentical ? .same : .changed(fraction: result.changedFraction)
    }
}

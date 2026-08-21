import Foundation

/// How a Storage Lens row says how big it is *without being read* — the bar behind it and the
/// share-of-scan figure beside its size.
///
/// Pure, and separate from the view, for the reason `StorageSection.counts` is: these are the
/// three decisions a rendered row cannot be asked about directly. A geometry probe can say a bar
/// is painted; only this can say it is the right length, that `<1%` is reached rather than a
/// rounded-to-nothing `0%`, and that the age-ordered list is deliberately without one.
enum StorageMagnitude {

    /// Whether this section's rows draw a magnitude bar.
    ///
    /// **Only the size-ordered lists.** `largest` and `reclaimCandidates` both arrive largest-first
    /// (`StorageLens.swift:47,51`), so a bar that shrinks down the list restates the order the eye
    /// is already following and the two agree. `stale` arrives *oldest*-first, and a size bar there
    /// would descend and rise against a ranking it has nothing to do with — the reader's first
    /// reading of a bar chart is that it is sorted by the bar.
    ///
    /// The **share** figure is not gated this way and appears on every row: "this file is 18% of
    /// what was scanned" is a fact about the file, true in whatever order it is listed.
    static func showsBar(_ section: StorageSection) -> Bool {
        switch section {
        case .largest, .reclaim: return true
        case .stale: return false
        }
    }

    /// The bar's length as a fraction of the row, against the **largest entry in the whole
    /// section** rather than the largest currently on screen.
    ///
    /// That choice is the one thing here a reader could notice being wrong. Scaling to the visible
    /// maximum makes every bar rescale as a query is typed — filter away the 900 MB file and the
    /// 90 MB one grows to full width, so the same file draws two different magnitudes in one
    /// session and neither is labelled. Against the section maximum a query only ever *removes*
    /// rows; the ones that remain keep the length they had.
    static func fraction(bytes: Int, largestBytes: Int) -> Double {
        guard largestBytes > 0, bytes > 0 else { return 0 }
        return min(1, Double(bytes) / Double(largestBytes))
    }

    /// This file as a percentage of every byte the scan measured — `nil` when there is nothing
    /// truthful to say (an empty scan, or a zero-byte file, which is 0% of anything).
    ///
    /// **Rounds away from zero, not to it.** A 3 MB file in a 2 GB tree is 0.15%, and `0%` claims
    /// the file is not there; `<1%` says it is small, which is the honest version of the same
    /// figure and the only reason this returns a string rather than a number.
    static func shareText(bytes: Int, ofTotal totalBytes: Int) -> String? {
        guard totalBytes > 0, bytes > 0 else { return nil }
        let percent = min(100, Double(bytes) / Double(totalBytes) * 100)
        if percent < 0.5 { return "<1%" }
        return "\(Int(percent.rounded()))%"
    }

    /// Whether a row's two quiet glyphs — Quick Look and Reveal in Finder — are showing.
    ///
    /// Hover *or* keyboard focus, and the second half is the load-bearing one. The glyphs rest at
    /// `opacity(0)`, which in SwiftUI removes neither hit-testing nor the accessibility element
    /// and — unlike `.hidden()` or an `if` — leaves the button in AppKit's key-view loop, so Full
    /// Keyboard Access still reaches it. Without this the ring would land on a control nobody can
    /// see; with it, focusing the row's glyph is what reveals the glyph.
    static func controlsRevealed(isHovered: Bool, isFocused: Bool) -> Bool {
        isHovered || isFocused
    }
}

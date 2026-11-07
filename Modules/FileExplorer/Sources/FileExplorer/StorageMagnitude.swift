import Foundation

/// How a Storage Lens row shows its size at a glance: the bar behind it and the share-of-scan
/// figure beside its size. Pure, like `StorageSection.counts`, so tests can check the bar's
/// length, the `<1%` floor and the barless age list, which a rendered row can't answer.
enum StorageMagnitude {

    /// Whether this section's rows draw a magnitude bar: only the size-ordered lists. `largest`
    /// and `reclaimCandidates` arrive largest-first (`StorageLensReport`), so the bar agrees with
    /// the order; `stale` is oldest-first, and a size bar there would read as the sort key.
    ///
    /// The share figure appears on every row: it is a fact about the file in any order.
    static func showsBar(_ section: StorageSection) -> Bool {
        switch section {
        case .largest, .reclaim: return true
        case .stale: return false
        }
    }

    /// The bar's length as a fraction of the row, against the largest entry in the whole section,
    /// not the largest on screen. Scaled to the visible maximum, bars would rescale as a query is
    /// typed; this way a query only removes rows and the rest keep their length.
    static func fraction(bytes: Int, largestBytes: Int) -> Double {
        guard largestBytes > 0, bytes > 0 else { return 0 }
        return min(1, Double(bytes) / Double(largestBytes))
    }

    /// This file as a percentage of every byte the scan measured, or `nil` for an empty scan or a
    /// zero-byte file. Rounds away from zero: below 0.5% it says `<1%`, because `0%` would claim
    /// the file isn't there. That is why it returns a string.
    static func shareText(bytes: Int, ofTotal totalBytes: Int) -> String? {
        guard totalBytes > 0, bytes > 0 else { return nil }
        let percent = min(100, Double(bytes) / Double(totalBytes) * 100)
        if percent < 0.5 { return "<1%" }
        return "\(Int(percent.rounded()))%"
    }

    /// Whether a row's two quiet glyphs, Quick Look and Reveal in Finder, are showing: on hover or
    /// keyboard focus. Focus matters because `opacity(0)`, unlike `.hidden()` or an `if`, leaves
    /// the button in the key-view loop, so Full Keyboard Access would ring an invisible control.
    static func controlsRevealed(isHovered: Bool, isFocused: Bool) -> Bool {
        isHovered || isFocused
    }
}

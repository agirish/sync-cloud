import AppKit

/// **A list keeps its `NSTextList` across re-reads** (review, 2026-10-09).
///
/// TextKit numbers a list's items by the identity of the `NSTextList` in their paragraph style, and
/// every projection makes new ones. So a list the re-read touched came back as a new list, and was
/// replaced whole — in the projection's rendering, in the decoration and in the view — at every
/// keystroke in it: 340 ms on a 256 KB note that is one long list, four times a whole re-read.
///
/// Here the re-read part takes the lists of the part it replaces, where each new list continues
/// one old one, and only what differs is replaced. Where a list is new — split from another, two
/// joined — ``wholeLists(around:in:against:)`` takes it whole.
enum PreviewListIdentity {

    /// `new` put in place of `window` of `old`, as little of it as differs: the range of `old` to
    /// replace, and what with. Each list in the replacement is given the old list its items outside
    /// the replacement are in, so the lists read on as one. A list split in two, or two joined,
    /// differs from the first item whose list no longer pairs, so the pairing is never ambiguous.
    static func patch(_ old: NSAttributedString, window: NSRange, with new: NSAttributedString)
        -> (range: NSRange, text: NSAttributedString) {
        guard let difference = PreviewAttributeShape.difference(from: old, in: window, to: new) else {
            return (NSRange(location: window.location, length: 0), NSAttributedString())
        }
        let piece = NSMutableAttributedString(attributedString: new.attributedSubstring(from: difference.new))
        let map = difference.lists
        guard !map.isEmpty else { return (difference.old, piece) }
        var restyled: [ObjectIdentifier: NSParagraphStyle] = [:]
        piece.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: piece.length)) { value, run, _ in
            guard let style = value as? NSParagraphStyle,
                  style.textLists.contains(where: { map[ObjectIdentifier($0)] != nil }) else { return }
            let replacement = restyled[ObjectIdentifier(style)] ?? {
                let copy = style.mutableCopy() as! NSMutableParagraphStyle
                copy.textLists = style.textLists.map { map[ObjectIdentifier($0)] ?? $0 }
                return copy
            }()
            restyled[ObjectIdentifier(style)] = replacement
            piece.addAttribute(.paragraphStyle, value: replacement, range: run)
        }
        return (difference.old, piece)
    }

    /// `range` of `fresh` widened so that no list is left half one `NSTextList` and half another
    /// once `fresh`'s `range` replaces what `old` holds there. `old` is `fresh` with `range` changed:
    /// the same before it, and after it. A list `range` touches or borders is taken whole where
    /// `old` holds any of its other items as another list — never where the re-read kept the list's
    /// identity, which ``patch(_:window:with:)`` does wherever it can.
    static func wholeLists(around range: NSRange, in fresh: NSAttributedString,
                           against old: NSAttributedString) -> NSRange {
        var touched = Set<ObjectIdentifier>()
        let lower = max(0, range.location - 1), upper = min(fresh.length, NSMaxRange(range) + 1)
        guard upper > lower else { return range }
        fresh.enumerateAttribute(.paragraphStyle, in: NSRange(location: lower, length: upper - lower)) { value, _, _ in
            if let list = (value as? NSParagraphStyle)?.textLists.first { touched.insert(ObjectIdentifier(list)) }
        }
        guard !touched.isEmpty else { return range }
        // Where `old` holds `fresh`'s characters after `range`.
        let shift = old.length - fresh.length
        var extents: [ObjectIdentifier: NSRange] = [:]
        var split = Set<ObjectIdentifier>()
        fresh.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: fresh.length)) { value, run, _ in
            guard let lists = (value as? NSParagraphStyle)?.textLists, let first = lists.first,
                  touched.contains(ObjectIdentifier(first)) else { return }
            let key = ObjectIdentifier(first)
            extents[key] = extents[key].map { NSUnionRange($0, run) } ?? run
            guard !split.contains(key) else { return }
            // The run's characters outside `range`, as `old` holds them.
            var kept: [NSRange] = []
            if run.location < range.location {
                kept.append(NSRange(location: run.location, length: min(NSMaxRange(run), range.location) - run.location))
            }
            if NSMaxRange(run) > NSMaxRange(range) {
                let start = max(run.location, NSMaxRange(range))
                kept.append(NSRange(location: start + shift, length: NSMaxRange(run) - start))
            }
            for part in kept where !split.contains(key) {
                old.enumerateAttribute(.paragraphStyle, in: part) { value, _, stop in
                    let olds = (value as? NSParagraphStyle)?.textLists ?? []
                    if olds.count != lists.count || zip(olds, lists).contains(where: { $0 !== $1 }) {
                        split.insert(key)
                        stop.pointee = true
                    }
                }
            }
        }
        return split.reduce(range) { NSUnionRange($0, extents[$1] ?? $0) }
    }
}

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
    /// identity, which ``patch(_:window:with:)`` does wherever it can. `widen` is applied after
    /// each list taken in — the decoration's whole paragraphs — and the two are repeated until
    /// neither widens the range.
    ///
    /// **One pass over `fresh`, however many rounds** (review, 2026-10-09). Each round enumerated
    /// the whole rendering, and where a whole re-read had made every list anew, each round pulled
    /// in only the next list: a note of adjacent lists took one pass per list. The lists' runs are
    /// read once now, and whether each is split is decided once, against `range` as given — a
    /// wider range only compares fewer of its items, so that answer can only replace more.
    ///
    /// **And a list `old` holds at the range's edge is `fresh`'s wherever `old` keeps it**
    /// (2026-10-12). `- the` … `- the` split in two by a Source edit, with an opened paragraph
    /// above, compared its far item first, took the old list and the new second one for one, and
    /// kept it — so both halves stayed one list on screen (seed 1737 of the session chains). From
    /// `fresh` alone nothing was split: the first half was the old list in full, and the second a
    /// list the range never reached, past a quote that carries no list. So each round also asks,
    /// of every run outside the range, whether `old` holds one of the lists at the range's edge
    /// there under another list — one lookup a run, never `old` read whole: reading the view's
    /// storage whole was a third of a keystroke in a note that is one long list (measured).
    static func wholeLists(around range: NSRange, in fresh: NSAttributedString, against old: NSAttributedString,
                           widening widen: (NSRange) -> NSRange = { $0 }) -> NSRange {
        func bordered(_ range: NSRange) -> NSRange {
            let lower = max(0, range.location - 1), upper = min(fresh.length, NSMaxRange(range) + 1)
            return NSRange(location: lower, length: max(0, upper - lower))
        }
        // The common case, read locally: no list beside the change, nothing to widen.
        var near = false
        let border = bordered(range)
        if border.length > 0 {
            fresh.enumerateAttribute(.paragraphStyle, in: border) { value, _, stop in
                if (value as? NSParagraphStyle)?.textLists.first != nil { near = true; stop.pointee = true }
            }
        }
        // …nor in `old` beside it, where a list may have been taken away.
        let shift = old.length - fresh.length
        let oldEdge = NSIntersectionRange(NSRange(location: border.location, length: border.length + shift),
                                          NSRange(location: 0, length: old.length))
        if !near, oldEdge.length > 0 {
            old.enumerateAttribute(.paragraphStyle, in: oldEdge) { value, _, stop in
                if (value as? NSParagraphStyle)?.textLists.first != nil { near = true; stop.pointee = true }
            }
        }
        guard near else { return range }

        // Every list's runs, by its outermost `NSTextList`, in order.
        var runs: [ObjectIdentifier: [NSRange]] = [:]
        var lists: [ObjectIdentifier] = []
        fresh.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: fresh.length)) { value, run, _ in
            guard let first = (value as? NSParagraphStyle)?.textLists.first else { return }
            let key = ObjectIdentifier(first)
            if runs[key] == nil { lists.append(key) }
            runs[key, default: []].append(run)
        }
        // `shift`: where `old` holds `fresh`'s characters after `range`.
        var split: [ObjectIdentifier: Bool] = [:]
        func isSplit(_ key: ObjectIdentifier) -> Bool {
            if let known = split[key] { return known }
            var found = false
            for run in runs[key] ?? [] where !found {
                guard let lists = (fresh.attribute(.paragraphStyle, at: run.location, effectiveRange: nil)
                                   as? NSParagraphStyle)?.textLists else { continue }
                // The run's characters outside `range`, as `old` holds them.
                var kept: [NSRange] = []
                if run.location < range.location {
                    kept.append(NSRange(location: run.location, length: min(NSMaxRange(run), range.location) - run.location))
                }
                if NSMaxRange(run) > NSMaxRange(range) {
                    let start = max(run.location, NSMaxRange(range))
                    kept.append(NSRange(location: start + shift, length: NSMaxRange(run) - start))
                }
                for part in kept where !found {
                    old.enumerateAttribute(.paragraphStyle, in: part) { value, _, stop in
                        let olds = (value as? NSParagraphStyle)?.textLists ?? []
                        if olds.count != lists.count || zip(olds, lists).contains(where: { $0 !== $1 }) {
                            found = true
                            stop.pointee = true
                        }
                    }
                }
            }
            split[key] = found
            return found
        }
        // Each list from its first item to its last, in order. One list's items do not stand among
        // another's, so these follow one another, and a round finds the lists beside its range by
        // halving — or, should they ever not, by reading them all.
        let extents = lists.map { key -> NSRange in
            let mine = runs[key]!
            return NSRange(location: mine[0].location, length: NSMaxRange(mine[mine.count - 1]) - mine[0].location)
        }
        let ordered = zip(extents, extents.dropFirst()).allSatisfy { NSMaxRange($0) <= $1.location }
        var current = range
        var taken = Set<ObjectIdentifier>()
        while true {
            let border = bordered(current)
            var widened = current
            var at = 0
            if ordered {
                var high = extents.count
                while at < high {
                    let mid = (at + high) / 2
                    if NSMaxRange(extents[mid]) <= border.location { at = mid + 1 } else { high = mid }
                }
            }
            while at < extents.count, !ordered || extents[at].location < NSMaxRange(border) {
                let key = lists[at], extent = extents[at]
                at += 1
                guard !taken.contains(key), extent.location < NSMaxRange(border), NSMaxRange(extent) > border.location,
                      runs[key]!.contains(where: { NSIntersectionRange($0, border).length > 0 }), isSplit(key)
                else { continue }
                taken.insert(key)
                widened = NSUnionRange(widened, extent)
            }
            // `old`'s lists at the edge, and each run outside the range where `old` holds one of
            // them under a list of `fresh`'s that is not it.
            var edge = Set<ObjectIdentifier>()
            let oldBorder = NSIntersectionRange(NSRange(location: border.location, length: border.length + shift),
                                                NSRange(location: 0, length: old.length))
            if oldBorder.length > 0 {
                old.enumerateAttribute(.paragraphStyle, in: oldBorder) { value, _, _ in
                    if let first = (value as? NSParagraphStyle)?.textLists.first { edge.insert(ObjectIdentifier(first)) }
                }
            }
            if !edge.isEmpty {
                for (index, key) in lists.enumerated() where !taken.contains(key) {
                    let strays = runs[key]!.contains { run in
                        guard NSMaxRange(run) <= current.location || run.location >= NSMaxRange(current) else { return false }
                        let at = run.location < current.location ? run.location : run.location + shift
                        guard at < old.length, let held = (old.attribute(.paragraphStyle, at: at, effectiveRange: nil)
                                                           as? NSParagraphStyle)?.textLists.first else { return false }
                        return edge.contains(ObjectIdentifier(held)) && ObjectIdentifier(held) != key
                    }
                    if strays {
                        taken.insert(key)
                        widened = NSUnionRange(widened, extents[index])
                    }
                }
            }
            widened = widen(widened)
            if widened == current { return current }
            current = widened
        }
    }
}

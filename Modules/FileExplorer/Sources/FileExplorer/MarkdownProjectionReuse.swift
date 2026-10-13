import AppKit

/// **Re-reading only what an edit touched** (TE67 §3.7, measured 2026-10-07).
///
/// A full projection costs about 20 ms on a 40 KB note and 130 ms at 256 KB, and the editable
/// preview made one on every keystroke. This re-reads the document-level blocks the edit touched,
/// with one untouched block either side, and keeps the rest of the old projection, moved by the
/// edit's length.
///
/// **It is only ever an optimisation: when it cannot show the result is the full projection's, it
/// makes the full one.** The block after the edit is the proof: it must come back from the re-read
/// exactly as it was, so an edit that reached past its own blocks — a fence that now runs on, an
/// HTML block opened — is caught at the first block it changed. It also declines
/// outright where a block's meaning comes from elsewhere in the file: link reference definitions,
/// which reach across the whole document, and front matter, which the first line decides.
/// `PreviewEditPropertyTests` holds it to the full projection on every random edit.
extension MarkdownProjection {

    /// `source` projected, re-reading only what changed since `previous` where that is provably the
    /// same as projecting it whole.
    static func project(_ source: String, style: Style = Style(), after previous: MarkdownProjection?)
        -> MarkdownProjection {
        guard let previous else { return project(source, style: style) }
        let declined: String
        if previous.style == style {
            switch previous.reread(source) {
            case .success(let reused): return reused
            case .failure(let reason): declined = reason.why
            }
        } else {
            declined = "style"
        }
        var whole = project(source, style: style)
        whole.reuse = .whole(declined)
        return whole
    }

    /// How a projection was made from the one before it — for the `[edit]` log line, which has to
    /// say why a slow keystroke was slow, and for the tests, which hold every path to being taken.
    enum Reuse: Equatable, CustomStringConvertible {
        /// The same source: the projection before, as it was.
        case unchanged
        /// Re-read in part — with the block before the edit re-read too, or none where the edit is
        /// in the first; proved by the block after it, or none where it is in the last; and after
        /// front matter, or not.
        case partial(left: Bool, right: Bool, frontMatter: Bool)
        /// Re-read whole, and why the part would not do.
        case whole(String)

        var description: String {
            switch self {
            case .unchanged: return "unchanged"
            case .partial: return "partial"
            case .whole(let why): return "whole(\(why))"
            }
        }
    }

    /// Why a part re-read would not do.
    struct Decline: Error { var why: String }

    /// How a projection came from the one before it.
    struct Lineage {
        var reuse = Reuse.whole("first read")
        /// The rendering before, and where this one's differs from it — so the decoration need
        /// not compare the two whole again, which at 256 KB was a quarter of a keystroke
        /// (measured 2026-10-09). Weak: it is the session's to keep, not this one's.
        weak var base: NSAttributedString?
        var changed: (old: NSRange, new: NSRange)?
    }

    var reuse: Reuse {
        get { lineage.reuse }
        set { lineage.reuse = newValue }
    }

    /// This projection with every list that continues one of `previous`'s given that list's
    /// `NSTextList`, and the rest of `previous`'s rendering kept where it draws the same.
    ///
    /// **A whole re-read keeps the lists too** (review, 2026-10-09). It made every list anew, so a
    /// keystroke in a note with a reference definition — re-read whole every time — replaced the
    /// list it was in, whole, in the decoration and on screen: the 340 ms of a 256 KB list, back.
    /// The same patch the part re-read makes, over the whole rendering.
    ///
    /// **The session's to ask, for the projection it keeps** (round 2, 2026-10-10): asked by every
    /// whole re-read, it ran for each of the translator's checks — up to three for one keystroke,
    /// on a note that always goes whole — and for a new text size, where every run is new anyway.
    func keepingLists(of previous: MarkdownProjection) -> MarkdownProjection {
        let patch = PreviewListIdentity.patch(previous.rendered,
                                              window: NSRange(location: 0, length: previous.rendered.length),
                                              with: rendered)
        let kept = NSMutableAttributedString(attributedString: previous.rendered)
        kept.replaceCharacters(in: patch.range, with: patch.text)
        return MarkdownProjection(source: source, style: style, index: index, rendered: kept,
                                  blocks: blocks, segments: segments, spans: spans,
                                  lineage: Lineage(reuse: reuse, base: previous.rendered, changed: Self.changed(by: patch)))
    }

    /// This projection at `style`, where only the column's width moved and every table still fits
    /// it, or still does not — `nil` where only a re-read is right.
    ///
    /// **The width decides one thing here: whether a table is too wide to edit** (§3.8). The
    /// window's every live-resize frame set a new width, and each was a whole re-read, a whole
    /// decoration and a whole comparison, and dropped a held space or an opened paragraph on the
    /// way (review, 2026-10-09). A rule's and an image's size follow the column too, but those are
    /// the decoration's, not the projection's.
    func restyled(_ style: Style) -> MarkdownProjection? {
        var moved = style
        moved.columnWidth = self.style.columnWidth
        guard moved == self.style else { return nil }
        func fits(_ width: CGFloat, _ column: CGFloat?) -> Bool { column.map { width <= $0 } ?? true }
        for block in blocks {
            guard case .table = block.kind, block.rendered.length > 0, NSMaxRange(block.rendered) <= rendered.length,
                  let width = rendered.attribute(.previewTableWidth, at: block.rendered.location, effectiveRange: nil)
                    as? CGFloat
            else { continue }
            if fits(width, self.style.columnWidth) != fits(width, style.columnWidth) { return nil }
        }
        return MarkdownProjection(source: source, style: style, index: index, rendered: rendered,
                                  blocks: blocks, segments: segments, spans: spans, lineage: Lineage(reuse: .unchanged))
    }

    /// One document-level block — or two, where the first has no place in the file — its blocks,
    /// and the whole lines it spans.
    private struct Group {
        var topLevel: Int
        var lastTopLevel: Int
        var blocks: Range<Int>
        /// From its first line's start to its last line's end, before the terminator.
        var lines: NSRange
    }

    /// `new` re-read in part, or why only a whole re-read is sure to be right.
    func reread(_ new: String) -> Result<MarkdownProjection, Decline> {
        let index = MarkdownSourceIndex(new)
        let old = self.index.units, units = index.units
        let shorter = min(old.count, units.count)
        var prefix = 0
        while prefix < shorter, old[prefix] == units[prefix] { prefix += 1 }
        if prefix == old.count, old.count == units.count {
            var same = self
            same.lineage = Lineage(reuse: .unchanged)
            return .success(same)
        }
        var suffix = 0
        while suffix < shorter - prefix, old[old.count - 1 - suffix] == units[units.count - 1 - suffix] { suffix += 1 }
        let changed = NSRange(location: prefix, length: old.count - suffix - prefix)
        let delta = units.count - old.count

        // A reference definition gives a link its target from anywhere in the file. A carriage
        // return ends a line for the parser but not for the front-matter split: neither is common
        // in a note being typed in, and both go the whole way.
        if let why = Self.reachesAcross(old) ?? Self.reachesAcross(units) { return .failure(Decline(why: why)) }
        // Front matter is decided by the first line and the first closer after it.
        let hasFrontMatter = blocks.first?.kind == .frontMatter
        let bodyStart = hasFrontMatter ? NSMaxRange(blocks[0].source) : 0
        // A change inside it is outside every group, and the window check below declines it.
        if !hasFrontMatter, Self.mayOpenFrontMatter(source, self.index) || Self.mayOpenFrontMatter(new, index) {
            return .failure(Decline(why: "may open front matter"))
        }

        let groups = self.groups(from: hasFrontMatter ? 1 : 0)
        guard !groups.isEmpty else { return .failure(Decline(why: "blocks out of line")) }
        // The groups the change touches, or stands between, and one more either side.
        let touchedFirst = groups.lastIndex { $0.lines.location <= changed.location } ?? -1
        let touchedLast = groups.firstIndex { NSMaxRange($0.lines) >= NSMaxRange(changed) } ?? groups.count
        let left = touchedFirst - 1 >= 0 ? touchedFirst - 1 : nil
        var right = touchedLast + 1 < groups.count ? touchedLast + 1 : nil
        // **A block that draws nothing proves nothing about its line** — an empty item's marker and
        // list are on the break after it, which the next block draws. Past the part re-read, that
        // break was kept as it was: `1. ` typed before `- b` started a list that the empty `2.`
        // below carries on, and the `2.` came back the same block, its line still in a list of its
        // own, starting at 2 (2026-10-12, seed 13228 of the 50,000-run). So the part runs on to the
        // next block, which draws the break, and that one is the proof.
        while let last = right, blocks[groups[last].blocks.upperBound - 1].rendered.length == 0 {
            right = last + 1 < groups.count ? last + 1 : nil
        }
        let first = groups[left ?? 0], last = groups[right ?? groups.count - 1]
        let start = left.map { groups[$0].lines.location } ?? bodyStart
        let end = right.map { NSMaxRange(groups[$0].lines) } ?? old.count
        guard start <= changed.location, NSMaxRange(changed) <= end else {
            return .failure(Decline(why: "front matter edited"))
        }

        let oldBlocks = first.blocks.lowerBound..<last.blocks.upperBound
        let renderedStart = blocks[oldBlocks.lowerBound].rendered.location
        let renderedEnd = blocks[oldBlocks].map { NSMaxRange($0.rendered) }.max() ?? renderedStart
        let previousEnd = blocks[..<oldBlocks.lowerBound].lazy.map { NSMaxRange($0.source) }.max() ?? 0
        let topLevel = left.map { groups[$0].topLevel } ?? (hasFrontMatter ? 1 : 0)

        let slice = Self.projectSlice(NSRange(location: start, length: end + delta - start), of: new,
                                      index: index, style: style, topLevel: topLevel,
                                      previousBlockSourceEnd: previousEnd)
        guard !slice.blocks.isEmpty else { return .failure(Decline(why: "nothing left to re-read")) }

        // Old spans by source: walk order is source order, so each part is one run of the array.
        let spanStart = spans.firstIndex { $0.source.location >= start } ?? spans.count
        let spanEnd = spans.firstIndex { $0.source.location > end } ?? spans.count
        // The break before the first block re-read belongs to it, but stands before the stretch,
        // and the re-read does not make one. Kept as it was after a block before the edit; made
        // anew after front matter, where the edit may have changed the blank lines it stands for.
        var oldSegmentStart = segments.firstIndex { $0.block >= oldBlocks.lowerBound } ?? segments.count
        var lead: [PreviewSegment] = []
        if oldBlocks.lowerBound > 0, oldSegmentStart < segments.count, segments[oldSegmentStart].kind == .blockBreak {
            if left == nil, let firstNew = slice.blocks.first {
                var renewed = segments[oldSegmentStart]
                let from = min(previousEnd, firstNew.source.location)
                renewed.source = NSRange(location: from, length: firstNew.source.location - from)
                lead = [renewed]
            }
            oldSegmentStart += 1
        }
        let oldSegmentEnd = segments.firstIndex { $0.block >= oldBlocks.upperBound } ?? segments.count

        let blockShift = slice.blocks.count - oldBlocks.count
        let spanShift = slice.spans.count - (spanEnd - spanStart)
        let renderedShift = slice.rendered.length - (renderedEnd - renderedStart)
        let lineShift = index.lines.count - self.index.lines.count
        let lastTopLevel = topLevel + slice.topLevelCount - 1
        let topLevelShift = right.map { lastTopLevel - groups[$0].lastTopLevel } ?? 0

        var newBlocks = Array(blocks[..<oldBlocks.lowerBound])
        newBlocks.reserveCapacity(blocks.count + blockShift)
        for var block in slice.blocks {
            block.rendered.location += renderedStart
            newBlocks.append(block)
        }
        for var block in blocks[oldBlocks.upperBound...] {
            block.source.location += delta
            block.rendered.location += renderedShift
            block.line = block.line.map { $0 + lineShift }
            block.topLevel += topLevelShift
            newBlocks.append(block)
        }

        var newSegments = Array(segments[..<(oldSegmentStart - lead.count)]) + lead
        newSegments.reserveCapacity(segments.count + slice.segments.count)
        for var segment in slice.segments {
            segment.rendered.location += renderedStart
            segment.block += oldBlocks.lowerBound
            segment.spans = segment.spans.map { $0 + spanStart }
            newSegments.append(segment)
        }
        for var segment in segments[oldSegmentEnd...] {
            segment.source.location += delta
            segment.rendered.location += renderedShift
            segment.block += blockShift
            segment.spans = segment.spans.map { $0 + spanShift }
            newSegments.append(segment)
        }

        var newSpans = Array(spans[..<spanStart])
        newSpans.append(contentsOf: slice.spans)
        for var span in spans[spanEnd...] {
            span.source.location += delta
            newSpans.append(span)
        }

        // Only what renders differently, each list in it still the list it was: a whole long list
        // replaced at every keystroke in it was most of the keystroke (PreviewListIdentity).
        let rendered = NSMutableAttributedString(attributedString: self.rendered)
        let patch = PreviewListIdentity.patch(self.rendered, window: NSRange(location: renderedStart,
                                                                             length: renderedEnd - renderedStart),
                                              with: slice.rendered)
        rendered.replaceCharacters(in: patch.range, with: patch.text)
        let result = MarkdownProjection(source: new, style: style, index: index, rendered: rendered,
                                        blocks: newBlocks, segments: newSegments, spans: newSpans,
                                        lineage: Lineage(reuse: .partial(left: left != nil, right: right != nil,
                                                                         frontMatter: hasFrontMatter),
                                                         base: self.rendered, changed: Self.changed(by: patch)))

        // The proof: the block after the edit came back as it was, so nothing after it can read
        // differently. The block before needs none — it is re-read, so whatever the edit joins to
        // it is right, and nothing before it can change: it starts a document-level block, and a
        // block starts the same however the one above it ended.
        if let right {
            let count = groups[right].blocks.count
            let newEnd = oldBlocks.upperBound + blockShift
            let shift = Shift(source: delta, rendered: renderedShift, block: blockShift, span: spanShift,
                              line: lineShift, topLevel: topLevelShift)
            guard newEnd - count >= oldBlocks.lowerBound,
                  result.matches(self, blocks: (newEnd - count)..<newEnd, old: groups[right].blocks, shift: shift)
            else { return .failure(Decline(why: "the edit reached the block after it")) }
        }
        return .success(result)
    }

    /// The ranges a patch replaced, in the rendering before it and in the one after.
    private static func changed(by patch: (range: NSRange, text: NSAttributedString)) -> (old: NSRange, new: NSRange) {
        (patch.range, NSRange(location: patch.range.location, length: patch.text.length))
    }

    /// Which of the two `units` hold, if either: a carriage return, or a line that could start a
    /// reference definition — one pass over the text for both.
    ///
    /// **A definition starts a line, so only a line can be one** (review, 2026-10-09). It used to
    /// be any `]:` at all, and a note with `if row[0]:` in a code block, `[[Page]]: status` or
    /// `see a[1]: b` in a sentence went the whole way at every keystroke — 130 ms at 256 KB, and the
    /// translator projects up to three times for one. A definition is a `[`, a label with no
    /// bracket in it, `]` and `:`, at the start of a paragraph's first line, which may stand after
    /// indentation and any `>` and list markers. **Wider than the parser, never narrower**: every
    /// `>`, `-`, `+`, `*`, digit, `.` and `)` is passed over, not only a well-formed marker; a line
    /// in a fence or inside a paragraph counts; and the label may run over lines, as the parser's
    /// may — `[a` + newline + `b]: /url` defines "a b".
    static func reachesAcross(_ units: [UInt16]) -> String? {
        let count = units.count
        var at = 0
        while at < count {
            var first = at
            while first < count, isLead(units[first]) { first += 1 }
            if first < count, units[first] == 0x5B, labelEndsInColon(units, from: first + 1) { return "definition" }
            while at < count, units[at] != 0x0A {
                if units[at] == 0x0D { return "carriage return" }
                at += 1
            }
            at += 1
        }
        return nil
    }

    /// What may stand before a definition on its line: indentation, quote and list markers.
    private static func isLead(_ unit: UInt16) -> Bool {
        switch unit {
        case 0x20, 0x09, 0x3E, 0x2D, 0x2B, 0x2A, 0x2E, 0x29, 0x30...0x39: return true
        default: return false
        }
    }

    /// Whether the label opened just before `from` closes, with no bracket inside it, on `]:`.
    /// Each scan stops at the next bracket, so the scans together read the text about once.
    private static func labelEndsInColon(_ units: [UInt16], from: Int) -> Bool {
        var at = from
        while at < units.count {
            switch units[at] {
            case 0x5C: at += 2
            case 0x5B: return false
            case 0x5D: return at + 1 < units.count && units[at + 1] == 0x3A
            default: at += 1
            }
        }
        return false
    }

    /// Whether `source`'s first line could open front matter: `---`, give or take what surrounds it.
    private static func mayOpenFrontMatter(_ source: String, _ index: MarkdownSourceIndex) -> Bool {
        guard let first = index.lines.first else { return false }
        return (source as NSString).substring(with: NSRange(location: first.start, length: first.end - first.start))
            .trimmingCharacters(in: .whitespaces).hasPrefix("---")
    }

    /// The document-level blocks in order, or none when their lines do not follow one another.
    ///
    /// **A block the parser gives no position joins the one after it.** A table under a paragraph
    /// with no blank line between takes the paragraph's last line for its header, and swift-markdown
    /// then reports the paragraph left above with no range, and the table as starting on that line
    /// (measured 2026-10-08). Only the two together have lines of their own — **from the first
    /// line either has**: a list whose item holds an empty heading, `- #`, waits for the block
    /// after it, and the lines it does have were dropped, so the re-read started at the next block
    /// and the list was lost (found 2026-10-09 by the wider random documents).
    private func groups(from firstBlock: Int) -> [Group] {
        var groups: [Group] = []
        var waiting: (topLevel: Int, block: Int, lower: Int, upper: Int)?
        var at = firstBlock
        while at < blocks.count {
            let topLevel = blocks[at].topLevel
            var lower = waiting?.lower ?? Int.max, upper = waiting?.upper ?? Int.min, unplaced = false
            var next = at
            while next < blocks.count, blocks[next].topLevel == topLevel {
                if blocks[next].line == nil {
                    unplaced = true
                } else {
                    lower = min(lower, blocks[next].source.location)
                    upper = max(upper, NSMaxRange(blocks[next].source))
                }
                next += 1
            }
            let first = waiting.map { (topLevel: $0.topLevel, block: $0.block) } ?? (topLevel: topLevel, block: at)
            at = next
            if unplaced || lower == Int.max {
                waiting = (first.topLevel, first.block, lower, upper)
                continue
            }
            waiting = nil
            let firstLine = index.lines[index.lineNumber(containing: lower) - 1]
            let lastLine = index.lines[index.lineNumber(containing: max(lower, upper - 1)) - 1]
            let lines = NSRange(location: firstLine.start, length: max(lastLine.end, upper) - firstLine.start)
            if let previous = groups.last, lines.location <= NSMaxRange(previous.lines) { return [] }
            groups.append(Group(topLevel: first.topLevel, lastTopLevel: topLevel, blocks: first.block..<next,
                                lines: lines))
        }
        return waiting == nil ? groups : []
    }

    /// How far a part of the projection moved.
    private struct Shift {
        var source = 0, rendered = 0, block = 0, span = 0, line = 0, topLevel = 0
    }

    /// Whether `blocks` here are `old` in `previous`, moved by `shift`: the blocks, their segments,
    /// their spans, and what they render — characters, and attributes by shape.
    private func matches(_ previous: MarkdownProjection, blocks new: Range<Int>, old: Range<Int>, shift: Shift) -> Bool {
        guard new.count == old.count else { return false }
        for (n, o) in zip(new, old) {
            var moved = previous.blocks[o]
            moved.source.location += shift.source
            moved.rendered.location += shift.rendered
            moved.line = moved.line.map { $0 + shift.line }
            moved.topLevel += shift.topLevel
            guard blocks[n] == moved else { return false }
        }
        let mine = segments.filter { new.contains($0.block) }
        let theirs = previous.segments.filter { old.contains($0.block) }
        guard mine.count == theirs.count else { return false }
        for (m, var t) in zip(mine, theirs) {
            t.source.location += shift.source
            t.rendered.location += shift.rendered
            t.block += shift.block
            t.spans = t.spans.map { $0 + shift.span }
            guard m == t else { return false }
            for (a, b) in zip(m.spans, t.spans) {
                var span = previous.spans[b - shift.span]
                span.source.location += shift.source
                guard spans.indices.contains(a), spans[a] == span else { return false }
            }
        }
        let range = NSRange(location: blocks[new.lowerBound].rendered.location,
                            length: NSMaxRange(blocks[new.upperBound - 1].rendered) - blocks[new.lowerBound].rendered.location)
        let before = NSRange(location: range.location - shift.rendered, length: range.length)
        guard NSMaxRange(range) <= rendered.length, NSMaxRange(before) <= previous.rendered.length else { return false }
        return PreviewAttributeShape.same(rendered.attributedSubstring(from: range),
                                          previous.rendered.attributedSubstring(from: before))
    }
}

extension NSAttributedString.Key {
    /// On a table's rows: how far its last column ends from the text's left edge, as a `CGFloat` —
    /// a table wider than the column is read-only, so this is what says whether a new column width
    /// changes anything in the projection (``MarkdownProjection/restyled(_:)``).
    static let previewTableWidth = NSAttributedString.Key("SyncCloud.preview.tableWidth")
}

/// **Attributed text compared by what it draws**, for two renderings made at different times.
///
/// Every projection makes its own `NSTextList`s and `NSTextAttachment`s, and each is equal only to
/// itself — so two renderings of the same text are never `isEqual`. Lists compare here by their
/// shape (marker, start, options) **and by how they group the items**: one list on one side must be
/// one list on the other, all through a comparison — TextKit numbers by that grouping, and a list
/// split in two can look the same item by item while its numbers start again (review, 2026-10-09).
/// Attachments compare by being there, fonts by name and size, and everything else as it stands.
enum PreviewAttributeShape {

    /// Where two renderings differ, and the old list each new one stands for where they agree.
    struct Difference {
        var old: NSRange
        var new: NSRange
        /// Each list of `new` found outside the difference, by identity: the `old` list there.
        var lists: [ObjectIdentifier: NSTextList]
    }

    /// Where `new` differs from `old` — or from `window` of it — in characters, or attributes by
    /// shape, as the range in each; `nil` when they are the same. Everything before the two ranges
    /// is the same in both, and so is everything after them.
    ///
    /// **Characters compared as one buffer, attributes by RUN**: a document's few hundred runs, not
    /// a dictionary bridged per character, which on a long note was the bulk of a keystroke.
    static func difference(from old: NSAttributedString, in window: NSRange? = nil,
                           to new: NSAttributedString) -> Difference? {
        let window = window ?? NSRange(location: 0, length: old.length)
        let base = window.location
        let before = MarkdownSourceIndex.units(of: old.string as NSString, in: window), after = units(new)
        var memo = Memo()
        let shorter = min(before.count, after.count)
        var prefix = 0
        while prefix < shorter, before[prefix] == after[prefix] { prefix += 1 }
        // Pull each end back to where the attributes first differ.
        var at = 0
        while at < prefix {
            var a = NSRange(), b = NSRange()
            guard same(attributes(of: old, at: base + at, &a), attributes(of: new, at: at, &b), &memo) else { prefix = at; break }
            at = min(NSMaxRange(a) - base, NSMaxRange(b))
        }
        // **The characters' suffix is measured after the prefix is pulled back**, against what is
        // left: where only attributes changed — a link's target — the characters all match, and a
        // suffix measured first was none, so the difference ran on to the end. That end was
        // replaced with lists of its own while the character after it kept the old one, and one
        // list was split in two (2026-10-09, once an empty item's line carries its list).
        var suffix = 0
        while suffix < shorter - prefix, before[before.count - 1 - suffix] == after[after.count - 1 - suffix] { suffix += 1 }
        var back = 0
        while back < suffix {
            var a = NSRange(), b = NSRange()
            let i = before.count - 1 - back, j = after.count - 1 - back
            guard same(attributes(of: old, at: base + i, &a), attributes(of: new, at: j, &b), &memo) else { suffix = back; break }
            back += min(base + i - a.location, j - b.location) + 1
        }
        suffix = min(suffix, shorter - prefix)
        guard before.count - prefix - suffix > 0 || after.count - prefix - suffix > 0 else { return nil }
        return Difference(old: NSRange(location: base + prefix, length: before.count - prefix - suffix),
                          new: NSRange(location: prefix, length: after.count - prefix - suffix),
                          lists: memo.oldLists)
    }

    /// The characters in one copy — `Array(string.utf16)` reads a storage's string a character at a
    /// time, and on a long note that alone cost more than the projection's walk.
    static func units(_ text: NSAttributedString) -> [unichar] {
        MarkdownSourceIndex.units(of: text.string as NSString)
    }

    /// Whether `a` and `b` hold the same characters with the same attributes, run by run.
    static func same(_ a: NSAttributedString, _ b: NSAttributedString) -> Bool {
        guard a.length == b.length, (a.string as NSString).isEqual(to: b.string) else { return false }
        var memo = Memo()
        var at = 0
        while at < a.length {
            var left = NSRange(), right = NSRange()
            let x = attributes(of: a, at: at, &left), y = attributes(of: b, at: at, &right)
            guard same(x, y, &memo) else { return false }
            at = min(NSMaxRange(left), NSMaxRange(right))
        }
        return true
    }

    /// A run's attributes as the string holds them. `attributes(at:effectiveRange:)` bridges each
    /// run to a Swift dictionary and comparing bridges it back — most of a comparison, measured.
    static func attributes(of text: NSAttributedString, at index: Int, _ range: inout NSRange) -> NSDictionary {
        var run = CFRange()
        let attributes = CFAttributedStringGetAttributes(text as CFAttributedString, index, &run) as NSDictionary
        range = NSRange(location: run.location, length: run.length)
        return attributes
    }

    /// Paragraph styles already compared — a list's items share one style object, so each pair is
    /// compared once, not once per run — and the lists paired so far, each with one other only.
    struct Memo {
        fileprivate var known: [Pair: Bool] = [:]
        fileprivate var last: (pair: Pair, same: Bool)?
        fileprivate struct Pair: Hashable { let left, right: ObjectIdentifier }
        private var newFor: [ObjectIdentifier: ObjectIdentifier] = [:]
        /// The left list each right list was paired with.
        fileprivate private(set) var oldLists: [ObjectIdentifier: NSTextList] = [:]

        /// Whether `a`'s lists may be `b`'s, as every pair before had them — and they are, after.
        fileprivate mutating func pair(_ a: [NSTextList], _ b: [NSTextList]) -> Bool {
            guard a.count == b.count else { return false }
            for (x, y) in zip(a, b) {
                if let known = newFor[ObjectIdentifier(x)], known != ObjectIdentifier(y) { return false }
                if let known = oldLists[ObjectIdentifier(y)], known !== x { return false }
            }
            for (x, y) in zip(a, b) {
                newFor[ObjectIdentifier(x)] = ObjectIdentifier(y)
                oldLists[ObjectIdentifier(y)] = x
            }
            return true
        }
    }

    nonisolated(unsafe) private static let attachmentKey = NSAttributedString.Key.attachment.rawValue as NSString
    nonisolated(unsafe) private static let paragraphStyleKey = NSAttributedString.Key.paragraphStyle.rawValue as NSString
    nonisolated(unsafe) private static let fontKey = NSAttributedString.Key.font.rawValue as NSString

    /// Equal runs, the common case by far, take the first line; only a run that differs as it
    /// stands is taken apart.
    static func same(_ a: NSDictionary, _ b: NSDictionary, _ memo: inout Memo) -> Bool {
        if a.isEqual(b) {
            // The same lists, which must still pair with themselves — asked of the memo first, by
            // the styles' identity, before any list is read.
            guard let style = a.object(forKey: paragraphStyleKey) else { return true }
            return sameShape(style, b.object(forKey: paragraphStyleKey) as Any, &memo)
        }
        guard a.count == b.count, (a.object(forKey: attachmentKey) == nil) == (b.object(forKey: attachmentKey) == nil)
        else { return false }
        var same = true
        a.enumerateKeysAndObjects { key, value, stop in
            let key = key as! NSString
            if key.isEqual(attachmentKey) { return }
            guard let other = b.object(forKey: key) else { same = false; stop.pointee = true; return }
            let equal: Bool
            if key.isEqual(paragraphStyleKey) {
                equal = sameShape(value, other, &memo)
            } else if key.isEqual(fontKey), let x = value as? NSFont, let y = other as? NSFont {
                // The font the system stands in for a glyph the text's own lacks — 中 in Helvetica —
                // is a new object each time, and not `isEqual` to the last one.
                equal = x.fontName == y.fontName && x.pointSize == y.pointSize
            } else {
                equal = (value as AnyObject).isEqual(other)
            }
            if !equal { same = false; stop.pointee = true }
        }
        return same
    }

    private static func sameShape(_ a: Any, _ b: Any, _ memo: inout Memo) -> Bool {
        let pair = Memo.Pair(left: ObjectIdentifier(a as AnyObject), right: ObjectIdentifier(b as AnyObject))
        // A paragraph's runs share its style: the pair just asked about, asked again, needs no lookup.
        if let last = memo.last, last.pair == pair { return last.same }
        defer { memo.last = (pair, memo.known[pair] ?? false) }
        if let known = memo.known[pair] { return known }
        guard let a = a as? NSParagraphStyle, let b = b as? NSParagraphStyle else { return false }
        let same: Bool
        if a.textLists.count != b.textLists.count
            || !zip(a.textLists, b.textLists).allSatisfy({
                $0.markerFormat == $1.markerFormat && $0.startingItemNumber == $1.startingItemNumber
                    && $0.listOptions == $1.listOptions
            }) {
            same = false
        } else {
            let left = a.mutableCopy() as! NSMutableParagraphStyle, right = b.mutableCopy() as! NSMutableParagraphStyle
            left.textLists = []
            right.textLists = []
            same = left.isEqual(right) && memo.pair(a.textLists, b.textLists)
        }
        memo.known[pair] = same
        return same
    }
}

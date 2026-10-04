import Foundation

/// A list item's opening, read off its line: where the marker is, what it is, and where the text
/// after it starts (TE54).
///
/// **Only the shape of ONE line** — whether that line really opens a list item is the parser's to
/// say (``MarkdownSourceContext``). `- - -` matches here and is a rule; `    - x` after a paragraph
/// matches here and is code. Every edit below asks both.
struct MarkdownListLine: Equatable {

    enum Marker: Equatable {
        case bullet(Character)
        /// The number as written, how many digits it was written with, and `.` or `)`.
        case ordered(Int, digits: Int, delimiter: Character)
    }

    /// The leading spaces and tabs, as written.
    var indent: String
    var marker: Marker
    /// The whitespace after the marker, as written — at least one character.
    var spacing: String
    /// The task box, `[ ]`, `[x]` or `[X]`, and the whitespace after it — `nil` on a plain item.
    var task: (box: String, spacing: String)?
    /// Everything after the marker and the box: the item's words. Empty on an empty item.
    var text: String

    static func == (a: MarkdownListLine, b: MarkdownListLine) -> Bool {
        a.indent == b.indent && a.marker == b.marker && a.spacing == b.spacing
            && a.task?.box == b.task?.box && a.task?.spacing == b.task?.spacing && a.text == b.text
    }

    /// Whether nothing but spaces and tabs follows the marker (and the box) — CommonMark's two
    /// whitespace characters, not Unicode's: an ideographic space is content to the parser.
    var isEmpty: Bool { text.allSatisfy { $0 == " " || $0 == "\t" } }

    /// The marker as written.
    var markerText: String {
        switch marker {
        case .bullet(let character): return String(character)
        case .ordered(let number, let digits, let delimiter):
            return Self.number(number, digits: digits) + String(delimiter)
        }
    }

    /// Everything before the item's words: indent, marker, spacing and box.
    var lead: String { indent + markerText + spacing + (task.map { $0.box + $0.spacing } ?? "") }

    /// The line's indent in COLUMNS, a tab advancing to the next multiple of four — CommonMark's
    /// tab stop, and the unit every indent rule below is stated in.
    var indentColumns: Int { Self.columns(of: indent) }

    /// **The column the item's words start at, by CommonMark's rule** — what a child item's marker
    /// must reach to nest under this one, and what Tab indents to. The marker's width plus the
    /// spaces after it, unless there are five or more: then the content is one space in and the
    /// rest is an indented code block inside the item, so the content column is marker + 1.
    var contentColumn: Int {
        let markerEnd = indentColumns + markerText.count
        let after = Self.columns(of: spacing, startingAt: markerEnd) - markerEnd
        guard !isEmpty || task != nil else { return markerEnd + 1 }
        return markerEnd + ((1...4).contains(after) ? after : 1)
    }

    /// Reads a list item's opening off `line`, or `nil` when the line does not have one.
    ///
    /// **A marker with no whitespace after it is not taken**, `-` alone included: CommonMark allows
    /// an empty item written that way, but a lone `-` is also how a rule or a setext underline
    /// starts being typed, and a Return there should do what a Return does.
    static func parse(_ line: String) -> MarkdownListLine? {
        let scalars = Array(line.unicodeScalars)
        var index = 0
        while index < scalars.count, scalars[index] == " " || scalars[index] == "\t" { index += 1 }
        let indent = String(String.UnicodeScalarView(scalars[0..<index]))
        guard index < scalars.count else { return nil }

        let marker: Marker
        let first = scalars[index]
        if first == "-" || first == "*" || first == "+" {
            marker = .bullet(Character(first))
            index += 1
        } else if ("0"..."9").contains(first) {
            let start = index
            while index < scalars.count, ("0"..."9").contains(scalars[index]) { index += 1 }
            let digits = index - start
            // CommonMark allows at most nine digits, which is also what keeps `+ 1` from overflowing.
            guard digits <= 9, index < scalars.count, scalars[index] == "." || scalars[index] == ")",
                  let number = Int(String(String.UnicodeScalarView(scalars[start..<index]))) else { return nil }
            marker = .ordered(number, digits: digits, delimiter: Character(scalars[index]))
            index += 1
        } else {
            return nil
        }

        let spacingStart = index
        while index < scalars.count, scalars[index] == " " || scalars[index] == "\t" { index += 1 }
        guard index > spacingStart else { return nil }
        let spacing = String(String.UnicodeScalarView(scalars[spacingStart..<index]))

        // The task box: `[ ]`, `[x]` or `[X]`, then whitespace or the end of the line.
        var task: (box: String, spacing: String)?
        if index + 2 < scalars.count, scalars[index] == "[", scalars[index + 2] == "]",
           [" ", "x", "X"].contains(scalars[index + 1]) {
            let afterBox = index + 3
            var end = afterBox
            while end < scalars.count, scalars[end] == " " || scalars[end] == "\t" { end += 1 }
            if end > afterBox || afterBox == scalars.count {
                task = (String(String.UnicodeScalarView(scalars[index..<afterBox])),
                        String(String.UnicodeScalarView(scalars[afterBox..<end])))
                index = end
            }
        }
        let text = String(String.UnicodeScalarView(scalars[index...]))
        return MarkdownListLine(indent: indent, marker: marker, spacing: spacing, task: task, text: text)
    }

    /// The opening the NEXT item gets when Return is pressed at the end of this one: the same
    /// indent, marker and spacing, the number counted on, and an empty box for a task.
    ///
    /// `nil` when the number cannot be counted on — a tenth digit is not a list marker.
    var continuation: String? {
        let next: String
        switch marker {
        case .bullet(let character):
            next = String(character)
        case .ordered(let number, let digits, let delimiter):
            guard number < 999_999_999 else { return nil }
            next = Self.number(number + 1, digits: digits) + String(delimiter)
        }
        // A task carries on as an unticked one; the spacing after its box is kept, or one space
        // when the box ended the line.
        let box = task.map { "[ ]" + ($0.spacing.isEmpty ? " " : $0.spacing) } ?? ""
        return indent + next + spacing + box
    }

    /// **A leading zero is kept** — `01.` counts on to `02.` — and nothing else is padded.
    private static func number(_ value: Int, digits: Int) -> String {
        let plain = String(value)
        return plain.count < digits ? String(repeating: "0", count: digits - plain.count) + plain : plain
    }

    /// The width of `whitespace` in columns, starting from `column`.
    static func columns(of whitespace: String, startingAt column: Int = 0) -> Int {
        var at = column
        for character in whitespace {
            at = character == "\t" ? (at / 4 + 1) * 4 : at + 1
        }
        return at
    }
}

/// What Return, Tab and ⇧Tab do inside a Markdown list (TE54) — pure functions over a buffer and a
/// selection, as ``MarkdownEdits`` is, so every rule is asserted character for character without a
/// text view.
///
/// **They take the buffer as an `NSString`**, because the text view's storage is one: handed
/// `textStorage.mutableString`, nothing here copies the document to answer a keystroke. The
/// `String` overloads are for the tests.
enum MarkdownListEdits {

    /// What Return does on a list item.
    enum ReturnEdit: Equatable {
        /// Insert the newline exactly as Return would, then this opening — the two as ONE undo step,
        /// apart from the typing before it, so one ⌘Z takes back the Return and what it added.
        case continueWith(String)
        /// The LAST item is empty: its opening (this range) comes off and the Return goes in after
        /// it — so the line it was on is the blank line that ends the list, and what is typed next is
        /// a paragraph of its own rather than more of the last item.
        case endList(NSRange)
        /// An empty item with an item after it that a paragraph would swallow — one at its own level
        /// or deeper, or a numbered one not starting at 1 (`2. Next` under a typed paragraph is that
        /// paragraph's words). Its opening comes off and nothing else: the line is left for the
        /// caret, and what is typed there continues the item above, as a line under a list does in
        /// Markdown — the one reading that keeps every item after it an item.
        case clearMarker(NSRange)
    }

    static func returnEdit(in text: String, selection: NSRange) -> ReturnEdit? {
        returnEdit(in: text as NSString, selection: selection)
    }

    /// What Return does at `selection`, or `nil` for "what Return always did".
    ///
    /// **Only with the caret at the end of an item's line**, nothing selected. A Return in the
    /// middle of an item's words, or over a selection, does what it did before this existed — the
    /// rule is narrow on purpose, because this is the one place Edit writes characters nobody typed.
    static func returnEdit(in ns: NSString, selection: NSRange) -> ReturnEdit? {
        guard selection.length == 0, MarkdownEdits.isValid(selection, in: ns) else { return nil }
        let line = MarkdownSourceLines.line(containing: selection.location, in: ns)
        guard selection.location == NSMaxRange(line.content),
              let item = MarkdownListLine.parse(ns.substring(with: line.content)),
              case .listItem = MarkdownSourceContext.block(at: selection.location, in: ns,
                                                           asIfWritten: item.isEmpty) else { return nil }
        if item.isEmpty {
            let next = MarkdownSourceLines.line(after: line, in: ns)
                .flatMap { MarkdownListLine.parse(ns.substring(with: $0.content)) }
            guard let next else { return .endList(line.content) }
            var swallowed = next.indentColumns >= item.indentColumns
            if case .ordered(let number, _, _) = next.marker, number != 1 { swallowed = true }
            return swallowed ? .clearMarker(line.content) : .endList(line.content)
        }
        return item.continuation.map(ReturnEdit.continueWith)
    }

    /// What Tab (or ⇧Tab, `outdent`) does in a list.
    enum TabEdit: Equatable {
        /// Replace `range` with `text` — one undo step — and select `selection` afterwards.
        case rewrite(range: NSRange, text: String, selection: NSRange)
        /// The caret is in a list item that cannot move that way — the first item of its list for
        /// Tab, an item at the top level for ⇧Tab. The key is taken and nothing changes, rather than
        /// a tab character landing in the middle of a list.
        case unchanged
    }

    static func tabEdit(in text: String, selection: NSRange, outdent: Bool) -> TabEdit? {
        tabEdit(in: text as NSString, selection: selection, outdent: outdent)
    }

    /// What Tab or ⇧Tab does at `selection`, or `nil` for "what the key always did".
    ///
    /// **Anywhere on an item's opening line, the item moves** — with nothing selected or with a
    /// selection inside that line. A selection over several lines is today's Tab.
    ///
    /// **The indent is the one CommonMark nests by**, read from the neighbour rather than fixed at
    /// two or four: Tab lines the marker up with the PREVIOUS item's words (two columns under `- `,
    /// three under `1. `), which makes it that item's child; ⇧Tab lines it up with the marker of the
    /// item its list is nested in, which makes it that item's sibling.
    ///
    /// **The item's own lines go with it, and only those** — which the parser decides
    /// (``MarkdownSourceContext/itemExtent(at:in:)``): its children and their text, a lazy line, a
    /// code block inside it; not a note indented under the list but outside its last item.
    ///
    /// **And the result is read back by the parser before it is offered**, because CommonMark has
    /// a rule the column arithmetic does not see: a list that interrupts a paragraph may only start
    /// at `1.`. So `   2. b` under `1. a` would be the words "a 2. b" — and after ⇧Tab, the item
    /// that followed the moved one, now the first of a sub-list under it, would be words too. Such
    /// an item is renumbered `1.`, its number alone; if even that does not land, nothing moves.
    static func tabEdit(in ns: NSString, selection: NSRange, outdent: Bool) -> TabEdit? {
        guard MarkdownEdits.isValid(selection, in: ns) else { return nil }
        let line = MarkdownSourceLines.line(containing: selection.location, in: ns)
        guard NSMaxRange(selection) <= NSMaxRange(line.content),
              let item = MarkdownListLine.parse(ns.substring(with: line.content)),
              case .listItem(let context) = MarkdownSourceContext.block(at: selection.location, in: ns,
                                                                        asIfWritten: item.isEmpty)
        else { return nil }

        let body = MarkdownFrontMatter.bodyStart(in: ns)
        let current = item.indentColumns
        let target: Int
        if outdent {
            guard let parentLine = context.parentItemLine,
                  let parent = neighbour(parentLine, from: line, number: context.line, in: ns),
                  parent.indentColumns < current else { return .unchanged }
            target = parent.indentColumns
        } else {
            guard let siblingLine = context.previousSiblingLine,
                  let sibling = neighbour(siblingLine, from: line, number: context.line, in: ns),
                  sibling.contentColumn > current else { return .unchanged }
            target = sibling.contentColumn
        }
        // An empty item is read as though a word followed its marker, here as everywhere: CommonMark
        // gives it no lines of its own otherwise.
        let extent = MarkdownSourceContext.itemExtent(at: line.content.location, in: ns, asIfWritten: item.isEmpty,
                                                      body: body)
        let lines = ownLines(after: line, number: context.line, through: extent?.lastLine ?? context.line, in: ns)
        let after = lines.last.map { MarkdownSourceLines.line(after: $0, in: ns) } ?? MarkdownSourceLines.line(after: line, in: ns)
        let following = after.flatMap { firstWritten(from: $0, in: ns) }
        let followingItem = following.flatMap { MarkdownListLine.parse(ns.substring(with: $0.content)) }

        // What the document reads as now, and which of its blocks are this item's.
        let before = MarkdownSourceContext.leaves(in: item.isEmpty ? written(ns, at: line) : ns, body: body)
        let moved = context.line...(context.line + lines.count)

        func ordered(_ item: MarkdownListLine?) -> Bool {
            if case .ordered(let number, _, _)? = item?.marker { return number != 1 }
            return false
        }
        // Each candidate: renumber the moved item? renumber the item after it?
        var candidates: [(Bool, Bool)] = [(false, false)]
        if ordered(item) { candidates.append((true, false)) }
        if ordered(followingItem) {
            candidates.append((false, true))
            if ordered(item) { candidates.append((true, true)) }
        }
        for (renumberItem, renumberFollowing) in candidates {
            let edit = rewrite(item, renumbered: renumberItem, on: line, lines: lines, firstLine: context.line,
                               extent: extent,
                               following: renumberFollowing ? following.flatMap { f in followingItem.map { (f, $0) } } : nil,
                               in: ns, to: target, selection: selection)
            guard case .rewrite(let range, let text, _) = edit else { continue }
            let result = ns.replacingCharacters(in: range, with: text) as NSString
            let movedLine = MarkdownSourceLines.line(startingAt: line.content.location, in: result)
            let leaves = MarkdownSourceContext.leaves(in: item.isEmpty ? written(result, at: movedLine) : result,
                                                      body: body)
            if sameDocument(before, leaves, moved: moved, by: outdent ? -1 : 1) { return edit }
        }
        return .unchanged
    }

    /// **The same document with the item moved, and nothing else** — every block still there, on
    /// its line, of its kind, with its words or code byte for byte; the moved item's own blocks one
    /// list level deeper (Tab) or shallower (⇧Tab), every other block at its level. Whatever the
    /// column arithmetic got wrong — a tab stop, a marker that changed width, a block the extent
    /// missed — this is where it is caught, and the key then changes nothing.
    private static func sameDocument(_ before: [MarkdownSourceContext.Leaf], _ after: [MarkdownSourceContext.Leaf],
                                      moved: ClosedRange<Int>, by step: Int) -> Bool {
        guard before.count == after.count else { return false }
        return zip(before, after).allSatisfy { old, new in
            old.line == new.line && old.kind == new.kind && old.text == new.text
                && new.depth == old.depth + (moved.contains(old.line) ? step : 0)
        }
    }

    /// `ns` with a word after the empty item on `line` — so the parser sees the item it is about to
    /// be. No line moves.
    private static func written(_ ns: NSString, at line: MarkdownSourceLines.Line) -> NSString {
        ns.replacingCharacters(in: NSRange(location: NSMaxRange(line.content), length: 0), with: "x") as NSString
    }

    /// The lines after the item's opening that are its own: up to `lastLine` (the parser's), blank
    /// lines included, trailing blank lines not.
    private static func ownLines(after line: MarkdownSourceLines.Line, number: Int, through lastLine: Int,
                                 in ns: NSString) -> [MarkdownSourceLines.Line] {
        var lines: [MarkdownSourceLines.Line] = []
        var cursor = line
        var at = number
        while at < lastLine, let next = MarkdownSourceLines.line(after: cursor, in: ns) {
            lines.append(next)
            cursor = next
            at += 1
        }
        while let last = lines.last, isBlank(ns.substring(with: last.content)) { lines.removeLast() }
        return lines
    }

    private static func firstWritten(from line: MarkdownSourceLines.Line, in ns: NSString) -> MarkdownSourceLines.Line? {
        var cursor: MarkdownSourceLines.Line? = line
        while let current = cursor {
            if !isBlank(ns.substring(with: current.content)) { return current }
            cursor = MarkdownSourceLines.line(after: current, in: ns)
        }
        return nil
    }

    private static func isBlank(_ text: String) -> Bool { text.allSatisfy { $0 == " " || $0 == "\t" } }

    /// The rewrite that puts `item`'s marker at column `target` and moves its own lines with it.
    ///
    /// **Everything under the item moves by its CONTENT column, not by its marker's.** Each of its
    /// lines indented to the old content column has exactly those columns taken off — a tab that
    /// straddles the edge split into the spaces left of it — and the new content column put on, as
    /// spaces. So whatever is inside the item reads the same to the parser, tabs and code included:
    /// a code line keeps every byte past the edge. A lazy line, indented less, is left as it is.
    /// The opening keeps its spacing; a tab there becomes the spaces it was worth.
    private static func rewrite(_ item: MarkdownListLine, renumbered: Bool, on line: MarkdownSourceLines.Line,
                                lines: [MarkdownSourceLines.Line], firstLine: Int,
                                extent: MarkdownSourceContext.ItemExtent?,
                                following: (MarkdownSourceLines.Line, MarkdownListLine)?,
                                in ns: NSString, to target: Int, selection: NSRange) -> TabEdit {
        let opening = renumbered ? item.renumbered(1) : item
        let oldContent = item.contentColumn
        let markerEnd = item.indentColumns + item.markerText.count
        let spacingColumns = MarkdownListLine.columns(of: item.spacing, startingAt: markerEnd) - markerEnd
        // **A tab after the marker becomes the spaces it was**: its width depends on the column it
        // starts at, and the marker is about to start at another. Spaces are kept as written.
        let spacing = item.spacing.contains("\t") && spacingColumns < 5
            ? String(repeating: " ", count: spacingColumns) : item.spacing
        // The new content column, which everything under the item is re-based on — so its children
        // stay its own whatever width the marker now has. Five or more columns of spacing is code in
        // the first line, and the content column is then one past the marker (CommonMark's rule).
        let newMarkerEnd = target + opening.markerText.count
        let newSpacing = MarkdownListLine.columns(of: spacing, startingAt: newMarkerEnd) - newMarkerEnd
        // An empty item's content column is one past its marker, whatever follows it — CommonMark's
        // rule for an item that opens on a blank line, as `contentColumn` reads the old one.
        let newContent = newMarkerEnd + ((item.isEmpty && item.task == nil) || !(1...4).contains(newSpacing) ? 1 : newSpacing)
        let oldIndent = (item.indent as NSString).length
        let oldMarker = (item.markerText as NSString).length
        let oldSpacing = (item.spacing as NSString).length
        let newMarker = (opening.markerText as NSString).length
        let newSpacingLength = (spacing as NSString).length
        let rest = ns.substring(with: NSRange(location: line.content.location + oldIndent + oldMarker + oldSpacing,
                                              length: line.content.length - oldIndent - oldMarker - oldSpacing))
        var rebuilt = String(repeating: " ", count: target) + opening.markerText + spacing + rest
        var last = line
        for (index, next) in lines.enumerated() {
            rebuilt += ns.substring(with: NSRange(location: NSMaxRange(last.content),
                                                  length: next.content.location - NSMaxRange(last.content)))
            let body = ns.substring(with: next.content)
            let number = firstLine + 1 + index
            let mode: LineMode = extent?.verbatimLines.contains(number) == true ? .verbatim
                : extent?.indentedCodeLines.contains(number) == true ? .indentedCode : .indentation
            // A blank line is left as it is — unless it is inside code, where whitespace past the
            // edge is the code's own and has to move with it.
            rebuilt += isBlank(body) && mode == .indentation ? body : moved(body, from: oldContent, to: newContent, mode: mode)
            last = next
        }
        if let (line, item) = following {
            // The item after it, renumbered `1.` where nothing else would let it stay an item.
            let renumbered = item.renumbered(1)
            rebuilt += ns.substring(with: NSRange(location: NSMaxRange(last.content),
                                                  length: line.content.location - NSMaxRange(last.content)))
            let lead = (item.indent as NSString).length + (item.markerText as NSString).length
            rebuilt += item.indent + renumbered.markerText
                + ns.substring(with: NSRange(location: line.content.location + lead, length: line.content.length - lead))
            last = line
        }
        let range = NSRange(location: line.content.location, length: NSMaxRange(last.content) - line.content.location)

        // The selection moves with what it was on: in the old indent it lands on the marker, inside
        // the marker or the spacing it stays inside the new one, and after them it keeps its place.
        // Monotonic, so a selection never comes out with its end before its start.
        func mapped(_ offset: Int) -> Int {
            let inLine = offset - line.content.location
            let base = line.content.location + target
            if inLine < oldIndent { return base }
            if inLine < oldIndent + oldMarker { return base + min(inLine - oldIndent, newMarker) }
            if inLine < oldIndent + oldMarker + oldSpacing {
                return base + newMarker + min(inLine - oldIndent - oldMarker, newSpacingLength)
            }
            return base + newMarker + newSpacingLength + (inLine - oldIndent - oldMarker - oldSpacing)
        }
        let start = mapped(selection.location)
        let end = mapped(NSMaxRange(selection))
        return .rewrite(range: range, text: rebuilt, selection: NSRange(location: start, length: end - start))
    }

    /// The list line a neighbour sits on, walked to from the caret's — `nil` when the line the parser
    /// named does not read as a list item here, which would mean the two disagree about lines and
    /// nothing should move.
    private static func neighbour(_ target: Int, from line: MarkdownSourceLines.Line, number: Int,
                                  in ns: NSString) -> MarkdownListLine? {
        guard let found = MarkdownSourceLines.line(target, from: line, number: number, in: ns) else { return nil }
        return MarkdownListLine.parse(ns.substring(with: found.content))
    }

    /// What the whitespace after the item's edge is, on one of its lines.
    private enum LineMode {
        /// Indentation: written as spaces, column for column.
        case indentation
        /// An indented code block's: its first four columns are indentation, the rest is code.
        case indentedCode
        /// Content — a fenced block's code, raw HTML — kept byte for byte.
        case verbatim
    }

    /// A line inside the item, its first `from` columns of indentation swapped for `to` columns of
    /// spaces — a tab across that edge split into the spaces right of it, as the parser itself
    /// splits one. Past the edge, `mode` decides: indentation is written as spaces at the columns it
    /// had (a tab's width depends on where it starts, and the line is about to start somewhere
    /// else), and content keeps every byte. A line not indented as far as the edge is a lazy line,
    /// and is returned as it is.
    private static func moved(_ line: String, from: Int, to: Int, mode: LineMode) -> String {
        var column = 0
        var index = line.startIndex
        var carried = 0
        while index < line.endIndex, column < from {
            let character = line[index]
            guard character == " " || character == "\t" else { return line }
            let next = character == "\t" ? (column / 4 + 1) * 4 : column + 1
            index = line.index(after: index)
            if next > from { carried = next - from; column = from; break }
            column = next
        }
        guard column >= from else { return line }
        // `carried` columns of a split tab, then the rest of the line from `index`, at column `from`.
        var head = String(repeating: " ", count: carried)
        var at = from + carried
        let limit: Int
        switch mode {
        case .verbatim: limit = at
        case .indentedCode: limit = from + 4
        case .indentation: limit = .max
        }
        while index < line.endIndex, at < limit {
            let character = line[index]
            guard character == " " || character == "\t" else { break }
            let next = character == "\t" ? (at / 4 + 1) * 4 : at + 1
            head += String(repeating: " ", count: next - at)
            at = next
            index = line.index(after: index)
        }
        return String(repeating: " ", count: to) + head + line[index...]
    }
}

extension MarkdownListLine {
    /// The same opening numbered `number` with no padding — the `1.` a list must start at to
    /// interrupt a paragraph. A bullet is returned as it is.
    func renumbered(_ number: Int) -> MarkdownListLine {
        guard case .ordered(_, _, let delimiter) = marker else { return self }
        var copy = self
        copy.marker = .ordered(number, digits: 1, delimiter: delimiter)
        return copy
    }
}

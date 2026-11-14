import Foundation

/// A list item's opening, read off its line: where the marker is, what it is, and where the text
/// after it starts.
///
/// Only the shape of one line; whether it really opens a list item is the parser's call
/// (``MarkdownSourceContext``). `- - -` matches here and is a rule; `    - x` after a paragraph
/// matches here and is code. Every edit below asks both.
struct MarkdownListLine {

    enum Marker: Equatable {
        case bullet(Character)
        /// The number as written, how many digits it was written with, and `.` or `)`.
        case ordered(Int, digits: Int, delimiter: Character)
    }

    /// The leading spaces and tabs, as written.
    var indent: String
    var marker: Marker
    /// The whitespace after the marker, as written: at least one character.
    var spacing: String
    /// The task box, `[ ]`, `[x]` or `[X]`, and the whitespace after it; `nil` on a plain item.
    var task: (box: String, spacing: String)?
    /// Everything after the marker and the box: the item's words. Empty on an empty item.
    var text: String

    /// Whether nothing but spaces and tabs follows the marker (and the box): CommonMark's two
    /// whitespace characters, not Unicode's, since an ideographic space is content to the parser.
    var isEmpty: Bool { text.allSatisfy { $0 == " " || $0 == "\t" } }

    /// The marker as written.
    var markerText: String {
        switch marker {
        case .bullet(let character): return String(character)
        case .ordered(let number, let digits, let delimiter):
            return Self.number(number, digits: digits) + String(delimiter)
        }
    }

    /// The line's indent in columns, a tab advancing to the next multiple of four (CommonMark's tab
    /// stop). Every indent rule below is stated in columns.
    var indentColumns: Int { Self.columns(of: indent) }

    /// The column the item's words start at, by CommonMark's rule: what a child's marker must
    /// reach to nest under this item, and what Tab indents to. The marker's width plus the spaces
    /// after it, unless there are five or more (the rest is then an indented code block inside the
    /// item) or the item is empty and has no box; then it is marker + 1.
    var contentColumn: Int {
        let markerEnd = indentColumns + markerText.count
        let after = Self.columns(of: spacing, startingAt: markerEnd) - markerEnd
        guard !isEmpty || task != nil else { return markerEnd + 1 }
        return markerEnd + ((1...4).contains(after) ? after : 1)
    }

    /// Reads a list item's opening off `line`, or `nil` when the line does not have one.
    ///
    /// A marker with no whitespace after it is not taken, `-` alone included: CommonMark allows that
    /// empty item, but a lone `-` is also how a rule or a setext underline starts being typed, and
    /// Return there should stay a plain Return.
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

    /// The opening a new item beside this one gets: the same indent, marker and spacing, the number
    /// counted on when `countingOn` (the item after this one) or kept when not (a new first item
    /// before it), and an empty box for a task. `nil` when counting on would need a tenth digit,
    /// which is not a list marker.
    func opening(countingOn: Bool) -> String? {
        let next: String
        switch marker {
        case .bullet(let character):
            next = String(character)
        case .ordered(let number, let digits, let delimiter):
            guard !countingOn || number < 999_999_999 else { return nil }
            next = Self.number(countingOn ? number + 1 : number, digits: digits) + String(delimiter)
        }
        // A task carries on as an unticked one; the spacing after its box is kept, or one space
        // when the box ended the line.
        let box = task.map { "[ ]" + ($0.spacing.isEmpty ? " " : $0.spacing) } ?? ""
        return indent + next + spacing + box
    }

    /// A leading zero is kept (`01.` counts on to `02.`); nothing else is padded.
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

/// What Return, Tab and ⇧Tab do inside a Markdown list: pure functions over a buffer and a
/// selection, like ``MarkdownEdits``, so every rule is asserted character for character without a
/// text view. They take an `NSString` so that, handed `textStorage.mutableString`, nothing copies
/// the document to answer a keystroke.
enum MarkdownListEdits {

    /// Told each time ``returnEdit(in:selection:)`` or ``tabEdit(in:selection:outdent:)`` reads the
    /// buffer, so a test can count what one key costs. Task-local, so parallel tests never count
    /// each other's keys.
    @TaskLocal static var onRead: (@Sendable () -> Void)?

    /// What Return does on a list item.
    enum ReturnEdit: Equatable {
        /// Insert the newline exactly as Return would, then this opening, as one undo step apart
        /// from the typing before it, so one ⌘Z takes back the Return and what it added.
        case continueWith(String)
        /// The item is empty: its opening (this range) comes off and the Return goes in after it,
        /// so its line becomes the blank line that ends the list and what is typed next is a
        /// paragraph of its own.
        ///
        /// `indent` goes in after that Return: in a sub-list, the empty item's own indent, so only
        /// the sub-list ends and what is typed belongs to its parent item. Empty at the top level.
        ///
        /// `separatesNext` when a non-blank line follows: a second line break goes in after the
        /// caret too, or that line would read as more of what is typed (`3. Bake` can't start a
        /// list under a paragraph, and would become its words).
        case endList(NSRange, indent: String, separatesNext: Bool)
    }

    /// What Return does at `selection`, or `nil` for "what Return always did".
    ///
    /// Only with the caret at the end of an item's words, nothing selected, whichever line they end
    /// on. Anywhere else, or over a selection, Return is a plain Return: the rule is narrow because
    /// this is the one place Edit writes characters nobody typed. The end of a line the words carry
    /// on from (`- Preheat the oven to` above `  200 degrees`) is the middle, by the parser's say.
    ///
    /// An item with children carries on as its first child, in the child's indent and marker, not
    /// as a sibling the children would then belong to, but only where that child is an item as
    /// written, empty. Under paragraph words only a task box is; elsewhere Return is a Return. Tab
    /// nests an empty item there anyway: see `anEmptyNestedItemStillMoves`.
    ///
    /// The same holds for a sibling: an empty item's content column is one past its marker, so after
    /// `-\th` or `-   wide` the sibling `  - b` would become the new item's child. The parser is
    /// asked there too; see ``opensAnItem``.
    static func returnEdit(in ns: NSString, selection: NSRange) -> ReturnEdit? {
        onRead?()
        guard selection.length == 0, MarkdownEdits.isValid(selection, in: ns) else { return nil }
        let line = MarkdownSourceLines.line(containing: selection.location, in: ns)
        guard selection.location == NSMaxRange(line.content) else { return nil }
        let own = MarkdownListLine.parse(ns.substring(with: line.content))
        // A blank line is no item's words. cmark gives the blank line under a list to its last
        // item, and a marker written there would swallow the paragraph after the list once a word
        // is typed. Only an empty item's own line, which has its marker, is blank and an item's.
        guard own != nil || !isBlank(ns.substring(with: line.content)) else { return nil }
        // No parse for a line no item can hold: one at the left edge with no list line above it in
        // its run of written lines (a lazy line follows its item with no blank line between; every
        // other item line is indented). Most Returns end a paragraph line, and a parse is 15 ms a MB.
        guard own != nil || mightBeInAnItem(line, in: ns),
              let place = MarkdownSourceContext.itemAtLineEnd(at: selection.location, in: ns,
                                                               asIfWritten: own?.isEmpty == true) else { return nil }
        // The item's opening: on this line, or on the line it opened on above.
        let opening = place.itemLine == place.line
            ? own
            : MarkdownSourceLines.line(place.itemLine, from: line, number: place.line, in: ns)
                .flatMap { MarkdownListLine.parse(ns.substring(with: $0.content)) }
        // The opening read off the line must be the item's own. A line can open an item inside
        // another (`- 2.`, `- - a`); its first marker is then the outer item's while the caret ends
        // the inner one, and carrying it on would write the wrong item. Return stays a Return.
        guard let opening, place.markerOffset == opening.indent.utf8.count else { return nil }

        if place.itemLine == place.line, opening.isEmpty {
            // The word the empty item was read with can make the line under it a lazy line of that
            // word; only a line indented to the item's content column is really the item's.
            let next = MarkdownSourceLines.line(after: line, in: ns)
            // And nothing after a blank line is an empty item's: an item that opens blank may have
            // only that one blank line, so `  more` after a blank line under `- ` is a paragraph
            // after the list, not the item's. A box is content, so a task is read as written.
            let opensBlank = opening.task == nil
                && (next.map { isBlank(ns.substring(with: $0.content)) } ?? true)
            let written = opensBlank ? nil : next.flatMap { firstWritten(from: $0, in: ns) }
            let reallyBelow = written.map { indentColumns(of: $0, in: ns) >= opening.contentColumn } ?? false
            guard place.below == .nothing || !reallyBelow else { return nil }
            // Not under a parent that is itself an empty `- `: ending the sub-list leaves a blank
            // line, the parent's second, which would end the parent too and send the sub-items
            // after it to the top level. The parent's first content line is right under it, so the
            // line above says.
            if place.nested, let above = MarkdownSourceLines.line(before: line, in: ns),
               let parent = MarkdownListLine.parse(ns.substring(with: above.content)),
               parent.isEmpty, parent.task == nil, parent.indentColumns < opening.indentColumns {
                return nil
            }
            return .endList(line.content, indent: place.nested ? opening.indent : "",
                            separatesNext: next.map { !isBlank(ns.substring(with: $0.content)) } ?? false)
        }
        switch place.below {
        case .nothing:
            guard let next = opening.opening(countingOn: true) else { return nil }
            // Asked of the parser only where a line below reaches the new item's content column; no
            // other line can become its own, so most Returns skip the parse.
            let following = MarkdownSourceLines.line(after: line, in: ns)
            let below = following.flatMap { firstWritten(from: $0, in: ns) }
            let column = MarkdownListLine.parse(next)?.contentColumn ?? 0
            let reaches = below.map { indentColumns(of: $0, in: ns) >= column }
            guard reaches != true || opensAnItem(next, at: selection, on: place.line, in: ns) else { return nil }
            // And it must still take no line once a word is typed in it: the word gives the line
            // straight under it a paragraph to run on into. Under `- # Groceries` over `Some text`,
            // that paragraph would become the new item's. Asked only where the line right under
            // could run on; a list line short of the new item's words is an item, never words.
            if let following, !isBlank(ns.substring(with: following.content)),
               MarkdownListLine.parse(ns.substring(with: following.content)) == nil
                || indentColumns(of: following, in: ns) >= column {
                guard opensAnItem(next, typed: true, at: selection, on: place.line, in: ns) else { return nil }
            }
            return .continueWith(next)
        case .child(let childLine):
            var child: MarkdownSourceLines.Line? = line
            for _ in place.line..<childLine { child = child.flatMap { MarkdownSourceLines.line(after: $0, in: ns) } }
            guard let first = child.flatMap({ MarkdownListLine.parse(ns.substring(with: $0.content)) })
            else { return nil }
            // The sub-list's own number first, so a sub-list that starts at 3 still does, the new
            // item taking the 3. Numbered 1 only where that alone opens an item: right under the
            // item's words, where only a list starting at 1 may interrupt a paragraph.
            //
            // Only where the opening is an item as it stands, empty. Under paragraph words it rarely
            // is: an empty item may not interrupt a paragraph, so `  - ` is a setext underline and
            // `  * ` or `  1. ` are more words. A task box is content, and a `#` heading is no
            // paragraph; those carry on.
            let numbered = first.renumbered(1)
            for candidate in numbered.marker == first.marker ? [first] : [first, numbered] {
                guard let opening = candidate.opening(countingOn: false) else { continue }
                if opensAnItem(opening, at: selection, on: place.line, in: ns) { return .continueWith(opening) }
            }
            return nil
        case .more:
            return nil
        }
    }

    /// What Tab (or ⇧Tab, `outdent`) does in a list.
    enum TabEdit: Equatable {
        /// Replace `range` with `text` as one undo step, then select `selection`.
        case rewrite(range: NSRange, text: String, selection: NSRange)
        /// The caret is in a list item that can't move that way (the first item of its list for
        /// Tab, a top-level item for ⇧Tab). The key is taken and nothing changes, rather than a tab
        /// character landing in the middle of a list.
        case unchanged
    }

    /// What Tab or ⇧Tab does at `selection`, or `nil` for "what the key always did".
    ///
    /// Anywhere on an item's opening line, with nothing selected or a selection inside that line,
    /// the item moves. A selection over several lines is a plain Tab.
    ///
    /// The indent is the one CommonMark nests by, read from the neighbour rather than fixed: Tab
    /// lines the marker up with the previous item's words (two columns under `- `, three under
    /// `1. `), making it that item's child; ⇧Tab lines it up with the parent item's marker, making
    /// it that item's sibling.
    ///
    /// The item's own lines go with it, and only those, as the parser decides
    /// (``MarkdownSourceContext/itemExtent(at:in:asIfWritten:body:)``): its children, a lazy line,
    /// a code block inside it; not a note indented under the list but outside its last item.
    ///
    /// The parser reads the result back before it is offered, because a list that interrupts a
    /// paragraph may only start at `1.`: `   2. b` under `1. a` would be the words "a 2. b". Such an
    /// item is renumbered `1.`, its number alone; if even that doesn't land, nothing moves.
    ///
    /// Cost: a parse up to the line, one of the whole body, and one per candidate, about 15 ms a MB
    /// each (a quarter of a second at the editor's 4 MiB limit). Kept whole-document on purpose: a
    /// window onto part of it would be a second set of rules about which blocks a move can reach.
    static func tabEdit(in ns: NSString, selection asked: NSRange, outdent: Bool) -> TabEdit? {
        onRead?()
        guard MarkdownEdits.isValid(asked, in: ns) else { return nil }
        let line = MarkdownSourceLines.line(containing: asked.location, in: ns)
        // A selection that ends just past the line's break, as a triple-click selects, is that
        // line; read as two lines, a plain Tab would replace the item with a tab character. Moved
        // here, the selection keeps its break.
        let takesBreak = asked.length > 0 && line.terminatorLength > 0 && NSMaxRange(asked) == line.end
        let selection = takesBreak
            ? NSRange(location: asked.location, length: NSMaxRange(line.content) - asked.location) : asked
        guard NSMaxRange(selection) <= NSMaxRange(line.content),
              let item = MarkdownListLine.parse(ns.substring(with: line.content)) else { return nil }
        let body = MarkdownFrontMatter.bodyStart(in: ns)
        guard case .listItem(let context) = MarkdownSourceContext.block(at: selection.location, in: ns,
                                                                        asIfWritten: item.isEmpty, body: body)
        else { return nil }

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
        // An empty item is read as though a word followed its marker, as everywhere: otherwise
        // CommonMark gives it no lines of its own.
        let extent = MarkdownSourceContext.itemExtent(at: line.content.location, in: ns, asIfWritten: item.isEmpty,
                                                      body: body)
        let lines = ownLines(after: line, number: context.line, through: extent?.lastLine ?? context.line, in: ns)
        let after = lines.last.map { MarkdownSourceLines.line(after: $0, in: ns) } ?? MarkdownSourceLines.line(after: line, in: ns)
        let following = after.flatMap { firstWritten(from: $0, in: ns) }
        let followingItem = following.flatMap { MarkdownListLine.parse(ns.substring(with: $0.content)) }

        // What the document reads as now (from the extent's own parse of the same text), and which
        // of its blocks are this item's.
        let before = extent?.leaves ?? MarkdownSourceContext.leaves(in: item.isEmpty ? written(ns, at: line) : ns, body: body)
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
        // A numbered item Tab makes the first of a new sub-list is numbered 1, as Help says, even
        // where nothing forces it (under a blank line). A move that keeps the number and opens a
        // list is held back while a renumbered one is tried; ⇧Tab keeps the number.
        var heldBack: TabEdit?
        for (renumberItem, renumberFollowing) in candidates {
            let edit = rewrite(item, renumbered: renumberItem, on: line, lines: lines, firstLine: context.line,
                               extent: extent,
                               following: renumberFollowing ? following.flatMap { f in followingItem.map { (f, $0) } } : nil,
                               in: ns, to: target, selection: selection)
            let result = ns.replacingCharacters(in: edit.range, with: edit.text) as NSString
            let movedLine = MarkdownSourceLines.line(startingAt: line.content.location, in: result)
            let leaves = MarkdownSourceContext.leaves(in: item.isEmpty ? written(result, at: movedLine) : result,
                                                      body: body)
            guard sameDocument(before, leaves, moved: moved, by: outdent ? -1 : 1) else { continue }
            let kept = takesBreak
                ? NSRange(location: edit.selection.location, length: edit.selection.length + line.terminatorLength)
                : edit.selection
            let accepted = TabEdit.rewrite(range: edit.range, text: edit.text, selection: kept)
            if !outdent, !renumberItem, ordered(item),
               case .listItem(let landed) = MarkdownSourceContext.block(at: movedLine.content.location, in: result,
                                                                         asIfWritten: item.isEmpty, body: body),
               landed.opensItsList {
                heldBack = heldBack ?? accepted
                continue
            }
            return accepted
        }
        return heldBack ?? .unchanged
    }

    /// The same document with the item moved and nothing else: every block still there, on its
    /// line, of its kind, its words or code byte for byte; the moved item's blocks one level deeper
    /// (Tab) or shallower (⇧Tab), every other block at its level. Whatever the column arithmetic got
    /// wrong (a tab stop, a marker that changed width, a block the extent missed) is caught here,
    /// and the key then changes nothing.
    private static func sameDocument(_ before: [MarkdownSourceContext.Leaf], _ after: [MarkdownSourceContext.Leaf],
                                      moved: ClosedRange<Int>, by step: Int) -> Bool {
        guard before.count == after.count else { return false }
        return zip(before, after).allSatisfy { old, new in
            old.line == new.line && old.kind == new.kind && old.text == new.text
                && new.depth == old.depth + (moved.contains(old.line) ? step : 0)
        }
    }

    /// `ns` with a word after the empty item on `line`, so the parser sees the item it is about to
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

    /// The columns of whitespace `line` starts with.
    private static func indentColumns(of line: MarkdownSourceLines.Line, in ns: NSString) -> Int {
        MarkdownListLine.columns(of: String(ns.substring(with: line.content).prefix { $0 == " " || $0 == "\t" }))
    }

    /// Whether `opening`, written after a Return at `selection` on line `number`, is an item as it
    /// stands (empty, nothing typed after it) that ends where it opens, taking no line below.
    /// Asked of the parser, because CommonMark has two rules the column arithmetic doesn't see: an
    /// empty item may not interrupt a paragraph, and its content column is one past its marker.
    ///
    /// - Parameter typed: ask it of the item with a word typed after the opening, as it will be a
    ///   keystroke later, when a line under it can run on into that word.
    private static func opensAnItem(_ opening: String, typed: Bool = false, at selection: NSRange, on number: Int,
                                    in ns: NSString) -> Bool {
        let opening = typed ? opening + "x" : opening
        let written = ns.replacingCharacters(in: selection, with: "\n" + opening) as NSString
        let caret = selection.location + 1 + (opening as NSString).length
        guard let place = MarkdownSourceContext.itemAtLineEnd(at: caret, in: written) else { return false }
        return place.itemLine == number + 1 && place.below == .nothing
    }

    /// Whether `line` could be part of a list item without being an item's opening: indented, or
    /// with a list line somewhere above it before a blank line (a lazy line). Shape only: the
    /// parser decides, and this spares it the lines it could not say yes to.
    private static func mightBeInAnItem(_ line: MarkdownSourceLines.Line, in ns: NSString) -> Bool {
        let text = ns.substring(with: line.content)
        if text.first == " " || text.first == "\t" { return true }
        var cursor = MarkdownSourceLines.line(before: line, in: ns)
        for _ in 0..<1_000 {
            guard let current = cursor else { return false }
            let above = ns.substring(with: current.content)
            if isBlank(above) { return false }
            if MarkdownListLine.parse(above) != nil || above.first == " " || above.first == "\t" { return true }
            cursor = MarkdownSourceLines.line(before: current, in: ns)
        }
        return true
    }

    /// The rewrite that puts `item`'s marker at column `target` and moves its own lines with it.
    ///
    /// Everything under the item moves by its content column, not its marker's. Each line indented
    /// to the old content column has exactly those columns taken off (a tab straddling the edge
    /// split into spaces) and the new content column put on as spaces, so the item's insides read
    /// the same to the parser; a code line keeps every byte past the edge. A lazy line, indented
    /// less, is left alone. The opening keeps its spacing; a tab there becomes the spaces it was.
    private static func rewrite(_ item: MarkdownListLine, renumbered: Bool, on line: MarkdownSourceLines.Line,
                                lines: [MarkdownSourceLines.Line], firstLine: Int,
                                extent: MarkdownSourceContext.ItemExtent?,
                                following: (MarkdownSourceLines.Line, MarkdownListLine)?,
                                in ns: NSString, to target: Int,
                                selection: NSRange) -> (range: NSRange, text: String, selection: NSRange) {
        let opening = renumbered ? item.renumbered(1) : item
        let oldContent = item.contentColumn
        let markerEnd = item.indentColumns + item.markerText.count
        let spacingColumns = MarkdownListLine.columns(of: item.spacing, startingAt: markerEnd) - markerEnd
        // A tab after the marker becomes the spaces it was: its width depends on the column it
        // starts at, and the marker is about to move. Spaces are kept as written.
        let spacing = item.spacing.contains("\t") && spacingColumns < 5
            ? String(repeating: " ", count: spacingColumns) : item.spacing
        // The new content column, which everything under the item is re-based on, so its children
        // stay its own whatever width the marker now has. Five or more columns of spacing is code in
        // the first line, and the content column is then one past the marker (CommonMark's rule).
        let newMarkerEnd = target + opening.markerText.count
        let newSpacing = MarkdownListLine.columns(of: spacing, startingAt: newMarkerEnd) - newMarkerEnd
        // An empty item's content column is one past its marker, whatever follows it: CommonMark's
        // rule for an item that opens blank, as `contentColumn` reads the old one.
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
            // A blank line is left as it is, unless it is inside code, where whitespace past the
            // edge is the code's own and must move with it.
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
        return (range, rebuilt, NSRange(location: start, length: end - start))
    }

    /// The list line a neighbour sits on, walked to from the caret's; `nil` when the line the parser
    /// named doesn't read as a list item here, so the two disagree and nothing should move.
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
        /// Content (a fenced block's code, raw HTML), kept byte for byte.
        case verbatim
    }

    /// A line inside the item, its first `from` columns of indentation swapped for `to` columns of
    /// spaces, a tab across that edge split into the spaces right of it as the parser splits one.
    /// Past the edge, `mode` decides: indentation becomes spaces at the columns it had (a tab's
    /// width depends on where it starts), and content keeps every byte. A line not indented as far
    /// as the edge is a lazy line, returned as it is.
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
    /// The same opening numbered `number` with no padding: the `1.` a list must start at to
    /// interrupt a paragraph. A bullet is returned as it is.
    func renumbered(_ number: Int) -> MarkdownListLine {
        guard case .ordered(_, _, let delimiter) = marker else { return self }
        var copy = self
        copy.marker = .ordered(number, digits: 1, delimiter: delimiter)
        return copy
    }
}

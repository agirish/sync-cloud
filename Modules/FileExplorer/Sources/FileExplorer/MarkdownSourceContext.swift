import Foundation
import cmark_gfm
import cmark_gfm_extensions

/// **Where a line of a Markdown buffer sits, as the preview's own parser reads it** — the question
/// Return, Tab, a pasted link and a dropped image each ask before they write anything (TE54–TE56).
///
/// **The parser, not a pattern.** "Is this a list item?" has a long tail: a `- ` inside a fenced
/// block, in an indented code block, inside raw HTML, in the front matter; a `- ` that cannot start
/// a list because it would interrupt a paragraph while empty; `- - -`, which is a rule. Each is a
/// rule CommonMark already states and `MarkdownBlocks` already obeys, so this asks the same parser
/// with the same options rather than restating any of it.
///
/// **cmark itself, not swift-markdown's tree**, because this runs on a keystroke. swift-markdown
/// parses with cmark and then converts every node into Swift values — measured 2026-10-04 on a
/// 100 KB note in a debug build, 41ms against cmark's 3ms. Only the buffer up to the end of the line
/// asked about is parsed: nothing below a line changes what opens on it.
enum MarkdownSourceContext {

    /// What holds a line.
    enum Block: Equatable {
        /// Inside the YAML block at the top — see ``MarkdownFrontMatter``.
        case frontMatter
        /// Inside a fenced or indented code block, its fences included.
        case code
        /// Inside a raw HTML block.
        case html
        /// The line opens a list item.
        case listItem(ListItem)
        /// Anything else: a paragraph, a heading, a blank line, a quote, the second line of an item.
        case other
    }

    /// A list item that opens on the line asked about, with the two neighbours Tab and ⇧Tab need.
    struct ListItem: Equatable {
        /// The 1-based line the item opens on — the line asked about, in the file's numbering.
        var line: Int
        /// The 1-based line of the item before it in the same list — or, when it opens a list of
        /// its own, of the last item of a list directly before it — `nil` when there is neither.
        var previousSiblingLine: Int?
        /// The 1-based line of the item whose content holds this item's list, `nil` at the top.
        var parentItemLine: Int?
    }

    /// What holds the line containing UTF-16 offset `location`.
    ///
    /// - Parameter asIfWritten: read the line as though a word followed what is on it. **For an
    ///   item with nothing after its marker**, which CommonMark reads by a different rule — an empty
    ///   item may not interrupt a paragraph, so the `  - ` that Tab makes under `- a`, before
    ///   anything is typed, is paragraph text until a word arrives. Return and ⇧Tab are asked about
    ///   that line exactly then, and mean the item it is about to be.
    static func block(at location: Int, in ns: NSString, asIfWritten: Bool = false,
                      body known: (line: Int, offset: Int)? = nil) -> Block {
        let line = MarkdownSourceLines.line(containing: location, in: ns)
        let body = known ?? MarkdownFrontMatter.bodyStart(in: ns)
        guard line.content.location >= body.offset else { return .frontMatter }

        let prefix = ns.substring(with: NSRange(location: body.offset,
                                                length: NSMaxRange(line.content) - body.offset))
        // Nothing follows the line in what is parsed, so the word reaches no other line.
        var bytes = Array((asIfWritten ? prefix + "x" : prefix).utf8)
        let lastLine = MarkdownSourceLines.lineCount(utf8: bytes)
        return bytes.withUnsafeMutableBufferPointer { buffer -> Block in
            guard let root = parse(buffer) else { return .other }
            defer { cmark_node_free(root) }
            return classify(lastLine, in: root, bodyStartLine: body.line,
                            lineIsBlank: !asIfWritten && ns.substring(with: line.content)
                                .allSatisfy { $0 == " " || $0 == "\t" })
        }
    }

    /// **The list item a Return at the end of `location`'s line would carry on, and what of it lies
    /// BELOW that line** — which ``block(at:in:asIfWritten:body:)`` cannot say, parsing nothing below.
    ///
    /// A Return is only "at the end of an item" when the item ends there: `- Preheat the oven to`
    /// with `  200 degrees` under it is the middle of one, and a marker there would split its
    /// sentence into two items. So the parse runs on to the next line with anything on it — enough,
    /// because whether a line belongs to an item is settled by that line and the ones above it.
    struct ItemAtLineEnd: Equatable {
        /// The 1-based line asked about, in the file's numbering.
        var line: Int
        /// The 1-based line the innermost item holding it opens on — `line` itself, or above it for
        /// the item's second line, a lazy line or a later paragraph of it.
        var itemLine: Int
        var below: Below
        /// Whether the item is in a list inside another item — a sub-list's.
        var nested = false

        enum Below: Equatable {
            /// Nothing: the line ends the item.
            case nothing
            /// The item's first child item, opening on this 1-based line.
            case child(Int)
            /// More of the item — its words carrying on, a paragraph, a block: the line is inside it.
            case more
        }
    }

    /// `nil` when the line is not the words of a list item — code, raw HTML, the front matter, a
    /// quote or a table inside the item, or no item at all.
    static func itemAtLineEnd(at location: Int, in ns: NSString, asIfWritten: Bool = false) -> ItemAtLineEnd? {
        let line = MarkdownSourceLines.line(containing: location, in: ns)
        let body = MarkdownFrontMatter.bodyStart(in: ns)
        guard line.content.location >= body.offset else { return nil }

        // The next line with anything on it, and how far below it is.
        var next = MarkdownSourceLines.line(after: line, in: ns)
        var distance = 1
        while let current = next, ns.substring(with: current.content).allSatisfy({ $0 == " " || $0 == "\t" }) {
            next = MarkdownSourceLines.line(after: current, in: ns)
            distance += 1
        }
        let upTo = ns.substring(with: NSRange(location: body.offset, length: NSMaxRange(line.content) - body.offset))
        let rest = next.map { ns.substring(with: NSRange(location: NSMaxRange(line.content),
                                                         length: NSMaxRange($0.content) - NSMaxRange(line.content))) } ?? ""
        // The word an empty item is read with goes at the end of its line, so no line moves.
        var bytes = Array((upTo + (asIfWritten ? "x" : "") + rest).utf8)
        let lineNumber = MarkdownSourceLines.lineCount(utf8: Array(upTo.utf8))
        let nextNumber = next == nil ? nil : lineNumber + distance

        return bytes.withUnsafeMutableBufferPointer { buffer -> ItemAtLineEnd? in
            guard let root = parse(buffer) else { return nil }
            defer { cmark_node_free(root) }
            let chain = self.chain(holding: lineNumber, in: root)
            let types = chain.map(cmark_node_get_type)
            guard !types.contains(CMARK_NODE_CODE_BLOCK), !types.contains(CMARK_NODE_HTML_BLOCK),
                  let item = chain.last(where: { cmark_node_get_type($0) == CMARK_NODE_ITEM }) else { return nil }
            // The line's own block sits in the item directly: not in a quote or a table inside it.
            if let leaf = chain.last, leaf != item, cmark_node_parent(leaf) != item { return nil }

            func fileLine(_ number: Int) -> Int { number + body.line - 1 }
            var below: ItemAtLineEnd.Below = .nothing
            if let nextNumber, Int(cmark_node_get_end_line(item)) >= nextNumber {
                below = .more
                var list = cmark_node_first_child(item)
                while let current = list, below == .more {
                    if cmark_node_get_type(current) == CMARK_NODE_LIST {
                        var child = cmark_node_first_child(current)
                        while let candidate = child {
                            if Int(cmark_node_get_start_line(candidate)) == nextNumber {
                                below = .child(fileLine(nextNumber))
                                break
                            }
                            child = cmark_node_next(candidate)
                        }
                    }
                    list = cmark_node_next(current)
                }
            }
            let nested = cmark_node_parent(item).flatMap(cmark_node_parent).map {
                cmark_node_get_type($0) == CMARK_NODE_ITEM } ?? false
            return ItemAtLineEnd(line: fileLine(lineNumber),
                                 itemLine: fileLine(Int(cmark_node_get_start_line(item))), below: below, nested: nested)
        }
    }

    /// **Where an image dropped or pasted at `location` goes so that it splits no block** (TE56),
    /// and how many columns it is indented to stay in the list item it lands in.
    ///
    /// On a blank line, right there. On a line with anything on it, after the block that line is
    /// in — a paragraph, a heading, a whole table, a whole quote — never inside it: a drop between a
    /// table's `|`s cut it in two and left the rows below as a paragraph of pipes, and one in a
    /// heading's words made half of them body text. In a list item the image stays in the item, at
    /// its words' column, so the items after it stay where they were.
    ///
    /// **`nil` for a written line no image may break**: in code, raw HTML or the front matter, or a
    /// line no block holds — a link definition, the closing line of an HTML comment. A blank line in
    /// one of those is the caller's to ask about, of the text with the image in it: the blank lines
    /// it adds end some of them and not others.
    static func imageSpot(at location: Int, in ns: NSString) -> (location: Int, indent: Int)? {
        let line = MarkdownSourceLines.line(containing: location, in: ns)
        let body = MarkdownFrontMatter.bodyStart(in: ns)
        func blank(_ line: MarkdownSourceLines.Line) -> Bool {
            ns.substring(with: line.content).allSatisfy { $0 == " " || $0 == "\t" }
        }
        guard line.content.location >= body.offset else { return blank(line) ? (location, 0) : nil }
        let number = MarkdownSourceLines.lineCount(utf8: Array(ns.substring(with: NSRange(
            location: body.offset, length: line.content.location - body.offset)).utf8))
        /// The line `target` (body-relative), walked to from the drop's.
        func lineAt(_ target: Int) -> MarkdownSourceLines.Line? {
            if target <= number { return MarkdownSourceLines.line(target, from: line, number: number, in: ns) }
            var current: MarkdownSourceLines.Line? = line
            for _ in number..<target { current = current.flatMap { MarkdownSourceLines.line(after: $0, in: ns) } }
            return current
        }
        /// The column an item's words start at, read off its opening line from its marker on.
        func contentColumn(_ item: UnsafeMutablePointer<cmark_node>) -> Int {
            guard let opening = lineAt(Int(cmark_node_get_start_line(item))) else { return 0 }
            let bytes = Array(ns.substring(with: opening.content).utf8)
            let column = min(max(Int(cmark_node_get_start_column(item)) - 1, 0), bytes.count)
            let before = String(decoding: bytes[..<column], as: UTF8.self)
            let from = String(decoding: bytes[column...], as: UTF8.self)
            let shape = String(repeating: " ", count: MarkdownListLine.columns(of: before)) + from
            return MarkdownListLine.parse(shape)?.contentColumn ?? 0
        }

        var bytes = Array(ns.substring(from: body.offset).utf8)
        return bytes.withUnsafeMutableBufferPointer { buffer -> (location: Int, indent: Int)? in
            guard let root = parse(buffer) else { return nil }
            defer { cmark_node_free(root) }
            let chain = chain(holding: number, in: root)
            let types = chain.map(cmark_node_get_type)
            if blank(line) {
                // Between two of an item's blocks, it is the item's; after its last, it is not.
                for item in chain.reversed() where cmark_node_get_type(item) == CMARK_NODE_ITEM {
                    let end = Int(cmark_node_get_end_line(item))
                    if end > number, ((number + 1)...end).contains(where: { lineAt($0).map { !blank($0) } ?? false }) {
                        return (location, contentColumn(item))
                    }
                }
                return (location, 0)
            }
            guard !types.contains(CMARK_NODE_CODE_BLOCK), !types.contains(CMARK_NODE_HTML_BLOCK),
                  let leaf = chain.last else { return nil }
            let target = chain.first { cmark_node_get_type($0) == CMARK_NODE_BLOCK_QUOTE }
                ?? chain.first { String(cString: cmark_node_get_type_string($0)) == "table" }
                ?? leaf
            // Its last WRITTEN line — clipped above whatever opens next, and back over blank lines:
            // a setext heading's end is reported one line past its underline, which is a blank line
            // as often as it is the next block's first.
            var end = Int(cmark_node_get_end_line(target))
            var node: UnsafeMutablePointer<cmark_node>? = target
            while let current = node, current != root {
                if let next = cmark_node_next(current) { end = min(end, Int(cmark_node_get_start_line(next)) - 1) }
                node = cmark_node_parent(current)
            }
            while end > number, lineAt(end).map(blank) ?? true { end -= 1 }
            let inside = chain.prefix { $0 != target }.last { cmark_node_get_type($0) == CMARK_NODE_ITEM }
            guard let last = lineAt(max(end, number)) else { return nil }
            return (NSMaxRange(last.content), inside.map(contentColumn) ?? 0)
        }
    }

    /// Whether `location` is somewhere a Markdown edit must leave alone: the front matter, a code
    /// block, or raw HTML. What TE55 and TE56 ask before they write a link into the text.
    static func isLiteral(at location: Int, in ns: NSString) -> Bool {
        switch block(at: location, in: ns) {
        case .frontMatter, .code, .html: return true
        case .listItem, .other: return false
        }
    }

    /// **The lines that belong to the item opening on `location`'s line, as the parser says** —
    /// its children, its continuation text, a lazy line, a fenced block inside it.
    ///
    /// The whole body is parsed, because the answer is BELOW the line. Asked by Tab and ⇧Tab
    /// alone, which move every one of these lines and nothing past them: a note indented under a
    /// list but outside its last item stays where it is, and a child after a lazy line goes along.
    struct ItemExtent {
        /// The item's last line, 1-based in the file's numbering — its opening line when it is one line.
        var lastLine: Int
        /// Lines whose characters past the item's edge are CONTENT, kept byte for byte: a fenced
        /// block's code, raw HTML. A tab there is the file's, not indentation.
        var verbatimLines = IndexSet()
        /// Lines of an indented code block: four columns of their whitespace are the block's
        /// indentation, and the rest is code.
        var indentedCodeLines = IndexSet()
        /// The whole body's ``leaves(in:body:)``, read off the same parse — what a move is held to,
        /// and one parse of the document fewer per Tab.
        var leaves: [Leaf] = []
    }

    static func itemExtent(at location: Int, in ns: NSString, asIfWritten: Bool = false,
                           body known: (line: Int, offset: Int)? = nil) -> ItemExtent? {
        let line = MarkdownSourceLines.line(containing: location, in: ns)
        let body = known ?? MarkdownFrontMatter.bodyStart(in: ns)
        guard line.content.location >= body.offset else { return nil }
        let bodyLine = MarkdownSourceLines.lineCount(utf8: Array(ns.substring(with: NSRange(
            location: body.offset, length: NSMaxRange(line.content) - body.offset)).utf8))
        // An empty item read as though a word followed its marker — see `block(at:in:asIfWritten:)`.
        // The word goes at the end of its line, so no line moves.
        let text = asIfWritten
            ? ns.replacingCharacters(in: NSRange(location: NSMaxRange(line.content), length: 0), with: "x") as NSString
            : ns
        var bytes = Array(text.substring(from: body.offset).utf8)
        return bytes.withUnsafeMutableBufferPointer { buffer -> ItemExtent? in
            guard let root = parse(buffer) else { return nil }
            defer { cmark_node_free(root) }
            // The OUTERMOST item opening on the line: Tab moves the whole line, and everything
            // under it.
            var node: UnsafeMutablePointer<cmark_node>? = root
            var item: UnsafeMutablePointer<cmark_node>?
            // From the LAST child back: a setext heading's end line is reported one past its
            // underline, so walked from the front it would claim the line the next block opens on.
            descend: while let current = node {
                var child = cmark_node_last_child(current)
                node = nil
                while let candidate = child {
                    let start = Int(cmark_node_get_start_line(candidate))
                    let end = Int(cmark_node_get_end_line(candidate))
                    if isBlock(candidate), start <= bodyLine, end >= bodyLine {
                        if cmark_node_get_type(candidate) == CMARK_NODE_ITEM, start == bodyLine {
                            item = candidate
                            break descend
                        }
                        node = candidate
                        break
                    }
                    child = cmark_node_previous(candidate)
                }
            }
            guard let item else { return nil }
            var extent = ItemExtent(lastLine: Int(cmark_node_get_end_line(item)) + body.line - 1)
            classifyLines(under: item, offset: body.line - 1, into: &extent, in: text)
            extent.leaves = leaves(of: root, bodyLine: body.line)
            return extent
        }
    }

    /// Sorts the lines under `node` into ``ItemExtent``'s two kinds. A fenced block's content is
    /// its lines between the fences — its last line too when no closing fence is there, which is
    /// read off the text for every fence in ONE walk down the lines.
    private static func classifyLines(under node: UnsafeMutablePointer<cmark_node>, offset: Int,
                                      into extent: inout ItemExtent, in text: NSString) {
        var fences: [(start: Int, end: Int, character: CChar, length: Int)] = []
        func collect(_ node: UnsafeMutablePointer<cmark_node>) {
            var child = cmark_node_first_child(node)
            while let current = child {
                let type = cmark_node_get_type(current)
                let start = Int(cmark_node_get_start_line(current)) + offset
                let end = Int(cmark_node_get_end_line(current)) + offset
                if type == CMARK_NODE_CODE_BLOCK {
                    var length: Int32 = 0, fenceOffset: Int32 = 0
                    var character: CChar = 0
                    if cmark_node_get_fenced(current, &length, &fenceOffset, &character) != 0 {
                        fences.append((start, end, character, Int(length)))
                    } else if end >= start {
                        extent.indentedCodeLines.insert(integersIn: start...end)
                    }
                } else if type == CMARK_NODE_HTML_BLOCK, end >= start {
                    extent.verbatimLines.insert(integersIn: start...end)
                } else if isBlock(current) {
                    collect(current)
                }
                child = cmark_node_next(current)
            }
        }
        collect(node)
        guard !fences.isEmpty else { return }
        // The text of each fence's last line, found walking down once.
        let wanted = Set(fences.map(\.end))
        var lastLines: [Int: String] = [:]
        var line: MarkdownSourceLines.Line? = MarkdownSourceLines.line(startingAt: 0, in: text)
        var number = 1
        let deepest = wanted.max() ?? 0
        while let current = line, number <= deepest {
            if wanted.contains(number) { lastLines[number] = text.substring(with: current.content) }
            line = MarkdownSourceLines.line(after: current, in: text)
            number += 1
        }
        for fence in fences {
            let closes = lastLines[fence.end].map { closesFence($0, character: fence.character, length: fence.length) } ?? false
            let last = closes ? fence.end - 1 : fence.end
            if last > fence.start { extent.verbatimLines.insert(integersIn: (fence.start + 1)...last) }
        }
    }

    /// Whether `content` is a closing fence of `character` at least `length` long.
    private static func closesFence(_ content: String, character: CChar, length: Int) -> Bool {
        let fence = Character(UnicodeScalar(UInt8(bitPattern: character)))
        let trimmed = content.drop { $0 == " " || $0 == "\t" }
        let run = trimmed.prefix { $0 == fence }
        return run.count >= length && trimmed.dropFirst(run.count).allSatisfy { $0 == " " || $0 == "\t" }
    }

    /// One block the reader sees, as the parser reads it: where it opens, how many list items hold
    /// it, what kind it is, and its words or code.
    struct Leaf: Equatable {
        var line: Int
        var depth: Int
        var kind: UInt32
        var text: String
    }

    /// **Every leaf block of the body and every list item, in order** — what Tab and ⇧Tab hold their
    /// result to. A move is accepted only when the document still reads as the same blocks with the
    /// same words and code, the moved item's own one level deeper or shallower and nothing else changed.
    static func leaves(in ns: NSString, body known: (line: Int, offset: Int)? = nil) -> [Leaf] {
        let body = known ?? MarkdownFrontMatter.bodyStart(in: ns)
        var bytes = Array(ns.substring(from: body.offset).utf8)
        return bytes.withUnsafeMutableBufferPointer { buffer -> [Leaf] in
            guard let root = parse(buffer) else { return [] }
            defer { cmark_node_free(root) }
            return leaves(of: root, bodyLine: body.line)
        }
    }

    private static func leaves(of root: UnsafeMutablePointer<cmark_node>, bodyLine: Int) -> [Leaf] {
        var leaves: [Leaf] = []
        func walk(_ node: UnsafeMutablePointer<cmark_node>, depth: Int) {
            var child = cmark_node_first_child(node)
            while let current = child {
                if isBlock(current) {
                    let type = cmark_node_get_type(current)
                    let line = Int(cmark_node_get_start_line(current)) + bodyLine - 1
                    if type == CMARK_NODE_ITEM {
                        // **Every item is counted where it opens, at its depth**, empty or not —
                        // or an empty one's nesting would be the one thing a move could change
                        // unseen. Counted as itself, not as a leaf, so an empty item that GAINS a
                        // child (Tab on the item under it) is still the same item.
                        leaves.append(Leaf(line: line, depth: depth + 1, kind: type.rawValue, text: ""))
                        walk(current, depth: depth + 1)
                    } else if cmark_node_first_child(current) == nil || !isBlock(cmark_node_first_child(current)!) {
                        if type != CMARK_NODE_LIST {
                            leaves.append(Leaf(line: line, depth: depth, kind: type.rawValue, text: words(current)))
                        }
                    } else {
                        walk(current, depth: depth)
                    }
                }
                child = cmark_node_next(current)
            }
        }
        walk(root, depth: 0)
        return leaves
    }

    /// A block's words, or its code: every literal under it, a soft or hard break as a space.
    private static func words(_ node: UnsafeMutablePointer<cmark_node>) -> String {
        if let literal = cmark_node_get_literal(node), !isBlock(node) || cmark_node_first_child(node) == nil {
            return String(cString: literal)
        }
        var text = ""
        var child = cmark_node_first_child(node)
        while let current = child {
            let type = cmark_node_get_type(current)
            if type == CMARK_NODE_SOFTBREAK || type == CMARK_NODE_LINEBREAK {
                text += " "
            } else {
                text += words(current)
            }
            child = cmark_node_next(current)
        }
        return text
    }

    // MARK: - The parse

    /// **The preview's parser, configured as the preview configures it** — swift-markdown 0.8's
    /// `CommonMarkConverter.parseString`: `TABLE_SPANS`, `SMART`, `SOURCEPOS`, and the table,
    /// strikethrough and tasklist extensions. Lines here are the preview's lines.
    private static func parse(_ buffer: UnsafeMutableBufferPointer<UInt8>) -> UnsafeMutablePointer<cmark_node>? {
        cmark_gfm_core_extensions_ensure_registered()
        guard let parser = cmark_parser_new(CMARK_OPT_TABLE_SPANS | CMARK_OPT_SMART | CMARK_OPT_SOURCEPOS)
        else { return nil }
        defer { cmark_parser_free(parser) }
        for name in ["table", "strikethrough", "tasklist"] {
            if let extensionPointer = cmark_find_syntax_extension(name) {
                cmark_parser_attach_syntax_extension(parser, extensionPointer)
            }
        }
        buffer.baseAddress.map { base in
            base.withMemoryRebound(to: CChar.self, capacity: buffer.count) {
                cmark_parser_feed(parser, $0, buffer.count)
            }
        }
        return cmark_parser_finish(parser)
    }

    /// Walks down the blocks that hold `line` — the LAST child at each level, because nothing was
    /// parsed below it — and reads the answer off that chain.
    private static func classify(_ line: Int, in root: UnsafeMutablePointer<cmark_node>,
                                 bodyStartLine: Int, lineIsBlank: Bool) -> Block {
        let chain = chain(holding: line, in: root)
        let types = chain.map(cmark_node_get_type)
        if types.contains(CMARK_NODE_CODE_BLOCK) { return .code }
        if types.contains(CMARK_NODE_HTML_BLOCK) { return .html }
        // cmark reports an HTML block that closes on its own end condition (`-->`, `</pre>`) as
        // ending one line short — so the closing line, last in what was parsed, is still its.
        // **Never a blank line**: one after `</details>`, the last in what was parsed, is reported
        // the same way, and it is the line that ENDS that block.
        if chain.isEmpty, !lineIsBlank, let last = cmark_node_last_child(root),
           cmark_node_get_type(last) == CMARK_NODE_HTML_BLOCK,
           Int(cmark_node_get_end_line(last)) == line - 1 {
            return .html
        }
        // A quoted item opens on this line too, but its line starts `> ` — and every caller reads
        // the line with `MarkdownListLine.parse` first, which takes only whitespace before a
        // marker, so a quoted list is never one these edits rewrite.
        guard let item = chain.last(where: {
            cmark_node_get_type($0) == CMARK_NODE_ITEM && Int(cmark_node_get_start_line($0)) == line
        }) else { return .other }

        func fileLine(_ node: UnsafeMutablePointer<cmark_node>) -> Int {
            Int(cmark_node_get_start_line(node)) + bodyStartLine - 1
        }
        var previous = cmark_node_previous(item).map(fileLine)
        let list = cmark_node_parent(item)
        if previous == nil, let list, let before = cmark_node_previous(list),
           cmark_node_get_type(before) == CMARK_NODE_LIST, let last = cmark_node_last_child(before) {
            // A change of bullet character starts a new list (`- a` then `* b`), which reads as the
            // same list to anybody looking at it; Tab nests under the item just above either way.
            previous = fileLine(last)
        }
        let grandparent = list.flatMap(cmark_node_parent)
        let parent = grandparent.flatMap { cmark_node_get_type($0) == CMARK_NODE_ITEM ? fileLine($0) : nil }
        return .listItem(ListItem(line: line + bodyStartLine - 1, previousSiblingLine: previous,
                                  parentItemLine: parent))
    }

    /// The blocks that hold `line`, outermost first — walked from the LAST child back at each
    /// level: a setext heading's end line is reported one past its underline, so from the front it
    /// would claim the line the next block opens on.
    private static func chain(holding line: Int, in root: UnsafeMutablePointer<cmark_node>)
        -> [UnsafeMutablePointer<cmark_node>] {
        var chain: [UnsafeMutablePointer<cmark_node>] = []
        var node: UnsafeMutablePointer<cmark_node>? = root
        while let current = node {
            var child = cmark_node_last_child(current)
            node = nil
            while let candidate = child {
                if isBlock(candidate),
                   Int(cmark_node_get_start_line(candidate)) <= line,
                   Int(cmark_node_get_end_line(candidate)) >= line {
                    chain.append(candidate)
                    node = candidate
                    break
                }
                child = cmark_node_previous(candidate)
            }
        }
        return chain
    }

    private static func isBlock(_ node: UnsafeMutablePointer<cmark_node>) -> Bool {
        (UInt32(cmark_node_get_type(node).rawValue) & UInt32(CMARK_NODE_TYPE_MASK)) == UInt32(CMARK_NODE_TYPE_BLOCK)
    }
}

/// **Lines as the parser counts them: `\n`, `\r\n` or a lone `\r` ends one, and nothing else does.**
///
/// `NSString.lineRange(for:)` also breaks at U+2028, U+2029 and U+0085, which cmark reads as
/// ordinary characters — so a line number from one and a range from the other would name different
/// lines in any note holding one of those. Everything here that turns a parser line into a range of
/// the buffer goes through this instead.
enum MarkdownSourceLines {

    struct Line: Equatable {
        /// The line's characters, its terminator excluded.
        var content: NSRange
        /// 0, 1 (`\n` or `\r`) or 2 (`\r\n`).
        var terminatorLength: Int
        var end: Int { NSMaxRange(content) + terminatorLength }
    }

    /// The line holding `location`. An offset just after a terminator is on the next line.
    static func line(containing location: Int, in ns: NSString) -> Line {
        let length = ns.length
        let clamped = min(max(location, 0), length)
        var start = clamped
        while start > 0 {
            let previous = ns.character(at: start - 1)
            if previous == 0x0A || previous == 0x0D { break }
            start -= 1
        }
        return line(startingAt: start, in: ns)
    }

    /// The line starting at `start`, which must be a line start.
    static func line(startingAt start: Int, in ns: NSString) -> Line {
        let length = ns.length
        var end = start
        while end < length {
            let character = ns.character(at: end)
            if character == 0x0A { return Line(content: NSRange(location: start, length: end - start), terminatorLength: 1) }
            if character == 0x0D {
                let crlf = end + 1 < length && ns.character(at: end + 1) == 0x0A
                return Line(content: NSRange(location: start, length: end - start), terminatorLength: crlf ? 2 : 1)
            }
            end += 1
        }
        return Line(content: NSRange(location: start, length: end - start), terminatorLength: 0)
    }

    /// The line after `line`, or `nil` when `line` is the last.
    static func line(after line: Line, in ns: NSString) -> Line? {
        guard line.terminatorLength > 0 else { return nil }
        return self.line(startingAt: line.end, in: ns)
    }

    /// The line before `line`, or `nil` when `line` is the first.
    ///
    /// **Found from the START of the terminator before it**, which in a Windows file is two
    /// characters back: one back is the `\n` of a `\r\n`, and the "line" holding it is the empty
    /// gap between the two — every neighbour Tab looked up in a CRLF file came back blank.
    static func line(before line: Line, in ns: NSString) -> Line? {
        guard line.content.location > 0 else { return nil }
        var end = line.content.location - 1
        if ns.character(at: end) == 0x0A, end > 0, ns.character(at: end - 1) == 0x0D { end -= 1 }
        return self.line(containing: end, in: ns)
    }

    /// How many lines the parser sees in `bytes` — the line number of the last one.
    static func lineCount(utf8 bytes: [UInt8]) -> Int {
        var count = 1
        var index = 0
        while index < bytes.count {
            if bytes[index] == 0x0A {
                count += 1
            } else if bytes[index] == 0x0D {
                count += 1
                if index + 1 < bytes.count, bytes[index + 1] == 0x0A { index += 1 }
            }
            index += 1
        }
        return count
    }

    /// The line `target` lines above `line` (`target < number`), walking up from it — the
    /// neighbours the parser names are almost always close by, so this is not a walk from the top.
    static func line(_ target: Int, from line: Line, number: Int, in ns: NSString) -> Line? {
        guard target >= 1, target <= number else { return nil }
        var current = line
        var at = number
        while at > target {
            guard let previous = self.line(before: current, in: ns) else { return nil }
            current = previous
            at -= 1
        }
        return current
    }
}

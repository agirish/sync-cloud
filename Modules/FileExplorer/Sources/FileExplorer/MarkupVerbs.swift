import Foundation

/// A markup verb: what the reader asked to do to the selection.
///
/// **Toggles, not inserts.** Every one of these that can be undone by repeating it is — pressing
/// bold on bold text takes the asterisks off. An editor whose Bold only ever adds `**` is one that
/// requires the keyboard to correct what the menu just did.
enum MarkupVerb: Equatable, Sendable {
    case bold
    case italic
    case strikethrough
    case inlineCode
    case link
    /// `0` is Body: the heading marker comes off and nothing replaces it.
    case heading(Int)
    case bulletList
    case numberedList
    case taskItem
    case blockQuote
    case codeBlock
    case horizontalRule

    /// The verbs the context menu offers, in the order it offers them; `nil` is a separator.
    ///
    /// **One flat list, because a menu item carries an `Int` and not an enum.** `NSMenuItem.tag` is
    /// how the click gets back here, so the index in this array IS the identity — which makes the
    /// order load-bearing in a way a menu's usually is not. Appending is safe; reordering is not.
    static let menuOrder: [MarkupVerb?] = [
        .bold, .italic, .strikethrough, .inlineCode, .link,
        nil,
        .heading(1), .heading(2), .heading(3), .heading(0),
        nil,
        .bulletList, .numberedList, .taskItem, .blockQuote,
        nil,
        .codeBlock, .horizontalRule,
    ]

    var title: String {
        switch self {
        case .bold: return "Bold"
        case .italic: return "Italic"
        case .strikethrough: return "Strikethrough"
        case .inlineCode: return "Inline Code"
        case .link: return "Link…"
        case .heading(0): return "Body"
        case .heading(let level): return "Heading \(level)"
        case .bulletList: return "Bulleted List"
        case .numberedList: return "Numbered List"
        case .taskItem: return "Task Item"
        case .blockQuote: return "Block Quote"
        case .codeBlock: return "Code Block"
        case .horizontalRule: return "Horizontal Rule"
        }
    }
}

/// A buffer and where the selection should be in it afterwards.
struct MarkupEdit: Equatable, Sendable {
    var text: String
    /// **In UTF-16, because that is what `NSTextView` speaks.** Everything else in this app counts
    /// characters; this one value is handed straight to `setSelectedRange`, so converting it would
    /// mean converting it back.
    var selection: NSRange
}

extension MarkdownEdits {

    /// Applies a verb to a selection, or answers `nil` when it does not apply.
    static func apply(_ verb: MarkupVerb, to text: String, selection: NSRange) -> MarkupEdit? {
        let ns = text as NSString
        guard selection.location != NSNotFound,
              selection.location >= 0,
              NSMaxRange(selection) <= ns.length else { return nil }

        switch verb {
        case .bold: return wrap(text, selection, with: "**")
        case .italic: return wrap(text, selection, with: "*", guardingAgainst: "*")
        case .strikethrough: return wrap(text, selection, with: "~~")
        case .inlineCode: return wrap(text, selection, with: "`")
        case .link: return link(text, selection)
        case .heading(let level): return prefixLines(text, selection, .heading(level))
        case .bulletList: return prefixLines(text, selection, .bullet)
        case .numberedList: return prefixLines(text, selection, .numbered)
        case .taskItem: return prefixLines(text, selection, .task)
        case .blockQuote: return prefixLines(text, selection, .quote)
        case .codeBlock: return fence(text, selection)
        case .horizontalRule: return rule(text, selection)
        }
    }

    // MARK: Inline

    /// Wraps the selection, or unwraps it when it is already wrapped.
    ///
    /// - Parameter guardingAgainst: a character that must NOT sit just outside the delimiters for
    ///   an unwrap to count. This is what stops Italic on the inside of `**bold**` seeing one `*`
    ///   on each side and quietly demoting it — with the guard, italic on bold text produces
    ///   `***both***`, which is what was asked for.
    static func wrap(_ text: String, _ selection: NSRange, with delimiter: String,
                     guardingAgainst neighbour: String? = nil) -> MarkupEdit {
        let ns = text as NSString
        let width = (delimiter as NSString).length
        let selected = ns.substring(with: selection)

        // Wrapped inside the selection: `**bold**` selected whole.
        if (selected as NSString).length >= width * 2,
           selected.hasPrefix(delimiter), selected.hasSuffix(delimiter) {
            let inner = (selected as NSString).substring(
                with: NSRange(location: width, length: (selected as NSString).length - width * 2))
            return MarkupEdit(text: ns.replacingCharacters(in: selection, with: inner),
                              selection: NSRange(location: selection.location,
                                                 length: (inner as NSString).length))
        }

        // Wrapped just outside it: `bold` selected between the asterisks.
        let before = NSRange(location: selection.location - width, length: width)
        let after = NSRange(location: NSMaxRange(selection), length: width)
        if selection.location >= width, NSMaxRange(after) <= ns.length,
           ns.substring(with: before) == delimiter, ns.substring(with: after) == delimiter,
           !isNeighboured(ns, before: before, after: after, by: neighbour) {
            let outer = NSRange(location: before.location, length: width * 2 + selection.length)
            return MarkupEdit(text: ns.replacingCharacters(in: outer, with: selected),
                              selection: NSRange(location: before.location, length: selection.length))
        }

        // Otherwise wrap it. An empty selection becomes an empty pair with the caret inside, which
        // is what somebody who pressed Bold before typing the word meant.
        let wrapped = delimiter + selected + delimiter
        return MarkupEdit(text: ns.replacingCharacters(in: selection, with: wrapped),
                          selection: NSRange(location: selection.location + width,
                                             length: selection.length))
    }

    private static func isNeighboured(_ ns: NSString, before: NSRange, after: NSRange,
                                      by neighbour: String?) -> Bool {
        guard let neighbour else { return false }
        let width = (neighbour as NSString).length
        let outerBefore = NSRange(location: before.location - width, length: width)
        if outerBefore.location >= 0, ns.substring(with: outerBefore) == neighbour { return true }
        let outerAfter = NSRange(location: NSMaxRange(after), length: width)
        if NSMaxRange(outerAfter) <= ns.length, ns.substring(with: outerAfter) == neighbour {
            return true
        }
        return false
    }

    /// `[selection](url)`, with the half that still needs typing selected.
    ///
    /// **Which half depends on what was selected.** With words selected, the words are the link
    /// text and the destination is what is missing; with nothing selected, both are missing and the
    /// text is what gets typed first.
    static func link(_ text: String, _ selection: NSRange) -> MarkupEdit {
        let ns = text as NSString
        let selected = ns.substring(with: selection)
        if selection.length == 0 {
            let inserted = "[text](url)"
            return MarkupEdit(text: ns.replacingCharacters(in: selection, with: inserted),
                              selection: NSRange(location: selection.location + 1, length: 4))
        }
        let inserted = "[\(selected)](url)"
        // The `url` placeholder: past `[`, the text, `](`.
        let start = selection.location + 1 + (selected as NSString).length + 2
        return MarkupEdit(text: ns.replacingCharacters(in: selection, with: inserted),
                          selection: NSRange(location: start, length: 3))
    }

    // MARK: Line prefixes

    /// What a line-level verb does to one line.
    enum LinePrefix {
        case heading(Int)
        case bullet
        case numbered
        case task
        case quote

        /// What already-applied looks like.
        var pattern: String {
            switch self {
            case .heading: return "^#{1,6}[ \t]+"
            // **Not a task**, which also opens with a bullet: pressing Bulleted List on a checklist
            // should make it a plain list, not strip the dash and leave the boxes behind.
            case .bullet: return "^[-*+][ \t]+(?!\\[[ xX]\\][ \t])"
            case .numbered: return "^[0-9]+[.)][ \t]+"
            case .task: return "^[-*+][ \t]+\\[[ xX]\\][ \t]+"
            case .quote: return "^>[ \t]?"
            }
        }

        /// What counts as "this verb is ALREADY applied here", which decides whether a press adds
        /// or removes.
        ///
        /// **Not the same question as ``pattern``, and conflating them broke headings.** `pattern`
        /// is what gets stripped — any heading marker — while this is what the press asked for. A
        /// document line reading `# Title` matches "is a heading", so asking for Heading 3 on it
        /// was read as "it already has one, take it off" and demoted the line to a paragraph.
        /// Level-exact here, level-agnostic there.
        var appliedPattern: String {
            switch self {
            case .heading(let level):
                guard level > 0 else { return "(?!)" }   // matches nothing: Body only ever removes
                return "^#{\(min(level, 6))}[ \t]+"
            default: return pattern
            }
        }

        /// Prefixes of OTHER kinds this one replaces rather than stacks on.
        ///
        /// **Quote replaces nothing**, which is the one asymmetry here and it is Markdown's: `> `
        /// nests in front of whatever the line already was, so quoting a bulleted list leaves a
        /// quoted bulleted list. The rest are alternatives to each other — a line is a heading or a
        /// list item, not both.
        var replaces: [String] {
            switch self {
            case .quote: return []
            default: return [LinePrefix.heading(1).pattern, LinePrefix.bullet.pattern,
                             LinePrefix.numbered.pattern, LinePrefix.task.pattern]
            }
        }

        func text(at index: Int) -> String {
            switch self {
            case .heading(let level):
                return level <= 0 ? "" : String(repeating: "#", count: min(level, 6)) + " "
            case .bullet: return "- "
            case .numbered: return "\(index + 1). "
            case .task: return "- [ ] "
            case .quote: return "> "
            }
        }
    }

    /// Adds a line prefix to every line the selection touches, or takes it off when every one of
    /// them already has it.
    ///
    /// **"Every one" is the rule, and the alternative is worse.** Toggling per line turns a mixed
    /// selection inside out — the plain lines become quoted and the quoted ones plain — which is
    /// never what somebody dragging across a paragraph meant. Asking whether they ALL have it means
    /// the first press finishes the job and the second undoes it.
    static func prefixLines(_ text: String, _ selection: NSRange, _ prefix: LinePrefix) -> MarkupEdit? {
        let ns = text as NSString
        let lines = lineRanges(covering: selection, in: ns)
        guard !lines.isEmpty else { return nil }

        // Body is a removal with nothing to put back, so it is never a toggle.
        let isRemoval: Bool
        if case .heading(let level) = prefix, level <= 0 {
            isRemoval = true
        } else {
            isRemoval = lines.allSatisfy { range in
                let line = ns.substring(with: range)
                return line.trimmingCharacters(in: .whitespaces).isEmpty
                    || firstMatch(prefix.appliedPattern, in: line) != nil
            }
        }

        var result = text
        var delta = 0
        var numbered = 0
        for range in lines {
            let shifted = NSRange(location: range.location + delta, length: range.length)
            let line = (result as NSString).substring(with: shifted)
            // A blank line inside a selection keeps its blankness: prefixing it would put a lone
            // `- ` between two paragraphs.
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let rewritten = isRemoval ? stripping(prefix, from: line)
                                      : applying(prefix, to: line, at: numbered)
            numbered += 1
            result = (result as NSString).replacingCharacters(in: shifted, with: rewritten)
            delta += (rewritten as NSString).length - shifted.length
        }
        guard result != text else { return nil }
        return MarkupEdit(text: result, selection: selectionAfter(selection, delta: delta, in: result))
    }

    private static func stripping(_ prefix: LinePrefix, from line: String) -> String {
        guard let match = firstMatch(prefix.pattern, in: line) else { return line }
        return (line as NSString).replacingCharacters(in: match, with: "")
    }

    private static func applying(_ prefix: LinePrefix, to line: String, at index: Int) -> String {
        var body = line
        // Its own kind first, so re-applying at a different level replaces rather than stacks.
        body = stripping(prefix, from: body)
        for pattern in prefix.replaces {
            if let match = firstMatch(pattern, in: body) {
                body = (body as NSString).replacingCharacters(in: match, with: "")
            }
        }
        return prefix.text(at: index) + body
    }

    /// The selection after an edit that changed the buffer's length by `delta`.
    ///
    /// **The whole run stays selected**, growing or shrinking with it, because the next verb is
    /// usually aimed at the same lines — quote it, then make it a list. A caret left at the end
    /// would mean re-dragging between every pair of verbs.
    private static func selectionAfter(_ selection: NSRange, delta: Int, in text: String) -> NSRange {
        let length = (text as NSString).length
        let location = min(max(selection.location, 0), length)
        return NSRange(location: location, length: min(max(selection.length + delta, 0), length - location))
    }

    // MARK: Blocks

    /// Wraps the touched lines in a fence.
    ///
    /// **Insert only, never a toggle**, and the reason is that the opposite operation is ambiguous:
    /// the fence that would have to come off is not in the selection, it is the line above and the
    /// line below it, and a "selection" of a fenced block made by dragging usually includes neither.
    static func fence(_ text: String, _ selection: NSRange) -> MarkupEdit {
        let ns = text as NSString
        let lines = lineRanges(covering: selection, in: ns)
        let start = lines.first?.location ?? selection.location
        let end = lines.last.map { NSMaxRange($0) } ?? NSMaxRange(selection)
        let body = ns.substring(with: NSRange(location: start, length: end - start))
        let fenced = "```\n" + body + "\n```"
        let replaced = NSRange(location: start, length: end - start)
        return MarkupEdit(text: ns.replacingCharacters(in: replaced, with: fenced),
                          // Inside the fence, on the code — not on the fence line nobody edits.
                          selection: NSRange(location: start + 4, length: (body as NSString).length))
    }

    /// A thematic break on its own line, below the line the caret is on.
    ///
    /// **Inserted after the line's TERMINATOR, not after its last character.** Landing before the
    /// newline pushes it down and leaves a stray blank line behind the rule. And the rule carries a
    /// blank line above it, which is what makes `---` a thematic break rather than a setext heading
    /// underlining the paragraph — the exact confusion ``MarkdownFrontMatter`` documents.
    static func rule(_ text: String, _ selection: NSRange) -> MarkupEdit {
        let ns = text as NSString
        let clamped = NSRange(location: min(selection.location, ns.length),
                              length: min(selection.length, max(ns.length - min(selection.location, ns.length), 0)))
        let end = ns.length == 0 ? 0 : NSMaxRange(ns.lineRange(for: clamped))
        // At the very end of a buffer whose last line has no terminator, the rule needs one of its
        // own before the blank line.
        let terminated = end > 0
            && CharacterSet.newlines.contains(UnicodeScalar(ns.character(at: end - 1)) ?? " ")
        let inserted = (terminated ? "" : "\n") + "\n---\n"
        return MarkupEdit(text: ns.replacingCharacters(in: NSRange(location: end, length: 0),
                                                       with: inserted),
                          selection: NSRange(location: end + (inserted as NSString).length, length: 0))
    }

    // MARK: Helpers

    /// The individual lines the selection touches, terminators excluded.
    static func lineRanges(covering selection: NSRange, in ns: NSString) -> [NSRange] {
        guard ns.length > 0 else { return [NSRange(location: 0, length: 0)] }
        let clamped = NSRange(location: min(selection.location, ns.length),
                              length: min(selection.length, ns.length - min(selection.location, ns.length)))
        let paragraph = ns.lineRange(for: clamped)
        var ranges: [NSRange] = []
        ns.enumerateSubstrings(in: paragraph, options: [.byLines, .substringNotRequired]) { _, range, _, _ in
            ranges.append(range)
        }
        // A selection sitting on a trailing empty line produces no substrings at all.
        return ranges.isEmpty ? [NSRange(location: paragraph.location, length: 0)] : ranges
    }

    /// The smallest edit that turns `old` into `new`: one range and one replacement.
    ///
    /// **So the change goes through the text view as an edit rather than as a new buffer.** Handing
    /// `NSTextView` a whole new string is not an edit it can undo — ⌘Z after a Bold would step back
    /// to whatever the last *typed* change was, past the verb entirely — and on a 4 MiB document it
    /// relayouts everything to change two characters. Common prefix and common suffix in UTF-16,
    /// which is all these verbs ever produce: every one of them touches a contiguous run.
    static func minimalReplacement(from old: String, to new: String) -> (range: NSRange, text: String) {
        let a = old as NSString
        let b = new as NSString
        var prefix = 0
        let shortest = min(a.length, b.length)
        while prefix < shortest, a.character(at: prefix) == b.character(at: prefix) { prefix += 1 }
        var suffix = 0
        while suffix < shortest - prefix,
              a.character(at: a.length - 1 - suffix) == b.character(at: b.length - 1 - suffix) {
            suffix += 1
        }
        let range = NSRange(location: prefix, length: a.length - prefix - suffix)
        let replacement = b.substring(with: NSRange(location: prefix,
                                                    length: b.length - prefix - suffix))
        return (range, replacement)
    }

    private static func firstMatch(_ pattern: String, in line: String) -> NSRange? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(location: 0, length: (line as NSString).length)
        return regex.firstMatch(in: line, range: range)?.range
    }
}

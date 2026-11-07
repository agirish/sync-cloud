import Foundation
import Events

/// Edit writes Mac (LF) line endings, and only those.
///
/// A file is converted on its first edit, not when opened: a CRLF, CR or mixed file opened, or
/// saved unchanged, comes back byte for byte (``EditorFileStore/open(path:fileManager:isCloudOnly:)``).
/// The first change turns every line break to LF, inside that change's undo step, so one ⌘Z gives
/// back the file as opened. Keeping each file's own ending would leave files mixed, since every path
/// that writes a line break writes `\n` (`LineEndingPathsTests` pins every path).
///
/// Two doors, one rule: ``EditorTextView`` for everything typed, pasted or dropped into Source and
/// the Markup verbs, and ``EditorSourceStorage/replace(_:with:undoManager:actionName:verbatim:)``
/// for an edit from outside the view, such as a Preview checkbox tick.
enum EditorLineEndings {

    /// One carriage return and what it becomes: nothing for the CR of a CRLF, `\n` for a lone CR.
    struct Change: Equatable {
        var range: NSRange
        var replacement: String
    }

    /// Every carriage return in `text`, in order; empty for a text that is already all LF.
    static func carriageReturns(in text: NSString) -> [Change] {
        var changes: [Change] = []
        var search = NSRange(location: 0, length: text.length)
        while true {
            let found = text.range(of: "\r", options: .literal, range: search)
            guard found.location != NSNotFound else { break }
            let pair = NSMaxRange(found) < text.length && text.character(at: NSMaxRange(found)) == 0x0A
            changes.append(Change(range: found, replacement: pair ? "" : "\n"))
            search = NSRange(location: NSMaxRange(found), length: text.length - NSMaxRange(found))
        }
        return changes
    }

    /// `text` with every CRLF and lone CR as LF.
    static func normalized(_ text: String) -> String {
        // By unit: `"\r\n"` is one Character, and a Character search for "\r" would not find it.
        guard text.utf16.contains(0x0D) else { return text }
        // `"\r\n"` is one Character, so the replacements go by unit, CRLF first.
        return text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    /// Text coming in (a paste, a drop) with every line break as LF: CRLF and CR as
    /// ``normalized(_:)``, plus U+2028, U+2029 and U+0085. Pages and Word put U+2028 on the
    /// clipboard for a soft return, which the text view draws as a break and cmark reads as none.
    /// Never a file's own text: a separator already in it is left alone.
    static func normalizedIncoming(_ text: String) -> String {
        let lf = normalized(text)
        guard lf.utf16.contains(where: { $0 == 0x2028 || $0 == 0x2029 || $0 == 0x85 }) else { return lf }
        return lf.replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")
            .replacingOccurrences(of: "\u{0085}", with: "\n")
    }

    /// Where `offset` lands once `changes` are made: one unit earlier for every CRLF's CR before it.
    /// An offset between a CR and its LF lands on the LF, which is now where that break starts.
    static func mapped(_ offset: Int, through changes: [Change]) -> Int {
        var shift = 0
        for change in changes where change.replacement.isEmpty && change.range.location < offset {
            shift += 1
        }
        return offset - shift
    }

    /// The one log line every conversion writes. A conversion changes every line of a file, so
    /// "my file changed" must be answerable from the log. Kinds and counts only, never the text.
    /// Nothing for no changes.
    static func logConversion(_ changes: [Change], of fileName: String?, on trigger: String) {
        guard !changes.isEmpty else { return }
        let crlf = changes.filter { $0.replacement.isEmpty }.count
        Logger.shared.info("[edit] converted \(fileName ?? "the open file") to LF — \(crlf) CRLF, "
                           + "\(changes.count - crlf) CR, on \(trigger)")
    }

    static func mapped(_ range: NSRange, through changes: [Change]) -> NSRange {
        let start = mapped(range.location, through: changes)
        let end = mapped(NSMaxRange(range), through: changes)
        return NSRange(location: start, length: max(0, end - start))
    }
}

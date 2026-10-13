import Foundation
import Events

/// Edit writes Mac (LF) line endings, and only those — the user's direction, 2026-10-05.
///
/// **A file is converted on its first EDIT, not when it is opened.** A CRLF, CR or mixed file that
/// is opened and read — or opened and saved without a change — comes back byte for byte, which is
/// what ``EditorFileStore/open(path:fileManager:isCloudOnly:)`` promises. The first change turns
/// every line break in it to LF, and everything written after that is LF. The conversion is part
/// of that first change's undo step, so one ⌘Z gives back the file exactly as it was opened.
///
/// **Why not keep each file's own ending:** measured 2026-10-05, every path that writes a line
/// break — Return, Return in a list, the Code Block and Horizontal Rule verbs, a paste or drop of
/// several lines, Replace with a line break — wrote `\n` into CRLF and CR files and left them
/// mixed, with the status line reading "Mixed". The choice was put to him: match each file, or
/// write LF. He chose LF, converting on edit (`LineEndingPathsTests` pins every path).
///
/// **Two doors, one rule:** ``EditorTextView`` for everything typed, pasted or dropped into Source and
/// the Markup verbs, and ``EditorSourceStorage/replace(_:with:undoManager:actionName:)`` for an edit
/// from outside the view — a Preview checkbox tick today.
enum EditorLineEndings {

    /// One carriage return and what it becomes: nothing for the CR of a CRLF, `\n` for a lone CR.
    struct Change: Equatable {
        var range: NSRange
        var replacement: String
    }

    /// Every carriage return in `text`, in order — empty for a text that is already all LF.
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

    /// **Text coming in — a paste, a drop — with every line break it carries as LF**: CRLF and CR as
    /// ``normalized(_:)``, and Unicode's LINE SEPARATOR (U+2028), PARAGRAPH SEPARATOR (U+2029) and
    /// NEXT LINE (U+0085) too. Pages and Word put U+2028 on the clipboard for a soft return, which
    /// the text view draws as a line break and cmark — and every other tool — reads as none: a line
    /// that is two on screen and one in the note. **Never a file's own text** (the user's direction,
    /// 2026-10-09): a separator already in it is left alone, and the status line does not name them.
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

    /// **The one line every conversion writes** (2026-10-09) — a conversion changes a file the
    /// person did not type into, every line of it, so a report of "my file changed" has to be
    /// answerable from the log. Kinds and counts only, never the text. Nothing for no changes.
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

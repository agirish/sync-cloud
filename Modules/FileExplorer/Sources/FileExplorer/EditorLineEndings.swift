import Foundation

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
        guard text.contains("\r") else { return text }
        // `"\r\n"` is one Character, so the replacements go by unit, CRLF first.
        return text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
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

    static func mapped(_ range: NSRange, through changes: [Change]) -> NSRange {
        let start = mapped(range.location, through: changes)
        let end = mapped(NSMaxRange(range), through: changes)
        return NSRange(location: start, length: max(0, end - start))
    }
}

import SwiftUI
import AppKit
import Design

/// Go to Line: what is typed into the field, and where in the text it lands.
///
/// A line is a line of the file, as an error message or diff names it and as the status line's
/// "Line 48" counts it (``EditorCaret``), never a wrapped row. The rule reads the text alone, so a
/// wrapped paragraph is one line however many rows it takes.
enum EditorGoToLine {

    /// A line, and a column on it when one was typed, both 1-based as the status line counts.
    struct Target: Equatable, Sendable {
        var line: Int
        var column: Int?
    }

    /// `"48"` or `"48:12"`, spaces allowed around either number. `nil` for anything else (`0`, a
    /// negative, a letter, `"12:0"`), and the field beeps rather than guessing. A number too large
    /// to hold reads as the largest line, which lands on the last (``utf16Offset(of:in:using:)``).
    /// A trailing colon with nothing after it is the line alone.
    static func parse(_ typed: String) -> Target? {
        let parts = typed.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let line = number(parts[0]) else { return nil }
        guard parts.count == 2, !parts[1].isEmpty else { return Target(line: line, column: nil) }
        guard let column = number(parts[1]) else { return nil }
        return Target(line: line, column: column)
    }

    /// A positive number in digits alone: `Int("+3")` and `Int("-3")` would accept a sign, and a
    /// sign is not a line.
    private static func number(_ text: String) -> Int? {
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        // Digits that overflow are a number past any end, not junk.
        let value = Int(text) ?? Int.max
        return value >= 1 ? value : nil
    }

    /// Where the caret goes for `target` in `text`, as a UTF-16 offset.
    ///
    /// Past the end goes to the last line, and past a line's end to its end: a near miss worth
    /// landing. The last line is by the field's count (``EditorDocumentFacts/lineCount(of:)``), so
    /// 9999 in a 400-line file lands on line 400, not the empty place after the last newline. The
    /// column counts characters, so ``EditorCaret/at(utf16Offset:in:)`` on the answer gives it back.
    /// A stale `index` (its length disagrees) is rebuilt, as in
    /// ``PlainTextEditor/utf16Offset(ofLine:in:using:)``.
    static func utf16Offset(of target: Target, in text: String, using index: EditorLineIndex) -> Int {
        let length = (text as NSString).length
        let lines = index.utf16Length == length ? index : EditorLineIndex(text: text)
        // The empty place after a final line break is where the caret can go, but no line of the file.
        let endsWithBreak = lines.lineCount > 1 && lines.utf16Offset(ofLine: lines.lineCount) == length
        let line = min(max(target.line, 1), endsWithBreak ? lines.lineCount - 1 : lines.lineCount)
        let start = lines.utf16Offset(ofLine: line) ?? 0
        let end = lines.terminatorStart(ofLine: line) ?? length
        var offset = start
        var remaining = max((target.column ?? 1) - 1, 0)
        guard remaining > 0, start < end else { return start }
        let utf16 = text.utf16
        guard let from = utf16.index(utf16.startIndex, offsetBy: start, limitedBy: utf16.endIndex) else {
            return start
        }
        // A line starts after a terminator, so `from` is on a character boundary, and so is `end`,
        // where a column past the line's end stops, never into the line break.
        for character in text[from...] {
            if remaining == 0 || offset >= end { break }
            offset += character.utf16.count
            remaining -= 1
        }
        return offset
    }
}

/// What the status line's "Line, Col" needs to be a door to Go to Line: whether the field is up,
/// how many lines it chooses among, and what choosing does. `nil` in Preview, which has no source
/// lines on screen, and the caret is words again.
struct EditorStatusGoToLine: Equatable {
    var isPresented: Binding<Bool>
    /// The document's line count, for the field's hint; `nil` until this file's lines are counted.
    var lineCount: Int?
    var accent: Color
    var onGo: (EditorGoToLine.Target) -> Void

    /// Compared on what the line draws, leaving out the act, as ``EditorStatusHeadings`` does.
    nonisolated static func == (a: EditorStatusGoToLine, b: EditorStatusGoToLine) -> Bool {
        a.isPresented.wrappedValue == b.isPresented.wrappedValue && a.lineCount == b.lineCount
            && a.accent == b.accent
    }

    static let help = ShortcutHint.tooltip("Go to Line", AppChord.goToLine.display)
}

/// The popover's field: a line, or `line:column`; Return goes, Escape closes.
struct EditorGoToLineField: View {
    let lineCount: Int?
    let onGo: (EditorGoToLine.Target) -> Void
    let onCancel: () -> Void

    @State private var typed = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Go to line")
                TextField("Line", text: $typed, prompt: Text("line or line:column"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                    .focused($isFocused)
                    .onSubmit(submit)
                    .accessibilityHint("A line number, or a line and a column with a colon between")
            }
            if let caption = Self.lineCountCaption(lineCount) {
                Text(caption)
                    .foregroundStyle(.secondary)
            }
        }
        .scaledFont(.system(size: 11))
        .padding(12)
        .onAppear { isFocused = true }
        .onExitCommand(perform: onCancel)
    }

    /// "This file has 400 lines.", or nothing until this file's lines are counted: the count on
    /// hand then is the last file's.
    static func lineCountCaption(_ lineCount: Int?) -> String? {
        guard let lineCount else { return nil }
        return lineCount == 1 ? "This file has 1 line." : "This file has \(lineCount.formatted(.number)) lines."
    }

    private func submit() {
        guard let target = EditorGoToLine.parse(typed) else {
            NSSound.beep()
            return
        }
        onGo(target)
    }
}

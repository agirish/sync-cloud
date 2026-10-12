import SwiftUI
import AppKit
import Design

/// **Go to a line (TE61)** — what is typed into the field, and where in the text it lands.
///
/// **A line is a line of the FILE**: what an error message, a diff or a stack trace names, counted
/// by the same rule the status line's "Line 48" is (``EditorCaret``) — never a row the window has
/// wrapped a long line into. The rule lives on the text alone, so it cannot see the wrapping at all,
/// which is the point: a wrapped paragraph is one line however many rows it takes.
enum EditorGoToLine {

    /// A line, and a column on it when one was typed — both 1-based, as the status line counts.
    struct Target: Equatable, Sendable {
        var line: Int
        var column: Int?
    }

    /// `"48"` or `"48:12"`, spaces allowed around either number.
    ///
    /// **`nil` for anything else, and the field beeps** rather than guessing: `0`, a negative, a
    /// letter, `"12:0"`. A number too large to hold is not junk — it is past the end, and past the
    /// end goes to the last line (``utf16Offset(of:in:using:)``), so it is read as the largest line
    /// there can be. A trailing colon with nothing after it is the line alone.
    static func parse(_ typed: String) -> Target? {
        let parts = typed.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let line = number(parts[0]) else { return nil }
        guard parts.count == 2, !parts[1].isEmpty else { return Target(line: line, column: nil) }
        guard let column = number(parts[1]) else { return nil }
        return Target(line: line, column: column)
    }

    /// A positive number written in digits alone — `Int("+3")` and `Int("-3")` would take a sign,
    /// and a person typing a sign has not typed a line.
    private static func number(_ text: String) -> Int? {
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        // Digits that overflow are a number past any end, not junk.
        let value = Int(text) ?? Int.max
        return value >= 1 ? value : nil
    }

    /// Where the caret goes for `target` in `text`, as a UTF-16 offset.
    ///
    /// **Past the end goes to the last line, and past a line's end to its end** — a number that is
    /// too large is a near miss worth landing, not an error to refuse. The last line is the file's
    /// last line by the count the field shows (``EditorDocumentFacts/lineCount(of:)``): a final line
    /// break opens no line after it, so 9999 in a 400-line file lands on line 400, where its text is,
    /// not on the empty place after its last newline.
    ///
    /// The column is counted in characters, as ``EditorCaret`` counts it — so an emoji is one column
    /// and ``EditorCaret/at(utf16Offset:in:)`` on the answer gives the line and column back.
    ///
    /// `index` is used only when it describes THIS text (its length agrees); a stale one is rebuilt,
    /// the bargain ``PlainTextEditor/utf16Offset(ofLine:in:using:)`` makes for an outline click.
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
        // A line starts after a terminator, so `from` is on a character boundary — and so is `end`,
        // which is where a column past the line's end stops: never on into the line break.
        for character in text[from...] {
            if remaining == 0 || offset >= end { break }
            offset += character.utf16.count
            remaining -= 1
        }
        return offset
    }
}

/// What the status line's "Line, Col" needs to be a door to Go to Line (TE61): whether the field is
/// up, how many lines it is choosing among, and what choosing does. `nil` where there is no going —
/// Preview, which has no source lines on screen — and the caret is words again.
struct EditorStatusGoToLine: Equatable {
    var isPresented: Binding<Bool>
    /// The document's line count, for the field's hint.
    var lineCount: Int
    var accent: Color
    var onGo: (EditorGoToLine.Target) -> Void

    /// Compared on what the line draws — the act left out, as ``EditorStatusHeadings`` does.
    nonisolated static func == (a: EditorStatusGoToLine, b: EditorStatusGoToLine) -> Bool {
        a.isPresented.wrappedValue == b.isPresented.wrappedValue && a.lineCount == b.lineCount
            && a.accent == b.accent
    }

    static let help = "Go to a line — \(AppChord.goToLine.display)"
}

/// The popover's field: a line, or `line:column`; Return goes, Escape closes.
struct EditorGoToLineField: View {
    let lineCount: Int
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
            Text(lineCount == 1 ? "This file has 1 line." : "This file has \(lineCount.formatted(.number)) lines.")
                .foregroundStyle(.secondary)
        }
        .scaledFont(.system(size: 11))
        .padding(12)
        .onAppear { isFocused = true }
        .onExitCommand(perform: onCancel)
    }

    private func submit() {
        guard let target = EditorGoToLine.parse(typed) else {
            NSSound.beep()
            return
        }
        onGo(target)
    }
}

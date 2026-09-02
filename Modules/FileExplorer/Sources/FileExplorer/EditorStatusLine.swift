import SwiftUI
import Design

/// The strip under the document: what is in the buffer, and where the caret is in it.
///
/// **The header answers "which file and is it saved"; this answers "what is in it".** They are two
/// questions and they were one line, which is why the meta line grew to `Markdown · 4.2 KB · saved`
/// and stopped there — a fourth and fifth segment would have pushed the file name out of a header
/// whose whole job is to name the file.
///
/// **It sheds segments as the column narrows**, the same bargain ``EditorModeBar`` strikes and in
/// the same shape — `ViewThatFits` over hand-named rungs, with a `forcedRung` so a test can ask for
/// one rather than trying to provoke it. The order it drops things in is the order they are worth:
/// the character count goes first (the word count says the same thing less precisely and is what
/// people actually read), then the counts entirely, leaving the caret — which is the only segment
/// that changes as you work and the only one you cannot get anywhere else.
struct EditorStatusLine: View {

    let facts: EditorDocumentFacts
    let caret: EditorCaret
    /// The file's size on disk, already formatted, or `nil` when nothing has been read.
    ///
    /// **Moved down from the header**, where it was the one measurement living apart from the
    /// others. It belongs with the encoding and the line endings: all three describe the file as it
    /// sits on disk rather than the buffer being typed into, which is why they share this end of
    /// the row.
    var fileSize: String?
    /// Forces a rung, for the tests that measure each one. `nil` picks by width.
    var forcedRung: Rung?

    /// The three rungs, named so a test can ask for one.
    enum Rung: CaseIterable { case full, counts, caret }

    var body: some View {
        Group {
            if let forcedRung {
                strip(forcedRung)
            } else {
                ViewThatFits(in: .horizontal) {
                    strip(.full)
                    strip(.counts)
                    strip(.caret)
                }
            }
        }
        .scaledFont(.system(size: 10))
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.accessibilityLabel(facts: facts, caret: caret, fileSize: fileSize))
    }

    private func strip(_ rung: Rung) -> some View {
        HStack(spacing: 14) {
            if rung != .caret {
                Text(facts.wordsCaption)
                if rung == .full { Text(facts.charactersCaption) }
            }
            Text(Self.caretCaption(caret))
            Spacer(minLength: 8)
            // The file's own facts, right-aligned and last: they are true of the file rather than
            // of what you are doing in it, and they change only when a different file is opened.
            if rung != .caret {
                if let fileSize { Text(fileSize) }
                if let encoding = facts.encoding { Text(encoding) }
                if let ending = facts.lineEnding { Text(ending.rawValue) }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    /// `Line 48, Col 12` — spelled out rather than abbreviated to `Ln`, because the strip has room
    /// for the words at every rung that draws them and the abbreviation saves four points.
    static func caretCaption(_ caret: EditorCaret) -> String {
        "Line \(caret.line), Col \(caret.column)"
    }

    /// One sentence for VoiceOver, because five separate labels in a row is five stops on the way
    /// to the text — and this strip is beside the thing a person came here to read.
    static func accessibilityLabel(facts: EditorDocumentFacts, caret: EditorCaret,
                                   fileSize: String? = nil) -> String {
        var parts = [facts.wordsCaption, facts.charactersCaption, caretCaption(caret)]
        if let fileSize { parts.append(fileSize) }
        if let encoding = facts.encoding { parts.append(encoding) }
        if let ending = facts.lineEnding { parts.append("\(ending.rawValue) line endings") }
        return parts.joined(separator: ", ")
    }
}

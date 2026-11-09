import Design
import SwiftUI
import Sync

/// A change Claude made to its notes, as the chat shows it (TE307): ✎, the line it wrote, and
/// Undo, which takes the change back while the line is still as Claude left it.
struct AskClaudeNotedRow: View {
    let noted: AskClaudeNoted
    let undone: Bool
    let accent: Color
    let isRunning: Bool
    let onUndo: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label(noted.line, systemImage: "square.and.pencil")
                .scaledFont(.callout)
                .foregroundStyle(undone ? AnyShapeStyle(.secondary) : AnyShapeStyle(accent))
                .strikethrough(undone)
                .fixedSize(horizontal: false, vertical: true)
                .help(noted.quote.map { "From your words: “\($0)”" } ?? "")
            Spacer(minLength: 4)
            if undone {
                Text("Undone").scaledFont(.footnote).foregroundStyle(.secondary)
            } else {
                Button("Undo", action: onUndo)
                    .controlSize(.small)
                    .disabled(isRunning)
                    .help("Takes this change to Notes for Claude back.")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        // A neutral well: its words are in the accent, and a word inked in its own wash fades.
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.well))
        .accessibilityElement(children: .combine)
    }
}

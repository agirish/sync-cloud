import SwiftUI
import Design

/// **Edit in Preview's switch: a small pill in the Preview column's top-trailing corner** (TE67
/// §1.2) — subtle and professional, in the user's words.
///
/// Off, it reads "Edit" beside a pencil, in the secondary colour. On, "Editing" in the accent, then a
/// quiet "Experimental" in the caption size: a word, not a badge. It wears the format bar's glass
/// track, so it follows Solid, Frosted and Clear without a style of its own. The first time it is
/// turned on, a popover says what "experimental" means here, once.
struct PreviewEditToggle: View {

    @Binding var isOn: Bool
    @Binding var introSeen: Bool
    var accent: Color
    var scale: CGFloat = 1
    /// The document is over ``maximumLength``: the pill stays, dimmed, and says why.
    var isTooLong = false

    @State private var showsIntro = false

    static let tooltip = "Edit in Preview — experimental. Best for small changes to text."
    static let introTitle = "Editing in Preview is experimental"
    static let introBody = "Use it for small changes — fixing a word, adding a sentence, ticking a box, "
        + "changing a table cell. Every change is written to the Markdown as you type, and ⌘Z undoes "
        + "it. Bigger changes, such as joining paragraphs or reshaping a table, still happen in Source."

    static let tooLongTooltip = "Too long to edit in Preview — use Source."

    /// **The longest document Preview edits: 256 KB of text**, in UTF-16 units — what a text
    /// view's storage counts, so it is read without walking the document; for English the same as
    /// the file's size. Past it Preview is read-only. Typing re-reads only the blocks it touched, but
    /// some edits still re-read the whole document — in front matter, in a note with reference
    /// links — and that costs about 130 ms at this length (measured 2026-10-07, plan C23).
    static let maximumLength = 256 * 1024

    static func isTooLong(length: Int) -> Bool { length > maximumLength }

    /// Where the pill is offered: Preview, or Split's Preview half (TE67.4), of a writable Markdown
    /// document.
    static func isOffered(hasDocument: Bool, isRefused: Bool, isMarkdown: Bool, isReadOnly: Bool,
                          mode: EditorMode) -> Bool {
        hasDocument && !isRefused && isMarkdown && !isReadOnly
            && EditorMode.resolved(mode, isMarkdown: isMarkdown) != .edit
    }

    /// Whether turning it on should show the intro: the first time, and only then.
    static func showsIntro(turningOn: Bool, introSeen: Bool) -> Bool { turningOn && !introSeen }

    var body: some View {
        // Over the limit the setting is kept but has nothing to edit: the pill reads off.
        let isOn = self.isOn && !isTooLong
        Button {
            let turningOn = !self.isOn
            self.isOn = turningOn
            // Once: seen when shown, whether or not "Got it" is what closes it.
            if Self.showsIntro(turningOn: turningOn, introSeen: introSeen) {
                showsIntro = true
                introSeen = true
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "pencil")
                    .scaledFont(.system(size: 11, weight: .medium))
                Text(isOn ? "Editing" : "Edit")
                    .scaledFont(.system(size: 11, weight: .medium))
                if isOn {
                    Text("Experimental")
                        .scaledFont(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(isOn ? accent : .secondary)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .contentShape(Capsule())
        }
        .buttonStyle(.hoverAffordance(.glyph, tint: accent))
        .disabled(isTooLong)
        .opacity(isTooLong ? 0.5 : 1)
        .chromeGlassTrack()
        .help(isTooLong ? Self.tooLongTooltip : Self.tooltip)
        .accessibilityLabel("Edit in Preview")
        .accessibilityValue(isTooLong ? "Unavailable. \(Self.tooLongTooltip)" : isOn ? "On, experimental" : "Off")
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
        .popover(isPresented: $showsIntro, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text(Self.introTitle).font(.headline)
                Text(Self.introBody).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    // No default-button key: a key equivalent here would take ⏎ from every field in
                    // the window (`BareKeyEquivalentScanTests`). A popover closes on esc or a click away.
                    Button("Got it") { showsIntro = false }
                }
            }
            .padding(14)
            .frame(width: 300)
        }
    }
}

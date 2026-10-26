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
    /// The one-time intro. **Held by the workspace, not here** (review V2, 2026-10-09): turning
    /// editing on rebuilt the column, and a pill holding its own `@State` was a new pill with the
    /// intro unshown — already marked seen, so it never showed. The workspace raises it whichever
    /// door turned editing on, the pill or Text ▸ Edit in Preview.
    @Binding var showsIntro: Bool
    var accent: Color
    var scale: CGFloat = 1
    /// The document is over ``maximumLength``: the pill stays, dimmed, and says why.
    var isTooLong = false

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

    /// The log line for a note held read-only in Preview — kinds and numbers, never its text.
    static func tooLongLog(length: Int) -> String {
        "[preview-edit] Preview is read-only for this note: \(length) UTF-16 units is over the \(maximumLength) Edit in Preview takes — held until the note is next opened in Preview"
    }

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
            self.isOn.toggle()
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
            // Over the limit, the tertiary style the header's greyed ＋ wears (review V14) — what
            // the secondary colour at half opacity came to as well (measured: 194 against 192), but
            // by the same rule as the others now, and without dimming the glass track under it.
            .foregroundStyle(isTooLong ? AnyShapeStyle(.tertiary) : isOn ? AnyShapeStyle(accent) : AnyShapeStyle(.secondary))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .contentShape(Capsule())
        }
        .buttonStyle(.hoverAffordance(.glyph, tint: accent))
        .disabled(isTooLong)
        .chromeGlassTrack()
        .help(isTooLong ? Self.tooLongTooltip : Self.tooltip)
        .accessibilityLabel("Edit in Preview")
        .accessibilityValue(isTooLong ? "Unavailable. \(Self.tooLongTooltip)" : isOn ? "On, experimental" : "Off")
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
        .popover(isPresented: $showsIntro, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text(Self.introTitle).scaledFont(.headline)
                Text(Self.introBody).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    // No default-button key: a key equivalent here would take ⏎ from every field in
                    // the window (`BareKeyEquivalentScanTests`). A popover closes on esc or a click away.
                    Button("Got It") { showsIntro = false }
                }
            }
            .padding(14)
            .frame(width: 300)
        }
    }
}

/// **Whether a note is too long to edit in Preview, decided when Preview is OPENED for it and held
/// while it stays open** (review V4, the lead's decision, 2026-10-09).
///
/// Re-read on every render, the limit swapped the read-only preview in mid-keystroke the moment
/// typing or a paste crossed 256 KB — the caret gone, the bar gone, the pill dimmed, and nothing
/// said; and in Split, typing in Source back and forth across it rebuilt Preview's half each time.
/// Now a note that grows past the limit while it is being edited stays editable until it is next
/// opened; one that is over it when opened is read-only, with the pill dimmed.
///
/// **The moments are the key**: the note (its path), the mode, and the setting. Opening a note,
/// switching to Preview or Split, and turning Edit on each change the key, and a hold for another
/// key is no hold — the length is read afresh, so the first render after a moment is already
/// right, before anything has had a chance to be told. The workspace takes the hold at those
/// moments and hands it up, so the Text and Markup menus agree with it without re-rendering the
/// window per keystroke.
public struct PreviewLengthHold: Equatable, Sendable {

    /// What the decision was made for.
    public struct Key: Equatable, Sendable {
        public var path: String?
        public var mode: EditorMode
        public var editing: Bool
        public init(path: String?, mode: EditorMode, editing: Bool) {
            self.path = path
            self.mode = mode
            self.editing = editing
        }
    }

    public var key: Key
    public var isTooLong: Bool

    public init(key: Key, isTooLong: Bool) {
        self.key = key
        self.isTooLong = isTooLong
    }

    /// The held answer for `key`, or — with none held for it — the length read now.
    public static func isTooLong(_ hold: PreviewLengthHold?, key: Key, length: () -> Int) -> Bool {
        if let hold, hold.key == key { return hold.isTooLong }
        return PreviewEditToggle.isTooLong(length: length())
    }
}

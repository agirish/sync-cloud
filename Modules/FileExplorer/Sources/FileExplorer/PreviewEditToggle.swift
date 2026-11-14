import SwiftUI
import Design

/// Edit in Preview's switch: a small, quiet pill in the Preview column's top-trailing corner.
///
/// Off, it reads "Edit" beside a pencil, in the secondary colour. On, "Editing" in the accent, then a
/// quiet "Experimental" in the caption size: a word, not a badge. It wears the format bar's glass
/// track, so it follows Solid, Frosted and Clear without a style of its own. The first time it is
/// turned on, a popover says what "experimental" means here, once.
struct PreviewEditToggle: View {

    @Binding var isOn: Bool
    /// The one-time intro, held by the workspace: turning editing on rebuilds the column, so a pill
    /// holding its own `@State` would lose it after marking it seen. The workspace raises it
    /// whichever way editing was turned on, the pill or Text ▸ Edit in Preview.
    @Binding var showsIntro: Bool
    var accent: Color
    /// The document is over ``maximumLength``: the pill stays, dimmed, and says why.
    var isTooLong = false

    static let tooltip = "Edit in Preview — experimental. Best for small changes to text."
    static let introTitle = "Editing in Preview is experimental"
    static let introBody = "Use it for small changes — fixing a word, adding a sentence, ticking a box, "
        + "changing a table cell. Every change is written to the Markdown as you type, and ⌘Z undoes "
        + "it. Bigger changes, such as joining paragraphs or reshaping a table, still happen in Source."

    static let tooLongTooltip = "Too long to edit in Preview — use Source."

    /// The longest document Preview edits: 256 KB of text, in UTF-16 units (what a text view's
    /// storage counts, so no walk; for English, the file's size). Past it Preview is read-only.
    /// Some edits still re-read the whole document (front matter, reference links), about 130 ms at
    /// this length.
    static let maximumLength = 256 * 1024

    static func isTooLong(length: Int) -> Bool { length > maximumLength }

    /// The log line for a note held read-only in Preview — kinds and numbers, never its text.
    static func tooLongLog(length: Int) -> String {
        "[preview-edit] Preview is read-only for this note: \(length) UTF-16 units is over the \(maximumLength) Edit in Preview takes — held until the note is next opened in Preview"
    }

    /// Where the pill is offered: Preview, or Split's Preview half, of a writable Markdown
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
            // Over the limit, the tertiary style the header's greyed ＋ wears, which leaves the
            // glass track under it undimmed.
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

/// Whether a note is too long to edit in Preview, decided when Preview is opened for it and held
/// while it stays open, so crossing 256 KB mid-keystroke never swaps in the read-only preview. A
/// note over the limit when opened is read-only, with the pill dimmed.
///
/// The key is the note's path, the mode and the setting; opening a note, switching to Preview or
/// Split, or turning Edit on changes it, and the length is then read afresh. The workspace hands
/// the hold up, so the Text and Markup menus agree without re-rendering the window per keystroke.
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

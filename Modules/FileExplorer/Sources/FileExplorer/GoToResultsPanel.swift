import SwiftUI
import Design

/// The Go-to results, hanging off the toolbar field rather than floating in the middle of the
/// window.
///
/// **No dim.** The card this replaces darkened the whole window, which is right for something you
/// go *to* and wrong for something you type *at*: the tree you are navigating is the context for
/// the folder you are looking for, and hiding it while you type its name was the complaint that
/// started §7.
///
/// **There is no scrim, and its absence is the feature.** This drew a transparent, hit-testing
/// fill over the whole host window, which turned every click anywhere on the window into a
/// dismissal *instead of* the click the user meant — measured 2026-08-19: with the palette up, the
/// panel's content claimed a hit at the far corner of the host (`hitTest → NSHostingView`), and the
/// panel's frame was the host's frame exactly. That was right while the card dimmed the window and
/// wrong the moment it stopped: a window you can see through is a window you expect to click.
///
/// So the panel is sized to this list now, and clicking away is the mouse monitor's job alone —
/// which is what it was written for, and why it **returns** the event it dismisses on.
/// `CommandPalettePanelController.clickDismissesThePalette` carries that boundary.
public struct GoToResultsPanel: View {

    /// Between the field's bottom edge and the list's top. Small enough that the two read as one
    /// object, and not zero: the field is a capsule, and a square-topped surface flush under a
    /// rounded one reads as a mistake rather than as a join.
    public static let gapBelowField: CGFloat = 6
    /// Unchanged from the card — this is the list that shipped, not a re-tuned one.
    public static let listMaxHeight: CGFloat = 420

    let rows: [PaletteRow]
    let query: String
    @Binding var selection: Int?
    let accent: Color
    let glassLevel: GlassLevel
    /// How wide the field is, which is how wide this is: the list and the field it hangs from read
    /// as one object, so they share an edge on both sides.
    let width: CGFloat
    let onRun: (PaletteRoute) -> Void
    /// The height this wants to be, reported up so the panel window can be exactly that tall.
    /// **A window taller than its content is a click sink**: the surplus is transparent, hit-tests
    /// to nothing, and AppKit delivers the click to the panel anyway — where nothing answers it.
    let onHeight: (CGFloat) -> Void

    public init(rows: [PaletteRow], query: String, selection: Binding<Int?>, accent: Color,
                glassLevel: GlassLevel, width: CGFloat,
                onRun: @escaping (PaletteRoute) -> Void, onHeight: @escaping (CGFloat) -> Void) {
        self.rows = rows
        self.query = query
        self._selection = selection
        self.accent = accent
        self.glassLevel = glassLevel
        self.width = width
        self.onRun = onRun
        self.onHeight = onHeight
    }

    public var body: some View {
        surface
            .frame(width: width)
            // **`fixedSize` vertically, and it is what keeps this from oscillating.** The panel's
            // height is set from the height reported below; if the content then measured itself
            // against that height, a window one point short would compress the list, report less,
            // and shrink again to nothing. Taking its ideal height regardless of the proposal makes
            // the reported value independent of the window, so the loop settles in one pass.
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeight($0) }
    }

    private var surface: some View {
        VStack(spacing: 0) {
            if rows.isEmpty {
                noResults
            } else {
                PaletteResultsList(rows: rows, query: query, selection: $selection,
                                   accent: accent, onChoose: run)
                    .frame(maxHeight: Self.listMaxHeight)
            }
            Divider()
            keyFooter
        }
        .contentSurface(hue: .blue, tint: 0)
        .groundedGlassCard(level: glassLevel)
        .shadow(color: .black.opacity(0.3), radius: 24, y: 6)
    }

    private var noResults: some View {
        Text("Nothing matches “\(query)”.")
            .scaledFont(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The three keys, kept from the card: the interaction's documentation lives where the
    /// interaction happens, and moving the field to the toolbar does not change what ↑ ↓ ↩ do.
    private var keyFooter: some View {
        HStack(spacing: 16) {
            HStack(spacing: 5) {
                ShortcutKeycap("↑")
                ShortcutKeycap("↓")
                Text("Navigate")
            }
            HStack(spacing: 5) {
                ShortcutKeycap("↩")
                Text("Open")
            }
            HStack(spacing: 5) {
                ShortcutKeycap("esc")
                Text("Close")
            }
            Spacer(minLength: 0)
        }
        .scaledFont(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }

    /// ↩ and a click both route through the same pure rule, never by reading the row here.
    private func run() {
        guard let route = PaletteSelection.chosen(at: selection, in: rows) else { return }
        onRun(route)
    }
}

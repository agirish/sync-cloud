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
/// The transparent fill behind it still hit-tests, and that is load-bearing rather than
/// leftover: the panel spans the host window, so this is what turns a click anywhere on the window
/// into a dismissal instead of a click that also selects a file. `CommandPalettePanelController`
/// carries the full boundary of what that catches and what the event monitors catch.
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
    /// The field's frame in this view's own coordinate space — SwiftUI's, so top-left origin. The
    /// panel spans the host window, so this is where the field is on screen, translated once by
    /// the controller that owns both.
    let fieldFrame: CGRect
    let onRun: (PaletteRoute) -> Void
    let onClose: () -> Void

    public init(rows: [PaletteRow], query: String, selection: Binding<Int?>, accent: Color,
                glassLevel: GlassLevel, fieldFrame: CGRect,
                onRun: @escaping (PaletteRoute) -> Void, onClose: @escaping () -> Void) {
        self.rows = rows
        self.query = query
        self._selection = selection
        self.accent = accent
        self.glassLevel = glassLevel
        self.fieldFrame = fieldFrame
        self.onRun = onRun
        self.onClose = onClose
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(perform: onClose)
            // Nothing until the field has been found and measured. A list drawn at the origin for
            // one frame is a flash in the top-left corner of the window, which reads as a glitch
            // rather than as a palette opening.
            if fieldFrame.width > 0 {
            surface
                .frame(width: fieldFrame.width)
                // `contentShape` before any padding, for the reason the card's own comment gives:
                // applied after, the hit region becomes the padded frame and swallows clicks in
                // the strip beside the list — the strip a user aims at when they mean "outside it".
                .contentShape(Rectangle())
                .offset(x: fieldFrame.minX,
                        y: fieldFrame.maxY + Self.gapBelowField)
            }
        }
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

import SwiftUI
import Design

/// The Go-to results, hanging off the toolbar field rather than floating mid-window.
///
/// No dim: the tree you are navigating is the context for the folder you are typing, so it stays
/// visible.
///
/// No scrim either. A hit-testing fill over the host window would turn every click on the window
/// into a dismissal instead of the click the user meant, and a window you can see through is one
/// you expect to click. So the panel is sized to this list, and clicking away is the mouse
/// monitor's job alone, which is why it **returns** the event it dismisses on.
/// `CommandPalettePanelController.clickDismissesThePalette` carries that boundary.
public struct GoToResultsPanel: View {

    /// Between the field's bottom edge and the list's top. Small enough that the two read as one
    /// object, and not zero: a square-topped surface flush under the capsule field reads as a
    /// mistake rather than a join.
    public static let gapBelowField: CGFloat = 6
    public static let listMaxHeight: CGFloat = 420

    let rows: [PaletteRow]
    let query: String
    @Binding var selection: Int?
    let accent: Color
    let glassLevel: GlassLevel
    /// The field's width, so the list and the field it hangs from share both side edges and read
    /// as one object.
    let width: CGFloat
    let onRun: (PaletteRoute) -> Void
    /// The height this wants to be, reported up so the panel window can be exactly that tall.
    /// **A window taller than its content is a click sink**: the surplus is transparent, hit-tests
    /// to nothing, and AppKit delivers the click to the panel anyway, where nothing answers it.
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
            // `fixedSize` vertically keeps this from oscillating. The panel's height comes from the
            // height reported below; measured against that height, a window one point short would
            // compress the list, report less, and shrink to nothing. The ideal height is independent
            // of the window, so the loop settles in one pass.
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
        // No drop shadow. The window is sized to exactly this list, and a shadow can't paint
        // outside its own window, so the blur is clipped to the window's rectangle: all that shows
        // is dark notches (14–26 luminance units) in the card's rounded corners, and nothing below
        // it. `NSWindow.hasShadow` doesn't help; setting it changes nothing here.
        //
        // Making room for a shadow undoes a decision elsewhere in this file. Growing the window
        // past its content makes the click sink `onHeight` exists to prevent; insetting the card
        // breaks the shared side edges that `width` is for.
        //
        // So `groundedGlassCard` draws the material and stroke that separate the card from the tree
        // behind. `theResultsPanelDeclaresNoShadow` keeps a shadow from being re-added.
    }

    private var noResults: some View {
        Text("Nothing matches “\(query)”.")
            .scaledFont(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The three keys, documented where the interaction happens.
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

import SwiftUI

/// The app's one expand-on-demand search container: a magnifier that reveals a field, the field
/// itself, and the focus / Escape / clear behaviour that ties the two together.
///
/// This mechanism existed only inside `DifferencesView` (Compare) — Organize's Duplicates search
/// shared the *grammar* (`TokenQuery`) but had an always-visible compact field with no expansion
/// and no Escape. Every surface with a token search drives this now, so "search behaves the same
/// everywhere" holds by construction instead of by two copies happening to agree.
///
/// The toggle and the field are separate views because they sit on different rows of their host:
/// the toggle rides the controls row (last item, far right), the field appears below it. They
/// share `text` and `isExpanded`, which the host owns.
public enum ExpandingSearch {
    /// The reveal/collapse animation. One constant, so the toggle and any host layout that keys
    /// off `isExpanded` (a card growing to fit the field) move as one.
    public static let animation: Animation = .easeOut(duration: 0.15)

    /// Collapses and clears in one animated transaction — what Escape and the toggle's second
    /// click both do. Clearing on collapse is deliberate: a query left live behind a hidden field
    /// is a filter you can't see or undo.
    public static func collapse(text: Binding<String>, isExpanded: Binding<Bool>) {
        withAnimation(animation) {
            text.wrappedValue = ""
            isExpanded.wrappedValue = false
        }
    }
}

/// The magnifier that reveals the field — the last item of its host's controls row, mirroring
/// where Compare's `standardHeaderControls` puts it.
public struct ExpandingSearchToggle: View {
    @Binding private var text: String
    @Binding private var isExpanded: Bool
    private let accent: Color
    private let help: String

    /// - Parameters:
    ///   - text: the live query. Cleared when the toggle collapses the field.
    ///   - isExpanded: whether the field is showing. Host-owned so the host can size around it.
    ///   - accent: the tint worn while the field is open or a query is live.
    ///   - help: the tooltip AND the accessibility label — it should name what this lens
    ///     searches, since that differs per surface.
    public init(text: Binding<String>, isExpanded: Binding<Bool>, accent: Color, help: String) {
        self._text = text
        self._isExpanded = isExpanded
        self.accent = accent
        self.help = help
    }

    public var body: some View {
        Button {
            withAnimation(ExpandingSearch.animation) {
                isExpanded.toggle()
                if !isExpanded { text = "" }
            }
        } label: {
            // Padded out so the hover wash has room around a 13pt glyph, then pulled back below
            // so the toggle's footprint in the header is unchanged (TokenChipsRow's idiom).
            Image(systemName: "magnifyingglass")
                .padding(5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.hoverAffordance(.glyph, tint: accent))
        .padding(-5)
        // Tints whenever the field is open OR a query is live — so a filter narrowing the list
        // can never be silently on behind a quiet, collapsed glyph.
        .foregroundStyle((isExpanded || !text.isEmpty) ? accent : Color.secondary)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The revealed field: the query, a clear button, an optional trailing slot, and an optional
/// accessories area below (chips, one-tap suggestions) that shares the field's surface.
///
/// Escape collapses and clears. Focus is claimed here, on appear — see the note on `body`.
public struct ExpandingSearchField<Trailing: View, Accessories: View>: View {
    @Binding private var text: String
    @Binding private var isExpanded: Bool
    private let placeholder: String
    private let trailing: () -> Trailing
    private let accessories: (Bool) -> Accessories

    @FocusState private var focused: Bool

    /// - Parameters:
    ///   - placeholder: this lens's vocabulary. It is the ONLY thing teaching which tokens bind
    ///     here, so it must advertise exactly the tokens this surface's grammar declares and no
    ///     others (see the per-lens grammar note in `LensSearch`).
    ///   - trailing: content inside the field row, after the clear button (Compare's "N of M").
    ///   - accessories: content below the field row, inside the same surface. Receives whether
    ///     the field holds the caret, for suggestions that only show while focused.
    public init(
        text: Binding<String>,
        isExpanded: Binding<Bool>,
        placeholder: String,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() },
        @ViewBuilder accessories: @escaping (Bool) -> Accessories = { _ in EmptyView() }
    ) {
        self._text = text
        self._isExpanded = isExpanded
        self.placeholder = placeholder
        self.trailing = trailing
        self.accessories = accessories
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    // Focus is claimed HERE, once the field exists — never by the toggle that
                    // reveals it. A FocusState write landing in the same transaction that
                    // inserts the field is silently dropped; the one-turn Task hop outlives that
                    // transaction. This is load-bearing: inline it back into the toggle and the
                    // field reveals unfocused, so you have to click it before typing.
                    .onAppear { Task { @MainActor in focused = true } }
                    .onExitCommand { ExpandingSearch.collapse(text: $text, isExpanded: $isExpanded) }
                if !text.isEmpty {
                    Button {
                        text = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .hoverInk()
                    }
                    .buttonStyle(.hoverAffordance(.inline))
                    .help("Clear search")
                    .accessibilityLabel("Clear search")
                }
                trailing()
            }
            accessories(focused)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .searchFieldSurface()
    }
}

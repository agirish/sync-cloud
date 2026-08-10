import SwiftUI
import Design

/// The ⌘K palette: one field over the window, grouped results beneath it.
///
/// **Every decision this view makes is somewhere else.** What the query means is
/// ``PaletteRouter``; what ↑ ↓ ↩ do is ``PaletteSelection``. What is left here is drawing and the
/// three key handlers, which is the most that can be left in a surface a unit test cannot drive.
///
/// The trigger is *not* here either, and must not be: ⌘K is a menu item in `MacApp`, because
/// `.onKeyPress` is strictly focus-scoped — with focus in a file table, which is where it always is,
/// a sibling's handler never fires, and with no focus at all nothing fires anywhere. A palette that
/// worked only when you had not clicked anything would be worse than none. The keys handled *inside*
/// this view are a different matter: the field owns the focus while the palette is up.
public struct CommandPaletteView: View {

    let rows: [PaletteRow]
    @Binding var query: String
    @Binding var selection: Int?
    let accent: Color
    let glassLevel: GlassLevel
    let onRun: (PaletteRoute) -> Void
    let onClose: () -> Void

    @FocusState private var fieldFocused: Bool
    @Environment(\.colorScheme) private var scheme

    public init(rows: [PaletteRow], query: Binding<String>, selection: Binding<Int?>,
                accent: Color, glassLevel: GlassLevel,
                onRun: @escaping (PaletteRoute) -> Void, onClose: @escaping () -> Void) {
        self.rows = rows
        self._query = query
        self._selection = selection
        self.accent = accent
        self.glassLevel = glassLevel
        self.onRun = onRun
        self.onClose = onClose
    }

    /// The card's width. Wide enough for a two-line row whose detail is a real relative path
    /// (`Finance/US/Income Tax Supporting Documents`) without truncating it into the same stub as
    /// its neighbour — the failure the scope chip's suite exists to catch, one surface over.
    static let cardWidth: CGFloat = 620
    static let listMaxHeight: CGFloat = 420

    public var body: some View {
        ZStack(alignment: .top) {
            Rectangle()
                .fill(Color.black.opacity(glassLevel.overlayScrimOpacity))
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)
            card
                .frame(width: Self.cardWidth)
                .padding(.top, 96)
                .contentShape(Rectangle())
        }
        .transition(.opacity)
    }

    private var card: some View {
        VStack(spacing: 0) {
            field
            if !rows.isEmpty {
                Divider()
                list
            } else {
                Divider()
                noResults
            }
        }
        .contentSurface(hue: .blue, tint: 0)
        .groundedGlassCard(level: glassLevel)
        .shadow(color: .black.opacity(0.3), radius: 30, y: 8)
    }

    // MARK: The field

    private var field: some View {
        HStack(spacing: 10) {
            Image(systemName: "command")
                .scaledFont(.system(size: 15, weight: .semibold))
                .foregroundStyle(accent)
            TextField("Go to a place, a folder, a person, or an action…", text: $query)
                .textFieldStyle(.plain)
                .scaledFont(.system(size: 19))
                .focused($fieldFocused)
                .onSubmit(run)
                // ↑ / ↓ walk the list while the caret stays in the field, so typing and choosing
                // never need a focus change. `.onKeyPress` is reliable HERE — this view owns the
                // focus for as long as it is up — which is exactly what it is not at the app level.
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onKeyPress(.downArrow) { move(1); return .handled }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .onAppear {
            // Next turn: a `FocusState` write inside the transaction that inserts the field is
            // silently dropped — the same reason the pane search field hops before claiming focus.
            DispatchQueue.main.async { fieldFocused = true }
        }
        // esc closes, from the field or from anywhere on the card.
        .onExitCommand(perform: onClose)
    }

    // MARK: The list

    private var list: some View {
        PaletteResultsList(rows: rows, selection: $selection, accent: accent, onChoose: { run() })
            .frame(maxHeight: Self.listMaxHeight)
    }

    private var noResults: some View {
        Text("Nothing matches “\(query)”.")
            .scaledFont(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: The three keys

    private func move(_ step: Int) {
        selection = PaletteSelection.moved(from: selection, by: step, in: rows)
    }

    /// ↩ — **through the pure rule, never by reading the row here.** A submit handler cannot be
    /// fired from a test, so anything decided inside one is decided where nothing can check it.
    private func run() {
        guard let route = PaletteSelection.chosen(at: selection, in: rows) else { return }
        onRun(route)
    }
}

// MARK: - The results list

/// The palette's rows, **extracted so they can be rendered and read back.**
///
/// Not organizational. `CommandPaletteView`'s card is wrapped in `contentSurface` +
/// `groundedGlassCard`, and **anything drawn inside that wrapper comes back WHITE in an offscreen
/// host** — measured, with a control: a plain blue rectangle renders blue through a bare
/// `NSHostingView` and white through the same host once the glass card is around it. So a render
/// test that mounted the whole palette could see the text and *nothing* about the selection
/// highlight, which is the one thing the palette's keyboard-only operation depends on. Rendering the
/// list on its own is what makes the highlight measurable, exactly as `ScopeChipLabel` is extracted
/// from `TidyView` so the scope chip's label can be.
///
/// ## Drawn in the ARRAY's order, with a header wherever the group changes
///
/// The first version grouped by `PaletteGroup` and drew the groups in a fixed order, which quietly
/// broke the only navigation this surface has: ``PaletteRouter`` ranks rows by score, so a folder
/// scoring 1,000 sits at index 0 while a place scoring 900 sits at index 2 — and drawing all the
/// places first put index 2 *above* index 0 on screen. ↓ from the top row jumped upward. The rows
/// are drawn in the order they are ranked, and a header is emitted whenever the group changes, so
/// what ↑ and ↓ do is what the eye sees.
struct PaletteResultsList: View {

    let rows: [PaletteRow]
    @Binding var selection: Int?
    let accent: Color
    let onChoose: () -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows.indices, id: \.self) { index in
                        // A header wherever the group changes — including at index 0.
                        if index == 0 || rows[index - 1].group != rows[index].group {
                            header(rows[index].group)
                        }
                        row(at: index).id(index)
                    }
                }
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: selection) { _, new in
                guard let new else { return }
                proxy.scrollTo(new, anchor: .center)
            }
        }
    }

    private func header(_ group: PaletteGroup) -> some View {
        Text(group.rawValue)
            .scaledFont(.system(size: 10.5, weight: .semibold))
            .textCase(.uppercase)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func row(at index: Int) -> some View {
        let row = rows[index]
        let isSelected = selection == index
        HStack(spacing: 12) {
            Image(systemName: row.symbol)
                .scaledFont(.system(size: 13))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title)
                    .scaledFont(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                if let detail = row.detail {
                    Text(detail)
                        .scaledFont(.system(size: 11))
                        .opacity(isSelected ? 0.85 : 1)
                        .foregroundStyle(isSelected ? AnyShapeStyle(Color.onFillLabel(accent))
                                                    : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                        // A path is truncated in the MIDDLE so the leaf survives — the leaf is what
                        // names the folder. Prose is truncated at the tail, because "re…ders that
                        // were shaped differently" is a sentence with a hole in it.
                        .truncationMode(detail.contains("/") ? .middle : .tail)
                }
            }
            Spacer(minLength: 8)
            // **The reason, on the row.** ROADMAP 14 asks for an unavailable result to be shown
            // disabled with its reason rather than hidden — an unmounted drive that simply vanished
            // teaches that the palette does not know about it.
            if let reason = row.unavailable {
                Text(reason)
                    .scaledFont(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize()
            } else if isSelected {
                Text("↩")
                    .scaledFont(.system(size: 11, weight: .semibold))
            }
        }
        // One `foregroundStyle` for the row, so the glyph, the title and the ↩ hint cannot disagree
        // about whether they are sitting on the accent. `Color.onFillLabel` is the app's one
        // on-fill glyph path — white for every hue, and the reason the fill may not be pale.
        .foregroundStyle(isSelected ? AnyShapeStyle(Color.onFillLabel(accent))
                         : AnyShapeStyle(row.isAvailable ? Color.primary : Color.secondary))
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(accent)
                    .padding(.horizontal, 8)
            }
        }
        .contentShape(Rectangle())
        .opacity(row.isAvailable ? 1 : 0.55)
        .onTapGesture {
            guard row.isAvailable else { return }
            selection = index
            onChoose()
        }
    }
}

import SwiftUI
import Design

/// The palette's rows, **extracted so they can be rendered and read back.**
///
/// Not organizational, and the reason outlived the view it was extracted from. **Anything drawn
/// inside a `contentSurface` + `groundedGlassCard` wrapper comes back WHITE in an offscreen host**
/// — measured, with a control: a plain blue rectangle renders blue through a bare `NSHostingView`
/// and white through the same host once the glass card is around it. So a render test that mounted
/// the whole surface could see the text and *nothing* about the selection highlight, which is the
/// one thing this keyboard-only list depends on. Rendering the list on its own is what makes the
/// highlight measurable, exactly as `ScopeChipLabel` is extracted from `LensWorkspaceView` so the
/// scope chip's label can be.
///
/// The card this was extracted from is gone — the ⌘K surface is now the toolbar's Go to field with
/// `GoToResultsPanel` beneath it (v4.2, §7) — and this list is what both of them drew.
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
    /// The live query, for match emphasis only — routing already happened upstream.
    var query: String = ""
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

    /// The row's text with the matched run set bold — why THIS row answered the query, visible
    /// without inference. Ranges come from `PaletteRouter.matchRange`, the ranking's own lookup:
    /// one matcher, never a display-side second tokenizer (those disagree exactly where case
    /// folds and diacritics make it matter). A row matched via keywords draws no emphasis — the
    /// visible text genuinely did not match, and pretending otherwise would mislead.
    ///
    /// Static and pure over its inputs so `PaletteEmphasisTests` can assert the split without
    /// a render.
    static func emphasized(_ string: String, query: String) -> Text {
        guard let range = PaletteRouter.matchRange(
            string, query.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return Text(string)
        }
        return Text(String(string[..<range.lowerBound]))
            + Text(String(string[range])).fontWeight(.bold)
            + Text(String(string[range.upperBound...]))
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
                Self.emphasized(row.title, query: query)
                    .scaledFont(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                if let detail = row.detail {
                    Self.emphasized(detail, query: query)
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
        // One element per row, and the state said out loud — the same treatment the Organize rail's
        // items get. Without `.combine` a row is three or four separate stops (glyph, title,
        // detail, reason), which on a list you navigate with ↑/↓ is three or four times the
        // announcement for one destination; without the traits, the highlight that decides what ↩
        // runs is visible only to people looking at it.
        //
        // An unavailable row takes **no** button trait and no action: it is text that explains
        // itself ("Backup SSD — Not mounted"), and announcing it as a button would promise an
        // activation that `onTapGesture` already refuses.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(row.isAvailable
                                ? (isSelected ? [.isButton, .isSelected] : .isButton)
                                : [])
        // The row is a tap gesture, not a `Button`, so VoiceOver has nothing to activate unless it
        // is given one — a button trait with no action behind it is the worse half of the pair.
        .accessibilityAction {
            guard row.isAvailable else { return }
            selection = index
            onChoose()
        }
    }
}

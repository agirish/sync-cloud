import SwiftUI
import Design

/// The palette row's geometry, named so something other than the row can compute what fits in it.
///
/// The row draws from these constants, so `everyDetailFitsTheFloorWidth` measures the real opening
/// a detail line gets; a test that re-typed the numbers would pass after the layout moved.
///
/// Public and top-level because that test is in `SyncCloudTests`: the strings it measures are the
/// `Settings` package's and the geometry is this one's, so only the app target can hold both.
public enum PaletteRowMetrics {
    public static let horizontalPadding: CGFloat = 16
    public static let spacing: CGFloat = 12
    public static let symbolWidth: CGFloat = 18
    /// `Spacer(minLength:)`: the least the row keeps between the text and whatever trails it.
    public static let minTrailingGap: CGFloat = 8
    public static let titleSize: CGFloat = 13
    public static let detailSize: CGFloat = 11

    /// What the title and detail actually have to lay out in.
    ///
    /// - Parameters:
    public static func textOpening(listWidth: CGFloat, trailing: CGFloat) -> CGFloat {
        // Two paddings, the symbol, the gaps between every pair in the HStack (one more when
        // something trails), the spacer's own floor, and the trailing item itself.
        let gaps = spacing * (trailing > 0 ? 3 : 2)
        return listWidth - horizontalPadding * 2 - symbolWidth - gaps - minTrailingGap - trailing
    }
}

/// The palette's rows, in their own view so they can be rendered and read back. **Anything inside
/// a `contentSurface` + `groundedGlassCard` wrapper renders white in an offscreen host**, so a test
/// mounting the whole surface sees the text but not the selection highlight, which this
/// keyboard-only list depends on. `ScopeChipLabel` is split out of `LensWorkspaceView` for the same
/// reason. The toolbar's Go to field draws this list in `GoToResultsPanel`.
///
/// ## Drawn in the array's order, with a header wherever the group changes
///
/// ``PaletteRouter`` ranks rows by score across groups, so drawing groups in a fixed order would
/// put a lower-ranked row above a higher one and make ↓ jump upward. Drawn in rank order, with a
/// header at each group change, ↑ and ↓ move the way the eye expects.
struct PaletteResultsList: View {

    let rows: [PaletteRow]
    /// The live query, for match emphasis only — routing already happened upstream.
    var query: String = ""
    @Binding var selection: Int?
    /// The app's raw accent. The selected row fills with it deepened, under a white label.
    let accent: Color
    let onChoose: () -> Void

    /// `LiquidGlassHue.accentFillColor` for the hue `accent` came from, deep enough that the white
    /// label clears 4.5:1, like every other filled control in the app.
    private var accentFill: Color { AccentFill.deepened(accent) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows.indices, id: \.self) { index in
                        // A header wherever the group changes, including at index 0.
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

    /// The row's text with the matched run set bold, so why this row answered is visible. Ranges
    /// come from `PaletteRouter.matchRange`, the ranking's own lookup: a second display-side
    /// tokenizer would disagree on case folds and diacritics. A row matched via keywords draws no
    /// emphasis, since its visible text didn't match.
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
        HStack(spacing: PaletteRowMetrics.spacing) {
            Image(systemName: row.symbol)
                .scaledFont(.system(size: PaletteRowMetrics.titleSize))
                .frame(width: PaletteRowMetrics.symbolWidth)
            VStack(alignment: .leading, spacing: 1) {
                Self.emphasized(row.title, query: query)
                    .scaledFont(.system(size: PaletteRowMetrics.titleSize, weight: .medium))
                    .lineLimit(1)
                if let detail = row.detail {
                    Self.emphasized(detail, query: query)
                        .scaledFont(.system(size: PaletteRowMetrics.detailSize))
                        .opacity(isSelected ? 0.85 : 1)
                        .foregroundStyle(isSelected ? AnyShapeStyle(Color.white)
                                                    : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                        // A path truncates in the middle so the leaf, which names the folder,
                        // survives. Prose truncates at the tail rather than with a hole in it.
                        .truncationMode(detail.contains("/") ? .middle : .tail)
                }
            }
            Spacer(minLength: PaletteRowMetrics.minTrailingGap)
            // An unavailable result is shown disabled with its reason, not hidden: an unmounted
            // drive that simply vanished would teach that the palette doesn't know about it.
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
        // One `foregroundStyle` for the row, so the glyph, title and ↩ hint agree about sitting on
        // the accent. White on every hue, which is why the selection fills with `accentFill`, never
        // the raw accent.
        .foregroundStyle(isSelected ? AnyShapeStyle(Color.white)
                         : AnyShapeStyle(row.isAvailable ? Color.primary : Color.secondary))
        .padding(.horizontal, PaletteRowMetrics.horizontalPadding)
        .padding(.vertical, 7)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                    .fill(accentFill)
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
        // One element per row, with its state announced, as the Organize rail's items do. Without
        // `.combine` a row is several VoiceOver stops for one destination; without the traits, the
        // highlight that decides what ↩ runs is visible only to sighted users.
        //
        // An unavailable row gets no button trait and no action: it is text that explains itself
        // ("Backup SSD — Not mounted"), and a button would promise an activation that is refused.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(row.isAvailable
                                ? (isSelected ? [.isButton, .isSelected] : .isButton)
                                : [])
        // The row is a tap gesture, not a `Button`, so VoiceOver has nothing to activate unless it
        // is given an action; a button trait with no action would be worse than neither.
        .accessibilityAction {
            guard row.isAvailable else { return }
            selection = index
            onChoose()
        }
    }
}

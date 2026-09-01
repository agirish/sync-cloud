import SwiftUI
import Design

/// What the editor's rail is showing — the folder's text files, or the open document's headings.
///
/// **Two halves of one question, asked one at a time.** They were stacked in the rail until now,
/// the outline under the files behind a divider, on the argument that "which file" and "where in
/// it" are asked together. What that cost was the whole card: a folder with a dozen notes in it and
/// a document with a dozen headings shared one 232pt column, and each got half a view of itself.
/// The stack also had to cap the outline at eight rows — an arbitrary number chosen so the list
/// above it would not vanish — so the reader with a long document got a scroller inside a scroller.
///
/// Tabs pay for that with one click: a heading is one press away from a file name rather than a
/// scroll away. ⌘N takes the tab back to ``files`` on its own (``EditorFileRailView``), because the
/// naming row is drawn in that half and a new-file shortcut that opened a row nobody could see is
/// the one way this arrangement could lose something.
///
/// Per window and not persisted across launches, like ``EditorMode``: it describes a reading
/// session, not a preference. Held on `ContentView` for the reason the rail's filter is — the
/// editor's view is rebuilt from nothing by every workspace switch.
public enum EditorRailTab: String, CaseIterable, Sendable {
    case files
    case outline

    /// **"Text Files", not "Files".** The rail lists the text-like files in the folder and nothing
    /// else — no images, no folders — and the tab is now the only place that says so: the header it
    /// replaced read "Text files in Downloads" and the folder half of that sentence moved to the
    /// line underneath.
    ///
    /// **Measured before it was chosen, and the margin is thin.** With the widest title in both
    /// halves — which is what the equal-halves layout actually has to fit — the bar measures
    /// **159 · 169 · 196 · 207pt** across Small · Default · Large · Largest, against the 212pt the
    /// rail leaves it. Five points of room at the top of the range, on a `fittingSize` reading that
    /// overstates a symbol's ink by three to five, so the true margin is better than it looks and
    /// still not comfortable. A longer word than "Text Files" needs re-measuring, not judgement:
    /// `EditorLayoutTests.theRailTabsFitTheRailAtEveryTextSize` fails and names the number.
    public var title: String {
        switch self {
        case .files: return "Text Files"
        case .outline: return "Outline"
        }
    }

    var symbol: String {
        switch self {
        case .files: return "doc.text"
        case .outline: return "list.bullet.indent"
        }
    }
}

/// The rail's Text Files / Outline tabs.
///
/// **Mirrors ``EditorModeBar``'s geometry, and is hand-drawn for the same reason** — the native
/// segmented control renders neutral inside this window's glass and ignores `.tint`, so a selected
/// segment could never carry the app's accent.
///
/// The one difference is the width. The mode capsule is `.fixedSize()` inside a document column
/// that can be any width, so it sheds its words when the column is narrow. This sits in a rail that
/// is 232pt and cannot be anything else, so it spans that width with two equal halves and the words
/// never shed — there is no width at which they would need to, which is what
/// `theRailTabsFitTheRailAtEveryTextSize` pins.
struct EditorRailTabBar: View {

    @Binding var tab: EditorRailTab
    /// The segments to draw. **A seam, and it exists for one measurement.** The two halves are
    /// equal, so what decides whether a word truncates is the WIDEST label in half the bar — not
    /// the sum of the two, which is what an ideal-width reading of the real bar would report. A
    /// test builds this with the widest title in both halves and measures that, which is the
    /// layout's actual worst case rather than a replica of it.
    var tabs: [EditorRailTab] = EditorRailTab.allCases
    let accent: Color
    /// The label colour on the accent fill — deepened by the host so white text stays legible on
    /// every hue, the same value the mode capsule's selected segment uses.
    let onAccent: Color

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(tabs.enumerated()), id: \.offset) { segment($0.element) }
        }
        .padding(2)
        .background(Capsule().fill(.quaternary.opacity(0.5)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Rail contents")
    }

    private func segment(_ candidate: EditorRailTab) -> some View {
        let isSelected = tab == candidate
        return Button {
            tab = candidate
        } label: {
            HStack(spacing: 4) {
                CapsuleGlyph(symbol: candidate.symbol)
                // **Semibold whether or not it is selected**, for the reason the mode capsule's
                // labels are: weight changes width, and a segment that bolded only on selection
                // would be a different width depending on which one was chosen — in a row of two
                // equal halves, that moves the divider between them on every click.
                Text(candidate.title)
                    .scaledFont(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? AnyShapeStyle(onAccent) : AnyShapeStyle(Color.secondary))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            // **After the padding and before the fill**, so the accent capsule covers the whole
            // half rather than hugging the words: two segments of unequal ink drawn at their
            // natural widths would put the seam between them off-centre and move it when the
            // outline's heading count changed the word beside it.
            .frame(maxWidth: .infinity)
            .background {
                if isSelected { Capsule().fill(accent) }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.hoverAffordance(isSelected ? .filled : .segment, tint: accent))
        .accessibilityLabel(candidate.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

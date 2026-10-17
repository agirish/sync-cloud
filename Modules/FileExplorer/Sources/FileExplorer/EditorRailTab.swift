import SwiftUI
import Design

/// What the editor's rail is showing — the folder's files, the open PDF's pages, or the open
/// document's outline.
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
    /// The open PDF's pages, as thumbnails — offered only while a PDF is open (``shown(pdfIsOpen:)``).
    case pages
    case outline

    /// **"Files", no longer "Text Files"**, because the tab lists PDFs too now, each kind under a
    /// heading of its own (``EditorRail/sections(_:)``). The kind of file moved from the tab to
    /// those headings; the tab names what the rail is showing, as Pages and Outline do.
    ///
    /// **Words only, no glyph — measured, and chosen on 2026-10-16.** A third tab leaves each about
    /// 67pt of the 212pt the rail gives the bar. With its glyph, "Outline" in all three segments
    /// measured **208 · 220 · 251 · 267pt** across Small · Default · Large · Largest — over from
    /// Default up, and "Pages" (202 · 233 · 243) over from Large. The words alone fit at every size:
    /// the widest, "Outline" at Largest, takes 64pt of its 67. He was shown the truncated bar and
    /// the alternatives and picked words only, on both the two- and the three-tab bar, so the bar
    /// does not change its look when a PDF opens. A longer word needs re-measuring, not judgement:
    /// `EditorLayoutTests.theRailTabsFitTheRailAtEveryTextSize` fails and names the number.
    public var title: String {
        switch self {
        case .files: return "Files"
        case .pages: return "Pages"
        case .outline: return "Outline"
        }
    }

    /// The tab's glyph — no longer drawn on the tab itself (``title`` says why), but still the
    /// status line's sign for the outline: its heading item wears it, pointing at this tab.
    var symbol: String {
        switch self {
        case .files: return "doc.text"
        case .pages: return "square.grid.2x2"
        case .outline: return "list.bullet.indent"
        }
    }

    /// The tabs the rail offers: **Files · Pages · Outline while a PDF is open, Files · Outline
    /// otherwise.** Pages has nothing to show for a text file, and a tab that is always there and
    /// usually empty is a tab people learn to ignore.
    ///
    /// **A PDF keeps Outline only when it has a contents worth the tab** — `pdfHasOutline`, see
    /// ``pdfOutlineIsWorthATab(_:)`` (asked 2026-10-17). It stayed for every PDF until then, saying
    /// "no bookmarks" when there were none, so that the tabs depended on the kind of file alone;
    /// in practice the PDFs people open here are statements and scans, whose outline is nothing or
    /// one entry their generator wrote ("Page Identifiers"), and the tab was a promise they broke.
    /// A text file always has it: headings are the reader's own, and a note gains them as it grows.
    public static func shown(pdfIsOpen: Bool, pdfHasOutline: Bool) -> [EditorRailTab] {
        guard pdfIsOpen else { return [.files, .outline] }
        return pdfHasOutline ? [.files, .pages, .outline] : [.files, .pages]
    }

    /// The fewest bookmarks a PDF needs for its Outline tab. One is no contents: it names the whole
    /// file, or is the generator's own label, and a one-row list sends you to one place.
    public static let minimumPDFBookmarks = 2

    /// Whether a PDF's bookmarks earn the Outline tab — every level counted, so a single chapter
    /// with sections under it qualifies.
    public static func pdfOutlineIsWorthATab(_ entries: [EditorPDFOutlineEntry]) -> Bool {
        entries.count >= minimumPDFBookmarks
    }

    /// The tab to draw for a remembered one: **a tab that is not offered falls back to Files** —
    /// Pages with no PDF open, Outline on a PDF without a contents.
    ///
    /// **A display filter, not a write-back** — `EditorMode.resolved`'s rule, for its reason. The
    /// host keeps what was chosen; this only decides what is drawn. Writing `.files` back when a
    /// text file opened would make one Markdown note cost the reader their place: read PDFs on
    /// Pages, glance at a note, and the next PDF would open on Files.
    public static func resolved(_ tab: EditorRailTab, pdfIsOpen: Bool, pdfHasOutline: Bool) -> EditorRailTab {
        shown(pdfIsOpen: pdfIsOpen, pdfHasOutline: pdfHasOutline).contains(tab) ? tab : .files
    }
}

/// The rail's Files / Pages / Outline tabs.
///
/// **Mirrors ``EditorModeBar``'s geometry, and is hand-drawn for the same reason** — the native
/// segmented control renders neutral inside this window's glass and ignores `.tint`, so a selected
/// segment could never carry the app's accent.
///
/// The one difference is the width. The mode capsule is `.fixedSize()` inside a document column
/// that can be any width, so it sheds its words when the column is narrow. This sits in a rail that
/// is 232pt and cannot be anything else, so it spans that width in equal segments — two, or three
/// with a PDF open — and the words never shed. They carry no glyph, which is what lets three fit
/// (``EditorRailTab/title``); `theRailTabsFitTheRailAtEveryTextSize` pins it.
struct EditorRailTabBar: View {

    @Binding var tab: EditorRailTab
    /// The segments to draw — ``EditorRailTab/shown(pdfIsOpen:)``, from the rail. **Also a seam for
    /// one measurement.** The segments are equal, so what decides whether a word truncates is the
    /// WIDEST label in one segment — not the sum, which is what an ideal-width reading of the real
    /// bar would report. A test builds this with one title in every segment and measures that,
    /// which is the layout's actual worst case rather than a replica of it.
    var tabs: [EditorRailTab] = EditorRailTab.shown(pdfIsOpen: false, pdfHasOutline: false)
    let accent: Color
    /// The label colour on the accent fill — deepened by the host so white text stays legible on
    /// every hue, the same value the mode capsule's selected segment uses.
    let onAccent: Color

    /// The bar's selection lens in Frosted and Clear — see `SelectionLens`.
    static let lensChannel = SelectionLensChannel("editor.rail.tabs")

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(tabs.enumerated()), id: \.offset) { segment($0.element) }
        }
        // Frosted and Clear: one glass lens that glides between the segments (RD46).
        .selectionLensHost(Self.lensChannel, selected: tab, style: .fill(.capsule, color: accent))
        .padding(2)
        // Frosted and Clear: a glass track, like the bar's other controls (`ChromeGlass`).
        .chromeGlassTrack()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Rail contents")
    }

    private func segment(_ candidate: EditorRailTab) -> some View {
        let isSelected = tab == candidate
        return Button {
            tab = candidate
        } label: {
            // **Semibold whether or not it is selected**, for the reason the mode capsule's
            // labels are: weight changes width, and a segment that bolded only on selection would
            // be a different width depending on which one was chosen — in a row of equal
            // segments, that moves the dividers between them on every click.
            Text(candidate.title)
                .scaledFont(.system(size: 10, weight: .semibold))
                .lineLimit(1)
            .selectionLensLabelInk(isSelected: isSelected, onFill: onAccent, unselected: Color.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            // **After the padding and before the fill**, so the accent capsule covers the whole
            // segment rather than hugging the words: segments of unequal ink drawn at their
            // natural widths would put the seams between them off-centre.
            .frame(maxWidth: .infinity)
            .background {
                if isSelected { SelectionLensTodayMarker { Capsule().fill(accent) } }
            }
            .selectionLensStop(Self.lensChannel, id: candidate)
            .contentShape(Capsule())
        }
        // `.filled` for the chosen half at Solid; under the lens, `.segment` (`SelectionLens`).
        .selectionLensChoiceButtonStyle(isSelected: isSelected, tint: accent)
        .accessibilityLabel(candidate.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

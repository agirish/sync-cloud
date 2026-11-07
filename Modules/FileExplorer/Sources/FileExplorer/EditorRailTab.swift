import SwiftUI
import Design

/// What the editor's rail is showing: the folder's files, the open PDF's pages, or the open
/// document's outline. Tabs, not a stack, so each gets the whole 232pt column instead of half of it
/// and a long outline needs no capped scroller inside a scroller. ⌘N switches back to ``files``
/// itself (``EditorFileRailView``), because the naming row is drawn there.
///
/// Per window and not persisted, like ``EditorMode``: a reading session, not a preference. Held on
/// `ContentView`, as the rail's filter is, because every workspace switch rebuilds the editor's
/// view.
public enum EditorRailTab: String, CaseIterable, Sendable {

    /// What hides the list, on its fold chevron and on the strip's lit button. Both put the whole
    /// list away whichever tab is showing, so the words don't name one tab.
    public static let hideListTitle = "Hide the file list"

    case files
    /// The open PDF's pages, as thumbnails; offered only while a PDF is open
    /// (``shown(pdfIsOpen:pdfHasOutline:markdownIsOpen:)``).
    case pages
    case outline

    /// "Files", not "Text Files": the tab lists PDFs too, each kind under its own heading
    /// (``EditorRail/sections(_:)``), and names what the rail shows, as Pages and Outline do.
    ///
    /// Words only, no glyph: three tabs leave each about 67pt of the bar's 212pt, and with glyphs
    /// "Outline" and "Pages" truncate at larger text sizes, while the widest word alone ("Outline"
    /// at Largest) takes 64pt. The same on the two-tab bar, so it doesn't change look when a PDF
    /// opens. `EditorLayoutTests.theRailTabsFitTheRailAtEveryTextSize` fails if a word stops fitting.
    public var title: String {
        switch self {
        case .files: return "Files"
        case .pages: return "Pages"
        case .outline: return "Outline"
        }
    }

    /// The tab's glyph: not drawn on the tab (``title`` says why), but the status line's heading
    /// item wears it, pointing at this tab.
    var symbol: String {
        switch self {
        case .files: return "doc.text"
        case .pages: return "square.grid.2x2"
        case .outline: return "list.bullet.indent"
        }
    }

    /// The tabs the rail offers: Files · Pages · Outline while a PDF is open, Files · Outline while a
    /// Markdown note is, Files alone otherwise. A tab that is usually empty is one people learn to
    /// ignore.
    ///
    /// A PDF keeps Outline only with a contents worth the tab (`pdfHasOutline`, see
    /// ``pdfOutlineIsWorthATab(_:)``): statements and scans have none, or one generator entry. A text
    /// file keeps it only when it is Markdown (`markdownIsOpen`), since only Markdown has headings; a
    /// note with none yet keeps it, as notes gain them. With nothing open, there is no Outline.
    public static func shown(pdfIsOpen: Bool, pdfHasOutline: Bool, markdownIsOpen: Bool) -> [EditorRailTab] {
        guard pdfIsOpen else { return markdownIsOpen ? [.files, .outline] : [.files] }
        return pdfHasOutline ? [.files, .pages, .outline] : [.files, .pages]
    }

    /// The fewest bookmarks a PDF needs for its Outline tab. One is no contents: it names the whole
    /// file, or is the generator's own label, and a one-row list sends you to one place.
    public static let minimumPDFBookmarks = 2

    /// Whether a PDF's bookmarks earn the Outline tab, every level counted, so a single chapter
    /// with sections under it qualifies.
    public static func pdfOutlineIsWorthATab(_ entries: [EditorPDFOutlineEntry]) -> Bool {
        entries.count >= minimumPDFBookmarks
    }

    /// The tab to draw for a remembered one: a tab not offered falls back to Files.
    ///
    /// A display filter, not a write-back, as `EditorMode.resolved` is: the host keeps what was
    /// chosen. Writing `.files` back would make one glance at a note send the next PDF to Files
    /// instead of Pages.
    public static func resolved(_ tab: EditorRailTab, pdfIsOpen: Bool, pdfHasOutline: Bool,
                                markdownIsOpen: Bool) -> EditorRailTab {
        shown(pdfIsOpen: pdfIsOpen, pdfHasOutline: pdfHasOutline, markdownIsOpen: markdownIsOpen).contains(tab)
            ? tab : .files
    }
}

/// The rail's Files / Pages / Outline tabs.
///
/// Mirrors ``EditorModeBar``'s geometry and is hand-drawn for the same reason: the native segmented
/// control renders neutral inside this window's glass and ignores `.tint`, so the selected segment
/// could never carry the app's accent.
///
/// Unlike the mode capsule, which sheds its words in a narrow column, this spans the rail's fixed
/// 232pt in equal segments and never sheds. No glyphs is what lets three fit
/// (``EditorRailTab/title``); `theRailTabsFitTheRailAtEveryTextSize` pins it.
struct EditorRailTabBar: View {

    @Binding var tab: EditorRailTab
    /// The segments to draw (``EditorRailTab/shown(pdfIsOpen:pdfHasOutline:markdownIsOpen:)``, from
    /// the rail). Also a test seam: with equal segments, the widest label decides truncation, not
    /// the sum, so a test puts one title in every segment to measure the real worst case.
    var tabs: [EditorRailTab] = EditorRailTab.shown(pdfIsOpen: false, pdfHasOutline: false, markdownIsOpen: true)
    /// The selected segment's fill, lens and hover: the deepened accent, as the mode capsule's
    /// (`LiquidGlassHue.accentFillColor`).
    let accentFill: Color
    /// The label colour on `accentFill`, the same value the mode capsule's selected segment uses.
    let onAccent: Color

    /// The bar's selection lens in Frosted and Clear; see `SelectionLens`.
    static let lensChannel = SelectionLensChannel("editor.rail.tabs")

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(tabs.enumerated()), id: \.offset) { segment($0.element) }
        }
        // Frosted and Clear: one glass lens that glides between the segments.
        .selectionLensHost(Self.lensChannel, selected: tab, style: .fill(.capsule, color: accentFill))
        .padding(2)
        // Frosted and Clear: a glass track, like the bar's other controls (`ChromeGlass`).
        .chromeGlassTrack()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("File list")
    }

    private func segment(_ candidate: EditorRailTab) -> some View {
        let isSelected = tab == candidate
        return Button {
            tab = candidate
        } label: {
            // Semibold whether or not selected, as the mode capsule's labels are: weight changes
            // width, so bolding on selection would move the dividers on every click.
            Text(candidate.title)
                .scaledFont(.system(size: 10, weight: .semibold))
                .lineLimit(1)
            .selectionLensLabelInk(isSelected: isSelected, onFill: onAccent, unselected: Color.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            // After the padding and before the fill, so the accent capsule covers the whole segment
            // rather than hugging the words, which would put the seams off-centre.
            .frame(maxWidth: .infinity)
            .background {
                if isSelected { SelectionLensTodayMarker { Capsule().fill(accentFill) } }
            }
            .selectionLensStop(Self.lensChannel, id: candidate)
            .contentShape(Capsule())
        }
        // `.filled` for the chosen half at Solid; under the lens, `.segment` (`SelectionLens`).
        .selectionLensChoiceButtonStyle(isSelected: isSelected, tint: accentFill)
        .accessibilityLabel(candidate.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .help(Self.help(candidate))
    }

    /// What each segment's tooltip says it shows.
    static func help(_ tab: EditorRailTab) -> String {
        switch tab {
        case .files: return "Show the text files and PDFs in this folder"
        case .pages: return "Show this PDF’s pages"
        case .outline: return "Show this document’s outline"
        }
    }
}

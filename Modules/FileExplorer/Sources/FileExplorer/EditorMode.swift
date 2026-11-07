import SwiftUI
import Design

/// What the editor column is showing.
///
/// Per window, and it survives opening another file: someone reading notes in Preview wants the
/// next one in Preview too. Not persisted across launches; it describes a reading session, not a
/// preference. The one automatic change is narrowing (``resolved(_:isMarkdown:)``). Held on
/// `ContentView` with the split fraction, because the workspace view is torn down on tab switches.
public enum EditorMode: String, CaseIterable, Sendable {
    case edit
    case preview
    case split

    /// `.edit` is labelled "Source", not "Edit": the label names which representation you are
    /// looking at, as the other two do, and "Edit" inside the Edit workspace, under the Edit menu,
    /// would read `Edit ▸ Edit` (`Workspace.title`). "Source" always has a referent: the capsule
    /// is drawn only for Markdown (`EditorWorkspaceView`, gated on `document.isMarkdown`).
    public var title: String {
        switch self {
        case .edit: return "Source"
        case .preview: return "Preview"
        case .split: return "Split"
        }
    }

    var symbol: String {
        switch self {
        case .edit: return "pencil"
        case .preview: return "eye"
        case .split: return "rectangle.split.2x1"
        }
    }

    /// Text ▸ Source / Preview / Split's chord: ⌃⌘1/2/3, in the capsule's order. Declared per case,
    /// not derived from `allCases.firstIndex`, so reordering the enum can't move a chord onto
    /// another mode (`AppChordTests` pins each).
    public var chord: AppChord {
        switch self {
        case .edit: return .editorSourceMode
        case .preview: return .editorPreviewMode
        case .split: return .editorSplitMode
        }
    }

    /// The mode a document should open in, given what the file is. A non-Markdown file is always
    /// `.edit`, decided here alone: the capsule is hidden for those files, so a preview carried
    /// over from a `.md` would have no way out.
    public static func resolved(_ stored: EditorMode, isMarkdown: Bool) -> EditorMode {
        isMarkdown ? stored : .edit
    }
}

/// The Source / Preview / Split capsule.
///
/// Hand-drawn segments in a container capsule, like the workspace bar, because the native
/// segmented control renders neutral inside this window's glass and ignores `.tint`.
///
/// It sheds its words when the column is narrow: labelled, it is about 200–250pt across the text
/// sizes, against a 260pt minimum column that must also hold the file name; glyph-only, about
/// 80–100pt. The names stay in the tooltip and accessibility label. At the 760pt window floor the
/// words shed only at the top of the text range, which
/// `EditorLayoutTests.theWordsShedAtTheNarrowestWindowOnlyAtTheTopOfTheTextRange` pins.
///
/// Expand's word shares this budget and is spent first: `EditorHeaderDoorsTests` holds that the
/// capsule keeps its words wherever Expand keeps its own, at every size, and that no word is drawn
/// over a cut name. Under glass the × takes 2pt more beside Expand
/// (`ChromeGlass.clearance(rowSpacing:outset:)`). Widths are `NSHostingView.fittingSize` on the
/// forced rung, as `EditorLayoutTests` measures; re-measure rather than trust prose.
///
/// `ViewThatFits`, not arithmetic as in `WorkspaceBarMetrics`: that one sits in a toolbar item,
/// proposed its own ideal width, while this sits in an `HStack` handed a real width.
struct EditorModeBar: View {

    @Binding var mode: EditorMode
    /// The selected segment's fill, lens and hover: the deepened accent, so the white label on it
    /// clears AA (`LiquidGlassHue.accentFillColor`).
    let accentFill: Color
    let onAccent: Color
    /// Forces a rung. `nil` picks by width, which the hidden height reservation relies on. The
    /// document header forces one because it asks whether the file's whole name still fits beside
    /// the words (`EditorWorkspaceView.nameRow`); tests force one to measure each rung.
    var forcedRung: Rung?

    /// The two rungs, named so a test can ask for one rather than provoke it.
    enum Rung { case labelled, glyphOnly }

    /// The capsule's selection lens in Frosted and Clear (`SelectionLens`).
    static let lensChannel = SelectionLensChannel("editor.mode")

    var body: some View {
        if let forcedRung {
            capsule(labelled: forcedRung == .labelled)
        } else {
            ViewThatFits(in: .horizontal) {
                capsule(labelled: true)
                capsule(labelled: false)
            }
        }
    }

    /// The room between two segments, and a glyph-only segment's padding either side of its
    /// glyph: what the keycaps over them must fit.
    static let segmentGap: CGFloat = 3
    static let glyphSegmentPadding: CGFloat = 6

    private func capsule(labelled: Bool) -> some View {
        HStack(spacing: Self.segmentGap) {
            ForEach(EditorMode.allCases, id: \.self) { candidate in
                segment(candidate, labelled: labelled)
            }
        }
        // Frosted and Clear: one glass lens that glides between modes.
        .selectionLensHost(Self.lensChannel, selected: mode, style: .fill(.capsule, color: accentFill))
        .padding(2)
        // Frosted and Clear: a glass track, like the bar's other controls (`ChromeGlass`).
        .chromeGlassTrack()
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("View mode")
    }

    private func segment(_ candidate: EditorMode, labelled: Bool) -> some View {
        let isSelected = mode == candidate
        return Button {
            mode = candidate
        } label: {
            HStack(spacing: 4) {
                CapsuleGlyph(symbol: candidate.symbol)
                if labelled {
                    // Semibold whether or not selected: weight changes width, so bolding only
                    // the selected segment would shift the file name beside it on every click.
                    // The accent fill marks the selection.
                    Text(candidate.title)
                        .scaledFont(.system(size: 10, weight: .semibold))
                }
            }
            .selectionLensLabelInk(isSelected: isSelected, onFill: onAccent, unselected: Color.secondary)
            .padding(.horizontal, labelled ? 8 : Self.glyphSegmentPadding)
            .padding(.vertical, 3)
            .background {
                if isSelected { SelectionLensTodayMarker { Capsule().fill(accentFill) } }
            }
            .selectionLensStop(Self.lensChannel, id: candidate)
            .contentShape(Capsule())
        }
        // `.filled` for the chosen mode at Solid; under the lens, `.segment` (`SelectionLens`).
        .selectionLensChoiceButtonStyle(isSelected: isSelected, tint: accentFill)
        // ⌥ shows ⌃⌘1–3, compact, since the glyph-only segments sit closer than a full key.
        .shortcutKeycap(candidate.chord.display, compact: true)
        // Once the word is shed, the name lives in the tooltip and the accessibility label.
        .help(ShortcutHint.tooltip(candidate.title, candidate.chord.display))
        .accessibilityLabel(candidate.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Capsule glyph

/// One segment's symbol, drawn inside a box that keeps the row a fixed width.
///
/// The symbols have different natural widths (`pencil`, `eye`, `rectangle.split.2x1` here, four
/// more on ``StorageSectionBar``), so an unframed row would change width with the selection and
/// shift whatever sits beside it.
///
/// The box scales with the glyph, through the type ramp's knee curve, so it grows with Settings ▸
/// Text size. A fixed box would pin the control at one size, and since `.frame` doesn't clip, an
/// enlarged glyph would overflow it.
struct CapsuleGlyph: View {

    let symbol: String

    @Environment(\.appFontScale) private var scale

    /// The glyph's own point size at the default text size.
    static let pointSize: CGFloat = 10
    /// The box drawn around it at the default text size, holding the widest symbol comfortably.
    static let boxSize: CGFloat = 13

    /// The box at `scale`, in the same proportion to the glyph as `boxSize` is to `pointSize`.
    /// The rule lives in ``Design/FontSize/scaledBox(_:basePoint:scale:)``, shared with `SetupSheet`
    /// and Organize's pass-lens row.
    static func box(at scale: CGFloat) -> CGFloat {
        FontSize.scaledBox(boxSize, basePoint: pointSize, scale: scale)
    }

    var body: some View {
        Image(systemName: symbol)
            .scaledFont(.system(size: Self.pointSize, weight: .medium))
            .frame(width: Self.box(at: scale), height: Self.box(at: scale))
    }
}

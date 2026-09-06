import SwiftUI
import Design

/// What the editor column is showing.
///
/// **Per window, and it survives opening another file** — which is the opposite of what this
/// comment claimed while the code did the other thing. Somebody reading three notes in Preview
/// wants the third to open in Preview too; making it a fact about each document would mean
/// re-choosing on every click, which is the behaviour every editor on the platform declines to
/// have. It is not persisted across launches: it describes a reading session, not a preference.
///
/// The one automatic change is narrowing — see ``resolved(_:isMarkdown:)``. Held on `ContentView`
/// alongside the split fraction, because the workspace view is torn down on every tab switch.
public enum EditorMode: String, CaseIterable, Sendable {
    case edit
    case preview
    case split

    /// **`.edit` is labelled "Source", not "Edit".** The case name says what the mode lets you
    /// do; the label says which representation of the document you are looking at, which is the
    /// question the other two segments answer and the only one that makes a three-way choice
    /// coherent. It also settles a collision the capsule could not win: the app already has a
    /// top-level `Edit` menu AND an `Edit` workspace (see `Workspace.title`, which weighed the
    /// menu-bar clash and took the cost), so a segment reading "Edit" inside the Edit workspace
    /// read as `Edit ▸ Edit`. Of the three, this is the one that could move — the menu is an
    /// AppKit convention and the workspace is a decided argument.
    ///
    /// "Source" always has a referent: the capsule is drawn only for Markdown
    /// (`EditorWorkspaceView`, gated on `document.isMarkdown`), so the word never appears over a
    /// `.txt` where there is no rendered form for it to be the source OF.
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

    /// Text ▸ Source / Preview / Split's chord — ⌃⌘1/2/3, in the capsule's own order.
    ///
    /// Declared per case rather than derived from `allCases.firstIndex`, so a reordering of the
    /// enum cannot silently move a chord onto a different mode: `AppChordTests` pins each display,
    /// and the pin is only worth something if the mapping is written down.
    public var chord: AppChord {
        switch self {
        case .edit: return .editorSourceMode
        case .preview: return .editorPreviewMode
        case .split: return .editorSplitMode
        }
    }

    /// The mode a document should open in, given what the file is.
    ///
    /// **A non-Markdown file is always `.edit`**, and this is the one place that decides it — the
    /// capsule is hidden for those files, and a mode that survived a switch from a `.md` to a
    /// `.txt` would leave the column showing a preview with no way to leave it.
    public static func resolved(_ stored: EditorMode, isMarkdown: Bool) -> EditorMode {
        isMarkdown ? stored : .edit
    }
}

/// The Source / Preview / Split capsule.
///
/// Mirrors the workspace bar's geometry at rail scale — hand-drawn segments inside a container
/// capsule, the selected one carrying the accent fill — for the reason the workspace bar is
/// hand-drawn rather than a `Picker`: the native segmented control renders neutral inside this
/// window's glass and ignores `.tint`, so a selected segment could never carry the app's accent.
///
/// **It sheds its words when the column is narrow**, the same bargain the workspace bar strikes and
/// for the same reason. Re-measured 2026-08-31 across Small · Default · Large · Largest, the
/// labelled capsule is **198 · 208 · 239 · 251pt** — against a document column whose guaranteed
/// minimum is 260, which leaves no room for the file name it sits beside. Glyph-only it is
/// **82 · 85 · 95 · 99**, which does. The names survive in the tooltip and the accessibility label,
/// exactly as the workspace bar's do.
///
/// The labelled figures are 15–20pt above what they were when this segment read "Edit"
/// (183 · 192 · 220 · 231), which is what the longer word costs. It buys a real corner and one
/// worth knowing about: at the 760pt window floor the words now shed at the **top of the text
/// range alone** — 135%, three points over a 368pt column — where "Edit" fitted. The glyph rung is
/// untouched by the rename, so the ceiling that actually constrains this control did not move.
/// `EditorLayoutTests.theWordsShedAtTheNarrowestWindowOnlyAtTheTopOfTheTextRange` pins that
/// boundary against the whole selectable range rather than the four named presets, because the
/// slider stops between them.
///
/// **The glyph figures used to be one number, and that was the bug, not a rounding.** Until the
/// same date this read "96–110" and the rung actually measured 85 at all four sizes, because the
/// symbols sat in a hard `13×13` frame; see ``CapsuleGlyph`` for what the frame is for and what it
/// now scales by. Every number here is `NSHostingView.fittingSize` on the forced rung, which is
/// what `EditorLayoutTests` measures — prose is not a measurement, so re-run it before editing it.
///
/// `ViewThatFits` rather than arithmetic, which is the opposite of `WorkspaceBarMetrics`' choice:
/// that one is in a toolbar item, which is proposed its own ideal width rather than the window's,
/// so it never sees the constraint. This is in an ordinary `HStack` that is handed a real width.
struct EditorModeBar: View {

    @Binding var mode: EditorMode
    let accent: Color
    let onAccent: Color
    /// Forces a rung, for the tests that measure each one. `nil` picks by width.
    var forcedRung: Rung?

    /// The two rungs, named so a test can ask for one rather than trying to provoke it.
    enum Rung { case labelled, glyphOnly }

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

    private func capsule(labelled: Bool) -> some View {
        HStack(spacing: 3) {
            ForEach(EditorMode.allCases, id: \.self) { candidate in
                segment(candidate, labelled: labelled)
            }
        }
        .padding(2)
        .background(Capsule().fill(.quaternary.opacity(0.5)))
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
                    // **Semibold whether or not it is selected.** Weight changes width, so a
                    // capsule that bolded only the selected segment measured two different widths
                    // depending on which one that was — and the file name beside it shifted on
                    // every click. The accent fill is what marks the selection; the weight was
                    // saying the same thing twice and charging for it.
                    Text(candidate.title)
                        .scaledFont(.system(size: 10, weight: .semibold))
                }
            }
            .foregroundStyle(isSelected ? AnyShapeStyle(onAccent) : AnyShapeStyle(Color.secondary))
            .padding(.horizontal, labelled ? 8 : 6)
            .padding(.vertical, 3)
            .background {
                if isSelected { Capsule().fill(accent) }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.hoverAffordance(isSelected ? .filled : .segment, tint: accent))
        // Once the word is shed the glyph is the only thing naming the mode, so the name has to
        // survive somewhere reachable — the tooltip for a mouse, the a11y label otherwise.
        .help(candidate.title)
        .accessibilityLabel(candidate.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Capsule glyph

/// One segment's symbol, drawn inside a box that keeps the row a fixed width.
///
/// **The box exists so the row does not resize as the selection moves through it.** These symbols
/// draw at different natural widths — `pencil`, `eye` and `rectangle.split.2x1` on the Editor's
/// capsule; four more on ``StorageSectionBar`` — and an unframed row would be a different width
/// depending on which segment happened to be under the fill, shifting whatever sits beside it on
/// every click. That goal is real and this keeps it.
///
/// **What it did NOT keep was a hard `13`.** The frame was a literal, so although the glyph inside
/// it was `.scaledFont`-ed and grew with Settings ▸ Text size, the box did not: measured
/// 2026-08-31, the Editor's glyph-only rung was **85pt at Small, Default, Large and Largest alike**
/// and Storage's was 113pt at all four — a control pinned at one size while the words beside it
/// grew, and, because `.frame` does not clip, an enlarged glyph *overflowing* its box rather than
/// being trimmed by it. The labelled rung scaled the whole time (186 → 217), which is exactly why
/// this went unseen: the test that asked whether the capsule grows only ever measured that one.
///
/// So the box is `boxSize` *at the scale the glyph itself renders at* — and through
/// `FontSize.scaledPointSize`, not a bare multiply, so the frame and its glyph track the type
/// ramp's own knee curve rather than diverging the moment `pointSize` moves above `knee`. At
/// today's 10pt they are the same number over the whole selectable range; the point is that they
/// stay the same number if either constant changes.
struct CapsuleGlyph: View {

    let symbol: String

    @Environment(\.appFontScale) private var scale

    /// The glyph's own point size at the default text size.
    static let pointSize: CGFloat = 10
    /// The box drawn around it at the default text size, holding the widest symbol comfortably.
    static let boxSize: CGFloat = 13

    /// The box at `scale`, in the same proportion to the glyph as `boxSize` is to `pointSize`.
    ///
    /// The arithmetic moved to ``Design/FontSize/scaledBox(_:basePoint:scale:)`` once the sweep
    /// that followed this fix found the same shape in `SetupSheet` and Organize's pass-lens row.
    /// Same expression, one copy — and the doc for the rule is where the reasoning now lives.
    static func box(at scale: CGFloat) -> CGFloat {
        FontSize.scaledBox(boxSize, basePoint: pointSize, scale: scale)
    }

    var body: some View {
        Image(systemName: symbol)
            .scaledFont(.system(size: Self.pointSize, weight: .medium))
            .frame(width: Self.box(at: scale), height: Self.box(at: scale))
    }
}

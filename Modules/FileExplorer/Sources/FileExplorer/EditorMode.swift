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

    public var title: String {
        switch self {
        case .edit: return "Edit"
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

    /// The mode a document should open in, given what the file is.
    ///
    /// **A non-Markdown file is always `.edit`**, and this is the one place that decides it — the
    /// capsule is hidden for those files, and a mode that survived a switch from a `.md` to a
    /// `.txt` would leave the column showing a preview with no way to leave it.
    public static func resolved(_ stored: EditorMode, isMarkdown: Bool) -> EditorMode {
        isMarkdown ? stored : .edit
    }
}

/// The Edit / Preview / Split capsule.
///
/// Mirrors the workspace bar's geometry at rail scale — hand-drawn segments inside a container
/// capsule, the selected one carrying the accent fill — for the reason the workspace bar is
/// hand-drawn rather than a `Picker`: the native segmented control renders neutral inside this
/// window's glass and ignores `.tint`, so a selected segment could never carry the app's accent.
///
/// **It sheds its words when the column is narrow**, the same bargain the workspace bar strikes and
/// for the same reason. Measured, the labelled capsule is 185pt at the default text size and 215 at
/// the largest — against a document column whose guaranteed minimum is 260, which leaves no room
/// for the file name it sits beside. Glyph-only it is 96–110, which does. The names survive in the
/// tooltip and the accessibility label, exactly as the workspace bar's do.
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
                Image(systemName: candidate.symbol)
                    .scaledFont(.system(size: 10, weight: .medium))
                    // Framed for the reason the workspace bar's glyphs are: these three symbols
                    // draw at three different widths, and an unframed row would change size as the
                    // selection moved through it.
                    .frame(width: 13, height: 13)
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

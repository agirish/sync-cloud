import PDFKit
import SwiftUI
import Design

/// **The find bar for a PDF, drawn as a card floating in the canvas's top-right corner** (Phase 6a,
/// mockup G, as Safari's): the field, the count, ‹ › and ×. It floats over the pages instead of
/// pushing them down a row, so opening it moves nothing (`theFindCardLeavesThePageWhereItWas`); the
/// capsule slides clear of it if it is docked there (``EditorPDFFloating/clear(_:of:sliding:within:)``).
///
/// **The app's own control, not `NSTextFinder`'s bar**: that one drives an `NSTextFinderClient`,
/// and a `PDFView` is not one — nor could it be without its text being extracted on the main
/// thread. The searching is ``EditorPDFFind``'s, in the PDFKit lane.
///
/// Typing searches once it settles; Return goes to the next match; Esc and × put the card away
/// and clear the highlights. While the lane is busy with other PDF work the count says so, inside
/// the card.
struct EditorPDFFindBar: View {
    @ObservedObject var find: EditorPDFFind
    let accent: Color
    @State private var typed = ""
    @FocusState private var focused: Bool

    /// The count's width — enough for "3 of 9 so far" on one line, and the waiting note on a
    /// second. **Fixed, not a ceiling**: the card's width is what the capsule slides clear of, so a
    /// count as wide as its words made a capsule docked beside it hop sideways, unanimated, at
    /// every step of a search — "Searching…", "1 of 12 so far", "1 of 12". Sized with the
    /// field's least width so the card, count and all, fits the narrowest column (`fieldMinWidth`).
    static let captionWidth: CGFloat = 140
    /// The field's least width — with the fixed count, what keeps the card inside a 368pt column.
    static let fieldMinWidth: CGFloat = 100

    var body: some View {
        if find.isShown {
            HStack(spacing: 6) {
                field
                if !find.caption.isEmpty {
                    Text(find.caption)
                        .scaledFont(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: Self.captionWidth, alignment: .leading)
                }
                stepper
                Button { find.hide() } label: {
                    Image(systemName: "xmark")
                        .scaledFont(.system(size: 9, weight: .semibold))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.hoverAffordance(.glyph, tint: accent))
                .accessibilityLabel("Close Find")
                .help(ShortcutHint.tooltip("Close Find", "esc"))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .modifier(EditorPDFFloatingGround(shape: .roundedRect(Radius.card)))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Find in this PDF")
            .onAppear {
                typed = find.query
                focused = true
            }
            .onChange(of: find.focusRequest) { _, _ in focused = true }
            // ⌘E writes the query from outside the field.
            .onChange(of: find.query) { _, query in if typed != query { typed = query } }
        }
    }

    private var field: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .scaledFont(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Find in this PDF", text: $typed)
                .textFieldStyle(.plain)
                .scaledFont(.system(size: 11))
                .focused($focused)
                .onChange(of: typed) { _, text in find.type(text) }
                .onSubmit { find.submit(typed) }
                .onExitCommand { find.hide() }
                .accessibilityLabel("Find in this PDF")
            if !typed.isEmpty {
                Button {
                    typed = ""
                    find.search("")
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .scaledFont(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear the search")
                .help("Clear the search")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .frame(minWidth: Self.fieldMinWidth, idealWidth: 170, maxWidth: 180)
        .background(RoundedRectangle(cornerRadius: Radius.chip).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: Radius.chip).strokeBorder(Color(nsColor: .separatorColor)))
    }

    private var stepper: some View {
        HStack(spacing: 2) {
            stepButton(forward: false)
            stepButton(forward: true)
        }
    }

    private func stepButton(forward: Bool) -> some View {
        let label = forward ? "Next match" : "Previous match"
        return Button { find.step(forward: forward) } label: {
            Image(systemName: forward ? "chevron.right" : "chevron.left")
                .scaledFont(.system(size: 9, weight: .semibold))
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.hoverAffordance(.glyph, tint: accent))
        .disabled(find.matches.isEmpty)
        .accessibilityLabel(label)
        .help(ShortcutHint.tooltip(label, forward ? AppChord.findNext.display : AppChord.findPrevious.display))
    }
}

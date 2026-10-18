import PDFKit
import SwiftUI
import Design

/// **The find bar for a PDF, under its header** (mockup 3) — the text find bar's shape: a field with
/// the count beside it, ‹ › and Done.
///
/// **The app's own control, not `NSTextFinder`'s bar**: that one drives an `NSTextFinderClient`,
/// and a `PDFView` is not one — nor could it be without its text being extracted on the main
/// thread. The searching is ``EditorPDFFind``'s, in the PDFKit lane.
///
/// Typing searches once it settles; Return goes to the next match; Esc and Done put the bar away
/// and clear the highlights.
struct EditorPDFFindBar: View {
    @ObservedObject var find: EditorPDFFind
    let accent: Color
    @State private var typed = ""
    @FocusState private var focused: Bool

    var body: some View {
        if find.isShown {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    field
                    Text(find.caption)
                        .scaledFont(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(-1)
                    Spacer(minLength: 0)
                    stepper
                    Button("Done") { find.hide() }
                        .controlSize(.small)
                        .help("Close the find bar")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                Divider()
            }
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
            TextField("Find in PDF", text: $typed)
                .textFieldStyle(.plain)
                .scaledFont(.system(size: 11))
                .focused($focused)
                .disabled(!find.isSearchable)
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
        .frame(minWidth: 140, idealWidth: 220, maxWidth: 260)
        .background(RoundedRectangle(cornerRadius: Radius.chip).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: Radius.chip).strokeBorder(Color(nsColor: .separatorColor)))
    }

    private var stepper: some View {
        HStack(spacing: 2) {
            stepButton(forward: false)
            stepButton(forward: true)
        }
        .padding(.horizontal, 2)
        .chromeGlassTrack()
    }

    private func stepButton(forward: Bool) -> some View {
        let label = forward ? "Next match" : "Previous match"
        return Button { find.step(forward: forward) } label: {
            Image(systemName: forward ? "chevron.right" : "chevron.left")
                .scaledFont(.system(size: 9, weight: .semibold))
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.hoverAffordance(.glyph, tint: accent))
        .disabled(find.matches.isEmpty)
        .accessibilityLabel(label)
        .help(forward ? "Next match (⌘G)" : "Previous match (⇧⌘G)")
    }
}

/// The reader's pages, with the find's matches drawn over them — its own view so a match landing
/// re-renders the page view and nothing else in the card.
struct EditorPDFReader: View {
    let document: PDFDocument?
    let state: EditorPDFViewState
    @ObservedObject var find: EditorPDFFind

    var body: some View {
        EditorPDFPageView(document: document, state: state, highlights: find.highlights)
    }
}

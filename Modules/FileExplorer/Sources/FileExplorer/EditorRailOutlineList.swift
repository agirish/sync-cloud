import SwiftUI
import Design

/// The rail's Outline tab: a scrolling list of an outline's rows, the current one marked, its
/// place remembered per file.
///
/// **One list for two kinds of outline** — a Markdown file's headings, and a PDF's bookmarks
/// (``EditorPDFRailOutline``), which arrive as rows of the same type. Lifted out of
/// ``EditorFileRailView`` for the PDF, so the scroll memory and the opening scroll are one piece of
/// code rather than two that could disagree about where a reader left off.
struct EditorRailOutlineList: View {

    let rows: [MarkdownOutlineEntry]
    /// Which row the reader is in — the caret's heading, or the bookmark at the current page.
    let currentIndex: Int?
    /// The open file, which the scroll memory is keyed by.
    let path: String?
    /// What stands in the list's place when there are no rows.
    let emptyCaption: String
    /// See ``EditorFileRailView/outlineAnchors``.
    @Binding var outlineAnchors: [String: Int]
    let accent: Color
    let onSelect: (MarkdownOutlineEntry) -> Void
    /// What each row is, for VoiceOver and an untitled row: headings or bookmarks.
    var noun: Noun = .heading
    /// Words drawn at a row's trailing edge, by row id — a bookmark's page number.
    var trailing: [Int: String] = [:]
    /// Rows that go nowhere — a bookmark with no page in this file. Drawn, and not clickable.
    var inert: Set<Int> = []

    enum Noun {
        case heading, bookmark
        var untitled: String { self == .heading ? "Untitled heading" : "Untitled bookmark" }
    }

    /// The outline's top row, as `.scrollPosition(id:)` reports and accepts it.
    @State private var topRow: Int?
    /// The section's height, as the scroll view reports it — the one input that decides how
    /// many rows are on screen, and so whether the current row would be past the fold.
    ///
    /// **`onGeometryChange` on the scroll view, not a `GeometryReader` around it.** A reader is a
    /// container with no intrinsic size of its own, and one wrapped around this rail collapsed it to
    /// 10pt for anything asking its ideal height — the trap `EditorLayoutTests` caught when the
    /// outline was first built. A modifier reads the same number and takes part in no layout.
    @State private var height: CGFloat = 0
    /// Read again for the row-height arithmetic — how many rows fit is a question about the app's
    /// text size as much as about the section's height.
    @Environment(\.appFontScale) private var fontScale

    var body: some View {
        if rows.isEmpty {
            Text(emptyCaption)
                .scaledFont(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.top, 4)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, entry in
                        row(entry, isCurrent: index == currentIndex)
                            .id(entry.id)
                    }
                }
                // The rows are the scroll targets, which is what lets the view below report which
                // of them are on screen.
                .scrollTargetLayout()
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
            }
            // **Both directions of one binding.** It accepts the row to open at, below, and it
            // reports the top row as the reader scrolls, which is what the recording reads.
            .scrollPosition(id: $topRow)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            // **`initial: true` on the rows, not on the path.** A Markdown outline is CLEARED the
            // instant the path changes and refilled 150ms later by a parse that runs off the main
            // actor, so a restore hung on the path change would scroll a list with no rows in it
            // and do nothing at all. This fires on the arrival, which is the first moment there is
            // anything to scroll to — and on the tab coming back, where the rows are already there.
            .onChange(of: rows, initial: true) { _, rows in
                guard !rows.isEmpty else { return }
                let fits = EditorOutlineScroll.rowsThatFit(height: height, scale: fontScale)
                if let target = EditorOutlineScroll.openingTarget(remembered: rememberedAnchor,
                                                                  current: currentRow,
                                                                  outline: rows,
                                                                  rowsThatFit: fits) {
                    topRow = target
                }
            }
            // **Recording is the binding reporting, not a second observation.** Every way the top
            // row can change ends up here — the reader scrolling, and the opening scroll above —
            // and both are worth remembering: the list is where it is either way.
            .onChange(of: topRow) { _, top in
                guard EditorOutlineScroll.recordsAnchor(path: path, outlineIsEmpty: rows.isEmpty,
                                                        top: top),
                      let path, let top else { return }
                outlineAnchors[path] = top
            }
        }
    }

    /// The row this file was left on, or `nil` for one nobody has scrolled yet.
    private var rememberedAnchor: Int? {
        path.flatMap { outlineAnchors[$0] }
    }

    /// The current row as a row id rather than an index into the array — which is what the scroll
    /// view speaks, and what makes "is it visible" a set membership test.
    private var currentRow: Int? {
        guard let currentIndex, rows.indices.contains(currentIndex) else { return nil }
        return rows[currentIndex].id
    }

    /// A list with nothing in it, built only to reach ``row(_:isCurrent:)`` from
    /// ``EditorFileRailView/outlineRowProbe(_:isCurrent:)``.
    static var probe: EditorRailOutlineList {
        EditorRailOutlineList(rows: [], currentIndex: nil, path: nil, emptyCaption: "",
                              outlineAnchors: .constant([:]), accent: .blue, onSelect: { _ in })
    }

    func row(_ entry: MarkdownOutlineEntry, isCurrent: Bool) -> some View {
        let title = entry.title.isEmpty ? noun.untitled : entry.title
        let goesNowhere = inert.contains(entry.id)
        return Button {
            onSelect(entry)
        } label: {
            HStack(spacing: 0) {
                Color.clear.frame(width: CGFloat(entry.depth) * EditorFileRailView.outlineIndentStep,
                                  height: 1)
                // **An empty heading keeps its row.** `##` on its own is legal and it is somewhere
                // in the document you can go; a row with nothing in it would be unclickable-looking,
                // so it says what it is instead of pretending it is not there.
                Text(title)
                    .scaledFont(.system(size: 11,
                                        weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(entry.title.isEmpty || goesNowhere ? AnyShapeStyle(.tertiary)
                                                                        : AnyShapeStyle(.primary))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if let words = trailing[entry.id] {
                    Text(words)
                        .scaledFont(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .contentShape(EditorFileRailView.rowOutline)
        }
        .buttonStyle(.hoverAffordance(isCurrent ? .filled : .row,
                                      tint: accent, shape: EditorFileRailView.rowShape))
        .disabled(goesNowhere)
        .help(goesNowhere ? "\(title) — not a page in this file" : title)
        .accessibilityLabel(noun == .heading ? "Heading level \(entry.level), \(entry.title)"
                                             : "Bookmark, \(title)")
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
    }
}

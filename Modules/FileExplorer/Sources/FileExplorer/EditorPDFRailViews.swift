import SwiftUI
import Design

/// The rail's Outline tab for an open PDF: its bookmarks, the one at the current page marked.
///
/// **Observes the reader's place, so the rail does not have to** — ``EditorPDFViewState`` moves on
/// every page turn, and only this list and ``EditorPDFRailPages`` redraw for it.
struct EditorPDFRailOutline: View {
    @ObservedObject var pdf: EditorPDFDocument
    @ObservedObject var view: EditorPDFViewState
    @Binding var outlineAnchors: [String: Int]
    let accent: Color

    var body: some View {
        let bookmarks = pdf.outline
        let rail = pdf.outlineRail
        EditorRailOutlineList(rows: rail.rows,
                              currentIndex: EditorPDFOutline.currentIndex(page: view.currentPage,
                                                                          in: bookmarks),
                              path: pdf.path,
                              emptyCaption: EditorPDFOutline.emptyCaption(phase: pdf.phase),
                              outlineAnchors: $outlineAnchors, accent: accent,
                              onSelect: { row in
                                  if let page = Self.page(for: row, in: bookmarks) { view.requestPage(page) }
                              },
                              noun: .bookmark,
                              trailing: rail.pageLabels,
                              inert: rail.inert)
            // One list per PDF — see `EditorRailOutlineList`'s `topRow`.
            .id(pdf.path)
    }

    /// The page a clicked row goes to, or `nil` for a row that goes nowhere.
    static func page(for row: MarkdownOutlineEntry, in bookmarks: [EditorPDFOutlineEntry]) -> Int? {
        bookmarks.indices.contains(row.id) ? bookmarks[row.id].pageIndex : nil
    }
}

/// The rail's Pages tab: the open PDF's pages as thumbnails, the current page ringed — in a grid of
/// two columns or more as the side column widens, or one under another (``EditorPDFPagesLayout``).
///
/// **What is on screen is what is asked for.** Each cell reports itself as it comes and goes, and
/// the set goes to ``EditorPDFThumbnails/show(_:)``, which renders those pages and a few either
/// side through the PDFKit lane and lets go of the rest. A cell with no image yet is a blank page
/// of the right shape, so a fast scroll shows paper, not a spinner per page.
///
/// **The current page follows the reader**: ringed as the page view scrolls, and brought into view
/// when it leaves the list's — unless the reader is the one scrolling the list.
struct EditorPDFRailPages: View {
    @ObservedObject var pdf: EditorPDFDocument
    @ObservedObject var view: EditorPDFViewState
    @ObservedObject var thumbnails: EditorPDFThumbnails
    let accent: Color
    var layout: EditorPDFPagesLayout = .grid
    var railWidth: CGFloat = EditorLayoutMetrics.railWidth

    @State private var visible: Set<Int> = []

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: EditorPDFPagesLayout.columnGap, alignment: .top),
              count: layout.columns(railWidth: railWidth))
    }

    var body: some View {
        if let facts = pdf.facts, pdf.phase == .open, facts.pageCount > 0 {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(0..<facts.pageCount, id: \.self) { index in
                            // The shape the image will have — crop box, turned — so a row does not
                            // change height when its thumbnail lands, which moved the grid under
                            // the reader and threw the opening scroll off the current page.
                            cell(index, size: facts.shownSizes.indices.contains(index)
                                    ? facts.shownSizes[index] : CGSize(width: 612, height: 792))
                                .id(index)
                                .onAppear { visible.insert(index); thumbnails.show(visible) }
                                .onDisappear { visible.remove(index); thumbnails.show(visible) }
                        }
                    }
                    .padding(.horizontal, EditorPDFPagesLayout.sidePadding)
                    .padding(.vertical, 6)
                }
                .onAppear { proxy.scrollTo(view.currentPage, anchor: .center) }
                // A switch of layout puts every cell somewhere new; the reader's page stays in view.
                .onChange(of: layout) { _, _ in proxy.scrollTo(view.currentPage, anchor: .center) }
                .onChange(of: view.currentPage) { _, page in
                    guard !visible.contains(page) else { return }
                    proxy.scrollTo(page, anchor: .center)
                }
                // A reload (the file changed on disk) under cells that never left the screen.
                .onChange(of: thumbnails.attachments) { _, _ in thumbnails.show(visible) }
            }
            // The tab put away: nothing on screen, so nothing is asked for. What was drawn stays,
            // within the cap, for the tab coming back.
            .onDisappear { thumbnails.show([]) }
            // **The size the cells draw at, asked for once a drag settles.** A drag crosses a size
            // step a few times, and each crossing redraws every page held; the pause lets a drag
            // ask once. The first ask, before anything is drawn, goes at once.
            .task(id: layout.renderEdge(railWidth: railWidth)) {
                let edge = layout.renderEdge(railWidth: railWidth)
                if !thumbnails.images.isEmpty {
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled else { return }
                }
                thumbnails.setRenderEdge(edge)
            }
        } else {
            Text(Self.caption(phase: pdf.phase))
                .scaledFont(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.top, 4)
        }
    }

    /// What the tab says when there are no pages to draw — for a refused file, the card's own
    /// reason, so the rail and the card say the same thing about it.
    static func caption(phase: EditorPDFDocument.Phase) -> String {
        switch phase {
        case .loading: return "Reading the PDF…"
        case .locked: return "Unlock the PDF to see its pages."
        case .refused(let reason): return reason
        case .open: return "This PDF has no pages."
        }
    }

    private func cell(_ index: Int, size: CGSize) -> some View {
        let isCurrent = index == view.currentPage
        return Button {
            view.requestPage(index)
        } label: {
            VStack(spacing: 4) {
                page(index, size: size)
                    .overlay {
                        RoundedRectangle(cornerRadius: 2)
                            .strokeBorder(isCurrent ? accent : Color.primary.opacity(0.15),
                                          lineWidth: isCurrent ? 3 : 0.5)
                            .padding(isCurrent ? -4 : 0)
                    }
                Text(String(index + 1))
                    .scaledFont(.system(size: 10, weight: isCurrent ? .semibold : .regular))
                    .monospacedDigit()
                    .foregroundStyle(isCurrent ? .primary : .secondary)
            }
            .padding(EditorPDFPagesLayout.cellInset)
            .contentShape(EditorFileRailView.rowOutline)
        }
        // The rail's own row wash, as every other row here wears — a bare `.plain` was the one
        // control in the rail that gave no sign it could be clicked.
        .buttonStyle(.hoverAffordance(.row, tint: accent, shape: EditorFileRailView.rowShape))
        .help("Go to page \(index + 1)")
        .accessibilityLabel("Page \(index + 1)")
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
    }

    /// The page's image, or a blank sheet of its shape until the image arrives. Pages stay white in
    /// both appearances, as the page view draws them.
    @ViewBuilder
    private func page(_ index: Int, size: CGSize) -> some View {
        if let image = thumbnails.images[index] {
            Image(decorative: image.cgImage, scale: 2)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Rectangle()
                .fill(Color.white)
                .aspectRatio(max(size.width, 1) / max(size.height, 1), contentMode: .fit)
        }
    }
}

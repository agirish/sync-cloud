import AppKit
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
///
/// **The tools' half (Phase 3)**: click selects and goes to the page, ⌘-click toggles, ⇧-click
/// extends; a selection's context menu rotates, deletes or extracts it into a copy; and dragging a
/// cell is a PENDING reorder — the cells move, each keeps its original number, and nothing is
/// written until Save Reordered Copy. All of that state is ``EditorPDFTools``', not this view's.
struct EditorPDFRailPages: View {
    @ObservedObject var pdf: EditorPDFDocument
    @ObservedObject var view: EditorPDFViewState
    @ObservedObject var thumbnails: EditorPDFThumbnails
    @ObservedObject var tools: EditorPDFTools
    let accent: Color
    /// Save Reordered Copy's fill — see ``EditorWorkspaceView/accentFill``.
    let accentFill: Color
    var layout: EditorPDFPagesLayout = .grid
    var railWidth: CGFloat = EditorLayoutMetrics.railWidth

    @State private var visible: Set<Int> = []
    /// The grid takes keys once a page is clicked: Esc clears the selection, ⌘A selects every page
    /// (through Edit ▸ Select All — ``EditorPDFPagesSelectAll``), Delete asks to leave the selection
    /// out of a copy. A focus of its own, so these keys never
    /// reach the grid while a field anywhere else is being typed in.
    @FocusState private var gridFocused: Bool

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: EditorPDFPagesLayout.columnGap, alignment: .top),
              count: layout.columns(railWidth: railWidth))
    }

    var body: some View {
        if let facts = pdf.facts, pdf.phase == .open, facts.pageCount > 0 {
            if tools.arrangement != nil, tools.offersPageTools { EditorPDFReorderBar(tools: tools, accentFill: accentFill) }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        // Shown in the pending order when there is one; ids are the ORIGINAL page,
                        // so a cell is the same cell wherever it is dragged to.
                        ForEach(tools.arrangement ?? Array(0..<facts.pageCount), id: \.self) { index in
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
                .focusable()
                .focusEffectDisabled()
                .focused($gridFocused)
                .onKeyPress(.escape) {
                    guard !tools.selection.pages.isEmpty else { return .ignored }
                    tools.clearSelection()
                    return .handled
                }
                // ⌘A is Edit ▸ Select All's, which reads this while the grid has focus. Not an
                // `.onKeyPress`: a menu key equivalent takes the key before a focused view sees it,
                // so the handler that was here never ran.
                .focusedValue(\.pdfPagesSelectAll, EditorPDFPagesSelectAll { tools.selectAll() })
                .onKeyPress(keys: [.delete, .deleteForward]) { _ in
                    tools.deleteSelectedPages() ? .handled : .ignored
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
        // Both pages of a spread, in a two-page layout.
        let isCurrent = view.visiblePages.contains(index)
        let isSelected = tools.selection.pages.contains(index)
        let button = Button { tap(index) } label: {
            cellLabel(index, size: size, isCurrent: isCurrent, isSelected: isSelected)
        }
        // The rail's own row wash, as every other row here wears — a bare `.plain` was the one
        // control in the rail that gave no sign it could be clicked.
        //
        // `.filled` while selected, as the Text Files rows are: the cell already carries its wash,
        // and a second one under the pointer doubled it.
        .buttonStyle(.hoverAffordance(isSelected ? .filled : .row, tint: accent, shape: EditorFileRailView.rowShape))
        return withPageActions(button, index: index, size: size, isSelected: isSelected)
    }

    private func tap(_ index: Int) {
        let click = EditorPDFPageSelection.click(for: NSEvent.modifierFlags)
        tools.click(index, click)
        gridFocused = true
        // Only a plain click goes to the page; ⌘ and ⇧ are about the selection.
        if click == .plain { view.requestPage(index) }
    }

    private func cellLabel(_ index: Int, size: CGSize, isCurrent: Bool, isSelected: Bool) -> some View {
        let ink: AnyShapeStyle = isSelected ? AnyShapeStyle(accent)
            : isCurrent ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)
        return VStack(spacing: 4) {
            page(index, size: size)
                .overlay {
                    // The current page's ring sits just inside the cell's rounded wash, at its
                    // corner radius less the gap — square corners 4 pt out poked past the wash.
                    RoundedRectangle(cornerRadius: isCurrent ? EditorPDFPagesLayout.currentRingRadius : 2)
                        .strokeBorder(isCurrent ? accent : Color.primary.opacity(0.15),
                                      lineWidth: isCurrent ? 3 : 0.5)
                        .padding(isCurrent ? -EditorPDFPagesLayout.currentRingOutset : 0)
                }
            // The ORIGINAL number, also while the pages are reordered — it is what the reader
            // dragged, and the new order is written only on Save.
            Text(String(index + 1))
                .scaledFont(.system(size: 10, weight: isCurrent || isSelected ? .semibold : .regular))
                .monospacedDigit()
                .foregroundStyle(ink)
        }
        .padding(EditorPDFPagesLayout.cellInset)
        .background {
            // The row's own outline, so the wash is the hover affordance's shape exactly.
            if isSelected { EditorFileRailView.rowOutline.fill(accent.opacity(0.18)) }
        }
        .contentShape(EditorFileRailView.rowOutline)
    }

    /// The cell's menu, its drag and drop, and what VoiceOver hears and can do.
    private func withPageActions(_ cell: some View, index: Int, size: CGSize, isSelected: Bool) -> some View {
        cell
            .contextMenu {
                EditorPDFPageMenu(tools: tools, pages: tools.selection.target(for: index, order: tools.order))
            }
            .draggable(EditorPDFPageDrag.payload(token: tools.dragToken, page: index)) {
                page(index, size: size).frame(width: 60)
            }
            .dropDestination(for: String.self) { items, _ in drop(items, onto: index) }
            .help("Go to page \(index + 1)")
            .accessibilityLabel("Page \(index + 1)")
            // Selected is the selection; the reader's place is said as a value, so the two read apart.
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityValue(view.visiblePages.contains(index) ? "Current page" : "")
            // The reorder a drag makes, for VoiceOver — the same pending order, saved the same way.
            .accessibilityAction(named: "Move Earlier") { tools.step(index, by: -1) }
            .accessibilityAction(named: "Move Later") { tools.step(index, by: 1) }
    }

    private func drop(_ items: [String], onto index: Int) -> Bool {
        guard tools.acceptsReorder,
              let dragged = items.compactMap({ EditorPDFPageDrag.page(in: $0, token: tools.dragToken) }).first
        else { return false }
        tools.move(tools.selection.target(for: dragged, order: tools.order), onto: index)
        return true
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

/// What a dragged page carries: the document's drag token and the page — never its path, which a
/// drop into another app's text field would paste — so a drop from another PDF, or text from
/// anywhere, is not taken for a reorder.
enum EditorPDFPageDrag {
    static let prefix = "synccloud-pdf-page:"

    static func payload(token: UUID, page: Int) -> String { "\(prefix)\(page):\(token.uuidString)" }

    static func page(in payload: String, token: UUID) -> Int? {
        guard payload.hasPrefix(prefix) else { return nil }
        let rest = payload.dropFirst(prefix.count)
        guard let colon = rest.firstIndex(of: ":"), String(rest[rest.index(after: colon)...]) == token.uuidString
        else { return nil }
        return Int(rest[..<colon])
    }
}

/// **A selection's menu in the Pages tab** — each item writes a copy. Its own view so a test can
/// host it: a row's `.contextMenu` body never runs offscreen.
struct EditorPDFPageMenu: View {
    @ObservedObject var tools: EditorPDFTools
    /// Zero-based, as shown.
    let pages: [Int]

    var body: some View {
        if let reason = tools.disabledReason {
            Text(reason)
        }
        Group {
            Button(Self.rotateTitle(pages, "Left")) { run(.rotate(pages: pages, quarterTurns: -1)) }
            Button(Self.rotateTitle(pages, "Right")) { run(.rotate(pages: pages, quarterTurns: 1)) }
            Button(Self.rotateTitle(pages, "180°")) { run(.rotate(pages: pages, quarterTurns: 2)) }
            Divider()
            Button(Self.title("Delete", pages)) {
                tools.sheet = .pages(.delete, prefill: EditorPDFPageMenu.rangeText(pages))
            }
            .disabled(!tools.mayDelete(pages))
            Button(Self.title("Extract", pages)) {
                tools.sheet = .pages(.extract, prefill: EditorPDFPageMenu.rangeText(pages))
            }
        }
        .disabled(!tools.offersPageTools || tools.running != nil)
    }

    private func run(_ tool: EditorPDFTool) {
        Task { await tools.run(tool) }
    }

    static func title(_ verb: String, _ pages: [Int]) -> String {
        pages.count == 1 ? "\(verb) Page \(pages[0] + 1)…" : "\(verb) \(pages.count) Pages…"
    }

    /// "Rotate 3 Pages Left" — the pages named as Delete and Extract name them, beside them.
    static func rotateTitle(_ pages: [Int], _ way: String) -> String {
        pages.count == 1 ? "Rotate Page \(pages[0] + 1) \(way)" : "Rotate \(pages.count) Pages \(way)"
    }

    /// "2-4, 7" for the field, one-based and in the order given — the copy name's runs, with a
    /// hyphen the parser reads.
    static func rangeText(_ pages: [Int]) -> String { EditorPDFCopyName.runs(pages, dash: "-") }
}

/// **The pending reorder's bar**, above the pages: nothing is written until Save.
struct EditorPDFReorderBar: View {
    @ObservedObject var tools: EditorPDFTools
    /// Save's fill: AppKit lays a white label on a prominent button's tint, so it takes the
    /// deepened accent.
    let accentFill: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("New page order — not saved")
                .scaledFont(.system(size: 11, weight: .semibold))
            HStack(spacing: 6) {
                Button("Reset") { tools.resetArrangement() }
                Button("Save Reordered Copy") { Task { await tools.saveArrangement() } }
                    .buttonStyle(.borderedProminent)
                    .tint(accentFill)
            }
            .controlSize(.small)
            .disabled(tools.running != nil)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

/// **⌘A in the Pages tab** — published while the grid has focus, for Edit ▸ Select All to call.
///
/// The menu item owns ⌘A app-wide, and AppKit offers a key equivalent to the menu before a focused
/// SwiftUI view's `.onKeyPress` sees it (measured 2026-10-17 in a standalone probe: the menu fired,
/// the handler did not). So the grid tells the item what ⌘A means there instead.
public struct EditorPDFPagesSelectAll {
    public let run: () -> Void

    public init(_ run: @escaping () -> Void) {
        self.run = run
    }
}

private struct EditorPDFPagesSelectAllKey: FocusedValueKey {
    typealias Value = EditorPDFPagesSelectAll
}

extension FocusedValues {
    public var pdfPagesSelectAll: EditorPDFPagesSelectAll? {
        get { self[EditorPDFPagesSelectAllKey.self] }
        set { self[EditorPDFPagesSelectAllKey.self] = newValue }
    }
}

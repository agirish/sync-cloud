import AppKit
import Design
import SwiftUI

/// One pane's tab strip: the 34pt row above its header.
///
/// **It belongs to the pane, not to the window.** Browse draws one, Compare draws one per side and
/// the Organize/Storage rail draws one at 220pt — all from the single `paneColumn` call site, so
/// there is no plumbing to keep in step. In Browse it looks like window chrome only because there
/// the pane *is* the window.
///
/// Drawn only when a pane holds a second tab (`PaneTabList.showsStrip`), which is Finder's rule and
/// what keeps an install that never opens one pixel-identical to the one before this shipped. The
/// caller owns that check, because at one tab the strip should occupy no space at all rather than
/// render empty.
///
/// This view is deliberately dumb: it takes rendered `Item`s and hands back ids. It never sees a
/// `PaneTab`, a provider or a `FileSyncManager`, which is what lets it be rendered — and read back
/// as pixels — from a test with no app around it.
public struct PaneTabStrip: View {

    /// One chip's worth of rendered facts.
    public struct Item: Identifiable, Equatable, Sendable {
        public let id: UUID
        /// The leaf folder's name, already resolved (a tab at a provider root wears the source's
        /// name — see `PaneTab.displayName`).
        public let title: String
        /// The provider's mark, as `ProviderLogo` takes it. **Load-bearing, not decoration:** two
        /// tabs can both read "Documents" from different clouds, and the mark is the only thing on
        /// the chip that tells them apart.
        public let markImageName: String
        public let isActive: Bool
        /// Pinned to the leading end: wears a pin instead of a ✕, and never folds away behind the
        /// overflow count.
        public let isPinned: Bool
        /// The full path, for the chip's tooltip — the strip's answer to "which Documents is this?"
        /// for anyone who wants more than the mark.
        public let fullPath: String

        public init(id: UUID, title: String, markImageName: String, isActive: Bool,
                    fullPath: String, isPinned: Bool = false) {
            self.id = id
            self.title = title
            self.markImageName = markImageName
            self.isActive = isActive
            self.fullPath = fullPath
            self.isPinned = isPinned
        }
    }

    let items: [Item]
    let onSelect: (UUID) -> Void
    let onClose: (UUID) -> Void
    let onCloseOthers: (UUID) -> Void
    let onDuplicate: (UUID) -> Void
    let onCopyPath: (UUID) -> Void
    /// Drag-to-reorder: this tab, dropped at that index.
    let onReorder: (UUID, Int) -> Void
    /// Pin or unpin this tab.
    let onSetPinned: (UUID, Bool) -> Void
    let onNew: () -> Void
    /// Track the strip must keep clear at its LEADING and TRAILING edges.
    ///
    /// **The seam controls sit on top of this row.** In Compare, ⇄ and 🔗 straddle the pane
    /// boundary at the top of the panes region — measured against the shipping app, the left pane's
    /// ＋ lands directly under ⇄ with about five points between them. The strip cannot see the
    /// layout it is in, so the pane column passes the reserve; it is zero everywhere else, which is
    /// Browse and the rail.
    let leadingInset: CGFloat
    let trailingInset: CGFloat

    @Environment(\.appFontScale) private var fontScale
    /// Which chip the pointer is over — the ✕ shows on that one and on the active tab, and nowhere
    /// else (v4.x roadmap companion §1's anatomy). Held here rather than per chip so only one can be lit.
    @State private var hoveredTab: UUID?
    /// The chip being dragged, and how far it has travelled. Held here so the dragged chip can be
    /// lifted above its neighbours while every other chip stays where it is.
    @State private var draggingTab: UUID?
    @State private var dragOffset: CGFloat = 0

    public init(items: [Item],
                leadingInset: CGFloat = 0,
                trailingInset: CGFloat = 0,
                onSelect: @escaping (UUID) -> Void,
                onClose: @escaping (UUID) -> Void,
                onCloseOthers: @escaping (UUID) -> Void,
                onDuplicate: @escaping (UUID) -> Void,
                onCopyPath: @escaping (UUID) -> Void,
                onReorder: @escaping (UUID, Int) -> Void = { _, _ in },
                onSetPinned: @escaping (UUID, Bool) -> Void = { _, _ in },
                onNew: @escaping () -> Void) {
        self.items = items
        self.leadingInset = leadingInset
        self.trailingInset = trailingInset
        self.onSelect = onSelect
        self.onClose = onClose
        self.onCloseOthers = onCloseOthers
        self.onDuplicate = onDuplicate
        self.onCopyPath = onCopyPath
        self.onReorder = onReorder
        self.onSetPinned = onSetPinned
        self.onNew = onNew
    }

    public var body: some View {
        // A strip with nothing in it is not a state the app can reach — `PaneTabList` is never
        // empty — but this view is public and every rung below indexes into `items`. Drawing
        // nothing beats trapping in a pane's body.
        if items.isEmpty {
            EmptyView()
        } else {
            stripBody
        }
    }

    private var stripBody: some View {
        GeometryReader { geo in
            // **The ladder is offered what is actually free**, which is the pane's width less the
            // strip's own gutters and the track the seam controls sit on — not `geo.size.width`.
            //
            // Measured: at the rail's 220pt the two 5pt gutters put the chip rung 10pt over
            // budget, and since that rung sizes its chip to consume everything left, the overrun
            // came out of the ONE element that has to survive there — the count of parked tabs was
            // squeezed to nothing. The wider rungs hid it, because their slack sits in a flexible
            // spacer that simply absorbed the error.
            let layout = PaneTabStripLadder.layout(
                available: geo.size.width - 2 * LiquidGlass.cardGutter - leadingInset - trailingInset,
                titles: items.map(\.title),
                scale: fontScale)
            strip(layout)
                .frame(width: geo.size.width, height: PaneTabStripLadder.stripHeight, alignment: .leading)
        }
        .frame(height: PaneTabStripLadder.stripHeight)
    }

    @ViewBuilder
    private func strip(_ layout: PaneTabStripLadder.Layout) -> some View {
        HStack(spacing: PaneTabStripLadder.tabGap) {
            switch layout.rung {
            case .full, .compact:
                let shown = visible(layout)
                ForEach(shown) { item in
                    chip(item, width: layout.tabWidth, visible: shown)
                }
            case .chip:
                // The active tab keeps its name and gains the chevron: at the rail's width a row of
                // chips would be marks with smears beside them, and the one thing that must survive
                // is *which folder this pane is showing*.
                activeChipMenu(width: layout.tabWidth)
            }
            if layout.showsOverflow {
                switch layout.rung {
                case .full, .compact:
                    // The ONLY way to reach a folded-away tab, so it is a menu.
                    overflowMenu(hidden: hiddenItems(layout))
                case .chip:
                    // A count, not a second menu. The active chip beside it already lists every
                    // tab — two controls that open the same list, 30pt apart, is one more than the
                    // rail has room to explain, and the roadmap's chip rung asks for "a count for
                    // the rest" rather than a second switcher.
                    overflowCount(layout.overflowCount)
                }
            }
            // The empty stretch, double-clickable — and it needs the `contentShape` to be hit at
            // all, since an `HStack`'s spacer paints nothing.
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { onNew() }
            newTabButton
        }
        .padding(.leading, LiquidGlass.cardGutter + leadingInset)
        .padding(.trailing, LiquidGlass.cardGutter + trailingInset)
    }

    private func visible(_ layout: PaneTabStripLadder.Layout) -> [Item] {
        Self.visible(items, slots: layout.visibleCount)
    }

    /// Where a dragged tab would land: the index it is dropped at, given how far it has travelled.
    ///
    /// **One rule, two consumers** — the live preview (which chips step aside) and the drop itself.
    /// They were separate arithmetic for one commit and could already disagree in two ways: a drag
    /// across the pin line, which `PaneTabList.move` refuses but the preview happily animated, and a
    /// drag past the last VISIBLE chip on the compact rung, which would have dropped the tab into
    /// the folded-away region — where it looks, from the strip, like it vanished.
    ///
    /// Returns `from` when the drop is a no-op, so a caller can treat "no move" and "moved to where
    /// it already was" identically.
    static func dropIndex(from: Int, steps: Int, items: [Item], visible: [Item]) -> Int {
        guard items.indices.contains(from) else { return from }
        var to = min(max(0, from + steps), items.count - 1)

        // Never across the pin line: pinned tabs are a prefix, and a drop that broke it would
        // either silently pin a tab or leave the list disagreeing with itself.
        let pinnedRun = items.prefix { $0.isPinned }.count
        to = items[from].isPinned ? min(to, max(0, pinnedRun - 1)) : max(to, pinnedRun)

        // Never past what is on screen: dragging a chip into the overflow is not a move anyone can
        // see, and the chip would appear to disappear.
        let shown = Set(visible.map(\.id))
        let drawn = items.indices.filter { shown.contains(items[$0].id) }
        if let first = drawn.first, let last = drawn.last, shown.contains(items[from].id) {
            to = min(max(to, first), last)
        }
        return min(max(0, to), items.count - 1)
    }

    /// How far a chip steps aside while another is dragged over it.
    ///
    /// One stride, in the direction that opens the gap — right for a chip the dragged tab has moved
    /// in front of, left for one it has moved behind. Zero for everything outside the range the
    /// drag currently spans, which is most of the strip.
    ///
    /// Static and priced from the same stride the drop index uses, so what the row shows during the
    /// drag and where the tab actually lands cannot disagree — that mismatch is the whole failure
    /// mode of a hand-drawn reorder.
    static func displacement(of item: Item, items: [Item], visible: [Item], dragging: UUID?,
                             offset: CGFloat, stride: CGFloat) -> CGFloat {
        guard let dragging, dragging != item.id, stride > 0,
              let from = items.firstIndex(where: { $0.id == dragging }),
              let index = items.firstIndex(where: { $0.id == item.id }) else { return 0 }
        let steps = Int((offset / stride).rounded())
        let to = dropIndex(from: from, steps: steps, items: items, visible: visible)
        if to > from, index > from, index <= to { return -stride }
        if to < from, index < from, index >= to { return stride }
        return 0
    }

    /// Which chips are drawn when there is not room for all of them.
    ///
    /// Two things always survive, and the order matters when they compete for the last slot:
    /// **the pinned tabs**, which are pinned precisely so they stay reachable, and **the active
    /// tab**, because a strip that folds away the pane's own tab describes somewhere else
    /// entirely. Pinned first — an active tab folded away is still named by the header underneath
    /// it, while a folded-away pin has nothing left to say it exists.
    ///
    /// Static so this can be tested; the window it picks is otherwise only visible in pixels.
    static func visible(_ items: [Item], slots: Int) -> [Item] {
        guard slots < items.count else { return items }
        guard slots > 0 else { return [] }
        let pinned = items.filter(\.isPinned)
        guard pinned.count < slots else { return Array(pinned.prefix(slots)) }

        let rest = items.filter { !$0.isPinned }
        let free = slots - pinned.count
        let activeIndex = rest.firstIndex(where: \.isActive) ?? 0
        let start = min(max(0, activeIndex - free + 1), max(0, rest.count - free))
        return pinned + Array(rest[start..<min(rest.count, start + free)])
    }

    private func hiddenItems(_ layout: PaneTabStripLadder.Layout) -> [Item] {
        Self.hidden(from: items, showing: visible(layout))
    }

    /// The folded-away tabs, **newest first** (roadmap Fig. 7).
    ///
    /// New tabs land at the trailing end, so list order puts the ones you just opened at the bottom
    /// of a menu you only opened because the strip ran out of room — the wrong end for the tab you
    /// are most likely reaching for. Static so the order can be tested: a menu's contents never
    /// reach the bitmap, so this is the only way to see it at all.
    static func hidden(from items: [Item], showing shown: [Item]) -> [Item] {
        let visible = Set(shown.map(\.id))
        return items.filter { !visible.contains($0.id) }.reversed()
    }

    // MARK: - The chip

    private func chip(_ item: Item, width: CGFloat, visible: [Item]) -> some View {
        Button {
            onSelect(item.id)
        } label: {
            HStack(spacing: PaneTabStripLadder.contentGap) {
                ProviderLogo(item.markImageName, size: PaneTabStripLadder.markSide)
                Text(item.title)
                    .scaledFont(PaneTabStripLadder.titleFont)
                    // Middle truncation, because the ends of a folder name are what tell two of them
                    // apart ("2023 Tax Return" / "2024 Tax Return" differ at the front; "Kaiser
                    // 2024" / "Kaiser 2025" at the back). A tail ellipsis loses one of those.
                    .truncationMode(.middle)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if item.isPinned {
                    // **A pin instead of a ✕.** Pinning is protection from a stray click as much as
                    // it is a position, so the pinned chip has no close button at all — Chrome and
                    // Safari both drop it — and the glyph is what says why. It sits in the ✕'s slot
                    // so the chip's width arithmetic is unchanged.
                    Image(systemName: "pin.fill")
                        .scaledFont(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: PaneTabStripLadder.closeSide,
                               height: PaneTabStripLadder.closeSide)
                        .help("Pinned — right-click to unpin")
                } else if items.count > 1 {
                    // **No ✕ on a lone tab.** The strip is normally hidden at one tab, but View ▸
                    // Tab Bar keeps it — and there the close button would be a ✕ that closes the
                    // WINDOW (there is no tab left to fall back to), which is a trap rather than a
                    // shortcut. Finder draws none there either. Close Tab in the context menu is
                    // disabled for the same reason and by the same count.
                    closeButton(item)
                }
            }
            .padding(.horizontal, PaneTabStripLadder.tabPadding)
            .frame(width: width, height: PaneTabStripLadder.tabHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.hoverAffordance(.segment))
        .background(alignment: .bottom) { activeGround(item) }
        // **Drag to reorder** (roadmap Fig. 8, left — the half that costs nothing; dropping FILES
        // on a tab is the other half and is deliberately not here).
        //
        // `simultaneousGesture` with a 6pt minimum, so a click still selects: the chip is a
        // `Button`, and a drag gesture that consumed the press would take tab-switching with it.
        // The drop index is arithmetic rather than a drop target — every chip on these two rungs is
        // exactly `width` wide, so the index is the translation over one chip's stride, which needs
        // no second view and cannot disagree with what is drawn.
        // The dragged chip rides the pointer; every chip it has passed steps aside by one stride,
        // so the GAP tracks the drop index rather than the row sitting still until you let go
        // (roadmap Fig. 8, left).
        .offset(x: draggingTab == item.id
                ? dragOffset
                : Self.displacement(of: item, items: items, visible: visible, dragging: draggingTab,
                                    offset: dragOffset, stride: width + PaneTabStripLadder.tabGap))
        .zIndex(draggingTab == item.id ? 1 : 0)
        .simultaneousGesture(
            DragGesture(minimumDistance: 6)
                .onChanged { value in
                    draggingTab = item.id
                    dragOffset = value.translation.width
                }
                .onEnded { value in
                    let stride = width + PaneTabStripLadder.tabGap
                    let steps = stride > 0 ? Int((value.translation.width / stride).rounded()) : 0
                    if steps != 0, let from = items.firstIndex(where: { $0.id == item.id }) {
                        // The same rule the preview animated — see `dropIndex`.
                        let to = Self.dropIndex(from: from, steps: steps, items: items, visible: visible)
                        if to != from { onReorder(item.id, to) }
                    }
                    draggingTab = nil
                    dragOffset = 0
                }
        )
        .animation(.easeOut(duration: 0.16), value: draggingTab)
        // The neighbours' step-aside, and the settle when the list re-orders under them.
        .animation(.easeOut(duration: 0.16), value: dragOffset)
        .onHover { hovering in
            // Only ever clear the id this chip set: the pointer can enter the next chip before this
            // one's exit arrives, and an unconditional `nil` on exit would then blank the ✕ that
            // just lit.
            if hovering { hoveredTab = item.id } else if hoveredTab == item.id { hoveredTab = nil }
        }
        .help(item.fullPath)
        .contextMenu { menu(for: item) }
    }

    /// The active tab: a raised surface with a 2pt accent rule under it.
    ///
    /// **Not an accent FILL.** The workspace bar 40pt above already owns that treatment, and two
    /// accent-filled rows stacked read as one smear with a gap in it — the same reason
    /// `ProviderLogo` refuses the accent for a folder's mark.
    @ViewBuilder
    private func activeGround(_ item: Item) -> some View {
        if item.isActive {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.quaternary.opacity(0.85))
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(Color.accentColor)
                    .frame(height: 2)
                    .padding(.horizontal, 3)
            }
        }
    }

    private func closeButton(_ item: Item) -> some View {
        Button {
            // ⌥ turns the ✕ into "close the others", which is also in the chip's context menu. Read
            // at fire time from `NSEvent`: a modifier held while a button is clicked never reaches
            // SwiftUI's action, and the alternative — a `.keyboardShortcut` per chip — would
            // register one key equivalent per tab.
            if NSEvent.modifierFlags.contains(.option) {
                onCloseOthers(item.id)
            } else {
                onClose(item.id)
            }
        } label: {
            Image(systemName: "xmark")
                .scaledFont(.system(size: 9, weight: .semibold))
                .frame(width: PaneTabStripLadder.closeSide, height: PaneTabStripLadder.closeSide)
                .contentShape(Rectangle())
        }
        .buttonStyle(.hoverAffordance(.glyph))
        // **On the active tab, and on the one under the pointer.** A row of chips each wearing a
        // permanent ✕ reads as a row of things to dismiss rather than places to go — and the strip
        // is mostly parked tabs. `opacity` rather than absence, so the title does not re-flow (and
        // does not resize) as the pointer crosses the strip.
        .opacity(item.isActive || hoveredTab == item.id ? 1 : 0)
        .help("Close this tab (⌥ to close the others)")
    }

    // MARK: - The narrow rungs

    private func activeChipMenu(width: CGFloat) -> some View {
        let active = items.first(where: \.isActive) ?? items[0]
        return Menu {
            ForEach(items) { item in
                Button { onSelect(item.id) } label: {
                    if item.isActive {
                        Label(item.title, systemImage: "checkmark")
                    } else {
                        Text(item.title)
                    }
                }
            }
        } label: {
            HStack(spacing: PaneTabStripLadder.contentGap) {
                ProviderLogo(active.markImageName, size: PaneTabStripLadder.markSide)
                Text(active.title)
                    .scaledFont(PaneTabStripLadder.titleFont)
                    .truncationMode(.middle)
                    .lineLimit(1)
            }
            .padding(.horizontal, PaneTabStripLadder.tabPadding)
        }
        .menuStyle(.borderlessButton)
        // **The system's indicator, and it has to be.** A `chevron.down` drawn in the label here
        // renders as nothing: the borderless menu style lays its label out itself and dropped the
        // trailing image — seen in a render, with the chip ending flush after its title and no
        // affordance at all on the one rung whose whole job is to say "there are others". Rather
        // than fight the chrome from outside (the house rule, and it loses here), the indicator is
        // the system's. `theChipRungWearsAChevron` renders it back.
        .menuIndicator(.visible)
        // **A cap, not a fill.** Sized to exactly the track left over, this row has zero slack, and
        // the one compressible child — the count of parked tabs — is what gave way: it rendered
        // clipped, then vanished. The chip takes what its name needs up to the cap and the spacer
        // absorbs the rest, so the count always has its own room.
        .frame(maxWidth: max(0, width))
        .frame(height: PaneTabStripLadder.tabHeight)
        .fixedSize(horizontal: true, vertical: false)
        .background(alignment: .bottom) { activeGround(active) }
        .help(active.fullPath)
        .contextMenu { menu(for: active) }
    }

    /// The chip rung's count of parked tabs — inert on purpose; the switcher is the chip's chevron.
    private func overflowCount(_ count: Int) -> some View {
        Text("\(count)")
            .scaledFont(PaneTabStripLadder.controlFont)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .frame(height: PaneTabStripLadder.tabHeight)
            .help("\(count) more \(count == 1 ? "tab" : "tabs") — the name above opens them")
    }

    private func overflowMenu(hidden: [Item]) -> some View {
        Menu {
            ForEach(hidden) { item in
                Button(item.title) { onSelect(item.id) }
            }
        } label: {
            HStack(spacing: 3) {
                Text("\(hidden.count)")
                    .scaledFont(PaneTabStripLadder.controlFont)
                Image(systemName: "chevron.down")
                    .scaledFont(PaneTabStripLadder.controlFont)
            }
            .padding(.horizontal, 6)
            .frame(height: PaneTabStripLadder.tabHeight)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("\(hidden.count) more \(hidden.count == 1 ? "tab" : "tabs")")
    }

    private var newTabButton: some View {
        Button(action: onNew) {
            Image(systemName: "plus")
                .scaledFont(PaneTabStripLadder.controlFont)
                .frame(width: PaneTabStripLadder.plusSide, height: PaneTabStripLadder.plusSide)
                .contentShape(Rectangle())
        }
        .buttonStyle(.hoverAffordance(.glyph))
        // "here", because ⌘T opens the CURRENT folder and the result is two tabs with the same
        // name — so the control has to say what it did before it does it.
        .help("New tab here (⌘T)")
    }

    @ViewBuilder
    private func menu(for item: Item) -> some View {
        Button("New Tab") { onNew() }
        Divider()
        Button("Close Tab") { onClose(item.id) }
            .disabled(items.count < 2)
        Button("Close Other Tabs") { onCloseOthers(item.id) }
            .disabled(items.count < 2)
        Divider()
        Button(item.isPinned ? "Unpin Tab" : "Pin Tab") { onSetPinned(item.id, !item.isPinned) }
        Button("Duplicate") { onDuplicate(item.id) }
        Button("Copy Path") { onCopyPath(item.id) }
    }
}

import AppKit
import Design
import SwiftUI

/// One pane's tab strip: the 34pt row above its header.
///
/// It belongs to the pane, not the window: Browse draws one, Compare one per side, and the
/// Organize/Storage rail one at 220pt, all from the single `paneColumn` call site. Drawn only when a
/// pane holds a second tab (`PaneTabList.showsStrip`), Finder's rule; the caller checks, so at one
/// tab the strip takes no space at all.
///
/// Deliberately dumb: it takes rendered `Item`s and hands back ids, never seeing a `PaneTab`, a
/// provider or a `FileSyncManager`, so a test can render it and read its pixels with no app around.
public struct PaneTabStrip: View {

    /// One chip's worth of rendered facts.
    public struct Item: Identifiable, Equatable, Sendable {
        public let id: UUID
        /// The leaf folder's name, already resolved (a tab at a provider root wears the source's
        /// name — see `PaneTab.displayName`).
        public let title: String
        /// The provider's mark, as `ProviderLogo` takes it. Not decoration: two tabs can both read
        /// "Documents" from different clouds, and the mark is what tells them apart.
        public let markImageName: String
        public let isActive: Bool
        /// Pinned to the leading end: wears a pin instead of a ✕, and never folds away behind the
        /// overflow count.
        public let isPinned: Bool
        /// The full path, for the chip's tooltip: which Documents this is.
        public let fullPath: String
        /// The source's display name ("iCloud Drive"), or nil when the source is gone. The mark's
        /// words: `ProviderLogo` is hidden from VoiceOver, so without this two "Documents" chips
        /// from different clouds sound the same. See `spokenName(_:)`.
        public let sourceName: String?

        public init(id: UUID, title: String, markImageName: String, isActive: Bool,
                    fullPath: String, isPinned: Bool = false, sourceName: String? = nil) {
            self.id = id
            self.title = title
            self.markImageName = markImageName
            self.isActive = isActive
            self.fullPath = fullPath
            self.isPinned = isPinned
            self.sourceName = sourceName
        }
    }

    /// What VoiceOver reads for a chip: its title, then the source the mark stands for, as
    /// "Documents, iCloud Drive".
    ///
    /// `ProviderLogo` hides itself from VoiceOver, right for every other mark and wrong here, where
    /// the mark tells same-named tabs apart (`Item.markImageName`). The source is left off when the
    /// title already carries it: a tab at a source root, or a title qualified "Documents — iCloud
    /// Drive".
    static func spokenName(_ item: Item) -> String {
        guard let source = item.sourceName, !source.isEmpty,
              item.title != source, !item.title.hasSuffix("— \(source)")
        else { return item.title }
        return "\(item.title), \(source)"
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
    /// Track the strip must keep clear at its leading and trailing edges.
    ///
    /// In Compare the seam controls (⇄, 🔗) straddle the pane boundary on top of this row, just
    /// above the left pane's ＋. The strip can't see its layout, so the pane column passes the
    /// reserve; it is zero in Browse and the rail.
    let leadingInset: CGFloat
    let trailingInset: CGFloat
    /// The window's `LiquidGlassHue.accentColor`, the colour the pane's rows wash their selection
    /// in. Never `Color.accentColor`, the system accent, which ignores the app's hue. Passed in, not
    /// read from `@AppStorage`, so a test can render this view with no app around it.
    let accent: Color
    /// Whether this pane is the one the action bar acts on. Feeds `PaneSelectionWash`, as the
    /// pane's rows do (see `chipGround`).
    let isActivePane: Bool

    @Environment(\.appFontScale) private var fontScale

    /// Shared geometry for the active tab's ground and rule, so the marker travels along the strip
    /// instead of being cut out under one chip and into the next.
    @Namespace private var activeMarker

    /// One marker, one id. The workspace bar above does the same (`ContentView.workspaceMarkerID`),
    /// so the two bars move alike.
    private static let activeMarkerID = "panetab.active.marker"

    /// The chip's outline, named once: the grey slab under every tab, the accent wash under the
    /// live one, and the hover wash handed to `HoverAffordanceStyle` all read it, so they can't
    /// disagree. `DestinationRowShape` is the same idiom (see `HoverAffordanceOutline`).
    ///
    /// The radius lives on the ladder beside the gutter it must agree with
    /// (`PaneTabStripLadder.chipRadius`): `Radius.well`, not `Radius.chip`, because the chip sits
    /// concentric inside the strip card, and `14 - 4` is 10.
    static let chipShape = HoverAffordanceShape.roundedRect(PaneTabStripLadder.chipRadius)
    /// `chipShape`, drawable: the slab under every tab and the accent wash under the live one.
    static let chipOutline = chipShape.outline

    /// Which chip the pointer is over: the ✕ shows on that one and on the active tab only. Held
    /// here, not per chip, so only one can be lit.
    @State private var hoveredTab: UUID?
    /// The chip being dragged, and how far it has travelled. Held here so the dragged chip can be
    /// lifted above its neighbours while every other chip stays where it is.
    @State private var draggingTab: UUID?
    @State private var dragOffset: CGFloat = 0
    /// True while a drag gesture is live. SwiftUI resets it however the drag ends, including a
    /// cancel (the window losing key, a modal), which never calls `onEnded` and would leave the
    /// chip parked at its last offset.
    @GestureState private var dragIsLive = false

    public init(items: [Item],
                leadingInset: CGFloat = 0,
                trailingInset: CGFloat = 0,
                accent: Color = LiquidGlassHue.stored().accentColor,
                isActivePane: Bool = true,
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
        self.accent = accent
        self.isActivePane = isActivePane
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
        // Unreachable in the app (`PaneTabList` is never empty), but this view is public and every
        // rung indexes into `items`: drawing nothing beats trapping in a pane's body.
        if items.isEmpty {
            EmptyView()
        } else {
            stripBody
        }
    }

    /// Which tab the marker is under: the only change that should move it.
    private var activeTabID: PaneTabStrip.Item.ID? { items.first(where: \.isActive)?.id }

    private var stripBody: some View {
        GeometryReader { geo in
            // The ladder is offered what is actually free: the width less the strip's gutters and
            // the seam controls' track, not `geo.size.width`. At the rail's 220pt any overrun
            // comes out of the chip rung's count of parked tabs, the one element that must survive.
            let layout = PaneTabStripLadder.layout(
                available: geo.size.width - 2 * PaneTabStripLadder.stripGutter - leadingInset - trailingInset,
                titles: items.map(\.title),
                scale: fontScale)
            strip(layout)
                .frame(width: geo.size.width, height: PaneTabStripLadder.stripHeight, alignment: .leading)
                // Keyed on which tab is active, not on `items`, so opening, closing or renaming a
                // tab doesn't slide the marker. Reduce Motion keeps the marker and drops the travel.
                .designAnimation(.easeOut(duration: 0.16), value: activeTabID)
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
                // The active tab keeps its name and gains the chevron: at the rail's width, what
                // must survive is which folder this pane shows.
                activeChipMenu(width: layout.tabWidth)
            }
            if layout.showsOverflow {
                switch layout.rung {
                case .full, .compact:
                    // The only way to reach a folded-away tab, so it is a menu.
                    overflowMenu(hidden: hiddenItems(layout))
                case .chip:
                    // A count, not a second menu: the active chip beside it already lists every tab.
                    overflowCount(layout.overflowCount)
                }
            }
            // The empty stretch, double-clickable. It needs the `contentShape` to be hit at all,
            // since it paints nothing.
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { onNew() }
            newTabButton
        }
        // Frosted and Clear: the active tab's marker as one glass lens that glides between chips.
        // Solid keeps `activeMarkerLayer`'s 0.16 s slide.
        .selectionLensHost(Self.lensChannel, selected: activeTabID, style: lensStyle)
        // The chips' drag animations, restated outside the host so the lens rides them; otherwise
        // the lens, drawn in the host's background, jumps to where a dragged active tab lands while
        // the chip glides there. Only where a lens draws: out here they would also fade a compact
        // rung that a drop re-windows, which at Solid stays instant.
        //
        // Not while the lens's chip is held, or it trails the pointer. The chip's own modifier,
        // closer, decides the chip; this decides only the lens: unanimated on the held chip, eased
        // while another chip is dragged past it. The drop clears `draggingTab`, so the settle eases.
        .designAnimation(drawsLens ? Self.dragEase(holding: draggingTab != nil && draggingTab == activeTabID) : nil,
                         value: draggingTab)
        .designAnimation(drawsLens ? Self.dragEase(holding: draggingTab != nil && draggingTab == activeTabID) : nil,
                         value: dragOffset)
        .padding(.leading, PaneTabStripLadder.stripGutter + leadingInset)
        .padding(.trailing, PaneTabStripLadder.stripGutter + trailingInset)
    }

    private func visible(_ layout: PaneTabStripLadder.Layout) -> [Item] {
        Self.visible(items, slots: layout.visibleCount)
    }

    /// How many tabs "Close Other Tabs" would close, keeping `item` and every pinned tab.
    ///
    /// Not the tab count: pins survive, so a strip of three whose other two are pinned has nothing
    /// to close. The menu item and the ⌥-✕ tooltip both ask this.
    static func closableOthers(of item: Item, in items: [Item]) -> Int {
        items.filter { $0.id != item.id && !$0.isPinned }.count
    }

    /// Where a dragged tab would land: the index it is dropped at, given how far it has travelled.
    ///
    /// One rule for the live preview (which chips step aside) and the drop, so they can't disagree
    /// about a drag across the pin line (`PaneTabList.move` refuses it) or past the last visible
    /// chip. Returns `from` when the drop is a no-op, so "no move" and "moved to where it already
    /// was" read alike.
    static func dropIndex(from: Int, steps: Int, items: [Item], visible: [Item]) -> Int {
        guard items.indices.contains(from) else { return from }
        var to = min(max(0, from + steps), items.count - 1)

        // Never across the pin line: pinned tabs are a prefix, and a drop that broke it would
        // either silently pin a tab or leave the list disagreeing with itself.
        let pinnedRun = items.prefix { $0.isPinned }.count
        to = items[from].isPinned ? min(to, max(0, pinnedRun - 1)) : max(to, pinnedRun)

        // Never past what is on screen: a chip dragged into the overflow would seem to vanish.
        //
        // The drawn indices need not be contiguous: `visible(_:slots:)` draws the pinned prefix
        // plus a window of the unpinned run, with a folded-away gap between once the window has
        // scrolled. One pin and four unpinned tabs in three slots draw `[P, T3, T4]`, and a range
        // clamp alone would let T3 land at 1 or 2, both hidden. So the clamp is followed by a snap
        // onto a drawn index, always back toward `from`: that only shortens the move, and can't
        // re-cross the pin line.
        //
        // This promises only that the drop index is a drawn chip's, not that the moved chip is
        // still drawn afterwards: `visible(_:slots:)` re-derives its window from the active tab,
        // so a legal drop can leave the tab in the overflow menu, as a newly opened tab would be.
        // `aDropCannotLandInTheGapBetweenThePinsAndTheWindow` and
        // `aLegalDropStillLandsWhereItWasAimed` pin the two halves.
        let shown = Set(visible.map(\.id))
        let drawn = items.indices.filter { shown.contains(items[$0].id) }
        if let first = drawn.first, let last = drawn.last, shown.contains(items[from].id) {
            to = min(max(to, first), last)
            if !drawn.contains(to) {
                // The `?? from` can't fire (`from` is drawn, on the far side of `to`, so each search
                // has a candidate); it keeps the expression total.
                to = (to > from ? drawn.last { $0 <= to } : drawn.first { $0 >= to }) ?? from
            }
        }
        return min(max(0, to), items.count - 1)
    }

    /// The drag's ease, for a view that is or is not holding the dragged chip. Nil while held, so
    /// the held chip rides the pointer instead of trailing it. Everything else (the neighbours
    /// stepping aside, every chip's settle once the drop clears `draggingTab`) eases. One rule for
    /// the chips' modifiers and the lens host's restatement of them.
    static func dragEase(holding: Bool) -> Animation? {
        holding ? nil : .easeOut(duration: 0.16)
    }

    /// How far a chip steps aside while another is dragged over it: one stride toward the gap for a
    /// chip inside the range the drag spans, zero for the rest. Priced from the stride `dropIndex`
    /// uses, so what the row shows and where the tab lands can't disagree.
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
    /// The pinned tabs and the active tab always survive, pins first when they compete for the last
    /// slot: a folded-away active tab is still named by the header below, while a folded-away pin
    /// has nothing to say it exists. Static so the window can be tested without pixels.
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

    /// The folded-away tabs, newest first. New tabs land at the trailing end, so list order would
    /// put the tab you just opened at the bottom of the menu. Static so the order can be tested: a
    /// menu's contents never reach the bitmap.
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
                    // The hidden mark's words — see `spokenName`.
                    .accessibilityLabel(Self.spokenName(item))
                    // Middle truncation: either end of a folder name can be what tells two apart
                    // ("2023 Tax Return", "Kaiser 2025").
                    .truncationMode(.middle)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if item.isPinned {
                    // A pin instead of a ✕: pinning guards against a stray click, so a pinned chip
                    // has no close button (as in Chrome and Safari) and the glyph says why. It
                    // takes the ✕'s slot, so the chip's width is unchanged.
                    Image(systemName: "pin.fill")
                        .scaledFont(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: PaneTabStripLadder.closeSide,
                               height: PaneTabStripLadder.closeSide)
                        .help("Pinned — right-click to unpin")
                } else if items.count > 1 {
                    // No ✕ on a lone tab: View ▸ Tab Bar can keep the strip at one tab, where a ✕
                    // would close the window. Finder draws none either, and Close Tab in the
                    // context menu is disabled by the same count.
                    closeButton(item)
                }
            }
            .padding(.horizontal, PaneTabStripLadder.tabPadding)
            .frame(width: width, height: PaneTabStripLadder.tabHeight)
            .contentShape(Rectangle())
        }
        // The hue, and the chip's own outline: `.segment`'s default is a capsule, which would round
        // the hover wash past the chip's rounded-rect slab. The slab and the active wash are drawn
        // from the same `chipShape`, so the three agree.
        .buttonStyle(.hoverAffordance(.segment, tint: accent, shape: Self.chipShape))
        .background(alignment: .bottom) { chipGround(item) }
        .selectionLensStop(Self.lensChannel, id: item.id)
        // Drag to reorder (dropping files on a tab is deliberately not supported).
        // `simultaneousGesture` with a 6pt minimum, so a click still selects: a drag that consumed
        // the press would take tab-switching with it. The drop index is arithmetic, not a drop
        // target: every chip on these rungs is `width` wide, so it is the translation over one
        // stride. The dragged chip rides the pointer and each chip it passes steps aside by one
        // stride, so the gap tracks the drop index.
        .offset(x: draggingTab == item.id
                ? dragOffset
                : Self.displacement(of: item, items: items, visible: visible, dragging: draggingTab,
                                    offset: dragOffset, stride: width + PaneTabStripLadder.tabGap))
        .zIndex(draggingTab == item.id ? 1 : 0)
        .simultaneousGesture(
            DragGesture(minimumDistance: 6)
                .updating($dragIsLive) { _, live, _ in live = true }
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
        // The held chip is not eased, so it rides the pointer. The drop clears `draggingTab` in the
        // same change that zeroes the offset, so its settle into the new slot still animates.
        .designAnimation(Self.dragEase(holding: draggingTab == item.id), value: draggingTab)
        // The neighbours' step-aside, and the settle when the list re-orders under them. Both honour
        // Reduce Motion: the drag is the user's movement, but chips sliding aside is the app's.
        .designAnimation(Self.dragEase(holding: draggingTab == item.id), value: dragOffset)
        // A cancelled drag: the gesture state reset without `onEnded`. Put the chip back.
        .onChange(of: dragIsLive) { _, live in
            if !live, draggingTab == item.id {
                draggingTab = nil
                dragOffset = 0
            }
        }
        .onHover { hovering in
            // Only clear the id this chip set: the pointer can enter the next chip before this one's
            // exit arrives, and a `nil` then would blank the ✕ that just lit.
            if hovering { hoveredTab = item.id } else if hoveredTab == item.id { hoveredTab = nil }
        }
        .help(item.fullPath)
        .contextMenu { menu(for: item) }
    }

    /// Every chip's ground: the grey slab all of them wear, the accent wash the live one takes on
    /// top, and the 2pt accent rule under that.
    ///
    /// Every chip wears the slab so the tabs read as places to go, as list rows are always there
    /// and the wash says which one you are on. The live wash is `PaneSelectionWash`, the rows' own
    /// numbers, so a tab and a row say "selected" in one colour. A wash, not a solid fill, because
    /// `ProviderLogo`'s multi-coloured mark and the `.primary` title can't be re-inked for contrast.
    ///
    /// The rule is not redundant with the pane's accent border (`ActivePaneMark`): the border says
    /// which pane is focused, the rule which tab is live. And in the unfocused pane the wash dims to
    /// a shade while the rule doesn't, so the strip still answers "which tab" there.
    @ViewBuilder
    private func chipGround(_ item: Item) -> some View {
        ZStack(alignment: .bottom) {
            // The active chip's slab is part of what the lens replaces: drawn over the lens, it would
            // lay an 85% film across the active tab's glass and rule. One slab in every state, so
            // Solid's is the same view whichever tab is active.
            SelectionLensGround(Self.chipOutline, isSelected: item.isActive,
                                selected: .quaternary.opacity(0.85), unselected: .quaternary.opacity(0.85))
            if item.isActive { SelectionLensTodayMarker { activeMarkerLayer } }
        }
    }

    /// The strip's selection lens in Frosted and Clear (see `SelectionLens`). The host is the
    /// strip's own row, so Compare's two strips never see each other's stops.
    static let lensChannel = SelectionLensChannel("pane.tabs")

    @Environment(\.selectionLensAppearance) private var lensAppearance
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// Whether the strip's lens draws, read here above the host for the animations that must
    /// enclose it.
    private var drawsLens: Bool {
        SelectionLensRule.material(for: lensAppearance, reduceTransparency: reduceTransparency) != .today
    }

    /// The lens wears what `activeMarkerLayer` draws: the chip's outline, the same wash (dimmed in
    /// the unfocused pane, as the marker is) and the 2pt rule on top.
    private var lensStyle: SelectionLensStyle {
        SelectionLensStyle(shape: Self.chipShape, color: accent,
                           markerOpacity: PaneSelectionWash.opacity(isActivePane: isActivePane),
                           rule: .init(color: accent, height: 2, inset: PaneTabStripLadder.ruleInset))
    }

    /// The live chip's half of `chipGround`: everything that travels when the active tab changes.
    ///
    /// Wash and rule move as one marker, since they mark one fact; the grey slab is on every chip,
    /// so it stays out. The two call sites can share one id because their rungs are exclusive
    /// (`.full` and `.compact` draw chips, `.chip` the menu), so only one source is ever in the
    /// hierarchy.
    private var activeMarkerLayer: some View {
        ZStack(alignment: .bottom) {
            Self.chipOutline
                .fill(accent.opacity(PaneSelectionWash.opacity(isActivePane: isActivePane)))
            // `Capsule`, not `RoundedRectangle(cornerRadius: 1)`: at 2pt tall the two draw the same
            // pixels, but only one of them stays a capsule if the height is ever tuned.
            Capsule(style: .continuous)
                .fill(accent)
                .frame(height: 2)
                .padding(.horizontal, PaneTabStripLadder.ruleInset)
        }
        .matchedGeometryEffect(id: Self.activeMarkerID, in: activeMarker)
    }

    private func closeButton(_ item: Item) -> some View {
        Button {
            // ⌥ turns the ✕ into "close the others", also in the context menu. Read from `NSEvent`
            // at fire time: a modifier held during a click never reaches SwiftUI's action, and a
            // `.keyboardShortcut` per chip would register a key equivalent per tab.
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
        // On the active tab and the one under the pointer only: a permanent ✕ on every chip reads
        // as things to dismiss. `opacity`, not absence, so the title doesn't re-flow as the pointer
        // crosses the strip.
        .opacity(item.isActive || hoveredTab == item.id ? 1 : 0)
        // The ⌥ half drops out of the tooltip when every other tab is pinned, rather than
        // promising a modifier that does nothing.
        .help(Self.closableOthers(of: item, in: items) > 0
              ? "Close this tab (⌥ to close the others)"
              : "Close this tab")
        // `.opacity(0)` hides a control from the eye only, so without this every parked tab carries
        // an invisible close button for VoiceOver. Announced exactly when drawn, and named, since
        // `.help` is the accessibility help on macOS, not the name.
        .accessibilityLabel("Close \(item.title)")
        .accessibilityHidden(!(item.isActive || hoveredTab == item.id))
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
                // `inAppKitLabel`: AppKit draws this label and ignores the frame around a resizable
                // image, so a catalog mark would come out at its native 512pt across the pane.
                ProviderLogo(active.markImageName, size: PaneTabStripLadder.markSide, inAppKitLabel: true)
                Text(active.title)
                    .scaledFont(PaneTabStripLadder.titleFont)
                    .accessibilityLabel(Self.spokenName(active))
                    .truncationMode(.middle)
                    .lineLimit(1)
            }
            .padding(.horizontal, PaneTabStripLadder.tabPadding)
        }
        .menuStyle(.borderlessButton)
        // The system's indicator: a `chevron.down` drawn in this label renders as nothing, because
        // the borderless menu style lays the label out itself and drops trailing images.
        // `theChipRungWearsAChevron` renders it back.
        .menuIndicator(.visible)
        // A cap, not a fill: sized to exactly the track left over, the row has no slack and the
        // count of parked tabs gives way. The chip takes what its name needs up to the cap and the
        // spacer absorbs the rest, so the count keeps its room.
        .frame(maxWidth: max(0, width))
        .frame(height: PaneTabStripLadder.tabHeight)
        .fixedSize(horizontal: true, vertical: false)
        .background(alignment: .bottom) { chipGround(active) }
        .selectionLensStop(Self.lensChannel, id: active.id)
        .help(active.fullPath)
        .contextMenu { menu(for: active) }
    }

    /// The chip rung's count of parked tabs: inert on purpose, since the switcher is the chip's chevron.
    private func overflowCount(_ count: Int) -> some View {
        Text("\(count)")
            .scaledFont(PaneTabStripLadder.controlFont)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .frame(height: PaneTabStripLadder.tabHeight)
            .help("\(count) more \(count == 1 ? "tab" : "tabs") — click the name beside this to see them")
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
        // Frosted and Clear: a glass capsule like every bar button (`ChromeGlass`), outside the
        // menu, because AppKit paints nothing inside a borderless menu's label. AppKit sizes the
        // menu itself (16pt tall, ignoring the label's frame), so the capsule grows 3pt to the ＋'s
        // 22pt. Up and down only: grown sideways, it would all but touch the last chip.
        .chromeGlassGround(.capsule, horizontalOutset: 0, verticalOutset: 3)
        .help("\(hidden.count) more \(hidden.count == 1 ? "tab" : "tabs")")
    }

    private var newTabButton: some View {
        Button(action: onNew) {
            Image(systemName: "plus")
                .scaledFont(PaneTabStripLadder.controlFont)
                .frame(width: PaneTabStripLadder.plusSide, height: PaneTabStripLadder.plusSide)
                .contentShape(Rectangle())
        }
        // Frosted and Clear: a glass circle with a round hover, like every bar button (`ChromeGlass`).
        .chromeGlassGlyphButton()
        .accessibilityLabel("New tab")
        // "here", because ⌘T opens the current folder, giving two tabs with the same name, so the
        // control says so first.
        .help("New tab here (⌘T)")
    }

    @ViewBuilder
    private func menu(for item: Item) -> some View {
        Button("New Tab") { onNew() }
        Divider()
        Button("Close Tab") { onClose(item.id) }
            .disabled(items.count < 2)
        // Not `items.count < 2`: Close Other Tabs keeps pinned tabs, so it is gated on whether a
        // closable other exists, the question the verb asks.
        Button("Close Other Tabs") { onCloseOthers(item.id) }
            .disabled(Self.closableOthers(of: item, in: items) == 0)
        Divider()
        Button(item.isPinned ? "Unpin Tab" : "Pin Tab") { onSetPinned(item.id, !item.isPinned) }
        Button("Duplicate") { onDuplicate(item.id) }
        Button("Copy Path") { onCopyPath(item.id) }
    }
}

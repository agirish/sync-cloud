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
        /// The full path, for the chip's tooltip — the strip's answer to "which Documents is this?"
        /// for anyone who wants more than the mark.
        public let fullPath: String

        public init(id: UUID, title: String, markImageName: String, isActive: Bool, fullPath: String) {
            self.id = id
            self.title = title
            self.markImageName = markImageName
            self.isActive = isActive
            self.fullPath = fullPath
        }
    }

    let items: [Item]
    let onSelect: (UUID) -> Void
    let onClose: (UUID) -> Void
    let onCloseOthers: (UUID) -> Void
    let onDuplicate: (UUID) -> Void
    let onCopyPath: (UUID) -> Void
    let onNew: () -> Void

    @Environment(\.appFontScale) private var fontScale

    public init(items: [Item],
                onSelect: @escaping (UUID) -> Void,
                onClose: @escaping (UUID) -> Void,
                onCloseOthers: @escaping (UUID) -> Void,
                onDuplicate: @escaping (UUID) -> Void,
                onCopyPath: @escaping (UUID) -> Void,
                onNew: @escaping () -> Void) {
        self.items = items
        self.onSelect = onSelect
        self.onClose = onClose
        self.onCloseOthers = onCloseOthers
        self.onDuplicate = onDuplicate
        self.onCopyPath = onCopyPath
        self.onNew = onNew
    }

    public var body: some View {
        GeometryReader { geo in
            let layout = PaneTabStripLadder.layout(available: geo.size.width,
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
                ForEach(visible(layout)) { item in
                    chip(item, width: layout.tabWidth)
                }
            case .chip:
                // The active tab keeps its name and gains the chevron: at the rail's width a row of
                // chips would be marks with smears beside them, and the one thing that must survive
                // is *which folder this pane is showing*.
                activeChipMenu(width: layout.tabWidth)
            }
            if layout.showsOverflow {
                overflowMenu(hidden: hiddenItems(layout))
            }
            // The empty stretch, double-clickable — and it needs the `contentShape` to be hit at
            // all, since an `HStack`'s spacer paints nothing.
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { onNew() }
            newTabButton
        }
        .padding(.horizontal, LiquidGlass.cardGutter)
    }

    private func visible(_ layout: PaneTabStripLadder.Layout) -> [Item] {
        // The visible window always contains the ACTIVE tab: folding away the tab the pane is
        // showing would leave a strip that describes somewhere else entirely.
        guard layout.visibleCount < items.count else { return items }
        let activeIndex = items.firstIndex(where: \.isActive) ?? 0
        let start = min(max(0, activeIndex - layout.visibleCount + 1), items.count - layout.visibleCount)
        return Array(items[start..<(start + layout.visibleCount)])
    }

    private func hiddenItems(_ layout: PaneTabStripLadder.Layout) -> [Item] {
        let shown = Set(visible(layout).map(\.id))
        return items.filter { !shown.contains($0.id) }
    }

    // MARK: - The chip

    private func chip(_ item: Item, width: CGFloat) -> some View {
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
                closeButton(item)
            }
            .padding(.horizontal, PaneTabStripLadder.tabPadding)
            .frame(width: width, height: PaneTabStripLadder.tabHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.hoverAffordance(.segment))
        .background(alignment: .bottom) { activeGround(item) }
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
        // Shown on the active tab and on hover. `opacity` rather than absence, so a chip's title
        // does not re-flow under the pointer.
        .opacity(item.isActive ? 1 : 0.45)
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
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.down")
                    .scaledFont(.system(size: 9, weight: .semibold))
            }
            .padding(.horizontal, PaneTabStripLadder.tabPadding)
            .frame(width: max(0, width), height: PaneTabStripLadder.tabHeight)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .background(alignment: .bottom) { activeGround(active) }
        .help(active.fullPath)
        .contextMenu { menu(for: active) }
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
        Button("Duplicate") { onDuplicate(item.id) }
        Button("Copy Path") { onCopyPath(item.id) }
    }
}

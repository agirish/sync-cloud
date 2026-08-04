import Design
import SwiftUI

/// Finder's "Customize Toolbar…" for the pane bar: drag items onto the bar, drag them off to remove,
/// drop the default set back.
///
/// Two differences from Finder, both deliberate:
///
/// * **The bar being edited lives in the sheet, not behind it.** Finder can leave its real toolbar
///   visible because the toolbar sits in the window's title bar, above where a sheet drops from. This
///   bar sits *inside* the window content, so a sheet covers it — an editable copy is the honest way
///   to show what you are arranging rather than an inch of it peeking out.
/// * **Every drag has a click.** Each item on the track carries Move Left / Move Right / Remove, and
///   each palette tile adds on click. Drag is the expected gesture, but this app has shipped a
///   drag-only affordance that never worked in a Release build before (`4d55246`), and an
///   arrangement you cannot reach without a mouse is not an accessible one.
struct PaneBarCustomizeSheet: View {
    /// What the pane you opened this from can actually draw.
    ///
    /// The arrangement is shared by both Compare panes and the Tidy rail, so it necessarily contains
    /// items a given pane has no use for — Collapse Pane is in the *default* arrangement and only the
    /// Tidy rail ever draws it, and Preview only exists in Columns view. Without this the sheet showed
    /// a Collapse Pane pill on the track of a Compare pane whose bar does not have one, which reads as
    /// a bug in the sheet. Those items are still fully editable here; they are just marked as not
    /// applying to the pane in front of you.
    var availableHere: Set<PaneBarItem> = Set(PaneBarItem.allCases)

    @Environment(\.dismiss) private var dismiss
    @AppStorage(PaneBar.arrangementKey) private var arrangementRaw: String =
        PaneBarArrangement.default.encoded
    @AppStorage(PaneBar.iconSizeKey) private var iconSizeRaw: String = PaneBarIconSize.regular.rawValue
    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue

    /// The slot the pointer is currently over, so the insertion caret can show where a drop lands.
    @State private var targetedSlot: Int?
    /// True while a bar item is over the palette, which is how a drag removes it.
    @State private var isOverPalette = false

    private var glassHue: LiquidGlassHue { LiquidGlassHue(rawValue: glassHueRaw) ?? .blue }

    private var arrangement: PaneBarArrangement { PaneBarArrangement(encoded: arrangementRaw) }

    private func update(_ transform: (inout PaneBarArrangement) -> Void) {
        var next = arrangement
        transform(&next)
        arrangementRaw = next.encoded
    }

    /// Everything the palette offers. Spacers last, as in Finder, because they are layout rather than
    /// ability — and `scan` is present but inert, so its absence from the removable set is explained
    /// rather than merely felt.
    static let palette: [PaneBarItem] = [
        .viewMode, .backForward, .newFolder, .sort, .hiddenFiles, .preview, .search, .collapse,
        .scan, .space, .flexibleSpace
    ]

    // MARK: Metrics
    //
    // The width is set by two things, neither of them taste.
    //
    // The floor is the *track*: a full bar is ten items, and at the first draft's 560pt they did not
    // fit — the row overflowed and what gave way was the provider capsule's label, so the sheet
    // shipped showing a bare cloud glyph where "iCloud" should have been. That is precisely the
    // leading edge the whole arrangement is measured against.
    //
    // The ceiling is the *window*: `ContentView` sets `minWidth: 600`, and the fix for the first
    // problem was a 700pt sheet — wider than the window it belongs to, at the size a real user can
    // drag theirs down to. Fixing an overflow by overflowing something bigger is not a fix.
    //
    // So: 600, with the row's own metrics tightened until ten items fit inside it, and a horizontal
    // scroll for the arrangements that still do not (nothing stops someone adding six spacers).

    private static let sheetWidth: CGFloat = 600
    /// The sheet's own inset, and the track card's. Named because `trackRowWidth` is derived from
    /// both: as three unrelated literals — 600 here, `.padding(22)` on the body, `.padding(9)` on the
    /// track — a later tweak to either padding would leave the derived width quietly wrong, and the
    /// symptom would be a track that scrolls a few points when it should not, or dead space where a
    /// drop target was meant to be. Change the padding and the width follows.
    private static let sheetPadding: CGFloat = 22
    private static let trackPadding: CGFloat = 9
    /// Width available to the track's row: the sheet, less its own padding, less the track's.
    ///
    /// A constant rather than a measurement, so the row inside the scroll view can be told to fill
    /// the viewport without a `GeometryReader` — which is what keeps the trailing slot greedy when
    /// the bar is short and scrollable when it is long.
    ///
    /// It assumes the body pads *before* it fixes the width (`.padding` then `.frame`). Swapped, the
    /// content box would be the full 600 and this would be 44pt short. The customize-sheet snapshot
    /// is what catches that: a track whose last pill is clipped is visible in the image and in
    /// nothing else the suite measures.
    private static let trackRowWidth: CGFloat = sheetWidth - 2 * sheetPadding - 2 * trackPadding
    private static let pillHeight: CGFloat = 26
    /// The default-set strip is a picture of the bar, not another bar — it is drawn smaller and
    /// quieter on purpose, because two rows of identical pills read as two editable bars.
    private static let samplePillHeight: CGFloat = 19
    private static let slotWidth: CGFloat = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            sectionLabel("Your pane bar")
            track
            sectionLabel("Drag an item onto the bar, or click to add it")
            paletteGrid
            sectionLabel("…or put the default set back")
            defaultSetRow
            Divider().padding(.top, 18)
            footer
        }
        .padding(Self.sheetPadding)
        .frame(width: Self.sheetWidth)
        // Escape closes it. There is nothing to cancel — every edit is applied to the shared
        // arrangement as it is made, so Done and Escape mean the same thing, and a sheet that
        // swallows Escape reads as stuck. `.cancelAction` on the Done button is not an option:
        // it already carries `.defaultAction`, and a button can only have one shortcut.
        .onExitCommand { dismiss() }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Customize Pane Bar")
                .scaledFont(.system(size: 15, weight: .semibold))
            Text("Drop items anywhere from the provider name to the trailing edge, and drag them "
                 + "off to remove them. Both panes share one arrangement.")
                .scaledFont(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if explainsItemsFromElsewhere {
                Label("Dimmed items don't apply to this pane. They stay in the arrangement and "
                      + "appear on the panes that use them.",
                      systemImage: "info.circle")
                    .scaledFont(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// One small-caps rule between sections. The first draft ran the bar, the palette and the footer
    /// together with nothing but spacing, and the result read as one undifferentiated grid of grey.
    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .scaledFont(.system(.caption, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .kerning(0.4)
            .padding(.top, 18)
            .padding(.bottom, 7)
    }

    /// Whether anything on the bar or in the palette belongs to a pane other than this one — the
    /// explanation is only worth the space when there is something to explain.
    var explainsItemsFromElsewhere: Bool {
        Self.palette.contains { !$0.isSpacer && !availableHere.contains($0) }
    }

    private func appliesHere(_ item: PaneBarItem) -> Bool {
        item.isSpacer || availableHere.contains(item)
    }

    // MARK: The editable bar

    /// Every part of the track you can aim at is its own drop target, and none of them overlap (the
    /// padding ring around the row is the one exception, and a drop there springs back):
    ///
    /// - the provider ghost inserts at the head (it is the leading edge you aim past),
    /// - each gap inserts at its own slot,
    /// - **each pill inserts before itself**, which is the whole point of the arrangement below,
    /// - the trailing slot takes the rest of the row and appends.
    ///
    /// There used to be one blanket destination over the whole track instead of the last two,
    /// appending whatever it caught, and it was a worse bug than the gap it filled. Dropping a pill
    /// onto another pill — or onto *itself*, which is how anyone abandons a drag — silently relocated
    /// it to the end of the bar. A drop that does nothing is a miss; a drop that quietly does the
    /// wrong thing is a defect, and it replaced the first with the second.
    ///
    /// It also rested on nested destinations resolving innermost-first, which needs a live event loop
    /// to check and so was never checked. If that assumption were wrong, every drop would have
    /// appended and the gaps would have been decoration. Leaf targets that do not overlap do not need
    /// the assumption to be true.
    private var track: some View {
        // Indicators ON. macOS overlay scrollers stay invisible until the pointer or a scroll asks
        // for them, so they cost nothing when the bar fits — and when it does not, they are the only
        // thing telling you the row continues. Hidden, a clipped pill reads as a broken sheet.
        ScrollView(.horizontal, showsIndicators: true) {
            trackRow.frame(minWidth: Self.trackRowWidth, alignment: .leading)
        }
        .padding(Self.trackPadding)
        .frame(minHeight: 50)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(.quaternary.opacity(0.28))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(targetedSlot == nil
                              ? AnyShapeStyle(.quaternary)
                              : AnyShapeStyle(glassHue.accentColor.opacity(0.7)),
                              lineWidth: targetedSlot == nil ? 0.5 : 1.5)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pane bar arrangement")
    }

    private var trackRow: some View {
        let items = arrangement.items
        return HStack(spacing: 0) {
            providerGhost
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                slot(index)
                trackItem(item, at: index)
            }
            // The trailing slot is what you aim at to append, so it takes the whole rest of the row
            // rather than another sliver. The width has to be applied INSIDE the slot, ahead of its
            // `contentShape` and drop destination: an outer `.frame(maxWidth: .infinity)` only grows
            // an empty box around the original hit area, centred, which is what this did at first —
            // the target claimed the row's leftovers in a comment and covered none of it.
            slot(items.count, flexible: true)
        }
    }

    /// Marks `index` as where a drop would land, and clears it on the way out.
    ///
    /// A slot and the pill beside it name the same insertion point, so crossing from one to the other
    /// can clear the caret a frame after the new target set it. That costs a flicker and never a
    /// wrong drop — both targets insert at the same index — which is why it is left alone rather than
    /// fixed with a second piece of state to keep in step.
    private func markTarget(_ index: Int, _ isTargeted: Bool) {
        targetedSlot = isTargeted ? index : (targetedSlot == index ? nil : targetedSlot)
    }

    /// The provider capsule's stand-in: the pane's identity, which is why it is anchored at the
    /// leading edge and is neither draggable nor removable.
    ///
    /// `fixedSize` and a layout priority because it is also the thing that lost when the row ran out
    /// of width — the shipped sheet squeezed its label away entirely and left a bare cloud glyph.
    private var providerGhost: some View {
        HStack(spacing: 5) {
            Image(systemName: "cloud.fill")
                .scaledFont(.system(size: 12))
                .foregroundStyle(.tertiary)
            Text("iCloud")
                .scaledFont(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .fixedSize()
        .layoutPriority(1)
        .padding(.horizontal, 9)
        .frame(height: Self.pillHeight)
        .background(Capsule().fill(.quaternary.opacity(0.45)))
        // Not draggable, not removable — but it *is* a drop target, because "past the provider name"
        // is exactly how someone aims at the head of the bar.
        .dropDestination(for: String.self) { payloads, _ in
            drop(payloads, at: 0)
        } isTargeted: { markTarget(0, $0) }
        .help("The provider name stays at the leading edge — it is the pane's identity, not a control")
        .accessibilityHidden(true)
    }

    /// One item on the track. The pill is what it looks like on the bar; the menu is what makes it
    /// reachable without a drag.
    private func trackItem(_ item: PaneBarItem, at index: Int) -> some View {
        pill(item, style: .onBar)
            .opacity(appliesHere(item) ? 1 : 0.4)
            .draggable(PaneBarDrop.payload(forItemAt: index))
            // A pill is both a drag source and a drop target. Dropping onto it inserts *before* it,
            // which makes the pills themselves aimable instead of being dead space between the gaps;
            // dropping a pill onto itself resolves to its own slot, changes nothing, and springs back.
            .dropDestination(for: String.self) { payloads, _ in
                drop(payloads, at: index)
            } isTargeted: { markTarget(index, $0) }
            .contextMenu {
                Button("Move Left") { update { $0.nudge(index, by: -1) } }
                    .disabled(index == 0)
                Button("Move Right") { update { $0.nudge(index, by: 1) } }
                    .disabled(index == arrangement.items.count - 1)
                Divider()
                Button("Remove", role: .destructive) { update { $0.remove(at: index) } }
                    .disabled(!item.isRemovable)
            }
            .help(trackHelp(item))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.displayName)
            .accessibilityHint(item.isRemovable ? "Draggable. Actions available." : "Always shown.")
            .accessibilityAction(named: "Move Left") { update { $0.nudge(index, by: -1) } }
            .accessibilityAction(named: "Move Right") { update { $0.nudge(index, by: 1) } }
            .accessibilityAction(named: "Remove") { update { $0.remove(at: index) } }
    }

    private func trackHelp(_ item: PaneBarItem) -> String {
        if !item.isRemovable {
            return "\(item.displayName) is always shown: a pane that cannot be scanned is a broken pane"
        }
        if !appliesHere(item) {
            return "\(item.displayName) doesn't apply to this pane — it appears on the panes that use it"
        }
        return "\(item.displayName) — drag to move, or right-click for more"
    }

    /// How solid a pill reads. The same shape does three jobs in this sheet and they must not look
    /// alike: one you can grab, one you can add, one that is only a picture of the default.
    private enum PillStyle {
        /// On the track — the real thing, grabbable.
        case onBar
        /// In the palette — a source you drag from.
        case palette
        /// In the default-set row — a picture, not a control.
        case sample
    }

    @ViewBuilder
    private func pill(_ item: PaneBarItem, style: PillStyle) -> some View {
        switch item {
        case .flexibleSpace, .space:
            spacerPill(item, style: style)
        default:
            HStack(spacing: 3) {
                Image(systemName: item.paletteSymbol)
                if item == .backForward { Image(systemName: "chevron.right") }
                if item == .viewMode { Image(systemName: "list.bullet") }
            }
            .scaledFont(.system(size: style == .sample ? 9.5 : 11.5, weight: .medium))
            .foregroundStyle(style == .sample ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
            .frame(minWidth: style == .sample ? 24 : 28)
            .frame(height: style == .sample ? Self.samplePillHeight : Self.pillHeight)
            .padding(.horizontal, style == .sample ? 5 : 6)
            .background(
                Capsule().fill(style == .sample
                               ? AnyShapeStyle(.quaternary.opacity(0.4))
                               : AnyShapeStyle(Material.regular))
            )
            .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 0.5))
        }
    }

    /// Spacers are drawn as what they are — a stretch of nothing — rather than as a control with a
    /// glyph in it, so the track reads as "gap here" at a glance instead of "some other button".
    private func spacerPill(_ item: PaneBarItem, style: PillStyle) -> some View {
        let flexible = item == .flexibleSpace
        return RoundedRectangle(cornerRadius: 5, style: .continuous)
            .strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 1, dash: flexible ? [] : [3, 3]))
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(.quaternary.opacity(flexible ? 0.35 : 0))
            )
            .frame(width: style == .sample ? (flexible ? 34 : 20) : (flexible ? 44 : 26),
                   height: (style == .sample ? Self.samplePillHeight : Self.pillHeight) - 4)
            .overlay {
                if flexible {
                    Image(systemName: item.paletteSymbol)
                        .scaledFont(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .opacity(style == .sample ? 0.7 : 1)
    }

    /// The gap between two items: an invisible drop target that grows a caret when aimed at.
    ///
    /// - Parameter flexible: when true the slot takes every remaining point of the row instead of a
    ///   fixed width. Used for the trailing slot, where the empty space to the right of the last pill
    ///   is the obvious place to aim an append at.
    private func slot(_ index: Int, flexible: Bool = false) -> some View {
        Rectangle()
            .fill(.clear)
            .frame(width: flexible ? nil : Self.slotWidth, height: Self.pillHeight + 6)
            .frame(maxWidth: flexible ? .infinity : nil)
            // Leading for the flexible slot: the caret marks where the item will land, which is hard
            // against the last pill, not adrift in the middle of the empty space.
            .overlay(alignment: flexible ? .leading : .center) {
                if targetedSlot == index {
                    Capsule()
                        .fill(glassHue.accentColor)
                        .frame(width: 3)
                }
            }
            .contentShape(Rectangle())
            .dropDestination(for: String.self) { payloads, _ in
                drop(payloads, at: index)
            } isTargeted: { markTarget(index, $0) }
    }

    /// Applies a drop at `index`, reporting whether the bar actually moved — the rules and their
    /// tests live in `PaneBarDrop`.
    private func drop(_ payloads: [String], at index: Int) -> Bool {
        guard let next = PaneBarDrop.applying(payloads, at: index, to: arrangement) else { return false }
        arrangementRaw = next.encoded
        return true
    }

    /// Drag-off-the-bar removal, from the palette's drop destination.
    private func dropToRemove(_ payloads: [String]) -> Bool {
        guard let next = PaneBarDrop.removing(payloads, from: arrangement) else { return false }
        arrangementRaw = next.encoded
        return true
    }

    // MARK: Palette

    private var paletteGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 10)], spacing: 12) {
            ForEach(Self.palette) { item in
                paletteTile(item)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(isOverPalette ? AnyShapeStyle(Color.red.opacity(0.09))
                                    : AnyShapeStyle(.quaternary.opacity(0.18)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(isOverPalette ? AnyShapeStyle(Color.red.opacity(0.5))
                                            : AnyShapeStyle(.quaternary),
                              lineWidth: isOverPalette ? 1.5 : 0.5)
        )
        // Dropping a bar item back into the palette removes it — Finder's drag-off-the-toolbar,
        // aimed at a target that actually exists rather than at "anywhere but the bar".
        .dropDestination(for: String.self) { payloads, _ in
            dropToRemove(payloads)
        } isTargeted: { isOverPalette = $0 }
    }

    /// One palette tile.
    ///
    /// Deliberately NOT dimmed for being on the bar already. The default arrangement carries every
    /// control, so the first draft opened with all ten tiles at 45% — a palette that looks broken,
    /// and the state anyone sees first. What is on the bar is said with a check instead, which is a
    /// fact rather than a disability.
    private func paletteTile(_ item: PaneBarItem) -> some View {
        let onBar = !item.isSpacer && arrangement.items.contains(item)
        return Button {
            update { $0.insert(item, at: $0.items.count) }
        } label: {
            VStack(spacing: 7) {
                pill(item, style: .palette)
                    .frame(height: Self.pillHeight)
                    .overlay(alignment: .topTrailing) {
                        if onBar {
                            Image(systemName: "checkmark.circle.fill")
                                .scaledFont(.system(size: 9))
                                .foregroundStyle(glassHue.accentColor)
                                .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                                .offset(x: 4, y: -4)
                        }
                    }
                VStack(spacing: 1) {
                    Text(item.displayName)
                        .scaledFont(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    // Fixed height rather than a conditional row: the captions used to appear only
                    // under some tiles, which made the grid's rows different heights and clipped the
                    // longest of them against the row below.
                    Text(captionFor(item, onBar: onBar))
                        .scaledFont(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
            .frame(maxWidth: .infinity)
            .opacity(appliesHere(item) ? 1 : 0.5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!item.isRemovable || onBar)
        .draggable(PaneBarDrop.payload(for: item))
        .help(paletteHelp(item, onBar: onBar))
        .accessibilityLabel(item.displayName)
        // Say where it lands, not just that it lands: clicking appends, which for a flexible space
        // means it arrives at the trailing end where it has nothing to push, and the placing is done
        // afterwards with Move Left. A hint that stopped at "adds it" would leave a spacer looking
        // like it had done nothing.
        .accessibilityHint(onBar
                           ? "Already on the bar"
                           : (item.isSpacer
                              ? "Adds to the end of the bar; use Move Left to place it"
                              : "Adds to the end of the bar"))
    }

    /// The one line under a tile's name. Deliberately not "on the bar" — the check already says that,
    /// and repeating it under seven of the ten tiles turned the palette into a wall of grey text.
    private func captionFor(_ item: PaneBarItem, onBar: Bool) -> String {
        if !item.isRemovable { return "always shown" }
        if !appliesHere(item) { return "other panes" }
        if item.isSpacer { return "repeatable" }
        return " "
    }

    private func paletteHelp(_ item: PaneBarItem, onBar: Bool) -> String {
        if !item.isRemovable {
            return "Scan is always on the bar — it is the pane's only scan control"
        }
        if onBar { return "\(item.displayName) is already on the bar — drag it on the bar to move it" }
        if !appliesHere(item) {
            return "Add \(item.displayName) — it doesn't apply to this pane, but the arrangement is "
                 + "shared, so it will appear on the panes that use it"
        }
        return "Add \(item.displayName)"
    }

    // MARK: The default set

    /// A picture of the bar as it ships, with the one button that puts it back — the mockup's
    /// "…or drag the default set into the toolbar", minus the drag, because there is exactly one
    /// thing anyone wants to do with it.
    private var defaultSetRow: some View {
        HStack(spacing: 0) {
            ForEach(Array(PaneBarArrangement.default.items.enumerated()), id: \.offset) { _, item in
                pill(item, style: .sample)
                    .padding(.trailing, 5)
            }
            Spacer(minLength: 12)
            Button("Restore") { arrangementRaw = PaneBarArrangement.default.encoded }
                // Same lesson as the provider ghost: the thing that must never be squeezed says so
                // itself rather than trusting the row to have room.
                .fixedSize()
                .disabled(arrangement == .default)
                .help(arrangement == .default
                      ? "The bar is already the default arrangement"
                      : "Put the bar back the way it shipped")
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(.quaternary.opacity(0.14))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 0.5)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Default arrangement")
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Text("Icon size")
                .scaledFont(.callout)
            Picker("Icon size", selection: $iconSizeRaw) {
                ForEach(PaneBarIconSize.allCases, id: \.rawValue) { size in
                    Text(size.displayName).tag(size.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accentedSegments(glassHue)
            .fixedSize()
            .help("A ceiling, not a fixed size — a pane too narrow for it still steps down rather than overflowing")

            Spacer(minLength: 0)

            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .shortcutKeycap("⏎")
        }
        .padding(.top, 16)
    }
}

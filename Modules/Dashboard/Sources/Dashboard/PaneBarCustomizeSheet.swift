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
        .viewMode, .backForward, .newFolder, .sort, .hiddenFiles, .preview, .collapse, .scan,
        .space, .flexibleSpace
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            track
            paletteGrid
            Divider()
            footer
        }
        .padding(22)
        .frame(width: 560)
        // Escape closes it. There is nothing to cancel — every edit is applied to the shared
        // arrangement as it is made, so Done and Escape mean the same thing, and a sheet that
        // swallows Escape reads as stuck. `.cancelAction` on the Done button is not an option:
        // it already carries `.defaultAction`, and a button can only have one shortcut.
        .onExitCommand { dismiss() }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Customize Pane Bar")
                .font(.headline)
            Text("Drag items onto the bar, anywhere from the provider name to the trailing edge. "
                 + "Drag one off to remove it. Both panes share this arrangement.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if explainsItemsFromElsewhere {
                Label("Dimmed items don't apply to this pane. They stay in the arrangement and "
                      + "appear on the panes that do use them.",
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
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

    /// The arrangement, as a track: a provider-capsule stand-in pinned at the leading edge (it is the
    /// pane's identity and provider switcher, not a control, so it can be neither moved nor removed),
    /// then a drop slot before and after every item.
    /// Every part of the track you can aim at is its own drop target, and none of them overlap (the
    /// 8pt padding ring around the row is the one exception, and a drop there springs back):
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
        let items = arrangement.items
        return HStack(spacing: 0) {
            providerGhost
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                slot(index)
                trackItem(item, at: index)
            }
            // The trailing slot is what you aim at to append, so it takes the whole rest of the row
            // rather than another 12pt sliver. The width has to be applied INSIDE the slot, ahead of
            // its `contentShape` and drop destination: an outer `.frame(maxWidth: .infinity)` only
            // grows an empty box around a 12pt hit area, centred, which is what this did at first —
            // the target claimed the row's leftovers in a comment and covered none of it.
            slot(items.count, flexible: true)
        }
        .padding(8)
        .frame(minHeight: 52)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.quaternary.opacity(0.35))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(glassHue.accentColor.opacity(targetedSlot == nil ? 0 : 0.55), lineWidth: 1.5)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pane bar arrangement")
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

    private var providerGhost: some View {
        HStack(spacing: 6) {
            Image(systemName: "cloud")
            Text("iCloud")
                .lineLimit(1)
        }
        .font(.callout.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(.quaternary.opacity(0.5)))
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
        trackPill(item)
            .opacity(appliesHere(item) ? 1 : 0.45)
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

    @ViewBuilder
    private func trackPill(_ item: PaneBarItem) -> some View {
        switch item {
        case .flexibleSpace:
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.tertiary.opacity(0.5))
                .frame(width: 46, height: 24)
                // `paletteSymbol`, not a second copy of the same glyph name: the SF Symbol test walks
                // that property, so a hardcoded name here would be the one glyph nothing checks.
                .overlay(Image(systemName: item.paletteSymbol)
                    .font(.caption2)
                    .foregroundStyle(.secondary))
        case .space:
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .frame(width: 30, height: 24)
        default:
            HStack(spacing: 3) {
                Image(systemName: item.paletteSymbol)
                if item == .backForward { Image(systemName: "chevron.right") }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(item.isRemovable ? Color.primary : Color.secondary)
            .frame(minWidth: 32, minHeight: 24)
            .padding(.horizontal, 6)
            .background(Capsule().fill(.background.opacity(0.9)))
            .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 0.5))
        }
    }

    /// The gap between two items: an invisible drop target that grows a caret when aimed at.
    ///
    /// - Parameter flexible: when true the slot takes every remaining point of the row instead of a
    ///   fixed 12pt. Used for the trailing slot, where the empty space to the right of the last pill
    ///   is the obvious place to aim an append at.
    private func slot(_ index: Int, flexible: Bool = false) -> some View {
        Rectangle()
            .fill(.clear)
            .frame(width: flexible ? nil : 12, height: 30)
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
        VStack(alignment: .leading, spacing: 10) {
            Text("Drag an item onto the bar, or click to add it")
                .font(.subheadline.weight(.medium))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 12)], spacing: 14) {
                ForEach(Self.palette) { item in
                    paletteTile(item)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isOverPalette ? AnyShapeStyle(Color.red.opacity(0.10))
                                        : AnyShapeStyle(.quaternary.opacity(0.2)))
            )
            // Dropping a bar item back into the palette removes it — Finder's drag-off-the-toolbar,
            // aimed at a target that actually exists rather than at "anywhere but the bar".
            .dropDestination(for: String.self) { payloads, _ in
                dropToRemove(payloads)
            } isTargeted: { isOverPalette = $0 }
        }
    }

    private func paletteTile(_ item: PaneBarItem) -> some View {
        let onBar = !item.isSpacer && arrangement.items.contains(item)
        return Button {
            update { $0.insert(item, at: $0.items.count) }
        } label: {
            VStack(spacing: 6) {
                trackPill(item)
                Text(item.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if !item.isRemovable {
                    Text("always shown")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity)
            .opacity(item.isRemovable && !onBar && appliesHere(item) ? 1 : 0.45)
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

    private func paletteHelp(_ item: PaneBarItem, onBar: Bool) -> String {
        if !item.isRemovable {
            return "Scan is always on the bar — it is the pane's only scan control"
        }
        if onBar { return "\(item.displayName) is already on the bar" }
        if !appliesHere(item) {
            return "Add \(item.displayName) — it doesn't apply to this pane, but the arrangement is "
                 + "shared, so it will appear on the panes that use it"
        }
        return "Add \(item.displayName)"
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Picker("Icon size", selection: $iconSizeRaw) {
                ForEach(PaneBarIconSize.allCases, id: \.rawValue) { size in
                    Text(size.displayName).tag(size.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .help("A ceiling, not a fixed size — a pane too narrow for it still steps down rather than overflowing")

            Button("Restore Defaults") { arrangementRaw = PaneBarArrangement.default.encoded }
                .disabled(arrangement == .default)

            Spacer(minLength: 0)

            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
    }
}

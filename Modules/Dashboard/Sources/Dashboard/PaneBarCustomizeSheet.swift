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
        }
    }

    // MARK: The editable bar

    /// The arrangement, as a track: a provider-capsule stand-in pinned at the leading edge (it is the
    /// pane's identity and provider switcher, not a control, so it can be neither moved nor removed),
    /// then a drop slot before and after every item.
    private var track: some View {
        HStack(spacing: 0) {
            providerGhost
            ForEach(Array(arrangement.items.enumerated()), id: \.offset) { index, item in
                slot(index)
                trackItem(item, at: index)
            }
            slot(arrangement.items.count)
                // The trailing slot is the one you aim at to append, so it gets the leftovers of the
                // row rather than the same 12pt as the rest.
                .frame(maxWidth: .infinity)
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
        .help("The provider name stays at the leading edge — it is the pane's identity, not a control")
        .accessibilityHidden(true)
    }

    /// One item on the track. The pill is what it looks like on the bar; the menu is what makes it
    /// reachable without a drag.
    private func trackItem(_ item: PaneBarItem, at index: Int) -> some View {
        trackPill(item)
            .draggable("bar:\(index)")
            .contextMenu {
                Button("Move Left") { update { $0.nudge(index, by: -1) } }
                    .disabled(index == 0)
                Button("Move Right") { update { $0.nudge(index, by: 1) } }
                    .disabled(index == arrangement.items.count - 1)
                Divider()
                Button("Remove", role: .destructive) { update { $0.remove(at: index) } }
                    .disabled(!item.isRemovable)
            }
            .help(item.isRemovable
                  ? "\(item.displayName) — drag to move, or right-click for more"
                  : "\(item.displayName) is always shown: a pane that cannot be scanned is a broken pane")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.displayName)
            .accessibilityHint(item.isRemovable ? "Draggable. Actions available." : "Always shown.")
            .accessibilityAction(named: "Move Left") { update { $0.nudge(index, by: -1) } }
            .accessibilityAction(named: "Move Right") { update { $0.nudge(index, by: 1) } }
            .accessibilityAction(named: "Remove") { update { $0.remove(at: index) } }
    }

    @ViewBuilder
    private func trackPill(_ item: PaneBarItem) -> some View {
        switch item {
        case .flexibleSpace:
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.tertiary.opacity(0.5))
                .frame(width: 46, height: 24)
                .overlay(Image(systemName: "arrow.left.and.right")
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

    /// The gap between two items: a thin, invisible drop target that grows a caret when aimed at.
    private func slot(_ index: Int) -> some View {
        Rectangle()
            .fill(.clear)
            .frame(width: 12, height: 30)
            .overlay {
                if targetedSlot == index {
                    Capsule()
                        .fill(glassHue.accentColor)
                        .frame(width: 3)
                }
            }
            .contentShape(Rectangle())
            .dropDestination(for: String.self) { payloads, _ in
                drop(payloads, at: index)
            } isTargeted: { targeted in
                targetedSlot = targeted ? index : (targetedSlot == index ? nil : targetedSlot)
            }
    }

    /// Applies a drop at `index`. Two payload shapes: `bar:<index>` is a move within the track,
    /// `palette:<raw>` is an add. Anything else is ignored rather than guessed at.
    private func drop(_ payloads: [String], at index: Int) -> Bool {
        guard let payload = payloads.first else { return false }
        if payload.hasPrefix("bar:"), let from = Int(payload.dropFirst("bar:".count)) {
            update { $0.move(from: from, to: index) }
            return true
        }
        if payload.hasPrefix("palette:"),
           let item = PaneBarItem(rawValue: String(payload.dropFirst("palette:".count))) {
            update { $0.insert(item, at: index) }
            return true
        }
        return false
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
                guard let payload = payloads.first, payload.hasPrefix("bar:"),
                      let index = Int(payload.dropFirst(4)) else { return false }
                update { $0.remove(at: index) }
                return true
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
            .opacity(item.isRemovable ? (onBar ? 0.45 : 1) : 0.45)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!item.isRemovable || onBar)
        .draggable("palette:\(item.rawValue)")
        .help(paletteHelp(item, onBar: onBar))
        .accessibilityLabel(item.displayName)
        .accessibilityHint(onBar ? "Already on the bar" : "Adds to the end of the bar")
    }

    private func paletteHelp(_ item: PaneBarItem, onBar: Bool) -> String {
        if !item.isRemovable {
            return "Scan is always on the bar — it is the pane's only scan control"
        }
        return onBar ? "\(item.displayName) is already on the bar" : "Add \(item.displayName)"
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

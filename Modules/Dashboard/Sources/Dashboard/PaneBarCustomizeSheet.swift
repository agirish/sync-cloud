import Design
import SwiftUI
import UniformTypeIdentifiers

/// Finder's "Customize Toolbar…" for the pane bar: drag items onto the bar, drag them off to remove,
/// put the default set back.
///
/// Two deliberate differences from Finder:
///
/// * The bar being edited lives in the sheet. Finder's toolbar sits above where a sheet drops
///   from; this bar sits inside the window content, so a sheet covers it, and an editable copy
///   shows what you are arranging.
/// * Every drag has a click. Each item on the track carries Move Left / Move Right / Remove, and
///   each palette tile adds on click: an arrangement you can't reach without a mouse isn't
///   accessible, and a drag-only affordance can fail in a Release build unnoticed.
public struct PaneBarCustomizeSheet: View {
    /// What the pane you opened this from can draw.
    ///
    /// The arrangement is shared by both Compare panes and the single-source rail, so it holds items
    /// a given pane has no use for (Collapse Pane is in the default, and only the rail draws it).
    /// Those items stay fully editable here, marked as not applying to this pane, so the track
    /// doesn't look wrong against the pane's real bar.
    var availableHere: Set<PaneBarItem> = Set(PaneBarItem.allCases)

    @Environment(\.dismiss) private var dismiss
    @AppStorage(PaneBar.arrangementKey) private var arrangementRaw: String =
        PaneBarArrangement.default.encoded
    @AppStorage(PaneBar.iconSizeKey) private var iconSizeRaw: String = PaneBarIconSize.regular.rawValue
    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue

    /// The slot the pointer is currently over, so the insertion caret can show where a drop lands.
    @State private var targetedSlot: Int?
    /// True while a bar item is over the palette, which is how a drag removes it.
    @State private var isOverPalette: Bool

    /// - Parameter showingRemoveTarget: seeds `isOverPalette`, for snapshots only. That state exists
    ///   only while a drag is in flight, which no test can stage, so this seam is the only way to
    ///   look at the remove affordance.
    public init(availableHere: Set<PaneBarItem> = Set(PaneBarItem.allCases),
         showingRemoveTarget: Bool = false) {
        self.availableHere = availableHere
        _isOverPalette = State(initialValue: showingRemoveTarget)
    }

    private var glassHue: LiquidGlassHue { LiquidGlassHue(rawValue: glassHueRaw) ?? .blue }

    private var arrangement: PaneBarArrangement { PaneBarArrangement(encoded: arrangementRaw) }

    private func update(_ transform: (inout PaneBarArrangement) -> Void) {
        var next = arrangement
        transform(&next)
        commit(next)
    }

    /// The only place this sheet writes the arrangement. Every add, remove, reorder and restore goes
    /// through here, and so does the logging (see `PaneBarEditLog`).
    ///
    /// One funnel rather than a log call beside each gesture, because no test can drive the
    /// gestures: a missed site would look like the rest.
    /// `PaneBarCustomizeSheetTests.testTheSheetWritesTheArrangementInExactlyOnePlace` counts the
    /// assignments in this file instead, a claim about absence that can be checked.
    ///
    /// The write is unconditional: `PaneBarEditLog.record` refuses a no-op, so an edit that changes
    /// nothing still normalizes the stored string and simply writes no line.
    private func commit(_ next: PaneBarArrangement) {
        let before = arrangement
        arrangementRaw = next.encoded
        PaneBarEditLog.record(from: before, to: next)
    }

    /// Everything the palette offers. Spacers last, as in Finder, because they are layout rather than
    /// ability, and `scan` is present but inert, so its absence from the removable set is explained.
    ///
    /// Hand-written, so a new case has to be listed here too. A missing item is a control that can
    /// be dragged off a bar and never put back: ⋯ carries only what a rung folded, so this palette
    /// is the only route back for a removed control, and the only route on at all for one that
    /// declines a migration step (Delete).
    /// `PaneBarCustomizeSheetTests.testThePaletteOffersEveryRemovableControl` checks it against
    /// `PaneBarItem.allCases`.
    static let palette: [PaneBarItem] = [
        .viewMode, .backForward, .newFolder, .sort, .hiddenFiles, .typeFilter, .search, .delete,
        .collapse, .scan, .space, .flexibleSpace
    ]

    // MARK: Metrics
    //
    // The width is set by two limits. The floor is the track: a full bar of ten items must fit, or
    // the row overflows at its leading edge, which is what the arrangement is measured against.
    // The ceiling is the window: the sheet must not be wider than the smallest window it belongs
    // to. So 600, with the row's metrics tightened until ten items fit, and a horizontal scroll for
    // arrangements that still don't (nothing stops someone adding six spacers).

    private static let sheetWidth: CGFloat = 600
    /// The sheet's own inset, and the track card's. Named because `trackRowWidth` is derived from
    /// both, so a change to either padding moves the derived width with it. As loose literals, the
    /// track would quietly scroll a few points or leave dead space where a drop target belongs.
    private static let sheetPadding: CGFloat = 22
    private static let trackPadding: CGFloat = 9
    /// Width available to the track's row: the sheet, less its own padding, less the track's.
    ///
    /// A constant rather than a measurement, so the row inside the scroll view can fill the
    /// viewport without a `GeometryReader`, which keeps the trailing slot greedy when the bar is
    /// short and scrollable when it is long.
    ///
    /// It assumes the body pads before it fixes the width (`.padding` then `.frame`). Swapped, the
    /// content box would be the full 600 and this would be 44pt short. Only the customize-sheet
    /// snapshot catches that, as a track whose last pill is clipped.
    private static let trackRowWidth: CGFloat = sheetWidth - 2 * sheetPadding - 2 * trackPadding
    private static let pillHeight: CGFloat = 26
    /// The default-set strip is a picture of the bar, not another bar, so it is drawn smaller and
    /// quieter: two rows of identical pills would read as two editable bars.
    private static let samplePillHeight: CGFloat = 19
    private static let slotWidth: CGFloat = 6

    public var body: some View {
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
        // Escape closes it. Every edit applies as it is made, so there is nothing to cancel, and a
        // sheet that swallows Escape reads as stuck. `.cancelAction` on Done isn't an option: it
        // already carries `.defaultAction`, and a button can only have one shortcut.
        .onExitCommand { dismiss() }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Customize Pane Bar")
                .scaledFont(.system(size: 15, weight: .semibold))
            Text("Drop items anywhere from the leading edge to the trailing edge, and drag them "
                 + "off to remove them. Both panes share one arrangement.")
                .scaledFont(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if explainsItemsFromElsewhere {
                Label("Dimmed items don’t apply to this pane. They stay in the arrangement and "
                      + "appear on the panes that use them.",
                      systemImage: "info.circle")
                    .scaledFont(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// One small-caps rule between sections, so the bar, the palette and the footer don't read as
    /// one undifferentiated grid of grey.
    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .scaledFont(.system(.caption, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .kerning(0.4)
            .padding(.top, 18)
            .padding(.bottom, 7)
    }

    /// Whether anything in the palette belongs to a pane other than this one; the explanation is
    /// only worth the space when there is something to explain.
    var explainsItemsFromElsewhere: Bool {
        Self.palette.contains { !$0.isSpacer && !availableHere.contains($0) }
    }

    private func appliesHere(_ item: PaneBarItem) -> Bool {
        item.isSpacer || availableHere.contains(item)
    }

    // MARK: The editable bar

    /// Every part of the track you can aim at is its own drop target, and none overlap (the padding
    /// ring around the row is the one exception, where a drop springs back, except on its leading
    /// side):
    ///
    /// - the leading-edge zone, laid over the row's scrolled leading padding, inserts at the head,
    /// - each gap between two pills inserts at its own slot,
    /// - each pill inserts before itself,
    /// - the trailing slot takes the rest of the row and appends.
    ///
    /// **Never** cover the track with one blanket destination: dropping a pill onto another, or
    /// onto itself to abandon a drag, would silently move it to the end of the bar. Leaf targets
    /// that don't overlap also don't depend on nested destinations resolving innermost-first, which
    /// needs a live event loop to check.
    private var track: some View {
        // Indicators on. macOS overlay scrollers stay invisible until the pointer or a scroll asks,
        // so they cost nothing when the bar fits, and when it doesn't they are the only sign the row
        // continues.
        ScrollView(.horizontal, showsIndicators: true) {
            trackRow.frame(minWidth: Self.trackRowWidth, alignment: .leading)
                // The leading padding is scrolled content and the head's zone lies over it, so the
                // zone scrolls with the row. Over the ScrollView instead, it would stay pinned at the
                // visible edge and a drop there would land at index 0, off-screen. Over the padding,
                // not in the row, so the first pill isn't pushed in from the edge.
                .padding(.horizontal, Self.trackPadding)
                .overlay(alignment: .leading) { leadingEdgeZone }
        }
        .padding(.vertical, Self.trackPadding)
        .frame(minHeight: 50)
        .background(
            RoundedRectangle(cornerRadius: Radius.well, style: .continuous)
                .fill(.quaternary.opacity(0.28))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.well, style: .continuous)
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
            // No slot ahead of the first pill: the leading-edge zone is the head's gap.
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if index > 0 { slot(index) }
                trackItem(item, at: index)
            }
            // The trailing slot is what you aim at to append, so it takes the rest of the row. The
            // width must be applied inside the slot, ahead of its `contentShape` and drop
            // destination: an outer `.frame(maxWidth: .infinity)` only grows an empty box around
            // the original hit area.
            slot(items.count, flexible: true)
        }
    }

    /// Marks `index` as where a drop would land, and clears it on the way out.
    ///
    /// A slot and the pill beside it name the same insertion point, so crossing from one to the
    /// other can clear the caret a frame after the new target set it. That costs a flicker, never a
    /// wrong drop, so it isn't worth a second piece of state.
    private func markTarget(_ index: Int, _ isTargeted: Bool) {
        targetedSlot = isTargeted ? index : (targetedSlot == index ? nil : targetedSlot)
    }

    /// A blank drop target at the head of the bar, so "first" is easy to aim at. The bar starts at
    /// the pane's leading edge, so this is that edge: nothing drawn, still aimable.
    ///
    /// It takes no width from the row: it lies over the row's leading padding, inside the scroll
    /// view so it scrolls away with the head (`track`), and the first pill sits as close to the edge
    /// as the default set's below. The first pill also inserts before itself, so this zone and that
    /// pill together land at index 0, and index 0's caret is drawn here since no slot precedes it.
    var leadingEdgeZone: some View {
        Rectangle()
            .fill(.clear)
            .frame(width: Self.leadingEdgeWidth)
            .frame(maxHeight: .infinity)
            .overlay(alignment: .trailing) {
                if targetedSlot == 0 {
                    Capsule()
                        .fill(glassHue.accentColor)
                        .frame(width: 3, height: Self.pillHeight + 6)
                }
            }
            .contentShape(Rectangle())
            .dropDestination(for: String.self) { payloads, _ in
                drop(payloads, at: 0)
            } isTargeted: { markTarget(0, $0) }
            .accessibilityHidden(true)
    }

    /// The track's leading padding, which the zone covers exactly.
    static let leadingEdgeWidth: CGFloat = trackPadding

    /// One item on the track. The pill is what it looks like on the bar; the menu makes it reachable
    /// without a drag. Internal so `PaneBarCustomizeSheetTests` can host one item and right-click
    /// it, since the whole interaction rests on the pills being aimable.
    func trackItem(_ item: PaneBarItem, at index: Int) -> some View {
        pill(item, style: .onBar)
            .opacity(appliesHere(item) ? 1 : 0.4)
            // A drawn shape is hit-testable only where it is painted, and a fixed space is a dashed
            // 1pt outline with no fill, so without this the drag, the drop and the context menu (the
            // only click-only way to remove it) would sit on a 1pt ring, and the bar could gain a
            // space it could never lose. `theSpaceOnTheTrackCanBeAimedAt` checks every pill answers
            // a menu at its centre.
            .contentShape(Rectangle())
            .draggable(PaneBarDrop.payload(forItemAt: index))
            // A pill is both a drag source and a drop target. Dropping onto it inserts before it,
            // so the pills are aimable rather than dead space between the gaps; dropping a pill onto
            // itself resolves to its own slot, changes nothing, and springs back.
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
            // Offered on exactly the same terms as the context menu above: a VoiceOver user offered
            // "Remove" on the always-shown Scan pill would activate it and get nothing, and an action
            // that can't fire is worse than an absent one. `if` around each action rather than a
            // no-op closure, since present-but-inert is the state to avoid.
            .accessibilityActions {
                if index > 0 {
                    Button("Move Left") { update { $0.nudge(index, by: -1) } }
                }
                if index < arrangement.items.count - 1 {
                    Button("Move Right") { update { $0.nudge(index, by: 1) } }
                }
                if item.isRemovable {
                    Button("Remove") { update { $0.remove(at: index) } }
                }
            }
    }

    private func trackHelp(_ item: PaneBarItem) -> String {
        if !item.isRemovable {
            return "\(item.displayName) is always shown: a pane that cannot be scanned is a broken pane"
        }
        if !appliesHere(item) {
            return "\(item.displayName) doesn’t apply to this pane — it appears on the panes that use it"
        }
        return "\(item.displayName) — drag to move, or right-click for more"
    }

    /// How solid a pill reads. The same shape does three jobs in this sheet and they must not look
    /// alike: one you can grab, one you can add, one that is only a picture of the default.
    private enum PillStyle {
        /// On the track: the real thing, grabbable.
        case onBar
        /// In the palette: a source you drag from.
        case palette
        /// In the default-set row: a picture, not a control.
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

    /// Spacers are drawn as what they are, a stretch of nothing, rather than as a control with a
    /// glyph, so the track reads as "gap here" at a glance.
    private func spacerPill(_ item: PaneBarItem, style: PillStyle) -> some View {
        let flexible = item == .flexibleSpace
        return RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
            .strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 1, dash: flexible ? [] : [3, 3]))
            .background(
                RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
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
            // Leading for the flexible slot: the caret marks where the item will land, hard against
            // the last pill, not adrift in the empty space.
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

    /// Applies a drop at `index`, reporting whether the bar moved. The rules and their tests live in
    /// `PaneBarDrop`.
    private func drop(_ payloads: [String], at index: Int) -> Bool {
        guard let next = PaneBarDrop.applying(payloads, at: index, to: arrangement) else { return false }
        commit(next)
        return true
    }

    /// Drag-off-the-bar removal, from the palette's drop destination.
    private func dropToRemove(_ payloads: [String]) -> Bool {
        guard let next = PaneBarDrop.removing(payloads, from: arrangement) else { return false }
        commit(next)
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
            RoundedRectangle(cornerRadius: Radius.well, style: .continuous)
                .fill(isOverPalette ? AnyShapeStyle(Color.red.opacity(0.09))
                                    : AnyShapeStyle(.quaternary.opacity(0.18)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.well, style: .continuous)
                .strokeBorder(isOverPalette ? AnyShapeStyle(Color.red.opacity(0.5))
                                            : AnyShapeStyle(.quaternary),
                              lineWidth: isOverPalette ? 1.5 : 0.5)
        )
        // The red wash says something will happen here; this says what. macOS has no minus or
        // trash badge for a drag (a green + for copy, a curved arrow for a link, nothing for a
        // move), so the target itself is the only place a remove can be drawn.
        //
        // `allowsHitTesting(false)` is required: this sits above the drop destination below, and an
        // overlay that took the hit would swallow the drop it explains.
        .overlay {
            if isOverPalette { removeOverlay.allowsHitTesting(false) }
        }
        // Dropping a bar item back into the palette removes it, like Finder's drag-off-the-toolbar
        // but aimed at a real target.
        //
        // A `DropDelegate` rather than `dropDestination(for:)`, because only a delegate can propose
        // `.move`; `dropDestination` always proposes a copy, which badges the cursor with a green +
        // over a target that deletes. The cost: `DropInfo` can't read a payload synchronously, so
        // this target accepts first and removes whatever turns out to be a bar item, and a palette
        // tile dragged into the palette animates as accepted and changes nothing. The track's
        // targets keep `dropDestination` and still spring back, which is where it matters.
        .onDrop(of: [.utf8PlainText], delegate: RemoveDropDelegate(
            isTargeted: { isOverPalette = $0 },
            remove: { dropToRemove([$0]) }))
    }

    /// What the palette says while a bar item is over it. Internal so it can be rendered on its own,
    /// since the real thing only appears mid-drag, which no test can stage.
    var removeOverlay: some View {
        VStack(spacing: 6) {
            Image(systemName: "trash")
                .scaledFont(.system(size: 22, weight: .semibold))
            Text("Remove from bar")
                .scaledFont(.system(.callout, weight: .semibold))
        }
        .foregroundStyle(Color.red)
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        // Opaque: a material would let the tiles' labels underneath read through "Remove from bar".
        // A material is for floating over a surface; this floats over labelled controls and must
        // read at a glance mid-drag.
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.red.opacity(0.45), lineWidth: 1)
        )
    }

    /// One palette tile. Not dimmed for being on the bar already: the default carries every
    /// control, so the palette would open with every tile dimmed and look broken. A check says
    /// what is on the bar instead.
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
                    // Always a caption line, even a blank one, so every grid row is the same height
                    // and the longest tiles don't clip against the row below.
                    Text(captionFor(item))
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
        // Say where it lands: clicking appends, which for a spacer means the trailing end, where it
        // pushes nothing until placed with Move Left. A hint that stopped at "adds it" would leave a
        // spacer looking like it did nothing.
        .accessibilityHint(onBar
                           ? "Already on the bar"
                           : (item.isSpacer
                              ? "Adds to the end of the bar; use Move Left to place it"
                              : "Adds to the end of the bar"))
    }

    /// The one line under a tile's name. Not "on the bar": the check already says that, and
    /// repeating it under most tiles would make the palette a wall of grey text.
    private func captionFor(_ item: PaneBarItem) -> String {
        if !item.isRemovable { return "always shown" }
        if !appliesHere(item) { return "other panes" }
        if item.isSpacer { return "repeatable" }
        return " "
    }

    private func paletteHelp(_ item: PaneBarItem, onBar: Bool) -> String {
        if !item.isRemovable {
            return "Scan is always on the bar — it is the pane’s only scan control"
        }
        if onBar { return "\(item.displayName) is already on the bar — drag it on the bar to move it" }
        if !appliesHere(item) {
            return "Add \(item.displayName) — it doesn’t apply to this pane, but the arrangement is "
                 + "shared, so it will appear on the panes that use it"
        }
        return "Add \(item.displayName)"
    }

    // MARK: The default set

    /// A picture of the bar as it ships, with the one button that puts it back. No drag, because
    /// there is exactly one thing anyone wants to do with it.
    private var defaultSetRow: some View {
        HStack(spacing: 0) {
            ForEach(Array(PaneBarArrangement.default.items.enumerated()), id: \.offset) { _, item in
                pill(item, style: .sample)
                    .padding(.trailing, 5)
            }
            Spacer(minLength: 12)
            Button("Restore") { commit(arrangement.restoredToDefault) }
                // Fixed size, so the pills beside it can never squeeze the button.
                .fixedSize()
                .disabled(arrangement.drawsTheDefault)
                .help(arrangement.drawsTheDefault
                      ? "The bar is already the default arrangement"
                      : "Put the bar back the way it shipped")
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: Radius.well, style: .continuous)
                .fill(.quaternary.opacity(0.14))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.well, style: .continuous)
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
                .shortcutKeycap("↩")
                .accentedProminent()
        }
        .padding(.top, 16)
    }
}

/// The palette's remove target, as a delegate rather than a `dropDestination`.
///
/// It exists for `dropUpdated`. `dropDestination(for:)` always proposes a copy, which macOS draws
/// as a green + on the cursor, the badge for "it will still be there afterwards". A delegate is
/// the only SwiftUI drop API that can propose an operation, and `.move` is both true and the only
/// proposal with no badge. There is no minus or trash badge, so the trash is drawn in the target.
///
/// `performDrop` accepts before it knows what it caught: every read from an `NSItemProvider` is
/// asynchronous, too late to answer the drag session. It returns true and removes whatever turns
/// out to be a bar item. See the call site for why that trade is acceptable here only.
private struct RemoveDropDelegate: DropDelegate {
    let isTargeted: (Bool) -> Void
    let remove: (String) -> Bool

    func dropEntered(info: DropInfo) { isTargeted(true) }
    func dropExited(info: DropInfo) { isTargeted(false) }

    /// The point of the type: `.move`, so the cursor stops promising a copy.
    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted(false)
        guard let provider = info.itemProviders(for: [.utf8PlainText]).first else { return false }
        // The completion lands off the main actor, and the closure it calls writes `@AppStorage`
        // through a SwiftUI view. Hop first.
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let payload = object as? NSString else { return }
            let text = payload as String
            Task { @MainActor in _ = remove(text) }
        }
        return true
    }
}

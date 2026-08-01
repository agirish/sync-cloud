import SwiftUI

/// One thing that can sit on a pane's bar.
///
/// The bar used to be a hard-coded `HStack` welded to the trailing edge by `margin-left: auto`'s
/// SwiftUI equivalent (a `Spacer` outside it), which meant no control could ever move left. It is now
/// a *track* running from the provider capsule to the pane's trailing edge, and this is its alphabet:
/// an arrangement is an ordered list of these, and the trailing-edge look is produced by a
/// `flexibleSpace` at the head of the list rather than by the layout being incapable of anything else.
///
/// Raw values are persisted — **append new cases, never renumber or rename**, or every stored
/// arrangement silently drops the item that changed.
public enum PaneBarItem: String, CaseIterable, Identifiable, Sendable, Codable {
    case viewMode
    case collapse
    case backForward
    case scan
    case newFolder
    case sort
    case hiddenFiles
    case preview
    case space
    case flexibleSpace

    public var id: String { rawValue }

    /// Spacers are layout, not controls: they are never offered in the overflow menu, never counted
    /// as duplicates, and (for `flexibleSpace`) cost no width to keep.
    public var isSpacer: Bool { self == .space || self == .flexibleSpace }

    /// The one item that can be neither removed nor folded.
    ///
    /// Scan is the pane's only scan control — the freshness badge that used to carry it became a
    /// toggle, so it cannot also be the scan button. A bar without this is a pane that can never be
    /// scanned, which is a broken pane rather than a customized one.
    public static let pinned: PaneBarItem = .scan

    public var isRemovable: Bool { self != Self.pinned }

    /// Palette label, and the label the overflow menu uses when this item has folded away.
    public var displayName: String {
        switch self {
        case .viewMode: return "View"
        case .collapse: return "Collapse Pane"
        case .backForward: return "Back/Forward"
        case .scan: return "Scan"
        case .newFolder: return "New Folder"
        case .sort: return "Sort"
        case .hiddenFiles: return "Hidden Files"
        case .preview: return "Preview"
        case .space: return "Space"
        case .flexibleSpace: return "Flexible Space"
        }
    }

    /// The palette tile's glyph. Paired items (View, Back/Forward) draw the first of their pair here;
    /// the bar itself draws both.
    public var paletteSymbol: String {
        switch self {
        case .viewMode: return "rectangle.split.3x1"
        case .collapse: return "sidebar.left"
        case .backForward: return "chevron.left"
        case .scan: return "arrow.clockwise"
        case .newFolder: return "folder.badge.plus"
        case .sort: return "arrow.up.arrow.down"
        case .hiddenFiles: return "eye.slash"
        case .preview: return "rectangle.righthalf.inset.filled"
        case .space: return "space"
        case .flexibleSpace: return "arrow.left.and.right"
        }
    }

    // `pillCount` was here — 2 for the paired items, 0 for a flexible space — written for a fold
    // arithmetic that in the end never needed it: `ViewThatFits` measures the real views, so nothing
    // ever asked this type how wide it thinks it is. It went for the same reason
    // `PaneNavMetrics.clusterWidth` did in the commit that introduced this file: a number describing
    // layout that no layout reads is a claim nothing checks, and the first time it disagreed with the
    // pills on screen there would be no test to notice.
}

/// The persisted order of a pane bar: which items are on it, and where.
///
/// Shared by both Compare panes and the Tidy rail — one arrangement, because the point of Compare's
/// side-by-side layout is that the two panes read as the same instrument pointed at two providers.
/// What stays per-pane is *state* (provider, hue wash, breadcrumb, whether Back is enabled), not the
/// arrangement.
public struct PaneBarArrangement: Equatable, Sendable {
    public private(set) var items: [PaneBarItem]

    /// A ceiling on how long a bar can get. Not a UI limit anyone will hit with the palette — it
    /// bounds what a corrupt or hand-edited defaults value can do to the layout ladder, which only
    /// has ten rungs.
    public static let maxItems = 16

    /// Today's bar, exactly: a flexible space (which is what pins the rest to the trailing edge),
    /// then the nine controls in the order they have always been drawn.
    ///
    /// This is load-bearing. An untouched install must render pixel-for-pixel what it rendered
    /// before the bar became arrangeable — `PaneHeaderHeightTests` and the 250pt snapshots assert
    /// exactly that, and they are the regression net for this whole change.
    public static let `default` = PaneBarArrangement([
        .flexibleSpace, .viewMode, .collapse, .backForward, .scan, .newFolder, .sort, .hiddenFiles, .preview
    ])

    /// Normalizes on the way in, so no other code has to defend against a malformed list:
    /// duplicate controls collapse to their first appearance, `scan` is restored if absent, and the
    /// whole thing is capped. Spacers are exempt from the duplicate rule — repeating them is how you
    /// centre or group things.
    public init(_ items: [PaneBarItem]) {
        var seen = Set<PaneBarItem>()
        var normalized: [PaneBarItem] = []
        for item in items {
            if item.isSpacer {
                normalized.append(item)
            } else if seen.insert(item).inserted {
                normalized.append(item)
            }
            if normalized.count == Self.maxItems { break }
        }
        // Scan is not removable. A stored arrangement without it came from a corrupt value or a
        // hand-edited plist, not from the sheet — restore it rather than ship a pane that cannot scan.
        if !normalized.contains(.scan) {
            if normalized.count == Self.maxItems { normalized.removeLast() }
            normalized.append(.scan)
        }
        self.items = normalized
    }

    // MARK: Persistence

    /// One defaults string, comma-joined. A list rather than JSON because it is read by `@AppStorage`,
    /// which stores strings, and because a human looking at the plist should be able to see what
    /// their bar is.
    public var encoded: String { items.map(\.rawValue).joined(separator: ",") }

    /// Unknown tokens are dropped, not rejected: that is what makes a bar arranged on a newer build
    /// survive a downgrade instead of resetting to the default.
    public init(encoded: String) {
        self.init(encoded.split(separator: ",").compactMap { PaneBarItem(rawValue: String($0)) })
    }

    // MARK: Editing

    public func canRemove(_ index: Int) -> Bool {
        items.indices.contains(index) && items[index].isRemovable
    }

    public mutating func remove(at index: Int) {
        guard canRemove(index) else { return }
        items.remove(at: index)
    }

    /// Inserts at `index`, clamped. A non-spacer already on the bar MOVES rather than duplicating —
    /// dragging Sort from the palette onto a bar that already has Sort should not give you two.
    public mutating func insert(_ item: PaneBarItem, at index: Int) {
        var target = min(max(index, 0), items.count)
        if !item.isSpacer, let existing = items.firstIndex(of: item) {
            items.remove(at: existing)
            if existing < target { target -= 1 }
        } else if items.count >= Self.maxItems {
            return
        }
        items.insert(item, at: min(target, items.count))
    }

    /// Moves the item at `index` to `destination`, expressed in the pre-move indices (the same
    /// convention `Array.move(fromOffsets:toOffset:)` uses).
    public mutating func move(from index: Int, to destination: Int) {
        guard items.indices.contains(index) else { return }
        let clamped = min(max(destination, 0), items.count)
        guard clamped != index, clamped != index + 1 else { return }
        let item = items.remove(at: index)
        items.insert(item, at: clamped > index ? clamped - 1 : clamped)
    }

    /// One step left or right, for the keyboard path. Drag is the expected gesture, but it cannot be
    /// the only one — VoiceOver and keyboard users get the same reach through the sheet's buttons.
    public mutating func nudge(_ index: Int, by offset: Int) {
        let destination = index + offset
        guard items.indices.contains(index), items.indices.contains(destination) else { return }
        items.swapAt(index, destination)
    }

    // MARK: Queries

    /// Available items this bar does NOT carry — they belong in the overflow menu, so a removal costs
    /// a pill and never an ability.
    ///
    /// This is also, for free, the rule for controls added in a future release: a stored arrangement
    /// predates them, so they are absent, so they arrive in ⋯ rather than rearranging a bar someone
    /// chose. Discoverability is the release notes' job, not the layout's.
    ///
    /// Ordered by `PaneBarItem.allCases` — the canonical bar order — not by `available`. These become
    /// menu items, and `available` is assembled by each host in whatever order its `if let`s happen to
    /// run: the menu was listing removed controls as Back/Forward, Sort, Hidden Files, View, which is
    /// not an order anyone can hold in their head. A menu that reorders itself when a host adds an
    /// optional callback is not a menu anyone can learn.
    public func absent(from available: [PaneBarItem]) -> [PaneBarItem] {
        PaneBarItem.allCases.filter { !$0.isSpacer && available.contains($0) && !items.contains($0) }
    }

    /// The arrangement restricted to what this host can actually offer — a header with no view-mode
    /// binding has no View control to place, and the Tidy rail has no Columns mode to preview.
    public func resolved(available: [PaneBarItem]) -> [PaneBarItem] {
        items.filter { $0.isSpacer || available.contains($0) }
    }
}

/// What the bar draws at one rung of the narrow-pane ladder.
public struct PaneBarLayoutPlan: Equatable, Sendable {
    /// Left to right, spacers included.
    public let visible: [PaneBarItem]
    /// Controls that folded away at this rung, plus anything removed from the bar entirely. This is
    /// the ⋯ menu's contents; empty means no ⋯ pill at all.
    public let overflow: [PaneBarItem]
    /// At the last rung the Tree|Columns switch stops being a two-segment control and becomes one
    /// pill whose menu holds the alternatives — the same compaction the hard-coded ladder did at its
    /// `.all` fold. It compacts rather than folding because that is what makes the deepest rung
    /// exactly as wide as it was before the bar became arrangeable, which is what keeps the 250pt
    /// pane picking the same rung and showing the same number of provider-name characters.
    public let compactsViewMode: Bool
}

public enum PaneBarLayout {
    /// Items the ladder will not take away, however narrow the pane gets.
    ///
    /// Scan is the pane's only scan control; Back/Forward is the pane's only in-place navigation.
    /// A pane that can move and rescan is still a pane — one that can do neither is a dead end, and
    /// no amount of narrowness justifies producing one. Everything else is negotiable and goes to ⋯.
    static let floor: Set<PaneBarItem> = [.scan, .backForward]

    /// Sheds `depth` items from the bar and reports what is left.
    ///
    /// Shedding order is the whole point of the ladder, and it now follows the user's own arrangement
    /// instead of a hard-coded "sort and hidden files first":
    ///
    /// 1. **Fixed spaces go first**, right to left. They are pure air; giving one up costs no ability.
    /// 2. **Then controls, right to left**, skipping the floor and the view switch. Whatever you put
    ///    last is what a cramped pane gives up first — which makes the arrangement a priority list
    ///    without anyone having to say so.
    /// 3. **Then the view switch compacts** to a single menu pill, as the last thing tried.
    /// 4. **Flexible spaces never shed** — they already cost nothing, and dropping one would move
    ///    everything else on the bar just as the pane got too small to absorb it.
    ///
    /// A `depth` past the end simply sheds everything sheddable, which is what the ladder's last rung
    /// asks for.
    public static func plan(arrangement: PaneBarArrangement,
                            available: [PaneBarItem],
                            depth: Int) -> PaneBarLayoutPlan {
        let placed = arrangement.resolved(available: available)
        var sheddable: [Int] = []
        for (index, item) in placed.enumerated().reversed() where item == .space {
            sheddable.append(index)
        }
        for (index, item) in placed.enumerated().reversed()
        where !item.isSpacer && item != .viewMode && !floor.contains(item) {
            sheddable.append(index)
        }
        let requested = max(depth, 0)
        let shed = Set(sheddable.prefix(requested))
        // The view switch compacts only once everything sheddable has already gone — it is the last
        // rung, not an early economy.
        let compacts = requested > sheddable.count && placed.contains(.viewMode)

        var visible: [PaneBarItem] = []
        var folded: [PaneBarItem] = []
        for (index, item) in placed.enumerated() {
            if shed.contains(index) {
                if !item.isSpacer { folded.append(item) }
            } else {
                visible.append(item)
            }
        }
        return PaneBarLayoutPlan(visible: visible,
                                 overflow: folded + arrangement.absent(from: available),
                                 compactsViewMode: compacts)
    }

    /// The deepest rung that changes anything for this arrangement. Past it, `plan` is idempotent —
    /// which is why the header can declare a fixed number of `ViewThatFits` variants and let the
    /// surplus ones be duplicates.
    public static func maxDepth(arrangement: PaneBarArrangement, available: [PaneBarItem]) -> Int {
        let placed = arrangement.resolved(available: available)
        let sheddable = placed.filter { $0 == .space || (!$0.isSpacer && $0 != .viewMode && !floor.contains($0)) }
        return sheddable.count + (placed.contains(.viewMode) ? 1 : 0)
    }

    // MARK: The ladder

    /// Whether a 6pt gap belongs before `index`. Not before the first item, and never on either side
    /// of a flexible space — the space is already the separation, and charging for a gap next to it
    /// is what made the bar wider than the one it replaced.
    ///
    /// Lives here, beside `width(of:controlSize:)`, rather than next to the `HStack` that draws it:
    /// the drawn bar and the measured bar must place gaps by the *same* rule or the arithmetic that
    /// picks a rung is quietly describing a different bar than the one on screen.
    static func needsGap(before index: Int, in items: [PaneBarItem]) -> Bool {
        guard index > 0 else { return false }
        return items[index] != .flexibleSpace && items[index - 1] != .flexibleSpace
    }

    /// The laid-out width of one item, at the pill size of the rung drawing it.
    ///
    /// Every figure here is the arithmetic of the view that draws the item in `PaneHeader.barItem`,
    /// expressed in the same `PaneNavMetrics` constants those views use — not a second opinion about
    /// them. `PaneBarLadderTests.everyItemMeasuresWhatItDraws` pins each one against the hosted view.
    static func width(of item: PaneBarItem, pill: CGSize, compactsViewMode: Bool) -> CGFloat {
        switch item {
        // A `Spacer(minLength: 0)`. It is what pins the bar to the trailing edge, and it costs the
        // bar's *minimum* width nothing — which is exactly the width a rung is chosen by.
        case .flexibleSpace:
            return 0
        case .space:
            return pill.width
        // Two segments inset from the plain pill, hair-spaced, inside a padded capsule ground.
        case .viewMode:
            return compactsViewMode
                ? pill.width
                : 2 * (pill.width - PaneNavMetrics.segmentInset)
                    + PaneNavMetrics.segmentSpacing + 2 * PaneNavMetrics.segmentPadding
        // One item, two pills — they move and fold together, so they measure together.
        case .backForward:
            return 2 * pill.width + PaneNavMetrics.pairSpacing
        // Styled as the view switch's selected segment, so it is a segment wide, not a pill wide.
        case .preview:
            return pill.width - PaneNavMetrics.segmentInset
        case .collapse, .scan, .newFolder, .sort, .hiddenFiles:
            return pill.width
        }
    }

    /// The laid-out width of a whole rung, gaps and ⋯ included.
    ///
    /// This is the number `ViewThatFits` used to discover by building the rung and measuring it. It
    /// is arithmetic now because building ten candidate bars per layout pass, twice per window, was
    /// the pane header's dominant main-thread cost.
    public static func width(of plan: PaneBarLayoutPlan, controlSize: ControlSize) -> CGFloat {
        let pill = PaneNavMetrics.pill(controlSize)
        var total: CGFloat = 0
        for (index, item) in plan.visible.enumerated() {
            if needsGap(before: index, in: plan.visible) { total += PaneNavMetrics.itemGap }
            total += width(of: item, pill: pill, compactsViewMode: plan.compactsViewMode)
        }
        if !plan.overflow.isEmpty {
            if plan.visible.last.map({ $0 != .flexibleSpace }) ?? false { total += PaneNavMetrics.itemGap }
            total += pill.width
        }
        return total
    }

    /// The tallest thing on a rung. Only the view switch is taller than a pill — it wears a padded
    /// capsule ground behind its two segments.
    public static func height(of plan: PaneBarLayoutPlan, controlSize: ControlSize) -> CGFloat {
        let pill = PaneNavMetrics.pill(controlSize)
        let carriesSwitch = plan.visible.contains(.viewMode) && !plan.compactsViewMode
        return pill.height + (carriesSwitch ? 2 * PaneNavMetrics.segmentPadding : 0)
    }
}

/// The pane bar's narrow-pane ladder: every layout the bar can step down through, widest first, and
/// the arithmetic that says which one a given width gets.
///
/// The header used to hand all ten rungs to `ViewThatFits` and let it search. That works, but
/// `ViewThatFits` *builds every child to measure it* — ten full bars of up to eight hover-affordance
/// controls each, twice over for two panes, on every layout pass. Measured with
/// `MainThreadHitchMonitor` while opening and closing Settings three times, that search cost 4,805 ms
/// of main-thread work and an 831 ms worst-case stall; cutting the ladder to a single rung took the
/// same interaction to 1,002 ms and 175 ms.
///
/// So the rung is computed instead of searched. Each rung's width is the sum of the widths of the
/// views that draw it (`PaneBarLayout.width(of:controlSize:)`), which makes "which rung fits" plain
/// arithmetic over `PaneNavMetrics`.
///
/// The header still hands the result to `ViewThatFits`, with the narrowest rung behind it as a
/// fallback. That is deliberate: if this arithmetic ever disagrees with the real fit, the layout
/// engine gets the final say and the bar steps down rather than overflowing the pane's trailing
/// edge — which has no loud failure mode and would not be noticed.
struct PaneBarLadder {
    let arrangement: PaneBarArrangement
    let available: [PaneBarItem]
    /// The largest control size the ladder may start from — the icon-size preference is a ceiling,
    /// not a pin, because a bar that overflows the pane is worse than small glyphs.
    let ceiling: ControlSize

    /// The narrowest rung: `.mini` with everything sheddable shed and the view switch compacted.
    /// Every ladder ends here, however long the arrangement.
    let terminal: Int

    init(arrangement: PaneBarArrangement, available: [PaneBarItem], ceiling: ControlSize) {
        self.arrangement = arrangement
        self.available = available
        self.ceiling = ceiling
        // Rung 0 is the ceiling size at depth 0; rung r > 0 is `.mini` at depth r - 1. So the rung
        // that reaches the deepest meaningful fold is one past it.
        self.terminal = PaneBarLayout.maxDepth(arrangement: arrangement, available: available) + 1
    }

    /// Rung 0 is the chosen icon size unfolded; every rung after it is `.mini`, shedding one more
    /// item into ⋯ each step.
    func controlSize(forRung rung: Int) -> ControlSize { rung == 0 ? ceiling : .mini }

    func depth(forRung rung: Int) -> Int { rung == 0 ? 0 : rung - 1 }

    func plan(forRung rung: Int) -> PaneBarLayoutPlan {
        PaneBarLayout.plan(arrangement: arrangement, available: available, depth: depth(forRung: rung))
    }

    func width(forRung rung: Int) -> CGFloat {
        PaneBarLayout.width(of: plan(forRung: rung), controlSize: controlSize(forRung: rung))
    }

    func height(forRung rung: Int) -> CGFloat {
        PaneBarLayout.height(of: plan(forRung: rung), controlSize: controlSize(forRung: rung))
    }

    // MARK: The searched ladder's slots

    /// How many literal children `PaneHeader.searchedLadder` declares, and the deepest ladder they
    /// must cover.
    ///
    /// `ViewThatFits` takes a `ViewBuilder`, and a `ForEach` inside one is a SINGLE child — the
    /// ladder silently collapses to one rung — so the searched path must declare a fixed count of
    /// literal children, whatever the arrangement. That count has to cover the deepest ladder any
    /// arrangement can build: `PaneBarArrangement.maxItems` is 16 and spacers are exempt from the
    /// duplicate rule, so a stored arrangement can carry 15 fixed spaces beside the pinned scan
    /// control — 15 sheddable items, `maxDepth` 15, `terminal` 16. Seventeen slots (rungs 0
    /// through 15, then the terminal) therefore cover every rung of every ladder.
    ///
    /// The previous count was ten, justified by a comment claiming "`terminal` is at most 9 for
    /// any arrangement the palette can build" — false for exactly the spacer-heavy case above, and
    /// the no-provider header jumped from rung 8 straight to full compaction at intermediate
    /// widths. `PaneBarLadderTests.theSearchedSlotsCoverTheDeepestLadderAnyArrangementCanBuild`
    /// pins the arithmetic against the worst arrangement the normalizer permits.
    static let searchedSlotCount = 17

    /// The rung the searched ladder's literal child at `slot` draws. Slots past `terminal` clamp
    /// to it: those children are duplicates of the terminal rung, which `ViewThatFits` walks past
    /// at no behavioural cost — the cost of *building* them is why the searched ladder is reserved
    /// for the rare no-provider header (see `PaneHeader.navCluster`).
    func searchedRung(forSlot slot: Int) -> Int { min(slot, terminal) }

    /// The rung an offer of `width` gets — the first one that fits, mirroring `ViewThatFits`'s own
    /// rule, and the narrowest rung when nothing does.
    ///
    /// *First*, not *narrowest-that-fits*: the ladder is deliberately not monotonic. Shedding the
    /// preview toggle (a segment wide) to gain a ⋯ pill (a full pill, plus its gap) makes the bar
    /// four points **wider**, so that rung can never be chosen — and a search that reordered the
    /// rungs by width would pick a different bar than the one this replaces.
    func rung(fitting width: CGFloat) -> Int {
        for rung in 0...terminal where self.width(forRung: rung) <= width { return rung }
        return terminal
    }
}

/// The drag payloads the customize sheet moves items with, and the rules for applying them.
///
/// This lives in the model rather than in the sheet for one reason: it is the part of drag-and-drop
/// that can be tested. The gestures need a real event loop, so the sheet's own behaviour is only ever
/// verifiable by hand — which makes it exactly the wrong place to also hide index arithmetic and
/// string parsing. Here, every payload shape has a test.
///
/// Each entry point answers with a *new arrangement or nil*, where nil means "this drop changes
/// nothing". The sheet reports that straight back to the drag session, so an item that cannot be
/// placed springs back instead of animating into a bar that did not move.
public enum PaneBarDrop {
    static let barPrefix = "bar:"
    static let palettePrefix = "palette:"

    /// The payload for an item already on the bar, identified by position.
    public static func payload(forItemAt index: Int) -> String { "\(barPrefix)\(index)" }

    /// The payload for a palette tile, identified by item.
    public static func payload(for item: PaneBarItem) -> String { "\(palettePrefix)\(item.rawValue)" }

    /// A drop onto the track at `index` (the slot *before* the item currently at that index).
    public static func applying(_ payloads: [String],
                                at index: Int,
                                to arrangement: PaneBarArrangement) -> PaneBarArrangement? {
        guard let payload = payloads.first else { return nil }
        var next = arrangement
        if let from = barIndex(payload) {
            // No range check here on purpose: `move` refuses an index it does not have, so a stale
            // payload — the bar changed under a drag in flight — falls out as "changed nothing" and
            // is refused below. An explicit guard here was measured to be unreachable: removing it
            // failed no test, because the one underneath it was already doing the work.
            next.move(from: from, to: index)
        } else if let item = paletteItem(payload) {
            next.insert(item, at: index)
        } else {
            return nil
        }
        return next == arrangement ? nil : next
    }

    /// A drag off the bar and back into the palette.
    public static func removing(_ payloads: [String],
                                from arrangement: PaneBarArrangement) -> PaneBarArrangement? {
        guard let payload = payloads.first, let index = barIndex(payload) else { return nil }
        var next = arrangement
        next.remove(at: index)
        return next == arrangement ? nil : next
    }

    private static func barIndex(_ payload: String) -> Int? {
        guard payload.hasPrefix(barPrefix) else { return nil }
        return Int(payload.dropFirst(barPrefix.count))
    }

    private static func paletteItem(_ payload: String) -> PaneBarItem? {
        guard payload.hasPrefix(palettePrefix) else { return nil }
        return PaneBarItem(rawValue: String(payload.dropFirst(palettePrefix.count)))
    }
}

/// The icon-size preference from the bar's right-click menu.
///
/// A **ceiling, not a pin**: the pane may still step below the chosen size when it genuinely cannot
/// fit, because overflowing the trailing edge is worse than smaller glyphs. Choosing Small therefore
/// starts the ladder one rung down rather than freezing it.
public enum PaneBarIconSize: String, CaseIterable, Sendable {
    case regular
    case small

    public var displayName: String { self == .regular ? "Regular" : "Small" }

    /// The largest control size the ladder may start from.
    public var ceiling: ControlSize { self == .regular ? .small : .mini }
}

/// Defaults keys for the bar. One arrangement and one icon size, app-wide — see `PaneBarArrangement`.
public enum PaneBar {
    public static let arrangementKey = "paneBarArrangement"
    public static let iconSizeKey = "paneBarIconSize"
}

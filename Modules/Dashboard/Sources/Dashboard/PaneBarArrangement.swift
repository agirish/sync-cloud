import Design
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
    /// Appended LAST, per the rule above — the raw values are persisted, so an existing bar keeps
    /// every item it had. A stored arrangement predates this case and therefore does not carry it,
    /// which is what `PaneBarMigration` exists to correct; ⋯ does not, because ⋯ carries only what
    /// this rung folded. ⌘F opens the field either way, so a bar without it is a bar missing a
    /// button, not an ability.
    case search
    /// Appended last, per the rule above, and deliberately NOT added to `PaneBarMigration`.
    ///
    /// Search's migration exists because a discoverable affordance was landing invisible for
    /// everyone who had ever opened the customize sheet. That reasoning does not transfer to a
    /// destructive control: pushing Delete onto a bar someone arranged is the thing that mechanism
    /// makes possible, not the thing it exists to do. So a bar arranged before this case simply
    /// does not carry it — and does not offer it in ⋯ either, since ⋯ stopped standing in for a
    /// bar someone had not opted into. The row menu's Delete and ⌘⌫ were reaching the same act all
    /// along, which is why this control can afford to wait to be added deliberately.
    case delete

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
        case .search: return "Search"
        case .delete: return "Delete"
        }
    }

    /// The word drawn under this item's pill in `PaneBarLabelMode.iconAndText`.
    ///
    /// Separate from `displayName`, which the palette and the ⋯ menu keep, because a menu row has
    /// the width for "Collapse Pane" (43pt of text) and a 33pt pill does not. The two describe the
    /// same control at two lengths; neither is a translation of the other.
    ///
    /// **A title says what the control IS, not what state it is in.** Hidden Files keeps one word
    /// while its eye swaps open and slashed, because the glyph is what carries the state and a word
    /// that changed with it would say the same thing twice — and, being measured type, would move
    /// every item to its left on each click. Scan is the exception that proves the rule: mid-scan
    /// the control is a different *act*, not the same act in a different state, so `ScanRungMode`
    /// supplies "Stop" in place of this. See `titleVariants`.
    public var barTitle: String {
        switch self {
        case .viewMode: return "View"
        case .collapse: return "Collapse"
        case .backForward: return "Back/Forward"
        case .scan: return "Scan"
        case .newFolder: return "New Folder"
        case .sort: return "Sort"
        case .hiddenFiles: return "Hidden"
        case .preview: return "Preview"
        case .space, .flexibleSpace: return ""
        case .search: return "Search"
        case .delete: return "Delete"
        }
    }

    /// Every title this item can ever draw, so the ladder can reserve the widest of them.
    ///
    /// A bar item is as wide as the wider of its pill and its word, so an item whose word changes
    /// could change width under the cursor and shift everything to its left. Today it cannot —
    /// "Scan" is 24.5pt and "Stop" 23pt, both inside the 33pt pill, so the reservation costs
    /// nothing. It exists so that a longer pair chosen later is absorbed by the layout instead of
    /// introducing that movement silently.
    public var titleVariants: [String] {
        self == .scan ? [barTitle, ScanRungMode.stopTitle] : [barTitle]
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
        case .search: return "magnifyingglass"
        case .delete: return "trash"
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
/// Shared by both Compare panes and the single-source rail — one arrangement, because the point of Compare's
/// side-by-side layout is that the two panes read as the same instrument pointed at two providers.
/// What stays per-pane is *state* (provider, hue wash, breadcrumb, whether Back is enabled), not the
/// arrangement.
public struct PaneBarArrangement: Equatable, Sendable {
    public private(set) var items: [PaneBarItem]

    /// A ceiling on how long a bar can get. Not a UI limit anyone will hit with the palette — it
    /// bounds what a corrupt or hand-edited defaults value can do to the layout ladder.
    ///
    /// Load-bearing beyond that: the ladder's depth is bounded BY this number, and the searched
    /// ladder in `PaneHeader` must declare a literal child per rung. `PaneBarLadder.searchedSlotCount`
    /// derives itself from this constant for that reason — raise it and the view is short a rung,
    /// which is a silent layout hole, so `PaneBarLadderTests` counts the view's children against it.
    public static let maxItems = 16

    /// A flexible space (which is what pins the rest to the trailing edge), then the controls in the
    /// order they have always been drawn, with Search at the trailing end.
    ///
    /// This is load-bearing. An untouched install must render pixel-for-pixel what it rendered
    /// before the bar became arrangeable — `PaneHeaderHeightTests` and the 250pt snapshots assert
    /// exactly that, and they are the regression net for that change.
    ///
    /// Search joining the list does not disturb them, and the reason is worth stating: an item only
    /// reaches the bar if the HOST offers it (`resolved(available:)`), and a header with no search
    /// bindings does not. Every existing caller — the two header tests, the snapshots, the ladder
    /// suite — therefore builds precisely the bar it built before. Only the app's own panes, which
    /// do pass bindings, gain the pill.
    ///
    /// Trailing end, and deliberately: it is where `ExpandingSearchToggle` sits on every other
    /// surface in the app, and the shedding order is right-to-left — so the narrowest pane gives up
    /// the magnifier first, which is the one control here that has a keyboard equivalent.
    /// Delete joins on the same terms Search did, and the same sentence above covers it: a header
    /// that passes no delete handler does not offer it, so every existing caller still builds
    /// precisely the bar it built before. It sits before Search rather than after because the
    /// shedding order is right-to-left and the magnifier is the one control here with a keyboard
    /// equivalent — Delete's own chord (⌘⌫) is Compare-only, so it is not the cheapest to lose.
    public static let `default` = PaneBarArrangement([
        .flexibleSpace, .viewMode, .collapse, .backForward, .scan, .newFolder, .sort, .hiddenFiles,
        .preview, .delete, .search
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

    // `absent(from:)` used to live here: the available items this bar does not carry, appended to
    // every ⋯ so that "a removal costs a pill and never an ability". It is gone, and with it that
    // rule — see `PaneBarLayout.plan`. Nothing replaced it, because nothing needs to: the customize
    // sheet's palette offers every removable control from `PaneBarCustomizeSheet.palette`, which is
    // where a control you took off is got back from.

    /// The arrangement restricted to what this host can actually offer — a header with no view-mode
    /// binding has no View control to place, and the single-source rail has no Columns mode to preview.
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
    ///
    /// **The overflow is what this rung folded, and nothing else.** It used to also carry every
    /// available control the arrangement did not place — "a removal costs a pill and never an
    /// ability" — and that made ⋯ two menus wearing one glyph: controls the pane is too narrow to
    /// draw, and controls you had deliberately taken off the bar. The second half handed back what
    /// the customize sheet had just been used to remove, so removing a control did not remove it;
    /// it only moved it somewhere less convenient than where it had been.
    ///
    /// The cost of dropping it, stated plainly: a control that ships in a later release is absent
    /// from every stored arrangement and now lands **nowhere** rather than in ⋯. `PaneBarMigration`
    /// is what puts it on the bar, and it is no longer a special measure for a headline affordance —
    /// it is the only route a new control has to a bar someone has customized. See `PaneBarItem`'s
    /// `delete` for the one case that deliberately declines it, and why it can afford to.
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
                                 overflow: folded,
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
        // Search draws the same plain nav pill as its neighbours rather than Design's
        // `ExpandingSearchToggle`, which sizes itself from a bare 13pt glyph. A pill among pills is
        // what the bar looks like, and it keeps this arithmetic one line instead of a second opinion
        // about a glyph's intrinsic width.
        case .collapse, .scan, .newFolder, .sort, .hiddenFiles, .search, .delete:
            return pill.width
        }
    }

    /// The width of one item once its title is taken into account.
    ///
    /// An item is as wide as **the wider of its pill and its word** — most words are narrower than
    /// the 33pt pill and cost nothing at all ("Sort" is 21pt, "Delete" 32pt); only New Folder,
    /// Preview, Search, Hidden and the Back/Forward pair are ever the binding half.
    ///
    /// The widest of `titleVariants`, not the current title: see there for why an item whose word
    /// can change reserves room for the longest of them.
    @MainActor
    static func titledWidth(of item: PaneBarItem, pill: CGSize, compactsViewMode: Bool,
                            scale: CGFloat) -> CGFloat {
        let base = width(of: item, pill: pill, compactsViewMode: compactsViewMode)
        guard !item.isSpacer else { return base }
        let widest = item.titleVariants
            .map { LabelMetrics.width(of: $0, font: PaneBarTitleMetrics.font, scale: scale) }
            .max() ?? 0
        return max(base, widest)
    }

    /// The laid-out width of a whole rung, gaps and ⋯ included.
    ///
    /// This is the number `ViewThatFits` used to discover by building the rung and measuring it. It
    /// is arithmetic now because building ten candidate bars per layout pass, twice per window, was
    /// the pane header's dominant main-thread cost.
    ///
    /// `titled` prices the same rung with a word under every pill. The ⋯ is deliberately *not*
    /// widened by it: it takes no title (Finder labels its Action menu, but our analogue is
    /// Finder's unlabelled `»` overflow), so it stays a pill wide in both modes.
    @MainActor
    /// `titled` has **no default**, deliberately. It used to, and while the gap was one constant
    /// that was harmless — every rung was priced identically. Now that the gap depends on it, a
    /// caller that forgets the argument prices a titled bar's 8pt gaps at 6 with no type error and
    /// no loud symptom (the bar over-compacts, or overruns its trailing edge). One production
    /// caller exists, `PaneBarLadder.width(forRung:)`; requiring the argument turns the whole class
    /// of mistake into a compile error rather than a layout that is quietly a few points wrong.
    public static func width(of plan: PaneBarLayoutPlan, controlSize: ControlSize,
                             titled: Bool, scale: CGFloat = 1) -> CGFloat {
        let pill = PaneNavMetrics.pill(controlSize)
        var total: CGFloat = 0
        for (index, item) in plan.visible.enumerated() {
            if needsGap(before: index, in: plan.visible) { total += PaneNavMetrics.itemGap(titled: titled) }
            total += titled
                ? titledWidth(of: item, pill: pill, compactsViewMode: plan.compactsViewMode,
                              scale: scale)
                : width(of: item, pill: pill, compactsViewMode: plan.compactsViewMode)
        }
        if !plan.overflow.isEmpty {
            if plan.visible.last.map({ $0 != .flexibleSpace }) ?? false { total += PaneNavMetrics.itemGap(titled: titled) }
            total += pill.width
        }
        return total
    }

    /// The tallest thing on a rung.
    ///
    /// Every control is exactly a pill tall, the view switch included. It used to be 6pt taller —
    /// its two segments sat on a ground with `segmentPadding` on *all four* edges — and nothing
    /// showed it, because the 34pt provider capsule sets the header's row height and a resting
    /// pill is barely tinted. Titles are what made it matter: a title hangs on a baseline below its
    /// control, so a 26pt switch put its word 6pt below every other word and took the row to 40pt,
    /// over the 34pt budget.
    ///
    /// The ground stays; its *vertical* padding is what went (see `PaneHeader.viewModeSwitch`).
    /// Finder's toolbar is the precedent — its segmented controls are not taller than its plain
    /// ones, every ground is one height and every title sits on one baseline. Applied in both
    /// modes, because the switch out-topping its neighbours is an inconsistency that predates
    /// titles rather than one they introduce.
    @MainActor
    public static func height(of plan: PaneBarLayoutPlan, controlSize: ControlSize,
                              titled: Bool = false, scale: CGFloat = 1) -> CGFloat {
        let pill = PaneNavMetrics.pill(controlSize)
        return titled
            ? PaneBarTitleMetrics.rowHeight(pillHeight: pill.height, scale: scale)
            : pill.height
    }
}

/// The pane bar's narrow-pane ladder: every layout the bar can step down through, widest first, and
/// the arithmetic that says which one a given width gets.
///
/// The header used to hand every rung to `ViewThatFits` and let it search. That works, but
/// `ViewThatFits` *builds every child to measure it* — ten full bars of up to eight hover-affordance
/// controls each, twice over for two panes, on every layout pass. Measured with
/// `MainThreadHitchMonitor` while opening and closing Settings three times, that search cost 4,805 ms
/// of main-thread work and an 831 ms worst-case stall; cutting the ladder to a single rung took the
/// same interaction to 1,002 ms and 175 ms.
///
/// The provider-less header still searches — it has no computed rung to hand over (see
/// `PaneHeader.searchedLadder`) — but it builds a bar only for the rungs that differ, which is the
/// same lesson applied to the case that cannot take the same cure.
///
/// So the rung is computed instead of searched. Each rung's width is the sum of the widths of the
/// views that draw it (`PaneBarLayout.width(of:controlSize:)`), which makes "which rung fits" plain
/// arithmetic over `PaneNavMetrics`.
///
/// The header still hands the result to `ViewThatFits`, with the narrowest rung behind it as a
/// fallback. That is deliberate: if this arithmetic ever disagrees with the real fit, the layout
/// engine gets the final say and the bar steps down rather than overflowing the pane's trailing
/// edge — which has no loud failure mode and would not be noticed.
@MainActor
struct PaneBarLadder {
    let arrangement: PaneBarArrangement
    let available: [PaneBarItem]
    /// The largest control size the ladder may start from — the icon-size preference is a ceiling,
    /// not a pin, because a bar that overflows the pane is worse than small glyphs.
    let ceiling: ControlSize
    /// The app's text scale, which prices the titled rung. Constant arithmetic priced every rung
    /// before titles existed, because a glyph pill is a published constant; a word is measured type
    /// and the app scales its own.
    let scale: CGFloat

    /// How many rungs at the head of the ladder draw titles: 1 when the preference asks for them
    /// *and* the row fits this text size, 0 otherwise.
    ///
    /// Zero restores exactly the ladder that shipped before titles — same rungs, same widths, same
    /// arithmetic — which is what makes `iconOnly` and Large text free of regression risk rather
    /// than merely tested for it.
    let titledRungs: Int

    /// The narrowest rung: `.mini` with everything sheddable shed and the view switch compacted.
    /// Every ladder ends here, however long the arrangement.
    let terminal: Int

    init(arrangement: PaneBarArrangement, available: [PaneBarItem], ceiling: ControlSize,
         labelMode: PaneBarLabelMode = .iconOnly, scale: CGFloat = 1) {
        self.arrangement = arrangement
        self.available = available
        self.ceiling = ceiling
        self.scale = scale
        // The gate. `iconAndText` is a ceiling, not a pin: it asks for titles, and they appear only
        // if the row they need fits the header the bar lives in.
        self.titledRungs = (labelMode == .iconAndText
                            && PaneBarTitleMetrics.rowFits(pillHeight: PaneNavMetrics.pill(ceiling).height,
                                                           scale: scale)) ? 1 : 0
        // Rung 0 is the ceiling size at depth 0; rung r > 0 is `.mini` at depth r - 1, shifted by
        // the titled rung when there is one. So the rung that reaches the deepest meaningful fold
        // is one past it.
        self.terminal = PaneBarLayout.maxDepth(arrangement: arrangement, available: available)
            + 1 + titledRungs
    }

    /// Whether this rung draws a word under each pill. Only the head of the ladder does: titles
    /// shed **all together as one rung**, ahead of the step down to `.mini`, because a bar where
    /// some items are words and others are glyphs reads as two controls — the rule
    /// `WorkspaceBarMetrics` already applies for the same reason.
    func isTitled(forRung rung: Int) -> Bool { rung < titledRungs }

    /// Rung 0 is the chosen icon size unfolded; every rung after the untitled one at the ceiling is
    /// `.mini`, shedding one more item into ⋯ each step.
    func controlSize(forRung rung: Int) -> ControlSize {
        rung <= titledRungs ? ceiling : .mini
    }

    func depth(forRung rung: Int) -> Int { max(0, rung - titledRungs - 1) }

    func plan(forRung rung: Int) -> PaneBarLayoutPlan {
        PaneBarLayout.plan(arrangement: arrangement, available: available, depth: depth(forRung: rung))
    }

    func width(forRung rung: Int) -> CGFloat {
        PaneBarLayout.width(of: plan(forRung: rung), controlSize: controlSize(forRung: rung),
                            titled: isTitled(forRung: rung), scale: scale)
    }

    func height(forRung rung: Int) -> CGFloat {
        PaneBarLayout.height(of: plan(forRung: rung), controlSize: controlSize(forRung: rung),
                             titled: isTitled(forRung: rung), scale: scale)
    }

    // MARK: The searched ladder's slots

    /// How many literal children `PaneHeader.searchedLadder` declares, and the deepest ladder they
    /// must cover.
    ///
    /// `ViewThatFits` takes a `ViewBuilder`, and a `ForEach` inside one is a SINGLE child — the
    /// ladder silently collapses to one rung — so the searched path must declare a fixed count of
    /// literal children, whatever the arrangement. That count has to cover the deepest ladder any
    /// arrangement can build, which is `maxItems + 1`, **derived** rather than restated so that
    /// raising `maxItems` cannot silently leave the ladder short:
    ///
    /// `maxDepth` counts sheddable items, plus one if the view switch is placed (it compacts as the
    /// last step). Spacers are exempt from the duplicate rule, so the longest ladder is a bar of
    /// fixed spaces — but a `maxItems`-long arrangement can never be *all* sheddable spaces: the
    /// normalizer forces `scan` on, which is floor (unsheddable) and displaces a space when the bar
    /// is full, and if the host cannot offer `scan` it is filtered back out of the resolved bar
    /// instead. Either way at most `maxItems - 1` items shed, so `maxDepth <= maxItems - 1` and
    /// `terminal <= maxItems + titledRungs`. Slots run rung 0 through the terminal.
    ///
    /// The previous count was ten, justified by a comment claiming "`terminal` is at most 9 for
    /// any arrangement the palette can build" — false for exactly the spacer-heavy case above, and
    /// the no-provider header jumped from rung 8 straight to full compaction at intermediate
    /// widths. `PaneBarLadderTests` pins both halves of the contract: the arithmetic against the
    /// worst arrangement the normalizer permits, and this count against the number of children
    /// `PaneHeader.searchedLadder` actually declares.
    ///
    /// **`+ 2`, not `+ 1`, since titles.** `titledRungs` adds at most one rung at the head, so the
    /// deepest ladder any arrangement and any preference can build is one longer than it was. Get
    /// this wrong and there is no error: the searched ladder is simply short a rung, and the
    /// provider-less header jumps from a mid rung straight to full compaction at intermediate
    /// widths — which is exactly the silent hole the ten-child version had.
    static let searchedSlotCount = PaneBarArrangement.maxItems + 2

    /// The rung the searched ladder's literal child at `slot` draws. Slots past `terminal` clamp
    /// to it — `PaneBarLayout.plan` is idempotent past `maxDepth`, so they are duplicates of the
    /// terminal rung.
    func searchedRung(forSlot slot: Int) -> Int { min(slot, terminal) }

    /// Whether the searched ladder's child at `slot` has to be a real bar.
    ///
    /// Slots up to `terminal` each draw a different rung, so they do. Past it they would redraw the
    /// terminal rung, and building a bar to measure it is the whole cost of this path — so those
    /// slots become inert stand-ins instead (see `searchedSlotIsInert` for why that is safe).
    ///
    /// The **last** slot is always a real bar: `ViewThatFits` renders its last child when nothing
    /// fits at all, which is the 250pt pane's case, and that fallback must be the terminal bar
    /// rather than a hole.
    func searchedSlotDrawsBar(_ slot: Int) -> Bool {
        slot <= terminal || slot == Self.searchedSlotCount - 1
    }

    /// Why an inert slot is unreachable, expressed as the property that makes it so: a stand-in has
    /// exactly the terminal rung's width, and slot `terminal` — a real bar of that same width —
    /// sits ahead of it. `ViewThatFits` takes the FIRST child that fits, so any offer wide enough
    /// for a stand-in was already taken by that bar, and any offer too narrow for it falls through
    /// to the last child, which is real. No offered width can select one.
    func searchedSlotIsInert(_ slot: Int) -> Bool { !searchedSlotDrawsBar(slot) }

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

/// Whether the bar draws a word under each pill — the second preference in its right-click menu.
///
/// **A ceiling, not a pin**, exactly as `PaneBarIconSize` is. Choosing `iconAndText` says "start
/// here": the bar still drops to `iconOnly` when the pane is too narrow for the titled rung, or
/// when the app's text size makes the titled row taller than the pinned header can hold (see
/// `PaneBarTitleMetrics.rowFits`). Choosing `iconOnly` pins downward — no width ever produces a
/// title.
///
/// Two cases, where Finder has three. Text Only is deliberately absent: with the glyph gone the
/// word becomes the only carrier of state, which forces Hidden Files' title to swap with its eye
/// and makes an item's width change on click. The two modes here keep the glyph as the state
/// carrier in every case, and the mode is additive if a third is ever wanted.
public enum PaneBarLabelMode: String, CaseIterable, Sendable {
    case iconAndText
    case iconOnly

    public var displayName: String {
        self == .iconAndText ? "Icon and Text" : "Icon Only"
    }
}

/// The type the bar's titles are drawn in, and the row budget they have to fit.
public enum PaneBarTitleMetrics {
    /// The title's base point size.
    ///
    /// 10pt, and the reason is the row rather than legibility: a titled row is the pill (20pt), a
    /// 2pt gap and one line of title, against the **34pt** the pinned 81pt pane header allows —
    /// and 10pt is the largest size whose line height (12.0) fits that. 11pt measures 13.0 for a
    /// 35pt row and 12pt measures 15.0 for 37pt, both of which break the 83.5 line the header
    /// shares with Organize's `LensHeaderCard`.
    public static let pointSize: CGFloat = 10
    /// Between the pill's bottom edge and the title's line box.
    public static let gap: CGFloat = 2
    /// What the pinned 81pt pane header leaves the bar's row. Matches the provider capsule's own
    /// 34pt, which is what sets the row height today.
    public static let rowBudget: CGFloat = 34

    public static let font: ScaledFont = .system(size: pointSize, weight: .regular)

    /// The height a titled row occupies at this text size.
    @MainActor
    public static func rowHeight(pillHeight: CGFloat, scale: CGFloat) -> CGFloat {
        pillHeight + gap + LabelMetrics.lineHeight(font: font, scale: scale)
    }

    /// Whether titles can be drawn at all at this text size.
    ///
    /// **This is the gate that keeps the feature off Large and Larger.** `pointSize` sits below
    /// `FontSize.knee` (11pt), so it takes the *full* multiplier, while `PaneNavMetrics.pill` is a
    /// fixed constant that does not scale: at ×1.25 the row is 37pt and at ×1.35 it is 38pt,
    /// against a 34pt budget. Clamping the title instead was rejected — someone who chose Larger
    /// did so because small text is hard to read, and a title that alone refuses to grow serves
    /// them worst of all. Falling back to `iconOnly` gives them exactly the bar that ships today.
    @MainActor
    public static func rowFits(pillHeight: CGFloat, scale: CGFloat) -> Bool {
        rowHeight(pillHeight: pillHeight, scale: scale) <= rowBudget
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
    /// Whether the bar draws words under its pills. App-wide, like the two above — Compare's two
    /// panes and the rail are one instrument pointed at different providers, so a bar that read
    /// differently on each side would be two instruments.
    public static let labelModeKey = "paneBarLabelMode"
    /// How far a stored arrangement has been brought forward — see `PaneBarMigration`.
    public static let migrationKey = "paneBarArrangementMigration"
}

/// Brings a bar someone arranged on an earlier build forward when a NEW control ships.
///
/// **Why this exists, stated as the thing it fixes.** The bar used to have a fallback: an available
/// control the arrangement did not place was appended to ⋯, so a new control at least landed
/// somewhere. That was right for a control someone can go and find and wrong for a headline one —
/// Search shipped as the answer to "the trees have no search", and for everybody who had ever
/// opened the customize sheet it landed permanently inside an overflow menu on a bar with visible
/// empty space: the affordance was there, and invisible. Reported from a real window, which is the
/// only reason it was caught: every test used a fresh default arrangement, where the item is
/// present and the bug cannot occur.
///
/// **That fallback is now gone** — ⋯ carries only what the rung folded, see `PaneBarLayout.plan` —
/// which makes this mechanism load-bearing rather than corrective. A control added to
/// `PaneBarArrangement.default` without a step below reaches a customized bar through **no route at
/// all** until its owner opens the customize sheet and drags it on, and nothing anywhere will say
/// so. Adding the step is not a judgement call about how discoverable the control deserves to be;
/// declining it is, and `PaneBarItem.delete` is the one case that declined deliberately, on the
/// strength of having two other routes to the same act.
///
/// **Why it is not just "always restore Search like `scan`".** `PaneBarArrangement.init` re-adds
/// `scan` unconditionally, which is right for the one control that must never be missing. Doing that
/// here would make Search unremovable — a bar item that grows back is worse than one that never
/// appeared, because the user can see they are being overruled.
///
/// So it runs ONCE per added control, recorded by a stored version. Remove Search after the
/// migration and it stays removed; that is the whole point of stamping rather than checking.
public enum PaneBarMigration {
    /// Bump this — and add a step below — whenever a control joins `PaneBarArrangement.default`.
    public static let currentVersion = 1

    /// Applies every migration a stored arrangement has not had yet, and records how far it got.
    ///
    /// A pane bar that was never customized has no stored arrangement at all and reads the default,
    /// which already carries every control; it is stamped anyway, so this never runs again for it
    /// and a later deliberate removal is not undone by the next launch.
    ///
    /// The version stamp is written in a `defer`, so it lands on **every** path out — including the
    /// early return for a bar that needed nothing. Written before the work (as it first was) it
    /// would record a migration that a crash could still prevent; written only on the success path
    /// it would re-run forever for the bars it correctly left alone.
    ///
    /// - Returns: whether a stored arrangement was actually REWRITTEN — not merely whether the
    ///   migration ran. That is what a caller should log: "moved someone's bar" is worth a line,
    ///   "had nothing to do" is not.
    @discardableResult
    public static func apply(defaults: UserDefaults) -> Bool {
        let from = defaults.integer(forKey: PaneBar.migrationKey)   // 0 when never stamped
        guard from < currentVersion else { return false }
        defer { defaults.set(currentVersion, forKey: PaneBar.migrationKey) }

        // `false`, not `true`: there is no stored arrangement, so nothing was rewritten. Returning
        // `true` here made the app log "added Search to a stored pane-bar arrangement" on the first
        // launch of EVERY install that had never customized its bar — the common case — about an
        // arrangement that does not exist, in the log file a launch is verified through.
        guard let stored = defaults.string(forKey: PaneBar.arrangementKey) else { return false }
        var arrangement = PaneBarArrangement(encoded: stored)
        let before = arrangement.items
        // v1 — Search. Appended at the trailing end, where the default carries it and where the
        // ladder gives it up first.
        if from < 1, !arrangement.items.contains(.search) {
            arrangement.insert(.search, at: arrangement.items.count)
        }
        // **Compared, not assumed.** This used to set a `changed` flag beside the `insert` call, and
        // `PaneBarArrangement.insert` is allowed to refuse: a bar already at `maxItems` — reachable,
        // because spacers are repeatable — gets nothing, silently. The flag then reported a
        // migration that had not happened and wrote the arrangement back unchanged. Reading the
        // items is the only thing that knows.
        guard arrangement.items != before else { return false }
        defaults.set(arrangement.encoded, forKey: PaneBar.arrangementKey)
        return true
    }
}

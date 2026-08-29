import Design
import Events
import SwiftUI

/// One thing that can sit on a pane's bar.
///
/// The bar used to be a hard-coded `HStack` welded to the trailing edge by `margin-left: auto`'s
/// SwiftUI equivalent (a `Spacer` outside it), which meant no control could ever move left. It is now
/// a *track* running the full width of the pane, and this is its alphabet:
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

    /// **The pane-collapse glyph, in one place because it was in three and had to stop being
    /// `sidebar.left`.**
    ///
    /// That is the glyph the window's own sidebar toggle wears (`ContentView+Toolbar`'s Sidebar
    /// item), and once the folder sidebar shipped the two sat about forty points apart down the
    /// same edge, wearing the same mark for two different acts: one shows the folder column, the
    /// other folds this pane back into the spine. Reported 2026-08-29 as exactly that confusion.
    ///
    /// **Not a plain `chevron.left`**, which is what a "<" would be — the Back button is `chevron.left`
    /// and it is the pill immediately to the right of this one, so that trade swaps a collision at
    /// forty points for one at eight. `arrow.left.to.line` keeps the leftward reading, says which
    /// edge the pane folds into, and shares its silhouette with neither neighbour.
    public static let collapseSymbol = "arrow.left.to.line"

    /// The palette tile's glyph. Paired items (View, Back/Forward) draw the first of their pair here;
    /// the bar itself draws both.
    public var paletteSymbol: String {
        switch self {
        case .viewMode: return "rectangle.split.3x1"
        case .collapse: return PaneBarItem.collapseSymbol
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

    /// Tokens in the stored string that no case of THIS build's `PaneBarItem` names — a newer
    /// build's controls, seen after a downgrade. Never drawn, never offered, never counted against
    /// `maxItems`; their whole job is to ride through `encoded` so that the customize sheet's
    /// write-back does not destroy them. Without this, `init(encoded:)`'s downgrade-survival
    /// promise held only until the first edit: `PaneBarCustomizeSheet.commit` writes the re-encoded
    /// arrangement over the stored one, so downgrade → edit → re-upgrade silently lost whatever the
    /// older build could not name. Carried at the tail rather than in place — the known items get
    /// inserted, removed and reordered, so original positions stop meaning anything the moment the
    /// sheet is used, and the newer build's own normalizer re-places them on the next read.
    ///
    /// Bounded like `items`: a corrupt or hand-edited value does not get to smuggle an unbounded
    /// payload that every later write faithfully re-persists.
    private var unknownTokens: [String] = []

    /// A ceiling on how long a bar can get. Not a UI limit anyone will hit with the palette — it
    /// bounds what a corrupt or hand-edited defaults value can do to the layout ladder.
    ///
    /// Load-bearing beyond that: the ladder's depth is bounded BY this number.
    ///
    /// It used to be load-bearing in a sharper way — `PaneHeader` searched its ladder with a
    /// `ViewThatFits`, which needs one *literal* child per rung, so a `searchedSlotCount` derived
    /// from this constant had to match the view's literal count or the ladder was silently short a
    /// rung. Both are gone: the header computes its rung at every width now, and a computed rung has
    /// no count to keep in step.
    public static let maxItems = 16

    /// The controls in the order they have always been drawn, with Search at the trailing end,
    /// **packed against the leading edge**.
    ///
    /// It opened with a `flexibleSpace`, and that space was the whole of what pinned the bar to the
    /// trailing edge. It existed because the provider capsule held the leading one. With the capsule
    /// retired the bar has the row to itself, and a leading space would park every control against
    /// the far edge of an otherwise empty track — so it goes, and the bar starts where the
    /// breadcrumb below it starts.
    ///
    /// **Only the default.** A stored arrangement is read back verbatim, space and all: that list is
    /// the user's answer to this question, not this one, and `PaneBarMigrationTests` pins that a
    /// customized bar is not rewritten by a change to the shipped default.
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
        .viewMode, .collapse, .backForward, .scan, .newFolder, .sort, .hiddenFiles,
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
    /// their bar is. Unknown tokens this arrangement is carrying (see `unknownTokens`) are appended
    /// after the items, so a downgrade's edits round-trip them back to disk.
    public var encoded: String { (items.map(\.rawValue) + unknownTokens).joined(separator: ",") }

    /// Unknown tokens are dropped from the BAR, not rejected — and carried through `encoded`, not
    /// discarded: both halves are what make a bar arranged on a newer build survive a downgrade
    /// instead of resetting to the default. Dropping them from the bar alone only survived the
    /// *reading*; the first edit on the older build wrote the pruned list back, and the newer
    /// build's control was gone for good.
    public init(encoded: String) {
        let tokens = encoded.split(separator: ",").map(String.init)
        self.init(tokens.compactMap { PaneBarItem(rawValue: $0) })
        unknownTokens = Array(tokens.filter { PaneBarItem(rawValue: $0) == nil }.prefix(Self.maxItems))
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
    /// showed it, because a 34pt provider capsule stood beside the bar and set the header's row
    /// height while a resting pill is barely tinted. Titles are what made it matter: a title hangs on
    /// a baseline below its control, so a 26pt switch put its word 6pt below every other word and
    /// took the row to 40pt, over the 34pt budget. The capsule is retired and the bar is alone on
    /// its row now — which means this arithmetic is no longer merely tidy, it is what the row's own
    /// reservation is computed from (`PaneHeader.tallestRungHeight`).
    ///
    /// The ground stays; its *vertical* padding is what went (see `PaneHeader.viewModeSwitch`).
    /// Finder's toolbar is the precedent — its segmented controls are not taller than its plain
    /// ones, every ground is one height and every title sits on one baseline. Applied in both
    /// modes, because the switch out-topping its neighbours is an inconsistency that predates
    /// titles rather than one they introduce.
    ///
    /// `titled` has **no default**, for the reason `width(of:)` lost its own: a caller that forgets
    /// the argument prices a titled row at bare pill height — no type error and no loud symptom,
    /// just a row measured short of the words it is drawing, which is a clipped title or a header
    /// that thinks it has room it does not. One production caller exists,
    /// `PaneBarLadder.height(forRung:)`; requiring the argument turns the whole class of mistake
    /// into a compile error rather than a layout that is quietly wrong.
    @MainActor
    public static func height(of plan: PaneBarLayoutPlan, controlSize: ControlSize,
                              titled: Bool, scale: CGFloat = 1) -> CGFloat {
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
/// The provider-less header kept searching for a while after that, on the reasoning that it had no
/// computed rung to hand over: with no provider capsule to be the taller thing in the row, the bar
/// was the row's own height authority, and a container pinned to one rung's height would report the
/// wrong height for every other rung. Reserving the TALLEST rung instead of the narrowest removed
/// that, and the branch went with it — measured first, across 250-900pt at three text sizes: the
/// two paths pick the same rung in all 81 cases, and the computed one holds the bar's top edge
/// steady where the searched one let it walk 9pt as the pane widened.
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
    /// What the pinned 81pt pane header leaves the bar's row. It matched the retired provider
    /// capsule's own 34pt, which used to be what set the row height; with the capsule gone the bar
    /// sets its own, and this is the ceiling that says how tall it may go.
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

    // MARK: The routes a shipped control has onto a customized bar
    //
    // Three sets, and between them they must account for **every non-spacer control in
    // `PaneBarArrangement.default`**. That accounting is the thing nothing used to do: the hazard
    // this type's own doc states — a control added to the default bar with no step here reaching a
    // customized bar through no route at all — was written down and bound to nothing, so the next
    // control to ship could reproduce Search's bug in silence. `PaneBarMigrationTests` derives the
    // expected set from `PaneBarArrangement.default` and names any control that belongs to none of
    // them; `everyControlTheMigrationClaimsToPlaceActuallyLands` keeps `migratedControls` honest by
    // running the migration rather than trusting the list.

    /// Controls that shipped on the bar **before this mechanism existed**.
    ///
    /// Every stored arrangement was written by a build that already offered these, so a bar without
    /// one of them is a bar someone arranged that way — not an affordance that never had a route.
    /// That is the whole difference between this set and the two below.
    ///
    /// **A frozen historical record, and it must never grow.** A control that ships from now on
    /// takes a migration step or declines one deliberately; parking it here would be claiming a
    /// route it never had, which is why the test pins these eight by name rather than reading them.
    public static let baselineControls: Set<PaneBarItem> = [
        .viewMode, .collapse, .backForward, .scan, .newFolder, .sort, .hiddenFiles, .preview
    ]

    /// Controls a step in `apply` puts onto a stored bar.
    ///
    /// A claim, not a mechanism — the steps are in `apply` and this list could disagree with them.
    /// It is bound to them behaviourally, one migration run per control, so it cannot.
    public static let migratedControls: Set<PaneBarItem> = [.search]

    /// Controls that ship on the default bar and **deliberately decline** a step.
    ///
    /// Declining is the judgement call (adding a step is the default), so the members are named
    /// here and named again in the test — a new control cannot join this list by accident, only by
    /// someone editing both places and saying why. `delete` is the one member and the reasoning is
    /// on the case itself: the row menu's Delete and ⌘⌫ reach the same act, so it can afford to
    /// wait to be added deliberately.
    public static let declinedControls: Set<PaneBarItem> = [.delete]

    /// The three routes taken together — the set a shipped control must belong to.
    ///
    /// Named because two things read it and one of them is a test: `PaneBarMigrationTests` asserts
    /// this is *exactly* the default bar's non-spacer controls, which is the whole accounting in one
    /// comparison. Both directions matter — a control on the bar and on no route is the hazard, and
    /// a control on a route but not on the bar is a claim about something that does not ship.
    static var routedControls: Set<PaneBarItem> {
        baselineControls.union(migratedControls).union(declinedControls)
    }

    /// Controls that ship on the default bar and reach a customized bar through **no route at all**.
    ///
    /// Empty in a correct build. Non-empty means someone added a case to `PaneBarArrangement.default`
    /// and stopped there, and the symptom is a control nobody who has ever opened the customize
    /// sheet will see — the exact shape of Search's original bug, minus the ⋯ consolation that made
    /// it recoverable.
    public static var controlsWithoutARoute: [PaneBarItem] {
        controlsWithoutARoute(shipping: .default, routed: routedControls)
    }

    /// The same derivation with both inputs handed in, which is the only way to prove it derives
    /// anything.
    ///
    /// In a correct build every shipped control is on a route, so the property above can only ever
    /// be checked against empty — and a version of it that had been mutated to `return []` would
    /// answer every such check correctly while leaving the runtime warning permanently dead. Feed
    /// this an empty `routed` and it must name the whole bar; that is what says it is computing.
    /// The spacer exemption is exercised by the same call: spacers are layout, and a bar without one
    /// is not missing an ability anybody could go looking for.
    static func controlsWithoutARoute(shipping arrangement: PaneBarArrangement,
                                      routed: Set<PaneBarItem>) -> [PaneBarItem] {
        arrangement.items.filter { !$0.isSpacer && !routed.contains($0) }
    }

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
    /// **What the resulting bar cannot show is reported elsewhere** — see
    /// `reportStoredArrangementReach`, which the app delegate calls once per launch. It used to be
    /// a `defer` on this function, and that was wrong for the reason stated three lines from the
    /// call site in `SyncCloudApp`: `App.init` can be re-run by SwiftUI, and this function's one
    /// production caller is inside it. Every other migration in that `init` is annotated "the
    /// repeat App.init calls noted above are harmless" precisely because a repeat WRITES NOTHING;
    /// this one wrote its whole report again each time. So a user who took Preview off two
    /// releases ago collected the same line however many times SwiftUI felt like rebuilding the
    /// scene — a per-launch fact logged per-init, which is the "never log a no-op" rule this file
    /// states and was breaking.
    ///
    /// Nothing about the report's content wanted to be here. It reads the stored arrangement and
    /// the shipped default, both of which are just as available from the delegate, and it runs
    /// AFTER this function rather than inside it, so it still reads the bar the user actually gets.
    ///
    /// - Returns: `.unchanged` when no stored arrangement was written, and `.rewritten` — carrying
    ///   whatever this run can NAME about the change — when one was. The distinction is the whole
    ///   return value: a caller has to be able to tell "had nothing to do" from "moved someone's
    ///   bar", and only the first of those may go unlogged.
    ///
    ///   **An enum, not a list, and not a `Bool` beside one.** This returned `[PaneBarItem]` —
    ///   the controls it had put onto the bar — and the doc claimed that was "empty when nothing was
    ///   rewritten". It was not. The list is derived by comparing the migrated items against
    ///   `before`, so it is empty for any **removal**, any **reorder**, and any **repeatable**
    ///   insertion (spacers are repeatable, which this file says two comments up). Each of those
    ///   rewrites and SAVES the arrangement and then answers `[]`, so `migrationMessage` answered
    ///   `nil` and the launch log said nothing at all about a bar that had just been rewritten
    ///   underneath its owner. Not reachable while `migratedControls == [.search]` — one
    ///   non-repeatable pure addition — but the entire point of returning something richer than a
    ///   `Bool` was the day a second step ships, and three of the four shapes such a step can take
    ///   land in that hole.
    ///
    ///   A struct or a `Bool`-plus-names would carry the same two facts and admit a third state
    ///   that cannot happen — `rewritten == false` with a non-empty `added` — leaving every reader
    ///   to decide which field to trust. The enum makes "was it rewritten" and "what changed"
    ///   one indivisible answer, and makes `.rewritten(added: [], removed: [])` a **named case the
    ///   message builder must handle** rather than a value indistinguishable from doing nothing.
    ///   That case is precisely the defect, so the type is what forces it to be answered.
    ///
    ///   `added` and `removed` are still DERIVED by comparison rather than flagged beside the
    ///   steps, for the reason the rewrite itself is: `insert` is allowed to refuse.
    @discardableResult
    public static func apply(defaults: UserDefaults) -> Outcome {
        let from = defaults.integer(forKey: PaneBar.migrationKey)   // 0 when never stamped
        guard from < currentVersion else { return .unchanged }
        defer { defaults.set(currentVersion, forKey: PaneBar.migrationKey) }

        // `.unchanged`, not a rewrite: there is no stored arrangement, so nothing was written.
        // Reporting a migration here made the app log "added Search to a stored pane-bar
        // arrangement" on the first launch of EVERY install that had never customized its bar —
        // the common case — about an arrangement that does not exist, in the log file a launch is
        // verified through.
        guard let stored = defaults.string(forKey: PaneBar.arrangementKey) else { return .unchanged }
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
        // **One write path, one derivation.** Every step above this line does nothing but mutate
        // `arrangement`, so whatever a future step does — insert, remove, reorder — reaches the
        // defaults through this single `set` and is described by this single `outcome` call. That
        // is what makes "a rewrite always returns `.rewritten`" a property of the code's shape
        // rather than of anyone remembering to update a flag beside their new step.
        guard case .rewritten(let added, let removed) =
                outcome(before: before, after: arrangement.items) else { return .unchanged }
        defaults.set(arrangement.encoded, forKey: PaneBar.arrangementKey)
        return .rewritten(added: added, removed: removed)
    }

    /// What changed between the bar as stored and the bar the steps produced.
    ///
    /// Split out from `apply` because it is the part with shapes worth testing and `apply` is the
    /// part that cannot produce them: the only step that ships is one non-repeatable pure addition,
    /// so a removal, a reorder and a repeatable insertion are unreachable through `apply` today
    /// and are exactly the shapes the old `[PaneBarItem]` return answered `[]` for. Fed directly,
    /// each of them is one line to state.
    ///
    /// `.unchanged` is decided HERE, by comparing the items, so `apply` cannot write a bar this
    /// function considers untouched — the two answers are one answer.
    ///
    /// Both lists are de-duplicated: a step may insert a repeatable item, and "added Space, Space"
    /// is not a sentence. Order is the migrated bar's for `added` and the stored bar's for
    /// `removed`, so a reader sees them where they were.
    static func outcome(before: [PaneBarItem], after: [PaneBarItem]) -> Outcome {
        guard after != before else { return .unchanged }
        var seenAdded: Set<PaneBarItem> = []
        var seenRemoved: Set<PaneBarItem> = []
        return .rewritten(
            added: after.filter { !before.contains($0) && seenAdded.insert($0).inserted },
            removed: before.filter { !after.contains($0) && seenRemoved.insert($0).inserted })
    }

    /// What a run of `apply` did to the stored arrangement.
    ///
    /// Two cases rather than one list, because the caller's question is "is there anything to say",
    /// and a list cannot answer it: an empty list used to mean both "nothing happened" and
    /// "something happened that I cannot name". See `apply`'s `- Returns:` for why that mattered.
    public enum Outcome: Equatable, Sendable {
        /// No stored arrangement was written — an install that never customized its bar, a bar
        /// already stamped at `currentVersion`, or a bar too full to take what a step offered it.
        /// The only case that may be logged as nothing.
        case unchanged
        /// The stored arrangement was rewritten and saved.
        ///
        /// **Both lists may be empty and that is a real state**, not a degenerate one: a step that
        /// reorders, or that inserts a repeatable item the bar already carries, changes the stored
        /// string while adding and removing no distinct control. The rewrite still happened, and
        /// `migrationMessage` still has to say so.
        case rewritten(added: [PaneBarItem], removed: [PaneBarItem])
    }

    /// The line a launch writes about the migration — **`nil` for `.unchanged` and non-`nil` for
    /// every rewrite**, which is the contract the whole `Outcome` type exists to make expressible.
    ///
    /// Every rewrite line opens with the same stem, so "this launch rewrote somebody's bar" is one
    /// grep of `~/sync-cloud.log` whether or not the run could name what it did. The naming is the
    /// part that can come up empty; the fact must not.
    ///
    /// Pure, and it is handed what `apply` answered rather than reading `migratedControls`, for two
    /// separate reasons. A run adds only what that particular bar was missing, so a bar that already
    /// carried Search and gained only the next control must not be told it gained both. And a
    /// version that consulted the claim list would be a line agreeing with a list instead of with
    /// the migration — the shape the literal it replaces already had.
    public static func migrationMessage(for outcome: Outcome) -> String? {
        guard case .rewritten(let added, let removed) = outcome else { return nil }
        let stem = "[panebar] rewrote a stored pane-bar arrangement"
        var clauses: [String] = []
        if !added.isEmpty { clauses.append("added \(names(added))") }
        if !removed.isEmpty { clauses.append("removed \(names(removed))") }
        // The rewrite it could not name — a reorder, or a repeatable item inserted again. The stem
        // alone is the honest sentence; saying nothing was the defect.
        guard !clauses.isEmpty else { return stem }
        return "\(stem): \(clauses.joined(separator: ", "))"
    }

    // MARK: What the resulting bar cannot show

    /// One line — at most two — saying which shipped controls the stored arrangement does not carry.
    ///
    /// The bar logged **nothing at all** before this. That was survivable while a removal cost a
    /// pill and never an ability: whatever was missing from the bar was still in ⋯. Since
    /// `9db37173` a removal is permanent, so "my Delete button is gone" and "the control this
    /// release shipped never appeared" are both states with no trace anywhere — and the second one
    /// is not even the user's doing.
    ///
    /// Proportional by construction: nothing is written for an install whose bar carries every
    /// shipped control, which is every uncustomized one (no stored arrangement at all) and every
    /// customized one that kept the lot.
    ///
    /// **It runs once per launch, from `SyncCloudAppDelegate.applicationDidFinishLaunching`** —
    /// which is a statement about the call site and true because of it. It used to say the same
    /// sentence about `apply`, where it was false: `apply`'s one production caller is `App.init`,
    /// which SwiftUI may re-run, so the report repeated with it. The delegate method fires exactly
    /// once per process, which is why the launch breadcrumb and the display-cycle guard's state
    /// already live there.
    ///
    /// - Parameter withoutARoute: the stranded list, defaulted to the real one. A parameter for the
    ///   same reason `unreachableMessage` takes one — in a correct build it is empty, so the branch
    ///   that matters is the branch no honest fixture can reach, and a test has to be able to hand
    ///   in a stranded control to prove this function warns about one at all.
    public static func reportStoredArrangementReach(defaults: UserDefaults,
                                                    withoutARoute: [PaneBarItem] = controlsWithoutARoute) {
        // No stored arrangement means the default bar, which carries every control by construction.
        guard let stored = defaults.string(forKey: PaneBar.arrangementKey) else { return }
        let arrangement = PaneBarArrangement(encoded: stored)
        if let line = unreachableMessage(for: arrangement, withoutARoute: withoutARoute) {
            Logger.shared.warning(line)
        }
        if let line = omissionMessage(for: arrangement) { Logger.shared.info(line) }
    }

    /// Shipped controls this arrangement does not carry **and could have carried**, or nil.
    ///
    /// Spacers are excluded: they are layout, not ability, and a bar without one is not missing
    /// anything a person could go looking for.
    ///
    /// **`declinedControls` are excluded too, and that is the point of the line rather than a
    /// detail.** A declined control has no migration step *by decision* — Delete's whole rationale
    /// is that it should wait to be added deliberately — so every bar customized before it shipped
    /// omits it, permanently and by design. Naming it here told those users, every launch and
    /// forever, to put back something the design had chosen not to push at them: advice about a
    /// state that is not a defect, cannot change on its own, and is the majority state. That is the
    /// nag this file's own "nothing is written for a bar that carries the lot" rule exists to
    /// prevent, one level up. A control the user really did take off is recorded by `PaneBarEditLog`
    /// at the moment they took it off, which is a better record than a standing complaint.
    ///
    /// The advice clause is dropped for a bar at `maxItems`, because there it is false:
    /// `PaneBarArrangement.insert` refuses on a full bar and refuses silently, so "put it back from
    /// Customize Pane Bar…" describes a gesture that does nothing until something else comes off.
    static func omissionMessage(for arrangement: PaneBarArrangement) -> String? {
        let omitted = omissions(from: arrangement).filter { !declinedControls.contains($0) }
        guard !omitted.isEmpty else { return nil }
        let advice = arrangement.items.count >= PaneBarArrangement.maxItems
            ? " — the bar is full at \(PaneBarArrangement.maxItems) items,"
                + " so nothing can go back on until something comes off"
            : " — put back from Customize Pane Bar…"
        return "[panebar] The stored pane-bar arrangement omits \(names(omitted))" + advice
    }

    /// The subset of those omissions that has no route back onto a bar of its own accord, or nil.
    ///
    /// A **warning**, and a different line from the one above, because it is a different fact: the
    /// controls above are missing because someone took them off or declined them, and these are
    /// missing because the build shipped them with nowhere to land.
    ///
    /// `withoutARoute` is a parameter, with **no default**, rather than a read of
    /// `controlsWithoutARoute` from inside. In a correct build that property is empty, so a version
    /// of this that consulted it directly could only ever be tested against nil — the branch that
    /// matters would be the one branch no fixture could reach. The one production caller passes it.
    static func unreachableMessage(for arrangement: PaneBarArrangement,
                                   withoutARoute: [PaneBarItem]) -> String? {
        let stranded = omissions(from: arrangement).filter { withoutARoute.contains($0) }
        guard !stranded.isEmpty else { return nil }
        // Agreed rather than hedged. "ship(s) … can never show it" read as a parenthesis for one
        // control and as a grammatical error for two, in a line whose job is to be read by someone
        // who has just been handed a bug report.
        let ship = stranded.count == 1 ? "ships" : "ship"
        let them = stranded.count == 1 ? "it" : "them"
        return "[panebar] \(names(stranded)) \(ship) on the default pane bar with no migration step,"
            + " so this stored arrangement can never show \(them) — see PaneBarMigration"
    }

    private static func omissions(from arrangement: PaneBarArrangement) -> [PaneBarItem] {
        let carried = Set(arrangement.items)
        return PaneBarArrangement.default.items.filter { !$0.isSpacer && !carried.contains($0) }
    }

    private static func names(_ items: [PaneBarItem]) -> String {
        items.map(\.displayName).joined(separator: ", ")
    }
}

/// The one place a user's own edit to the pane bar is written down.
///
/// The bar had no logging of any kind, which mattered the moment `9db37173` made a removal
/// permanent: taking Delete off the bar used to demote it into ⋯ and now deletes it outright, and
/// neither the act nor its result left a trace in `~/sync-cloud.log`. A support question about a
/// control that "disappeared" had literally nothing to read.
///
/// **Decisions and outcomes only.** One line per edit that actually changed the bar, naming what
/// moved and what the bar now is; nothing at all for an edit that changed nothing — a drag that
/// springs back, a Move Left on the leftmost pill, a Remove on Scan. That rule is the whole reason
/// `message(from:to:)` returns an Optional rather than a String: a no-op has no line to write, and
/// the last thing this file needs is the strip-chip defect where the most ordinary gesture in a
/// surface became its loudest log entry.
public enum PaneBarEditLog {

    /// What changed, as one line — or **nil when nothing did**.
    ///
    /// Pure, so the wording is testable without a hosted sheet: the sheet's own gestures need a
    /// real event loop, so a message built inside a `Button` action would be unverifiable.
    public static func message(from before: PaneBarArrangement, to after: PaneBarArrangement) -> String? {
        guard before != after else { return nil }
        // Multiset differences, not set ones: spacers repeat, so "the bar gained a Space" is a
        // question about counts. A pure reorder leaves both empty, which is what names it.
        let added = surplus(of: after.items, over: before.items)
        let removed = surplus(of: before.items, over: after.items)
        let what: String
        switch (added.isEmpty, removed.isEmpty) {
        case (true, true):   what = "reordered the pane bar"
        case (false, true):  what = "added \(names(added)) to the pane bar"
        case (true, false):  what = "removed \(names(removed)) from the pane bar"
        case (false, false): what = "added \(names(added)) to the pane bar and removed \(names(removed))"
        }
        // Restore is not given a verb of its own: it is described by what it did, plus the one fact
        // that distinguishes it from an edit that happens to land on the same list. A gesture-named
        // line would have to be trusted; this one is read off the result.
        let tail = after == PaneBarArrangement.default ? " (the default arrangement)" : ""
        return "[panebar] User \(what) — it is now \(after.encoded)\(tail)"
    }

    /// Writes that line, if there is one.
    ///
    /// - Returns: whether anything was logged, so the no-op path is assertable. A test cannot prove
    ///   an absence from `Logger.shared.entries` alone — the buffer is capped and a sibling suite
    ///   can evict what it is looking for.
    @discardableResult
    public static func record(from before: PaneBarArrangement, to after: PaneBarArrangement) -> Bool {
        guard let line = message(from: before, to: after) else { return false }
        Logger.shared.info(line)
        return true
    }

    /// The items of `lhs` that `rhs` does not account for, counting repeats.
    private static func surplus(of lhs: [PaneBarItem], over rhs: [PaneBarItem]) -> [PaneBarItem] {
        var remaining = rhs
        var extra: [PaneBarItem] = []
        for item in lhs {
            if let index = remaining.firstIndex(of: item) {
                remaining.remove(at: index)
            } else {
                extra.append(item)
            }
        }
        return extra
    }

    private static func names(_ items: [PaneBarItem]) -> String {
        items.map(\.displayName).joined(separator: ", ")
    }
}

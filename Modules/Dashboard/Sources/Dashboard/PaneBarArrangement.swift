import Design
import Events
import SwiftUI

/// One thing that can sit on a pane's bar.
///
/// The bar is a track running the full width of the pane, and this is its alphabet: an arrangement
/// is an ordered list of these, and a `flexibleSpace` pushes what follows it toward the trailing
/// edge.
///
/// Raw values are persisted: **append new cases, never renumber or rename**, or every stored
/// arrangement silently drops the item that changed.
public enum PaneBarItem: String, CaseIterable, Identifiable, Sendable, Codable {
    case viewMode
    case collapse
    case backForward
    case scan
    case newFolder
    case sort
    case hiddenFiles
    // The raw value `preview` is retired (the pane's old preview toggle) and must not be reused. A
    // stored arrangement that lists it reads it as an unknown token, off the bar but carried
    // through `encoded`, so a maintenance-line build sharing these defaults keeps its button.
    case space
    case flexibleSpace
    /// Appended last, per the rule above. A stored arrangement older than this case lacks it, which
    /// `PaneBarMigration` corrects; ⋯ doesn't, since it carries only what a rung folded. ⌘F opens
    /// the field either way, so a bar without it is missing a button, not an ability.
    case search
    /// Appended last, per the rule above, and deliberately not added to `PaneBarMigration`: pushing
    /// a destructive control onto a bar someone arranged is not what migration is for. A bar
    /// arranged before this case lacks it, and ⋯ doesn't offer it. The row menu's Delete and ⌘⌫
    /// reach the same act, so this control can wait to be added deliberately.
    case delete
    /// Appended last, per the rule above. Filter by Type: the pane shows only the file types ticked
    /// in its list, keeping every folder that holds one. Unlike Delete it is migrated onto older
    /// bars (`PaneBarMigration` step 2), for Search's reason: it is a harmless way of looking, and a
    /// customized bar would otherwise never see it.
    case typeFilter

    public var id: String { rawValue }

    /// Spacers are layout, not controls: they are never offered in the overflow menu, never counted
    /// as duplicates, and (for `flexibleSpace`) cost no width to keep.
    public var isSpacer: Bool { self == .space || self == .flexibleSpace }

    /// The one item that can be neither removed nor folded. Scan is the pane's only scan control,
    /// so a bar without it is a pane that can never be scanned: broken, not customized.
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
        case .space: return "Space"
        case .flexibleSpace: return "Flexible Space"
        case .search: return "Search"
        case .delete: return "Delete"
        case .typeFilter: return "Filter by Type"
        }
    }

    /// The word drawn under this item's pill in `PaneBarLabelMode.iconAndText`.
    ///
    /// Separate from `displayName`, which the palette and the ⋯ menu keep, because a menu row has
    /// room for "Collapse Pane" and a 33pt pill doesn't. The same control at two lengths.
    ///
    /// A title says what the control is, not its state. Hidden Files keeps one word while its eye
    /// swaps open and slashed: the glyph carries the state, and a word that changed with it would
    /// say it twice and, being measured type, shift every item to its left on each click. Scan is
    /// the exception, because mid-scan it does a different act, so `ScanRungMode` supplies "Stop".
    /// See `titleVariants`.
    public var barTitle: String {
        switch self {
        case .viewMode: return "View"
        case .collapse: return "Collapse"
        case .backForward: return "Back/Forward"
        case .scan: return "Scan"
        case .newFolder: return "New Folder"
        case .sort: return "Sort"
        case .hiddenFiles: return "Hidden"
        case .space, .flexibleSpace: return ""
        case .search: return "Search"
        case .delete: return "Delete"
        case .typeFilter: return "Filter"
        }
    }

    /// Every title this item can ever draw, so the ladder can reserve the widest of them.
    ///
    /// An item is as wide as the wider of its pill and its word, so a word that changes could change
    /// width under the cursor and shift everything to its left. "Scan" and "Stop" both fit inside
    /// the 33pt pill today, so this costs nothing; it absorbs a longer pair chosen later.
    public var titleVariants: [String] {
        self == .scan ? [barTitle, ScanRungMode.stopTitle] : [barTitle]
    }

    /// The pane-collapse glyph, in one place. Not `sidebar.left`, which the window's sidebar toggle
    /// (`ContentView+Toolbar`) wears a short way down the same edge for a different act, and not
    /// `chevron.left`, which Back wears on the pill right beside it. `arrow.left.to.line` reads
    /// leftward, says which edge the pane folds into, and matches neither neighbour.
    public static let collapseSymbol = "arrow.left.to.line"

    /// The Filter button's glyph; filled while a filter is on, so the state rides in the glyph the
    /// way Hidden's eye does.
    public static let typeFilterSymbol = "line.3.horizontal.decrease.circle"

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
        case .space: return "space"
        case .flexibleSpace: return "arrow.left.and.right"
        case .search: return "magnifyingglass"
        case .delete: return "trash"
        case .typeFilter: return PaneBarItem.typeFilterSymbol
        }
    }

    // No width lives on the item: `PaneBarLayout.width(of:pill:compactsViewMode:)` prices each one
    // from the constants the drawing code uses, so a layout number can't drift from the pills.
}

/// The persisted order of a pane bar: which items are on it, and where.
///
/// Shared by both Compare panes and the single-source rail — one arrangement, because the point of Compare's
/// side-by-side layout is that the two panes read as the same instrument pointed at two providers.
/// What stays per-pane is *state* (provider, hue wash, breadcrumb, whether Back is enabled), not the
/// arrangement.
public struct PaneBarArrangement: Equatable, Sendable {
    public private(set) var items: [PaneBarItem]

    /// Tokens in the stored string that no case of this build's `PaneBarItem` names: a newer build's
    /// controls seen after a downgrade, or a retired one (`preview`) an older build wrote. Never
    /// drawn, offered or counted against `maxItems`; they ride through `encoded` so the customize
    /// sheet's write-back (`PaneBarCustomizeSheet.commit`) doesn't destroy them. Without this, a
    /// downgrade, an edit and a re-upgrade would lose whatever the older build couldn't name.
    ///
    /// Carried at the tail, since edits make original positions meaningless. A newer build re-places
    /// its own control on its next read. A retired one is drawn by the older build at the end of its
    /// bar, and a bar this build wrote from scratch carries no `preview` at all.
    ///
    /// `==` still compares them (two stored strings that differ are different values), but "is this
    /// the shipped bar" is `drawsTheDefault`, which reads the items alone (see `restoredToDefault`).
    /// Bounded like `items`, so a corrupt value can't smuggle in a payload every write re-persists.
    private var unknownTokens: [String] = []

    /// A ceiling on how long a bar can get. Not a limit the palette will hit: it bounds what a
    /// corrupt or hand-edited defaults value can do, and with it the ladder's depth.
    public static let maxItems = 16

    /// The controls in their standard order, packed against the leading edge, so the bar starts
    /// where the breadcrumb below it starts.
    ///
    /// Only the default: a stored arrangement is read back verbatim, spaces and all, and
    /// `PaneBarMigrationTests` checks that a change to the default doesn't rewrite a customized bar.
    /// An item reaches the bar only if the host offers it (`resolved(available:)`), so a header with
    /// no search bindings or delete handler builds its bar without Search or Delete.
    ///
    /// Search is last, where `ExpandingSearchToggle` sits on every other surface, and shedding runs
    /// right to left, so the narrowest pane gives up the magnifier first: it is the one control
    /// here with a keyboard equivalent everywhere. Delete sits before it, since its ⌘⌫ is
    /// Compare-only.
    public static let `default` = PaneBarArrangement([
        .viewMode, .collapse, .backForward, .scan, .newFolder, .sort, .hiddenFiles,
        .delete, .typeFilter, .search
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

    /// Unknown tokens are dropped from the bar, not rejected, and carried through `encoded`, not
    /// discarded. Both halves are needed for a bar arranged on a newer build to survive a downgrade
    /// and an edit on the older build.
    public init(encoded: String) {
        let tokens = encoded.split(separator: ",").map(String.init)
        self.init(tokens.compactMap { PaneBarItem(rawValue: $0) })
        unknownTokens = Array(tokens.filter { PaneBarItem(rawValue: $0) == nil }.prefix(Self.maxItems))
    }

    /// Whether this draws the shipped bar. The items alone: a bar carrying another build's tokens
    /// draws exactly the default, and a Restore against it would change nothing on screen.
    public var drawsTheDefault: Bool { items == Self.default.items }

    /// The shipped bar, still carrying this one's tokens for other builds. Restore resets what this
    /// build draws, not what another build will read.
    public var restoredToDefault: PaneBarArrangement {
        var restored = Self.default
        restored.unknownTokens = unknownTokens
        return restored
    }

    // MARK: Editing

    public func canRemove(_ index: Int) -> Bool {
        items.indices.contains(index) && items[index].isRemovable
    }

    public mutating func remove(at index: Int) {
        guard canRemove(index) else { return }
        items.remove(at: index)
    }

    /// Inserts at `index`, clamped. A non-spacer already on the bar moves rather than duplicating:
    /// dragging Sort from the palette onto a bar that has Sort shouldn't give you two.
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

    /// One step left or right, for the keyboard path. Drag is the expected gesture but can't be the
    /// only one: VoiceOver and keyboard users get the same reach through the sheet's buttons.
    public mutating func nudge(_ index: Int, by offset: Int) {
        let destination = index + offset
        guard items.indices.contains(index), items.indices.contains(destination) else { return }
        items.swapAt(index, destination)
    }

    // MARK: Queries

    // A control taken off the bar comes back from the customize sheet's palette
    // (`PaneBarCustomizeSheet.palette`), not from ⋯, which holds only what a rung folded.

    /// The arrangement restricted to what this host can offer: a header with no view-mode binding
    /// has no View control to place.
    public func resolved(available: [PaneBarItem]) -> [PaneBarItem] {
        items.filter { $0.isSpacer || available.contains($0) }
    }
}

/// What the bar draws at one rung of the narrow-pane ladder.
public struct PaneBarLayoutPlan: Equatable, Sendable {
    /// Left to right, spacers included.
    public let visible: [PaneBarItem]
    /// Controls that folded away at this rung: the ⋯ menu's contents. Empty means no ⋯ pill at all.
    public let overflow: [PaneBarItem]
    /// At the last rung the Tree|Columns switch stops being a two-segment control and becomes one
    /// pill whose menu holds the alternatives. It compacts rather than folding, so the switch
    /// stays on the bar at the narrowest rung, one pill wide.
    public let compactsViewMode: Bool
}

public enum PaneBarLayout {
    /// Items the ladder will not take away, however narrow the pane gets.
    ///
    /// Scan is the pane's only scan control, and Back/Forward its only in-place navigation. A pane
    /// that can do neither is a dead end, however narrow. Everything else may go to ⋯.
    static let floor: Set<PaneBarItem> = [.scan, .backForward]

    /// Sheds `depth` items from the bar and reports what is left. The order follows the user's own
    /// arrangement:
    ///
    /// 1. Fixed spaces first, right to left. They are pure air.
    /// 2. Then controls, right to left, skipping the floor and the view switch. Whatever you put
    ///    last is what a cramped pane gives up first, so the arrangement is a priority list.
    /// 3. Then the view switch compacts to a single menu pill, as the last thing tried.
    /// 4. Flexible spaces never shed: they cost nothing, and dropping one would move everything
    ///    else on the bar.
    ///
    /// A `depth` past the end sheds everything sheddable, which the ladder's last rung asks for.
    ///
    /// The overflow is what this rung folded and nothing else, never controls the user took off
    /// the bar, or removing a control would only move it into ⋯. So a control that ships later
    /// reaches a customized bar only through `PaneBarMigration` (see `PaneBarItem.delete` for the
    /// one that declines).
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
        // The view switch compacts only once everything sheddable has gone: it is the last rung,
        // not an early economy.
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

    /// The deepest rung that changes anything for this arrangement. Past it `plan` is idempotent,
    /// and `PaneBarLadder` ends its ladder there.
    public static func maxDepth(arrangement: PaneBarArrangement, available: [PaneBarItem]) -> Int {
        let placed = arrangement.resolved(available: available)
        let sheddable = placed.filter { $0 == .space || (!$0.isSpacer && $0 != .viewMode && !floor.contains($0)) }
        return sheddable.count + (placed.contains(.viewMode) ? 1 : 0)
    }

    // MARK: The ladder

    /// Whether a 6pt gap belongs before `index`. Not before the first item, and never on either side
    /// of a flexible space, which is already the separation.
    ///
    /// Here, beside `width(of:controlSize:)`, rather than next to the `HStack` that draws it: the
    /// drawn bar and the measured bar must place gaps by the same rule, or the arithmetic that picks
    /// a rung describes a different bar than the one on screen.
    static func needsGap(before index: Int, in items: [PaneBarItem]) -> Bool {
        guard index > 0 else { return false }
        return items[index] != .flexibleSpace && items[index - 1] != .flexibleSpace
    }

    /// The laid-out width of one item, at the pill size of the rung drawing it.
    ///
    /// Every figure is the arithmetic of the view that draws the item in `PaneHeader.barItem`, in
    /// the same `PaneNavMetrics` constants. `PaneBarLadderTests.everyItemMeasuresWhatItDraws` pins
    /// each one against the hosted view.
    static func width(of item: PaneBarItem, pill: CGSize, compactsViewMode: Bool) -> CGFloat {
        switch item {
        // A `Spacer(minLength: 0)`: it costs the bar's minimum width nothing, and the minimum width
        // is what a rung is chosen by.
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
        // Search draws the same plain nav pill as its neighbours, not Design's
        // `ExpandingSearchToggle`, which sizes itself from a bare 13pt glyph, so it measures as one
        // pill.
        case .collapse, .scan, .newFolder, .sort, .hiddenFiles, .search, .delete, .typeFilter:
            return pill.width
        }
    }

    /// The width of one item once its title is taken into account.
    ///
    /// An item is as wide as the wider of its pill and its word. Most words are narrower than the
    /// 33pt pill and cost nothing; only New Folder, Search, Hidden and the Back/Forward pair are
    /// ever the binding half. Uses the widest of `titleVariants` (see there).
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
    /// Arithmetic rather than building candidate bars and measuring them, which was the pane
    /// header's dominant main-thread cost.
    ///
    /// `titled` prices the same rung with a word under every pill. The ⋯ takes no title (like
    /// Finder's unlabelled `»` overflow), so it stays a pill wide in both modes.
    @MainActor
    /// `titled` has **no default**: the gap depends on it, so a caller that forgot it would price a
    /// titled bar's 8pt gaps at 6 with no type error, and the bar would quietly over-compact or
    /// overrun its trailing edge. The one production caller is `PaneBarLadder.width(forRung:)`.
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
    /// Every control is exactly a pill tall, the view switch included: its ground has no vertical
    /// padding (see `PaneHeader.viewModeSwitch`), as Finder's segmented controls are no taller than
    /// its plain ones. A titled switch that stood taller would hang its word below every other word
    /// and push the row over budget. The row's reservation is computed from this
    /// (`PaneHeader.tallestRungHeight`).
    ///
    /// `titled` has **no default**, for `width(of:)`'s reason: forgotten, it would price a titled
    /// row at bare pill height with no type error, clipping the words or claiming room the header
    /// lacks. The one production caller is `PaneBarLadder.height(forRung:)`.
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
/// The rung is computed, not searched. `ViewThatFits` builds every child to measure it, ten full
/// bars twice over for two panes on every layout pass, and with `MainThreadHitchMonitor` that cost
/// seconds of main-thread work over a few Settings opens. Each rung's width is the sum of the views
/// that draw it (`PaneBarLayout.width(of:controlSize:)`), plain arithmetic over `PaneNavMetrics`.
/// The header reserves the tallest rung's height, so the bar's top edge holds steady as the pane
/// widens.
///
/// The header still hands the result to `ViewThatFits`, with the narrowest rung behind it as a
/// fallback, on purpose: if this arithmetic ever disagrees with the real fit, the layout engine
/// steps the bar down rather than letting it silently overflow the pane's trailing edge.
@MainActor
struct PaneBarLadder {
    let arrangement: PaneBarArrangement
    let available: [PaneBarItem]
    /// The largest control size the ladder may start from. The icon-size preference is a ceiling,
    /// not a pin, because a bar that overflows the pane is worse than small glyphs.
    let ceiling: ControlSize
    /// The app's text scale, which prices the titled rung: a glyph pill is a published constant,
    /// but a word is measured type and the app scales its own.
    let scale: CGFloat

    /// How many rungs at the head of the ladder draw titles: 1 when the preference asks for them
    /// and the row fits this text size, 0 otherwise. Zero leaves the untitled ladder exactly as it
    /// is, so `iconOnly` and large text pay nothing for titles.
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
        // The gate. `iconAndText` is a ceiling, not a pin: titles appear only if the row they need
        // fits the header.
        self.titledRungs = (labelMode == .iconAndText
                            && PaneBarTitleMetrics.rowFits(pillHeight: PaneNavMetrics.pill(ceiling).height,
                                                           scale: scale)) ? 1 : 0
        // Rung 0 is the ceiling size at depth 0; rung r > 0 is `.mini` at depth r - 1, shifted by
        // the titled rung when there is one. So the rung that reaches the deepest meaningful fold
        // is one past it.
        self.terminal = PaneBarLayout.maxDepth(arrangement: arrangement, available: available)
            + 1 + titledRungs
    }

    /// Whether this rung draws a word under each pill. Only the head of the ladder does: titles shed
    /// all together as one rung, ahead of the step down to `.mini`, because a bar of some words and
    /// some glyphs reads as two controls (`WorkspaceBarMetrics` applies the same rule).
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

    /// The rung an offer of `width` gets: the first one that fits, mirroring `ViewThatFits`, and the
    /// narrowest rung when nothing does.
    ///
    /// First, not narrowest-that-fits, because the ladder isn't guaranteed monotonic: shedding a
    /// control narrower than the ⋯ pill it brings in (a full pill plus its gap) makes the bar
    /// wider, so that rung must never be chosen.
    func rung(fitting width: CGFloat) -> Int {
        for rung in 0...terminal where self.width(forRung: rung) <= width { return rung }
        return terminal
    }
}

/// The drag payloads the customize sheet moves items with, and the rules for applying them.
///
/// In the model rather than the sheet because it is the testable part of drag and drop: the
/// gestures need a real event loop, so the sheet's behaviour is only checkable by hand, the wrong
/// place to hide index arithmetic and string parsing.
///
/// Each entry point answers a new arrangement or nil, where nil means "this drop changes nothing".
/// The sheet reports that to the drag session, so an item that can't be placed springs back
/// instead of animating into a bar that didn't move.
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
            // No range check: `move` refuses an index it doesn't have, so a stale payload (the bar
            // changed under a drag in flight) falls out as "changed nothing" and is refused below.
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

/// Whether the bar draws a word under each pill, the second preference in its right-click menu.
///
/// A ceiling, not a pin, like `PaneBarIconSize`. `iconAndText` says "start here": the bar still
/// drops to `iconOnly` when the pane is too narrow for the titled rung, and at the top of the text
/// sizes (see `PaneBarTitleMetrics.rowBudget`). `iconOnly` never produces a title.
///
/// Two cases where Finder has three. Text Only is left out: with no glyph the word must carry the
/// state, so Hidden Files' title would swap with its eye and the item's width would change on click.
public enum PaneBarLabelMode: String, CaseIterable, Sendable {
    case iconAndText
    case iconOnly

    public var displayName: String {
        self == .iconAndText ? "Icon and Text" : "Icon Only"
    }
}

/// The type the bar's titles are drawn in, and the height that costs the row.
public enum PaneBarTitleMetrics {
    /// The title's base point size.
    ///
    /// 10pt, so the word reads as a caption under its pill rather than competing with the
    /// breadcrumb below it, as `WorkspaceBarMetrics` treats its own labels.
    public static let pointSize: CGFloat = 10
    /// Between the pill's bottom edge and the title's line box.
    public static let gap: CGFloat = 2

    /// The tallest titled row the pinned 81pt pane header can carry and still keep its content 6pt
    /// clear of both card edges, the floor `PaneBarLadderTests.theHeaderIsBalancedTopToBottom`
    /// holds the header to.
    ///
    /// Calibrated against the rendered header, not derived: `rowHeight` is the row's box, the floor
    /// is about where ink lands, and no sum of these constants gets from one to the other.
    /// `rowHeight` takes six values across the slider's range, and the tightest clearance at each,
    /// with the gate lifted so every size drew words, is:
    ///
    /// | row | 33pt | 34pt | 35pt | 36pt | 37pt | 38pt |
    /// |---|---|---|---|---|---|---|
    /// | text size | 90% | 95% | 100–105% | 110–115% | 120–125% | 130–135% |
    /// | clearance | 9.0 | 8.0 | 7.0 | 6.5 | **5.0** | **4.0** |
    ///
    /// The floor is crossed between the 36pt and 37pt rows, so 36.5 leaves half a point of margin
    /// on each side, the widest any value can. Re-measure the table if `LabelMetrics.lineHeight`
    /// changes. `PaneBarTitleTests.theGateHasBothDirectionsWithMarginOnEach` fails if this lands on
    /// a producible row.
    ///
    /// Two tests hold it, one per direction. Too high, and
    /// `PaneBarLadderTests.theTitledHeaderClearsBothEdges` sees the crowding. Too low, and nothing
    /// crowds because the header renders untitled, so `PaneBarTitleTests.theTextSizesThatGetWords`
    /// names the percentages outright.
    public static let rowBudget: CGFloat = 36.5

    public static let font: ScaledFont = .system(size: pointSize, weight: .regular)

    /// The height a titled row occupies at this text size, exactly, at all ten sizes:
    /// `PaneBarLadderTests.everyRungIsReservedAsTallAsTheBarItDraws` measures it against the drawn
    /// rung. `LabelMetrics.lineHeight` must measure the box SwiftUI gives the `Text`, not
    /// `NSLayoutManager.defaultLineHeight`, which runs a point short at small sizes; a SwiftUI child
    /// isn't clipped by `maxHeight`, so a short reservation would go unseen.
    ///
    /// This is a box, not a prediction of where ink lands, which is why `rowBudget` is calibrated
    /// against the drawn header rather than computed from these constants.
    @MainActor
    public static func rowHeight(pillHeight: CGFloat, scale: CGFloat) -> CGFloat {
        pillHeight + gap + LabelMetrics.lineHeight(font: font, scale: scale)
    }

    /// Whether titles can be drawn at all at this text size.
    ///
    /// The fallback is `iconOnly`, not a smaller word: clamping the title would give the person who
    /// chose the largest text, because small text is hard to read, the one label that refuses to
    /// grow. They get the untitled bar instead. See `rowBudget` for where the line sits.
    @MainActor
    public static func rowFits(pillHeight: CGFloat, scale: CGFloat) -> Bool {
        rowHeight(pillHeight: pillHeight, scale: scale) <= rowBudget
    }
}

/// The icon-size preference from the bar's right-click menu.
///
/// A ceiling, not a pin: the pane may still step below the chosen size when it can't fit, because
/// overflowing the trailing edge is worse than smaller glyphs. Small starts the ladder one rung
/// down rather than freezing it.
public enum PaneBarIconSize: String, CaseIterable, Sendable {
    case regular
    case small

    public var displayName: String { self == .regular ? "Regular" : "Small" }

    /// The largest control size the ladder may start from.
    public var ceiling: ControlSize { self == .regular ? .small : .mini }
}

/// Defaults keys for the bar. One arrangement and one icon size, app-wide (see `PaneBarArrangement`).
public enum PaneBar {
    public static let arrangementKey = "paneBarArrangement"
    public static let iconSizeKey = "paneBarIconSize"
    /// Whether the bar draws words under its pills. App-wide like the two above: Compare's two
    /// panes and the rail are one instrument pointed at different providers.
    public static let labelModeKey = "paneBarLabelMode"
    /// How far a stored arrangement has been brought forward; see `PaneBarMigration`.
    public static let migrationKey = "paneBarArrangementMigration"
}

/// Brings a bar someone arranged on an earlier build forward when a new control ships.
///
/// ⋯ carries only what a rung folded (`PaneBarLayout.plan`), so a control added to
/// `PaneBarArrangement.default` without a step here reaches a customized bar through no route at
/// all, and nothing says so. Adding the step is the default; declining is the judgement call, and
/// `PaneBarItem.delete` is the one control that declines, since two other routes reach its act.
///
/// Not "always restore it, like `scan`": `PaneBarArrangement.init` re-adds `scan` because it must
/// never be missing, but doing that here would make the control unremovable, and a bar item that
/// grows back overrules the user visibly. So each step runs once, recorded by a stored version:
/// remove Search after the migration and it stays removed.
public enum PaneBarMigration {
    /// Bump this, and add a step below, whenever a control joins `PaneBarArrangement.default`.
    public static let currentVersion = 2

    // MARK: The routes a shipped control has onto a customized bar
    //
    // Between them these three sets must account for every non-spacer control in
    // `PaneBarArrangement.default`, or a new control could reach no customized bar in silence.
    // `PaneBarMigrationTests` derives the expected set from the default and names any control in
    // none of them; `everyControlTheMigrationClaimsToPlaceActuallyLands` keeps `migratedControls`
    // honest by running the migration rather than trusting the list.

    /// Controls that shipped on the bar before this mechanism existed. Every stored arrangement
    /// was written by a build that offered these, so a bar without one was arranged that way.
    ///
    /// Frozen, and it must never grow: a new control takes a migration step or declines one, and
    /// listing it here would claim a route it never had, which is why the test pins these by name.
    /// It only shrinks when a control is retired from the bar altogether.
    public static let baselineControls: Set<PaneBarItem> = [
        .viewMode, .collapse, .backForward, .scan, .newFolder, .sort, .hiddenFiles
    ]

    /// Controls a step in `apply` puts onto a stored bar. A claim, not a mechanism, so the tests
    /// bind it to the steps by running the migration once per control.
    public static let migratedControls: Set<PaneBarItem> = [.search, .typeFilter]

    /// Controls that ship on the default bar and deliberately decline a step.
    ///
    /// Declining is the judgement call, so the members are named here and again in the test: a
    /// control can join only by someone editing both places and saying why. `delete` is the one
    /// member; its reasoning is on the case.
    public static let declinedControls: Set<PaneBarItem> = [.delete]

    /// The three routes together: the set a shipped control must belong to.
    ///
    /// `PaneBarMigrationTests` asserts this is exactly the default bar's non-spacer controls. Both
    /// directions matter: a control on the bar and on no route is the hazard, and one on a route
    /// but not on the bar is a claim about something that doesn't ship.
    static var routedControls: Set<PaneBarItem> {
        baselineControls.union(migratedControls).union(declinedControls)
    }

    /// Controls that ship on the default bar and reach a customized bar through no route at all.
    /// Empty in a correct build. Non-empty means a case was added to `PaneBarArrangement.default`
    /// and nothing else, so nobody who ever opened the customize sheet will see it.
    public static var controlsWithoutARoute: [PaneBarItem] {
        controlsWithoutARoute(shipping: .default, routed: routedControls)
    }

    /// The same derivation with both inputs handed in, which is the only way to prove it derives
    /// anything: the property above is empty in a correct build, so a mutation to `return []` would
    /// pass every check of it. Fed an empty `routed`, this must name the whole bar. The same call
    /// exercises the spacer exemption: spacers are layout, not an ability anyone looks for.
    static func controlsWithoutARoute(shipping arrangement: PaneBarArrangement,
                                      routed: Set<PaneBarItem>) -> [PaneBarItem] {
        arrangement.items.filter { !$0.isSpacer && !routed.contains($0) }
    }

    /// Applies every migration a stored arrangement hasn't had yet, and records how far it got.
    ///
    /// A bar that was never customized has no stored arrangement and reads the default, which
    /// carries every control; it is stamped anyway, so this never runs again for it and a later
    /// deliberate removal isn't undone by the next launch.
    ///
    /// The version stamp is written in a `defer`, so it lands on every path out, the early return
    /// included. Written before the work it would record a migration a crash could still prevent;
    /// written only on success it would re-run forever for the bars it rightly left alone.
    ///
    /// What the resulting bar can't show is reported by `reportStoredArrangementReach`, once per
    /// launch from the app delegate, not from here: this function's caller is `App.init`, which
    /// SwiftUI may re-run, and a repeat must write nothing, log lines included.
    ///
    /// - Returns: `.unchanged` when no stored arrangement was written, and `.rewritten`, carrying
    ///   whatever this run can name about the change, when one was. A caller must be able to tell
    ///   "had nothing to do" from "moved someone's bar", and only the first may go unlogged.
    ///
    ///   An enum, not a list or a `Bool` beside one. A rewrite that names no distinct control (a
    ///   reorder, or a repeatable item inserted again) is `.rewritten(added: [], removed: [])`, a
    ///   case the message builder must handle, rather than an empty list that reads as doing
    ///   nothing. `added` and `removed` are derived by comparison, because `insert` may refuse.
    @discardableResult
    public static func apply(defaults: UserDefaults) -> Outcome {
        let from = defaults.integer(forKey: PaneBar.migrationKey)   // 0 when never stamped
        guard from < currentVersion else { return .unchanged }
        defer { defaults.set(currentVersion, forKey: PaneBar.migrationKey) }

        // `.unchanged`, not a rewrite: with no stored arrangement nothing was written, and
        // reporting one would log a migration on the first launch of every uncustomized install.
        guard let stored = defaults.string(forKey: PaneBar.arrangementKey) else { return .unchanged }
        var arrangement = PaneBarArrangement(encoded: stored)
        let before = arrangement.items
        // Step 1: Search, at the trailing end, where the default carries it and where the ladder
        // gives it up first.
        if from < 1, !arrangement.items.contains(.search) {
            arrangement.insert(.search, at: arrangement.items.count)
        }
        // Step 2: Filter by Type, just before Search, where the default carries it, or at the
        // trailing end on a bar that has dropped Search.
        if from < 2, !arrangement.items.contains(.typeFilter) {
            let at = arrangement.items.firstIndex(of: .search) ?? arrangement.items.count
            arrangement.insert(.typeFilter, at: at)
        }
        // Compared, not flagged: `PaneBarArrangement.insert` may refuse (a bar at `maxItems`,
        // reachable because spacers repeat), so only the items know whether anything changed.
        // Every step above only mutates `arrangement`, so whatever a future step does reaches the
        // defaults through this one `set` and is described by this one `outcome` call.
        guard case .rewritten(let added, let removed) =
                outcome(before: before, after: arrangement.items) else { return .unchanged }
        defaults.set(arrangement.encoded, forKey: PaneBar.arrangementKey)
        return .rewritten(added: added, removed: removed)
    }

    /// What changed between the bar as stored and the bar the steps produced.
    ///
    /// Split out from `apply` so the shapes `apply` can't produce today (a removal, a reorder, a
    /// repeatable insertion) can each be tested directly. `.unchanged` is decided here, so `apply`
    /// can't write a bar this considers untouched.
    ///
    /// Both lists are de-duplicated, since a step may insert a repeatable item and "added Space,
    /// Space" is no sentence. `added` follows the migrated bar's order and `removed` the stored
    /// bar's, so a reader sees them where they were.
    static func outcome(before: [PaneBarItem], after: [PaneBarItem]) -> Outcome {
        guard after != before else { return .unchanged }
        var seenAdded: Set<PaneBarItem> = []
        var seenRemoved: Set<PaneBarItem> = []
        return .rewritten(
            added: after.filter { !before.contains($0) && seenAdded.insert($0).inserted },
            removed: before.filter { !after.contains($0) && seenRemoved.insert($0).inserted })
    }

    /// What a run of `apply` did to the stored arrangement. Two cases rather than a list, because
    /// the caller asks "is there anything to say", and an empty list can't tell "nothing happened"
    /// from "something happened that can't be named". See `apply`'s `- Returns:`.
    public enum Outcome: Equatable, Sendable {
        /// No stored arrangement was written: an install that never customized its bar, a bar
        /// already stamped at `currentVersion`, or a bar too full to take what a step offered.
        /// The only case that may be logged as nothing.
        case unchanged
        /// The stored arrangement was rewritten and saved. Both lists may be empty, a real state:
        /// a step that reorders, or inserts a repeatable item the bar already carries, changes the
        /// stored string while adding and removing no distinct control, and `migrationMessage`
        /// still has to say so.
        case rewritten(added: [PaneBarItem], removed: [PaneBarItem])
    }

    /// The line a launch writes about the migration: `nil` for `.unchanged` and non-`nil` for every
    /// rewrite. Every rewrite line opens with the same stem, so "this launch rewrote somebody's
    /// bar" is one grep of `~/sync-cloud.log` even when the run can't name what it did.
    ///
    /// Pure, and handed what `apply` answered rather than reading `migratedControls`: a run adds
    /// only what that bar was missing, so a bar that already had Search and gained only the next
    /// control must not be told it gained both.
    public static func migrationMessage(for outcome: Outcome) -> String? {
        guard case .rewritten(let added, let removed) = outcome else { return nil }
        let stem = "[panebar] rewrote a stored pane-bar arrangement"
        var clauses: [String] = []
        if !added.isEmpty { clauses.append("added \(names(added))") }
        if !removed.isEmpty { clauses.append("removed \(names(removed))") }
        // The rewrite it can't name (a reorder, or a repeatable item inserted again): the stem
        // alone is the honest sentence.
        guard !clauses.isEmpty else { return stem }
        return "\(stem): \(clauses.joined(separator: ", "))"
    }

    // MARK: What the resulting bar cannot show

    /// One line, at most two, saying which shipped controls the stored arrangement doesn't carry.
    ///
    /// A removal is permanent, so without this a control the user took off and a control this
    /// release shipped that never appeared would both leave no trace. Nothing is written for a bar
    /// that carries every shipped control, which includes every uncustomized install.
    ///
    /// Called once per launch from `SyncCloudAppDelegate.applicationDidFinishLaunching`, which
    /// fires once per process, unlike `App.init`, which SwiftUI may re-run.
    ///
    /// - Parameter withoutARoute: the stranded list, defaulted to the real one. A parameter, as in
    ///   `unreachableMessage`, because it is empty in a correct build, and a test has to hand in a
    ///   stranded control to prove this warns about one.
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

    /// Shipped controls this arrangement doesn't carry and could have carried, or nil.
    ///
    /// Spacers are excluded: they are layout, not ability. `declinedControls` are excluded too: a
    /// declined control has no migration step by decision, so every bar customized before it
    /// shipped omits it by design, and naming it would nag most users every launch about a state
    /// that isn't a defect. A control the user really took off is recorded by `PaneBarEditLog`.
    ///
    /// The advice clause is dropped for a bar at `maxItems`, where it would be false:
    /// `PaneBarArrangement.insert` silently refuses on a full bar, so "put it back from Customize
    /// Pane Bar…" would describe a gesture that does nothing.
    static func omissionMessage(for arrangement: PaneBarArrangement) -> String? {
        let omitted = omissions(from: arrangement).filter { !declinedControls.contains($0) }
        guard !omitted.isEmpty else { return nil }
        let advice = arrangement.items.count >= PaneBarArrangement.maxItems
            ? " — the bar is full at \(PaneBarArrangement.maxItems) items,"
                + " so nothing can go back on until something comes off"
            : " — put back from Customize Pane Bar…"
        return "[panebar] The stored pane-bar arrangement omits \(names(omitted))" + advice
    }

    /// The subset of those omissions with no route back onto a bar, or nil.
    ///
    /// A warning, and a separate line, because it is a different fact: the controls above are
    /// missing because someone took them off or declined them, these because the build shipped
    /// them with nowhere to land. `withoutARoute` is a parameter with **no default**: in a correct
    /// build `controlsWithoutARoute` is empty, so reading it inside could only be tested against
    /// nil. The one production caller passes it.
    static func unreachableMessage(for arrangement: PaneBarArrangement,
                                   withoutARoute: [PaneBarItem]) -> String? {
        let stranded = omissions(from: arrangement).filter { withoutARoute.contains($0) }
        guard !stranded.isEmpty else { return nil }
        // Verb and pronoun agree with the count, since this line is read by someone handling a bug
        // report.
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

/// The one place a user's own edit to the pane bar is written down, so a control that
/// "disappeared" leaves a trace in `~/sync-cloud.log`.
///
/// Decisions and outcomes only: one line per edit that changed the bar, naming what moved and what
/// the bar now is, and nothing for an edit that changed nothing (a drag that springs back, a Move
/// Left on the leftmost pill, a Remove on Scan). That is why `message(from:to:)` returns an
/// Optional: the most ordinary gesture must not become the loudest log entry.
public enum PaneBarEditLog {

    /// What changed, as one line, or nil when nothing did.
    ///
    /// Pure, so the wording is testable without a hosted sheet: the sheet's own gestures need a
    /// real event loop, so a message built inside a `Button` action would be unverifiable.
    public static func message(from before: PaneBarArrangement, to after: PaneBarArrangement) -> String? {
        // The items, not the stored strings: a change only in tokens another build carries is not
        // an edit anyone made here.
        guard before.items != after.items else { return nil }
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
        let tail = after.drawsTheDefault ? " (the default arrangement)" : ""
        return "[panebar] User \(what) — it is now \(after.encoded)\(tail)"
    }

    /// Writes that line, if there is one.
    ///
    /// - Returns: whether anything was logged, so the no-op path is assertable. A test can't prove
    ///   an absence from `Logger.shared.entries` alone: the buffer is capped and a sibling suite
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

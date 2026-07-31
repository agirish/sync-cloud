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

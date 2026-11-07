import SwiftUI
import Design
import Sync

/// The strip under Browse's pane: how much is here, what is picked, how much of it is in the
/// cloud, and how old the listing is.
///
/// Browse only, so it is built into `browseLayout`, not `paneColumn`: in Compare each pane header
/// already carries its side's facts, and one shared strip would repeat a pane or pick a winner.
///
/// It sheds from the right; ``PaneStatusFacts/Rung`` owns the order. `ViewThatFits` over
/// hand-named rungs with a `forcedRung` escape, as ``EditorStatusLine`` does, so a test can pick a
/// rung without squeezing a layout.
struct PaneStatusBar: View {

    var facts: PaneStatusFacts
    /// Forces a rung, for the tests that measure each one. `nil` picks by width.
    var forcedRung: PaneStatusFacts.Rung?
    /// Clears the type filter: the ✕ on its chip. The chip is drawn whenever the facts carry a
    /// filter, at every rung, so a narrow pane never hides that it is filtered.
    var onClearTypeFilter: (() -> Void)? = nil

    var body: some View {
        Group {
            if let forcedRung {
                strip(forcedRung)
            } else {
                // Spelled out, not `ForEach(Rung.allCases)`: `ViewThatFits` picks between its
                // children, and a `ForEach` is one child, so the ladder would never shed.
                // `theLadderOffersEveryRungInSheddingOrder` pins this list against `allCases`.
                ViewThatFits(in: .horizontal) {
                    strip(.full)
                    strip(.selectionAndCloud)
                    strip(.selection)
                    strip(.items)
                }
            }
        }
        .scaledFont(.system(size: 10))
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(facts.accessibilityLabel)
        .accessibilityActions {
            if facts.typeFilter != nil, let onClearTypeFilter {
                Button("Clear Filter", action: onClearTypeFilter)
            }
        }
    }

    /// One rung, measured at its ideal width so `ViewThatFits` can compare the four.
    ///
    /// Without `fixedSize(horizontal:)` every rung reports the width it was offered and they all
    /// "fit". The trailing `Spacer(minLength: 8)` is inside the measurement so the rung that fits
    /// keeps a little air after its last segment. Segments are keyed by position, since two can
    /// draw the same string.
    private func strip(_ rung: PaneStatusFacts.Rung) -> some View {
        HStack(spacing: 14) {
            ForEach(Array(facts.segments(rung).enumerated()), id: \.offset) { index, segment in
                Text(segment)
                // Right after the count it qualifies, so it is the last thing a narrowing pane keeps.
                if index == 0, let filter = facts.typeFilter { typeFilterChip(filter) }
            }
            Spacer(minLength: 8)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func typeFilterChip(_ filter: PaneStatusFacts.TypeFilter) -> some View {
        HStack(spacing: 3) {
            // Inked `.primary` on the accent's wash, never the accent on its own wash.
            Text(filter.summary).fontWeight(.semibold).foregroundStyle(.primary)
            if let onClearTypeFilter {
                Button(action: onClearTypeFilter) {
                    Image(systemName: "xmark")
                        .scaledFont(.system(size: 7, weight: .bold))
                        .frame(width: 12, height: 12)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Clear the filter")
                .accessibilityLabel("Clear the filter")
            }
        }
        .foregroundStyle(.secondary)
        .padding(.leading, 7)
        .padding(.trailing, onClearTypeFilter == nil ? 7 : 3)
        .padding(.vertical, 1)
        .background(Capsule().fill(LiquidGlassHue.stored().accentColor.opacity(0.16)))
    }
}

/// The bar plus the 30-second tick that keeps its freshness segment honest.
///
/// Split out so ``PaneStatusBar`` stays a function of its facts, renderable at a fixed instant by a
/// test. The tick is anchored to the read stamp, not view creation, for the reason
/// `DifferencesView.withScanFreshness` gives: an arbitrary phase puts every label up to 30s off.
/// With nothing loaded there is no age to tick, so the bar renders once.
struct TickingPaneStatusBar: View {

    var facts: PaneStatusFacts
    var onClearTypeFilter: (() -> Void)? = nil

    var body: some View {
        if let readAt = facts.readAt {
            TimelineView(.periodic(from: readAt, by: 30)) { context in
                PaneStatusBar(facts: at(context.date), onClearTypeFilter: onClearTypeFilter)
            }
        } else {
            PaneStatusBar(facts: facts, onClearTypeFilter: onClearTypeFilter)
        }
    }

    private func at(_ now: Date) -> PaneStatusFacts {
        var facts = facts
        facts.now = now
        return facts
    }
}

/// Browse's status bar with its census attached: the one view the app composes.
///
/// It takes a `PaneTree`, never a `[FileNode]`: `FileNode`'s derived `==` recurses the whole
/// subtree, so a large pane would pay an O(tree) comparison on the main thread whenever SwiftUI
/// diffs this view. `PaneTree` compares by stamp; the nodes are read only by the census, off the
/// main actor.
///
/// The census restarts on the stamp, the pane's publish counter, so any republish supersedes the
/// count in flight and the bar shows `—` until the new one lands.
public struct BrowseStatusBar: View {

    var itemCount: Int
    var tree: PaneTree
    var selection: PaneStatusFacts.Selection?
    var readAt: Date?
    var changedOnDisk: Bool
    /// Substituted by the tests, for the reason ``CloudOnlyCensus/count(in:stat:)`` gives.
    var stat: MaterializationStatus.StatFlags = MaterializationStatus.realStatFlags
    /// The pane's type filter, for "28 of 52 items" and its chip.
    var typeFilter: PaneStatusFacts.TypeFilter?
    var onClearTypeFilter: (() -> Void)?

    @State private var cloudOnlyCount: Int?

    public init(itemCount: Int, tree: PaneTree, selection: PaneStatusFacts.Selection?,
                readAt: Date?, changedOnDisk: Bool = false,
                stat: @escaping MaterializationStatus.StatFlags = MaterializationStatus.realStatFlags,
                typeFilter: PaneStatusFacts.TypeFilter? = nil, onClearTypeFilter: (() -> Void)? = nil) {
        self.typeFilter = typeFilter
        self.onClearTypeFilter = onClearTypeFilter
        self.itemCount = itemCount
        self.tree = tree
        self.selection = selection
        self.readAt = readAt
        self.changedOnDisk = changedOnDisk
        self.stat = stat
    }

    public var body: some View {
        TickingPaneStatusBar(facts: PaneStatusFacts(itemCount: itemCount,
                                                    selection: selection,
                                                    cloudOnlyCount: cloudOnlyCount,
                                                    readAt: readAt,
                                                    changedOnDisk: changedOnDisk,
                                                    typeFilter: typeFilter),
                             onClearTypeFilter: onClearTypeFilter)
            .task(id: tree.version) {
                // Back to `—` first, or the previous tree's count sits under the new tree's rows
                // for as long as the walk takes.
                cloudOnlyCount = nil
                // Nil means cancelled, which here means the pane republished: the successor task
                // owns the answer, so this one writes nothing.
                if let count = await CloudOnlyCensus.run(over: tree.nodes, stat: stat) {
                    cloudOnlyCount = count
                }
            }
    }
}

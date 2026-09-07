import SwiftUI
import Design
import Sync

/// The strip under Browse's pane: how much is here, what is picked, how much of it is in the
/// cloud, and how old the listing is.
///
/// **Browse only, and that is the whole of the v4.2 deferral being answered.** The bar was held
/// since v4.2 on what it would say in Compare, where two panes want two answers and one strip can
/// give only one. The one-line pane headers reached the verdict this takes: the per-pane header
/// already carries each side's own facts, so a second, shared line under both of them would
/// either repeat one pane or silently pick a winner. Browse has exactly one pane, so the question
/// does not arise there — which is why the bar is built into `browseLayout` rather than into
/// `paneColumn`, the function all three surfaces share. A future Compare bar would be per pane and
/// a different design; nothing here decides it.
///
/// **It sheds from the right** — see ``PaneStatusFacts/Rung``, which owns the order and the reason
/// for it. The mechanism is `ViewThatFits` over hand-named rungs with a `forcedRung` escape, the
/// same construction ``EditorStatusLine`` uses, because a test that has to *provoke* a rung by
/// squeezing a layout is a test about SwiftUI rather than about the ladder.
struct PaneStatusBar: View {

    var facts: PaneStatusFacts
    /// Forces a rung, for the tests that measure each one. `nil` picks by width.
    var forcedRung: PaneStatusFacts.Rung?

    var body: some View {
        Group {
            if let forcedRung {
                strip(forcedRung)
            } else {
                // **Spelled out, not `ForEach(Rung.allCases)`.** `ViewThatFits` picks between its
                // *children*, and a `ForEach` is one child — routed through it the ladder would
                // collapse to a single candidate and never shed anything.
                // `theLadderOffersEveryRungInSheddingOrder` pins this list against `allCases`, so
                // a rung added to the enum and forgotten here fails rather than going unoffered.
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
    }

    /// One rung, measured at its ideal width so `ViewThatFits` can compare the four.
    ///
    /// `fixedSize(horizontal:)` is what makes the comparison meaningful — without it every rung
    /// reports the width it was offered and they all "fit". The trailing `Spacer(minLength: 8)` is
    /// inside that measurement on purpose: it makes a rung claim eight points more than its text
    /// needs, so the widest one that fits still has a little air after its last segment rather than
    /// meeting the padding exactly. Segments are keyed by position rather than by their text — two
    /// rungs can legitimately draw the same string, and identity here is "which slot", not "which
    /// words".
    private func strip(_ rung: PaneStatusFacts.Rung) -> some View {
        HStack(spacing: 14) {
            ForEach(Array(facts.segments(rung).enumerated()), id: \.offset) { Text($0.element) }
            Spacer(minLength: 8)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// The bar plus the 30-second tick that keeps its freshness segment honest.
///
/// Split from the bar itself so ``PaneStatusBar`` stays a function of its facts and can be
/// rendered at a fixed instant by a test. The tick is anchored to the read stamp rather than to
/// view creation, for the reason `DifferencesView.withScanFreshness` gives: an arbitrary phase
/// puts every label up to 30s from the truth and lands the fresh→stale flip late by the same
/// amount. With nothing loaded there is no age to tick, so the bar renders once.
struct TickingPaneStatusBar: View {

    var facts: PaneStatusFacts

    var body: some View {
        if let readAt = facts.readAt {
            TimelineView(.periodic(from: readAt, by: 30)) { context in
                PaneStatusBar(facts: at(context.date))
            }
        } else {
            PaneStatusBar(facts: facts)
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
/// **It takes a `PaneTree`, never a `[FileNode]`.** Holding the raw graph in a SwiftUI view is
/// verbatim the bug `PaneTree`'s own documentation exists to describe — `FileNode`'s derived `==`
/// recurses through the whole subtree, and a ~40,000-node pane then pays an O(tree) comparison on
/// the main thread every time SwiftUI asks whether this view changed. `PaneTree` compares by
/// stamp; the nodes are reached only inside the census task, which runs off the main actor.
///
/// The census restarts on the stamp, which is the pane's publish counter — so a scan, a delete, a
/// navigation or a hidden-files toggle each supersede the count in flight and the bar returns to
/// `—` while the new one runs. That is the honest state: the previous number was about a tree that
/// no longer exists.
public struct BrowseStatusBar: View {

    var itemCount: Int
    var tree: PaneTree
    var selection: PaneStatusFacts.Selection?
    var readAt: Date?
    /// Substituted by the tests, for the reason ``CloudOnlyCensus/count(in:stat:)`` gives.
    var stat: MaterializationStatus.StatFlags = MaterializationStatus.realStatFlags

    @State private var cloudOnlyCount: Int?

    public init(itemCount: Int, tree: PaneTree, selection: PaneStatusFacts.Selection?,
                readAt: Date?,
                stat: @escaping MaterializationStatus.StatFlags = MaterializationStatus.realStatFlags) {
        self.itemCount = itemCount
        self.tree = tree
        self.selection = selection
        self.readAt = readAt
        self.stat = stat
    }

    public var body: some View {
        TickingPaneStatusBar(facts: PaneStatusFacts(itemCount: itemCount,
                                                    selection: selection,
                                                    cloudOnlyCount: cloudOnlyCount,
                                                    readAt: readAt))
            .task(id: tree.version) {
                // Back to `—` FIRST. Without this the previous tree's count sits under the new
                // tree's rows for as long as the walk takes, which is the one thing the roadmap's
                // brief rules out by name: a number that is about to change.
                cloudOnlyCount = nil
                // Nil comes back from a cancelled census, and cancellation here means the pane
                // republished — so the successor task owns the answer and this one must not write
                // the `nil` it would otherwise publish a second time.
                if let count = await CloudOnlyCensus.run(over: tree.nodes, stat: stat) {
                    cloudOnlyCount = count
                }
            }
    }
}

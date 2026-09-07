import Foundation
import Design
import Sync

/// The four facts Browse's status bar states, and every word it uses to state them.
///
/// **Pure, and separate from the view, because the interesting part is the shedding.** The bar has
/// to fit a pane that is sometimes 250pt wide, so it drops segments from the right as the column
/// narrows — and which segment goes at which width is a decision worth pinning in a test rather
/// than provoking through a layout. The view is then a `ViewThatFits` over rungs this type names,
/// exactly the bargain ``EditorStatusLine`` strikes (and the reason this reads like it).
///
/// **The order they shed in is the order they are worth**, read out of the roadmap's own brief:
/// the item count stays longest because it is the only segment that is true of the pane rather
/// than of something happening to it, and it is the one a person glances down for. The freshness
/// goes first — it is the slowest-moving fact here, and the header's ↻ rung already carries a
/// spinner while a walk runs. Then the cloud-only census, which is a property of the whole tree
/// and not of what is on screen. The selection is second-to-last because it is the only segment
/// that answers a question the user has just asked by clicking.
public struct PaneStatusFacts: Equatable {

    /// Every file and folder in the pane's tree, recursively — `FileSyncManager.leftItemCount`,
    /// the same number Compare's own footer reads.
    public var itemCount: Int

    /// What this pane has selected, or nil when nothing is.
    public var selection: Selection?

    /// How many files in the whole tree are cloud-only placeholders, or **nil while the census is
    /// still walking**.
    ///
    /// Nil is not "none" and is not rendered as a zero: the roadmap's brief is explicit that this
    /// reads `—` until the walk finishes, "rather than a number that is about to change". The
    /// census is `lstat` per file over a tree that routinely holds 40,000 nodes, so the window
    /// where this is nil is real and a number climbing through it would be worse than a dash.
    public var cloudOnlyCount: Int?

    /// When the walk behind the rows on screen read the disk, or nil when the pane has never
    /// loaded a tree.
    public var readAt: Date?

    /// The pane's selection, reduced to the three numbers the bar states.
    public struct Selection: Equatable {
        public var itemCount: Int
        /// Summed `fileSize` of the selected FILES. Folders contribute nothing — their byte size
        /// is not in the tree, and a walk to find it is exactly what this bar must never do. The
        /// same rule (and the same reason) as `DetailsSelectionSummary`.
        public var fileBytes: Int64
        /// How many of the selected paths are known to be cloud-only.
        ///
        /// **From the badge memo, not from the census**, which is why it can be right while
        /// `cloudOnlyCount` is still nil. A selected row has been drawn, so `CloudOnlyBadgeCache`
        /// already holds its answer — the same read File ▸ Download makes for the same reason, and
        /// no new syscall. The two segments can therefore disagree in kind for a moment (one
        /// answering about three rows, the other still counting forty thousand), but neither is
        /// ever wrong about its own scope, which is the property that matters.
        public var cloudOnlyCount: Int

        public init(itemCount: Int, fileBytes: Int64, cloudOnlyCount: Int) {
            self.itemCount = itemCount
            self.fileBytes = fileBytes
            self.cloudOnlyCount = cloudOnlyCount
        }

        /// Reduces a pane's already-resolved selection nodes.
        ///
        /// **Takes nodes, never paths.** `paneColumn` resolves its own selection once per render
        /// (`ownNodes`) for the header's Delete rung, and that resolution is a walk this bar must
        /// not repeat — the whole point of `FileSyncManager`'s path→node index is that the walk
        /// happens once.
        ///
        /// `isCloudOnly` is the badge memo's `cached(_:)`, injected so the rule can be tested
        /// without a real dataless file (an `SF_` flag no test can set — see
        /// `MaterializationStatus.StatFlags`). It answers nil for a path nobody has statted yet,
        /// and nil counts as **not** cloud-only: this clause says how many of the selection are
        /// known to live in the cloud, and an unstatted row is not known to.
        ///
        /// `@MainActor`, and the annotation is `CloudOnlyBadgeCache`'s rather than this type's:
        /// the memo is main-actor state, so its `cached(_:)` cannot be handed to a nonisolated
        /// closure parameter at all. Everything that builds a selection is already on the main
        /// actor — this runs inside a view body.
        @MainActor
        public static func make(nodes: [FileNode],
                                isCloudOnly: @MainActor (String) -> Bool?) -> Selection? {
            guard !nodes.isEmpty else { return nil }
            var bytes: Int64 = 0
            var inCloud = 0
            for node in nodes where !node.isDirectory {
                bytes += Int64(node.fileSize ?? 0)
                if isCloudOnly(node.id) == true { inCloud += 1 }
            }
            return Selection(itemCount: nodes.count, fileBytes: bytes, cloudOnlyCount: inCloud)
        }
    }

    /// The rungs, widest first, named so a test can ask for one.
    ///
    /// `CaseIterable` **in shedding order**, and that order is the specification: the view spells
    /// its `ViewThatFits` candidates out one by one (a `ForEach` there is a single child and would
    /// collapse the ladder), and `theLadderOffersEveryRungInSheddingOrder` checks that list against
    /// `allCases`. So a rung added here and forgotten there fails rather than going unoffered.
    public enum Rung: CaseIterable { case full, selectionAndCloud, selection, items }

    /// Which segments a rung draws. Every rung draws `items`; the rest fall off the right.
    func segments(_ rung: Rung) -> [String] {
        var parts = [itemsCaption]
        if let selection, rung != .items { parts.append(Self.selectionCaption(selection)) }
        if rung == .full || rung == .selectionAndCloud { parts.append(cloudOnlyCaption) }
        if rung == .full, let freshness { parts.append(freshness.text) }
        return parts
    }

    /// `1,284 items` — grouped, because a bare `1284` in a strip of small type is a smear. `1 item`
    /// singular; `Empty` at zero, which says the same thing as "0 items" and reads as a state
    /// rather than as a measurement that failed.
    var itemsCaption: String {
        switch itemCount {
        case 0: return "Empty"
        case 1: return "1 item"
        default: return "\(itemCount.formatted()) items"
        }
    }

    /// `3 selected · 42.6 MB, 1 in the cloud`.
    ///
    /// The size clause is dropped when only folders are selected (there are no bytes this bar is
    /// allowed to know), and the cloud clause when none of the selection is cloud-only — a
    /// `0 in the cloud` on every ordinary selection would be furniture.
    static func selectionCaption(_ selection: Selection) -> String {
        var caption = "\(selection.itemCount.formatted()) selected"
        var detail: [String] = []
        if selection.fileBytes > 0 {
            detail.append(ByteCountFormatter.string(fromByteCount: selection.fileBytes, countStyle: .file))
        }
        if selection.cloudOnlyCount > 0 {
            detail.append("\(selection.cloudOnlyCount.formatted()) in the cloud")
        }
        guard !detail.isEmpty else { return caption }
        caption += " · " + detail.joined(separator: ", ")
        return caption
    }

    /// `212 in the cloud only`, or `— in the cloud only` while the census walks. See
    /// ``cloudOnlyCount`` for why the dash is not a zero.
    var cloudOnlyCaption: String {
        guard let cloudOnlyCount else { return "— in the cloud only" }
        return "\(cloudOnlyCount.formatted()) in the cloud only"
    }

    /// The freshness of the rows on screen, or nil when nothing has been loaded — in which case the
    /// segment is absent rather than reading "never", because a pane with no tree has nothing under
    /// the bar for the word to be about.
    ///
    /// `now` is a parameter so the caller's ticking clock drives it, the way the differences pill's
    /// does; the type has no clock of its own.
    var freshness: ScanFreshness.Result? {
        guard let readAt else { return nil }
        return ScanFreshness.describe(scanDate: readAt, now: now)
    }

    /// Memberwise, spelled out because the compiler's is internal and the app composes this from
    /// another module. `now` defaults to *now*, so only a test placing the clock passes it.
    public init(itemCount: Int, selection: Selection? = nil, cloudOnlyCount: Int? = nil,
                readAt: Date? = nil, now: Date = Date()) {
        self.itemCount = itemCount
        self.selection = selection
        self.cloudOnlyCount = cloudOnlyCount
        self.readAt = readAt
        self.now = now
    }

    /// The clock the freshness is measured against. Held rather than read, so a test can place
    /// `readAt` and `now` a known distance apart and the bar can be re-rendered on a tick without
    /// the rest of the facts moving.
    public var now: Date = Date()

    /// One sentence for VoiceOver, for the reason ``EditorStatusLine`` gives: five stops in a row
    /// on the way past a strip beside the thing a person came here to read.
    ///
    /// **Always the full set, whatever rung is drawn.** Shedding is a width bargain, and VoiceOver
    /// has no width — a narrow pane must not make the cloud-only count unspeakable. The freshness
    /// goes in through `spoken`, which is the one place staleness is put into words.
    var accessibilityLabel: String {
        var parts = [itemsCaption]
        if let selection { parts.append(Self.selectionCaption(selection)) }
        parts.append(cloudOnlyCaption)
        if let freshness { parts.append(freshness.spoken) }
        return parts.joined(separator: ", ")
    }
}

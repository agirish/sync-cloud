import Foundation
import Design
import Sync

/// The four facts Browse's status bar states, and every word it uses to state them.
///
/// Pure and separate from the view so the shedding can be pinned in a test: the bar drops
/// segments from the right as a narrow pane narrows, and the view is a `ViewThatFits` over the
/// rungs this type names, as ``EditorStatusLine`` is.
///
/// They shed in order of worth. The freshness goes first (the header's ↻ already spins while a
/// walk runs), then the cloud-only census, a property of the whole tree, then the selection. The
/// item count stays longest: it is what a person glances down for.
public struct PaneStatusFacts: Equatable {

    /// Every file and folder in the pane's tree, recursively: `FileSyncManager.leftItemCount`, the
    /// number Compare's footer reads.
    public var itemCount: Int

    /// What this pane has selected, or nil when nothing is.
    public var selection: Selection?

    /// How many files in the whole tree are cloud-only placeholders, or nil while the census is
    /// still walking.
    ///
    /// Nil is not "none": it reads `—` until the walk finishes, not a number about to change. The
    /// census is an `lstat` per file over tens of thousands of nodes, so the nil window is real.
    public var cloudOnlyCount: Int?

    /// When the walk behind the rows on screen read the disk, or nil when the pane has never
    /// loaded a tree.
    public var readAt: Date?

    /// The folder watcher saw the pane's folder change since that walk began
    /// (`FileSyncManager.leftChangedOnDisk`), and the freshness segment says so.
    public var changedOnDisk: Bool = false

    /// The pane's type filter, when one is on: how many items there are before it, and what it
    /// shows. `itemCount` is then the count after it, so the caption reads "28 of 52 items".
    public var typeFilter: TypeFilter?

    public struct TypeFilter: Equatable {
        /// Every file and folder before the type filter.
        public var totalCount: Int
        /// The chip's words: "Images", "Images, PDFs".
        public var summary: String

        public init(totalCount: Int, summary: String) {
            self.totalCount = totalCount
            self.summary = summary
        }
    }

    /// The pane's selection, reduced to the three numbers the bar states.
    public struct Selection: Equatable {
        public var itemCount: Int
        /// Summed `fileSize` of the selected files. Folders add nothing: their size is not in the
        /// tree, and this bar must never walk to find it. The same rule as `DetailsSelectionSummary`.
        public var fileBytes: Int64
        /// How many of the selected paths are known to be cloud-only.
        ///
        /// From the badge memo, not the census, so it can be right while `cloudOnlyCount` is still
        /// nil: a selected row has been drawn, so `CloudOnlyBadgeCache` already holds its answer
        /// (the read File ▸ Download makes) and no syscall is needed.
        public var cloudOnlyCount: Int

        public init(itemCount: Int, fileBytes: Int64, cloudOnlyCount: Int) {
            self.itemCount = itemCount
            self.fileBytes = fileBytes
            self.cloudOnlyCount = cloudOnlyCount
        }

        /// Reduces a pane's already-resolved selection nodes.
        ///
        /// Takes nodes, never paths: `paneColumn` already resolves its selection once per render
        /// (`ownNodes`), and this bar must not repeat the walk.
        ///
        /// `isCloudOnly` is the badge memo's `cached(_:)`, injected so a test needs no dataless
        /// file (see `MaterializationStatus.StatFlags`). Nil, for a path not yet statted, counts as
        /// not cloud-only: the clause counts what is known to be in the cloud.
        ///
        /// `@MainActor` because the memo is main-actor state, so its `cached(_:)` can't be passed
        /// as a nonisolated closure. Every caller is a view body, already on the main actor.
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
    /// `CaseIterable` in shedding order, which is the specification. The view spells its
    /// `ViewThatFits` candidates out one by one, and `theLadderOffersEveryRungInSheddingOrder`
    /// checks them against `allCases`, so a rung added here and forgotten there fails.
    public enum Rung: CaseIterable { case full, selectionAndCloud, selection, items }

    /// Which segments a rung draws. Every rung draws `items`; the rest fall off the right.
    func segments(_ rung: Rung) -> [String] {
        var parts = [itemsCaption]
        if let selection, rung != .items { parts.append(Self.selectionCaption(selection)) }
        if rung == .full || rung == .selectionAndCloud { parts.append(cloudOnlyCaption) }
        if rung == .full, let freshness { parts.append(freshness.text) }
        return parts
    }

    /// `1,284 items`, grouped so small type stays legible; `1 item` singular; `Empty` at zero, which
    /// reads as a state rather than a failed measurement. With a type filter, `28 of 52 items`.
    var itemsCaption: String {
        if let typeFilter {
            return "\(itemCount.formatted()) of \(typeFilter.totalCount.formatted()) items"
        }
        switch itemCount {
        case 0: return "Empty"
        case 1: return "1 item"
        default: return "\(itemCount.formatted()) items"
        }
    }

    /// `3 selected · 42.6 MB, 1 in the cloud`.
    ///
    /// The size clause is dropped when only folders are selected (this bar knows no folder bytes),
    /// and the cloud clause when none of the selection is cloud-only.
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

    /// The freshness of the rows on screen, or nil when nothing has been loaded: the segment is
    /// then absent rather than reading "never". Measured against `now`, which the caller's ticking
    /// clock sets, as the differences pill's does.
    var freshness: ScanFreshness.Result? {
        guard let readAt else { return nil }
        return ScanFreshness.describe(scanDate: readAt, now: now, changedOnDisk: changedOnDisk)
    }

    /// Memberwise, spelled out because the compiler's is internal and the app builds this from
    /// another module. Only a test placing the clock passes `now`.
    public init(itemCount: Int, selection: Selection? = nil, cloudOnlyCount: Int? = nil,
                readAt: Date? = nil, changedOnDisk: Bool = false, now: Date = Date(),
                typeFilter: TypeFilter? = nil) {
        self.typeFilter = typeFilter
        self.itemCount = itemCount
        self.selection = selection
        self.cloudOnlyCount = cloudOnlyCount
        self.readAt = readAt
        self.changedOnDisk = changedOnDisk
        self.now = now
    }

    /// The clock the freshness is measured against. Held rather than read, so a test can place it a
    /// known distance from `readAt` and a tick can re-render the bar without moving the other facts.
    public var now: Date = Date()

    /// One sentence for VoiceOver, for the reason ``EditorStatusLine`` gives: not a stop per segment.
    ///
    /// Always the full set, whatever rung is drawn: VoiceOver has no width, so a narrow pane must
    /// not make a segment unspeakable. The freshness goes in through `spoken`, its spoken form.
    var accessibilityLabel: String {
        var parts = [itemsCaption]
        if let typeFilter { parts.append("filtered to \(typeFilter.summary)") }
        if let selection { parts.append(Self.selectionCaption(selection)) }
        parts.append(cloudOnlyCaption)
        if let freshness { parts.append(freshness.spoken) }
        return parts.joined(separator: ", ")
    }
}

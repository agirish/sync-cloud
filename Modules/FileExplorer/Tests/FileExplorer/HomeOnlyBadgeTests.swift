import Testing
import AppKit
import SwiftUI
import Sync
@testable import FileExplorer

/// The `⌂ on this Mac only` row badge: what it paints, when it does not, and that it can never
/// paint alongside the ☁ badge it mirrors.
///
/// **Pixels, not geometry.** ⌂ and ☁ share one slot and one font, so they occupy identical width —
/// a `fittingSize` assertion cannot tell them apart, and cannot tell either from an empty slot on
/// a row that reserves one. `FileRowAccessoryStabilityTests` owns the geometry question (the slot
/// does not move when an answer lands); this owns the paint question.
@MainActor
@Suite(.machinePinned(.pixelSampling)) struct HomeOnlyBadgeRenderTests {

    private static let canvas = CGSize(width: 60, height: 24)

    /// Renders the accessory cluster and returns its bitmap.
    ///
    /// The window background is not decoration. Without one the glyph composites against a
    /// borderless window's own buffer and every difference reads as zero — the "diffs against
    /// BLACK" trap that made a shortcut-reveal pixel test vacuous.
    private func bitmap(isCloudOnly: Bool, isOnThisMacOnly: Bool, reserves: Bool = true) -> NSBitmapImageRep? {
        let subject = HStack(spacing: 0) {
            FileRowAccessories(isCloudOnly: isCloudOnly, isOnThisMacOnly: isOnThisMacOnly,
                               reservesCloudSlot: reserves, diffStatus: nil, containedDiffCount: 0)
        }
        .frame(width: Self.canvas.width, height: Self.canvas.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, .light)

        let host = NSHostingView(rootView: AnyView(subject))
        host.frame = CGRect(origin: .zero, size: Self.canvas)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.colorSpace = .sRGB
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    private func pixelsDiffering(_ lhs: NSBitmapImageRep, _ rhs: NSBitmapImageRep) -> Int {
        var differing = 0
        for y in 0..<min(lhs.pixelsHigh, rhs.pixelsHigh) {
            for x in 0..<min(lhs.pixelsWide, rhs.pixelsWide) {
                guard let a = lhs.colorAt(x: x, y: y), let b = rhs.colorAt(x: x, y: y) else { continue }
                let delta = max(abs(a.redComponent - b.redComponent),
                                max(abs(a.greenComponent - b.greenComponent),
                                    abs(a.blueComponent - b.blueComponent)))
                if delta > 0.02 { differing += 1 }
            }
        }
        return differing
    }

    /// The badge paints something. Measured against the same row with the flag off, so the
    /// baseline is the row itself rather than an empty canvas.
    @Test func theHomeBadgePaints() throws {
        let none = try #require(bitmap(isCloudOnly: false, isOnThisMacOnly: false))
        let home = try #require(bitmap(isCloudOnly: false, isOnThisMacOnly: true))
        #expect(pixelsDiffering(none, home) > 0, "⌂ painted nothing at all")
    }

    /// …and the ☁ badge it mirrors paints something DIFFERENT. Without this the exclusivity test
    /// below would pass against a ⌂ that is secretly the cloud glyph.
    @Test func theTwoBadgesArePaintedDifferently() throws {
        let cloud = try #require(bitmap(isCloudOnly: true, isOnThisMacOnly: false))
        let home = try #require(bitmap(isCloudOnly: false, isOnThisMacOnly: true))
        #expect(pixelsDiffering(cloud, home) > 0, "⌂ and ☁ paint identically — they are one glyph")
    }

    /// **Mutual exclusion, in paint.** Both inputs true is the rare real case — a dataless file
    /// outside every DISCOVERED provider root. The row must show ☁ alone: "not on this Mac" is
    /// what was measured, "in no cloud folder" is the inference that is wrong there.
    @Test func whenBothApplyOnlyTheCloudBadgeIsPainted() throws {
        let cloudAlone = try #require(bitmap(isCloudOnly: true, isOnThisMacOnly: false))
        let both = try #require(bitmap(isCloudOnly: true, isOnThisMacOnly: true))
        #expect(pixelsDiffering(cloudAlone, both) == 0,
                "⌂ added paint to a row already showing ☁ — the two are not exclusive")
    }

    /// A row that reserves no slot (a directory, which can never show ☁) still paints ⌂ — the
    /// reservation and the badge are separate decisions. This is the branch that once silently
    /// dropped the cloud badge for unreserved callers.
    @Test func anUnreservedRowStillPaintsTheHomeBadge() throws {
        let none = try #require(bitmap(isCloudOnly: false, isOnThisMacOnly: false, reserves: false))
        let home = try #require(bitmap(isCloudOnly: false, isOnThisMacOnly: true, reserves: false))
        #expect(pixelsDiffering(none, home) > 0, "⌂ vanished on a row that reserves no slot")
    }
}

/// The badge's memo, and the one thing it has to get right: dropping every answer when the source
/// list moves.
@MainActor
@Suite struct HomeOnlyBadgeCacheTests {

    /// Built the way production builds it — from real providers through
    /// `FileLocation.coverage` — rather than by hand-assembling `CloudRoot`s. A memo test that
    /// invented its own coverage values could invalidate correctly against inputs the app never
    /// produces.
    private func coverage(_ roots: [(String, String)]) -> FileLocation.Coverage {
        FileLocation.coverage(
            of: roots.map { CloudProvider(id: $0.0, displayName: $0.0, imageName: "icloud",
                                          path: $0.1, type: .iCloud) },
            disabledProviderIds: [])
    }

    @Test func itAnswersWhatTheClassifierDoes() {
        let table = HomeOnlyBadgeCache.Table()
        let c = coverage([("iCloud", "/Users/u/iCloud")])
        #expect(table.isOutsideEveryCloudFolder(path: "/Users/u/Projects/a.txt", coverage: c))
        #expect(table.isOutsideEveryCloudFolder(path: "/Users/u/iCloud/a.txt", coverage: c) == false)
    }

    /// A second ask under the same coverage is served from the memo — the point of having one.
    @Test func aRepeatAskIsRemembered() {
        let table = HomeOnlyBadgeCache.Table()
        let c = coverage([("iCloud", "/Users/u/iCloud")])
        #expect(table.cached("/Users/u/Projects/a.txt", coverage: c) == nil)
        _ = table.isOutsideEveryCloudFolder(path: "/Users/u/Projects/a.txt", coverage: c)
        #expect(table.cached("/Users/u/Projects/a.txt", coverage: c) == true)
    }

    /// **The invalidation.** A folder that was outside every cloud root stops being so the moment
    /// a provider is re-pointed at it. Serving the remembered answer there is `4cae0471`'s finding
    /// outliving the provider.
    ///
    /// Mutation seam: delete the `self.coverage != coverage` wipe in
    /// `Table.isOutsideEveryCloudFolder` and this fails — the memo hands back `true` for a path
    /// that is now inside iCloud.
    @Test func aChangedSourceListDropsEveryRememberedAnswer() {
        let table = HomeOnlyBadgeCache.Table()
        let path = "/Users/u/Projects/a.txt"
        let before = coverage([("iCloud", "/Users/u/iCloud")])
        #expect(table.isOutsideEveryCloudFolder(path: path, coverage: before))

        // The user points iCloud at ~/Projects — the same path is now covered.
        let after = coverage([("iCloud", "/Users/u/Projects")])
        #expect(table.isOutsideEveryCloudFolder(path: path, coverage: after) == false,
                "served a remembered answer about a source list that no longer exists")
    }

    /// The other direction, which the first would not catch on its own: a provider REMOVED makes a
    /// covered path uncovered.
    @Test func removingAProviderAlsoDropsRememberedAnswers() {
        let table = HomeOnlyBadgeCache.Table()
        let path = "/Users/u/iCloud/a.txt"
        #expect(table.isOutsideEveryCloudFolder(
            path: path, coverage: coverage([("iCloud", "/Users/u/iCloud")])) == false)
        #expect(table.isOutsideEveryCloudFolder(path: path, coverage: .empty),
                "a path stayed covered after its provider was removed")
    }

    /// `cached` reports staleness as a MISS rather than as a stale hit — otherwise a caller could
    /// read the old answer without going through the wipe.
    @Test func aCachedLookupUnderNewCoverageMisses() {
        let table = HomeOnlyBadgeCache.Table()
        let path = "/Users/u/Projects/a.txt"
        let before = coverage([("iCloud", "/Users/u/iCloud")])
        _ = table.isOutsideEveryCloudFolder(path: path, coverage: before)
        #expect(table.cached(path, coverage: before) == true)
        #expect(table.cached(path, coverage: coverage([("iCloud", "/Users/u/Projects")])) == nil)
    }

    /// The capacity wipe, which cannot be tripped on the shared table without dropping the entries
    /// every parallel suite is asserting on — the reason `Table` is injectable at all.
    @Test func theTableIsBounded() {
        let table = HomeOnlyBadgeCache.Table(capacity: 4)
        let c = coverage([("iCloud", "/Users/u/iCloud")])
        for i in 0..<5 { _ = table.isOutsideEveryCloudFolder(path: "/Users/u/p/\(i)", coverage: c) }
        #expect(table.cached("/Users/u/p/0", coverage: c) == nil, "the memo grew past its capacity")
        #expect(table.cached("/Users/u/p/4", coverage: c) == true, "the newest answer was lost")
    }
}

/// That the ⌂ badge is actually IN the rows it ships on.
///
/// **The gap this closes is the one `RiskyNameBadgeWiringTests` was written for.** The suites above
/// exercise `FileRowAccessories` directly — so replacing `isOnThisMacOnly:` with `false` at both
/// pane call sites (`FileTreeView`'s row and `PaneColumnsView`'s) would leave every one of them
/// green while the badge appeared nowhere in the app. Columns is the default view mode, so a badge
/// wired into the tree alone would be missing from most of the usage.
///
/// Pixels rather than width, because ⌂ lands in the slot the cloud badge already reserves on a file
/// row: the row is exactly as wide with it as without, which is the whole point of the reservation
/// and the reason a `fittingSize` delta cannot see this.
@MainActor
@Suite(.serialized, .machinePinned(.pixelSampling)) struct HomeOnlyBadgeWiringTests {

    private static let canvas = CGSize(width: 260, height: 28)

    private func rowInfo() -> FileRowInfo {
        FileRowInfo(FileNode(id: "/root/notes.md", name: "notes.md", isDirectory: false, fileSize: 1024))
    }

    private func bitmap<V: View>(_ view: V) -> NSBitmapImageRep? {
        let subject = view
            .frame(width: Self.canvas.width, height: Self.canvas.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: AnyView(subject))
        host.frame = CGRect(origin: .zero, size: Self.canvas)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.colorSpace = .sRGB
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    private func pixelsDiffering(_ lhs: NSBitmapImageRep, _ rhs: NSBitmapImageRep) -> Int {
        var differing = 0
        for y in 0..<min(lhs.pixelsHigh, rhs.pixelsHigh) {
            for x in 0..<min(lhs.pixelsWide, rhs.pixelsWide) {
                guard let a = lhs.colorAt(x: x, y: y), let b = rhs.colorAt(x: x, y: y) else { continue }
                let delta = max(abs(a.redComponent - b.redComponent),
                                max(abs(a.greenComponent - b.greenComponent),
                                    abs(a.blueComponent - b.blueComponent)))
                if delta > 0.02 { differing += 1 }
            }
        }
        return differing
    }

    /// The tree pane's row. The two differ ONLY in `isOnThisMacOnly` — same node, same name, same
    /// density — so the delta cannot come from anything else on the row.
    @Test func theTreeRowDrawsTheBadge() throws {
        let without = try #require(bitmap(FileRowView(
            node: rowInfo(), isIgnored: false, diffStatus: nil, containedDiffCount: 0,
            density: .comfortable, isOnThisMacOnly: false)))
        let with = try #require(bitmap(FileRowView(
            node: rowInfo(), isIgnored: false, diffStatus: nil, containedDiffCount: 0,
            density: .comfortable, isOnThisMacOnly: true)))
        #expect(pixelsDiffering(without, with) > 0,
                "FileRowView is not passing isOnThisMacOnly through — the badge ships nowhere")
    }

    /// The Columns row, which wraps `FileRowView` — the default view mode.
    @Test func theColumnsRowDrawsTheBadge() throws {
        let row = PaneRow(side: .left, version: 0,
                          node: FileNode(id: "/root/notes.md", name: "notes.md",
                                         isDirectory: false, fileSize: 1024),
                          children: nil)
        let without = try #require(bitmap(ColumnRowView(
            row: row, isIgnored: false, diffStatus: nil, containedDiffCount: 0,
            density: .comfortable, showsChevron: false, isOnThisMacOnly: false)))
        let with = try #require(bitmap(ColumnRowView(
            row: row, isIgnored: false, diffStatus: nil, containedDiffCount: 0,
            density: .comfortable, showsChevron: false, isOnThisMacOnly: true)))
        #expect(pixelsDiffering(without, with) > 0,
                "ColumnRowView is not passing isOnThisMacOnly through — the badge is missing from the default view mode")
    }
}

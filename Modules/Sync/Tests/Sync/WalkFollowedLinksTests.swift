import Testing
import Foundation
import Combine
@testable import Sync

/// **What a walk records about the folder links it follows** — the provenance the targeted cache
/// drop (`dropPrefetchedTrees(holding:)`) and the app's "which pane holds this file" read, so that
/// neither has to traverse a tree to answer.
///
/// Below a folder symlink the walk's ids come back resolved, so a write spelled the way a pane row
/// names it is under no prefix of the root. The walk is the one place that knows it went through
/// a link; these pin what it writes down, where that record travels, and what clears it.
@Suite struct WalkFollowedLinksTests {

    /// `R` holds `link → T` (outside it), `inside → R/plain` (inside it) and `loop → R` (a cycle);
    /// `T/sub` holds `link2 → U`, outside both. `Q` holds a RELATIVE link, `rel → ../T/sub`.
    private static func makeFixture() throws -> (base: URL, r: URL, t: URL, u: URL, q: URL) {
        let fm = FileManager.default
        let base = try makeCanonicalTempRoot(prefix: "synccloud-walk-followed-links")
        let r = base.appendingPathComponent("R", isDirectory: true)
        let t = base.appendingPathComponent("T", isDirectory: true)
        let u = base.appendingPathComponent("U", isDirectory: true)
        let q = base.appendingPathComponent("Q", isDirectory: true)
        try fm.createDirectory(at: r.appendingPathComponent("plain"), withIntermediateDirectories: true)
        try fm.createDirectory(at: t.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try fm.createDirectory(at: u.appendingPathComponent("u1"), withIntermediateDirectories: true)
        try fm.createDirectory(at: q, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: t.appendingPathComponent("sub/x.txt"))
        try Data("p".utf8).write(to: r.appendingPathComponent("plain/p.txt"))
        try Data("u".utf8).write(to: u.appendingPathComponent("u1/u.txt"))
        try fm.createSymbolicLink(at: r.appendingPathComponent("link"), withDestinationURL: t)
        try fm.createSymbolicLink(at: r.appendingPathComponent("inside"), withDestinationURL: r.appendingPathComponent("plain"))
        try fm.createSymbolicLink(at: r.appendingPathComponent("loop"), withDestinationURL: r)
        try fm.createSymbolicLink(at: t.appendingPathComponent("sub/link2"), withDestinationURL: u)
        try fm.createSymbolicLink(atPath: q.appendingPathComponent("rel").path, withDestinationPath: "../T/sub")
        return (base, r, t, u, q)
    }

    /// The spelling a target is recorded in — `resolvingSymlinksInPath`'s, which takes `/private`
    /// off a temp root, because it is the spelling `folder(_:holds:)` asks a written path in too.
    private static func resolved(_ url: URL) -> String { url.resolvingSymlinksInPath().path }

    private static func followed(walking url: URL, maxDepth: Int? = nil) async -> Set<String> {
        let followed = FileSyncManager.FollowedLinks()
        _ = await FileSyncManager.buildTree(url: url, sortOption: .name, maxDepth: maxDepth,
                                            linkedFolders: [:], followedLinks: followed)
        return followed.targets
    }

    // MARK: - The walk

    /// **Each folder link the walk listed outside its root, nested ones included.** `T` through
    /// `link`, and `U` through `link2`, which the walk reaches only inside `T`. Not `inside`, whose
    /// target the walk lists under `R` anyway, and not `loop`, which the cycle guard never lists. A
    /// relative link records where it really leads. And a walk through no link records nothing:
    /// the temp root's `/private`, which the resolver takes off, is not a link.
    @Test func aWalkRecordsEachFolderLinkItListedOutsideItsRoot() async throws {
        let f = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        #expect(await Self.followed(walking: f.r) == [Self.resolved(f.t), Self.resolved(f.u)])
        #expect(await Self.followed(walking: f.q) == [Self.resolved(f.t.appendingPathComponent("sub")), Self.resolved(f.u)],
                "a relative link was not recorded where it leads")
        #expect(await Self.followed(walking: f.t) == [Self.resolved(f.u)])
        #expect(await Self.followed(walking: f.u).isEmpty, "a walk through no link recorded one")
    }

    /// **A root reached through a link records where it resolves**: a pane on the link itself, or
    /// focused below it, lists ids spelled where the link leads from its first level down. Its own
    /// nested link is recorded beside it.
    @Test func aRootReachedThroughALinkRecordsWhereItResolves() async throws {
        let f = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        #expect(await Self.followed(walking: f.r.appendingPathComponent("link"))
                == [Self.resolved(f.t), Self.resolved(f.u)], "a root that IS a link")
        #expect(await Self.followed(walking: f.r.appendingPathComponent("link/sub"))
                == [Self.resolved(f.t.appendingPathComponent("sub")), Self.resolved(f.u)], "a root below one")
    }

    /// **A link the walk did not list is not recorded.** The shallow first paint stops at the
    /// root's children, so `link` is reported and never read — nothing of `T`'s is in that tree.
    @Test func aShallowWalkRecordsNoLinkItDidNotList() async throws {
        let f = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        #expect(await Self.followed(walking: f.r, maxDepth: 1).isEmpty)
    }

    // MARK: - Where the record travels

    /// **The cache entry carries its walk's targets, and the pane carries the walk it shows** —
    /// the pane's for the app, which asks after a write has already emptied the cache entry. Set by
    /// every publish, the cache hit included; moved by a swap; cleared with the pane's tree.
    @MainActor
    @Test func theEntryAndThePaneCarryTheWalksTargets() async throws {
        let f = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let m = FileSyncManager()
        m.linkedFolders = [:]
        let left = CloudProvider(id: "L", displayName: "L", imageName: "folder", rootPath: f.r.path, type: .localFolder)
        let right = CloudProvider(id: "R", displayName: "R", imageName: "folder", rootPath: f.u.path, type: .localFolder)
        await m.refreshTreesAndScan(left: left, right: right, comparing: false)
        let reach: Set<String> = [Self.resolved(f.t), Self.resolved(f.u)]
        #expect(m.prefetchedTreeLinkTargets[f.r.path] == reach, "the cache entry does not carry its walk's targets")
        #expect(m.prefetchedTreeLinkTargets[f.u.path] == nil, "a walk through no link has a record")
        #expect(m.leftTreeLinkTargets == reach, "the pane does not carry the targets of the walk it shows")
        #expect(m.rightTreeLinkTargets.isEmpty)

        m.leftTreeLinkTargets = []
        await m.refreshTreesAndScan(left: left, right: right, reloading: .leftOnly, comparing: false)
        #expect(m.leftTreeLinkTargets == reach, "a tree served from the cache lost its walk's targets")

        #expect(m.swapPanes(), "premise: the swap was refused")
        #expect(m.rightTreeLinkTargets == reach && m.leftTreeLinkTargets.isEmpty,
                "the targets did not travel with the tree")
        #expect(m.swapPanes(), "premise: the swap back was refused")
        try #require(m.leftTreeLinkTargets == reach, "premise: the swap back did not return the targets")
        m.invalidatePaneTree(isLeft: true)
        #expect(m.leftTreeLinkTargets.isEmpty, "a dropped tree's targets outlived it")
        m.rightTreeLinkTargets = reach
        m.invalidatePaneTree(isLeft: false)
        #expect(m.rightTreeLinkTargets.isEmpty, "a dropped right tree's targets outlived it")
    }

    /// **The shallow first paint publishes its root's record too.** A pane focused below a link
    /// draws rows spelled where the link leads from that first paint, seconds before the deep walk
    /// lands — and a document opened from one of them is saved under that spelling. Each publish
    /// of the pane's tree is watched, and the record read as it lands.
    @MainActor
    @Test func theShallowFirstPaintCarriesItsRootsRecord() async throws {
        let f = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let m = FileSyncManager()
        m.linkedFolders = [:]
        var seen: [Set<String>] = []
        let watch = m.$leftTree.dropFirst().sink { _ in MainActor.assumeIsolated { seen.append(m.leftTreeLinkTargets) } }
        defer { watch.cancel() }
        await m.loadTree(path: f.r.appendingPathComponent("link/sub").path, isLeft: true)
        let sub = Self.resolved(f.t.appendingPathComponent("sub"))
        try #require(seen.count >= 2, "premise: no shallow paint was published before the deep tree: \(seen)")
        #expect(seen.first == [sub], "the first paint did not carry where its root resolves: \(seen)")
        #expect(seen.last == [sub, Self.resolved(f.u)], "the deep tree did not carry its walk's record: \(seen)")
    }

    /// **A slice inherits its root's targets**, as it inherits the root's stopped bit and read
    /// stamp: it is part of that walk. Liberally — the record does not say where in the tree each
    /// link sits, so a slice holding none of them over-reports, which costs a needless drop and
    /// never a stale tree.
    @MainActor
    @Test func aSliceInheritsItsRootsTargets() async throws {
        let f = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let m = FileSyncManager()
        m.linkedFolders = [:]
        await m.loadTree(path: f.r.path, isLeft: true)
        let reach: Set<String> = [Self.resolved(f.t), Self.resolved(f.u)]
        try #require(m.prefetchedTreeLinkTargets[f.r.path] == reach, "premise: the root's walk recorded no targets")

        m.leftRelativePath = "plain"
        await m.loadTree(path: f.r.path, isLeft: true)
        let plain = f.r.appendingPathComponent("plain").path
        try #require(m.lastLoadedLeftFocusPath == plain, "premise: the pane is not on the slice")
        #expect(m.prefetchedTreeLinkTargets[plain] == reach, "the slice's entry lost its root's targets")
        #expect(m.leftTreeLinkTargets == reach, "the pane on the slice lost its root's targets")
    }

    /// **A graft adds the link its one listing followed.** A column opening a link the walk left
    /// unread lists `T` for the first time, so the cache entry it writes back and the pane both
    /// learn `T` with it — or the next write there would leave that grafted tree stale.
    @MainActor
    @Test func aGraftAddsTheLinkItsListingFollowed() async throws {
        let f = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let m = FileSyncManager()
        m.linkedFolders = [:]
        let shallow = await FileSyncManager.buildTree(url: f.r, sortOption: .name, maxDepth: 1, linkedFolders: [:])
        let link = f.r.appendingPathComponent("link").path
        try #require(FileSyncManager.isUnexplored(atPath: link, under: f.r.path, in: shallow),
                     "premise: the link arrived already walked — this measures nothing")
        m.rawLeftTree = shallow
        m.lastLoadedLeftFocusPath = f.r.path
        m.prefetchedTrees[f.r.path] = shallow

        m.loadColumnChildren(atPath: link, isLeft: true)
        await waitUntil("the listing grafts into the pane's tree") {
            !FileSyncManager.isUnexplored(atPath: link, under: f.r.path, in: m.rawLeftTree)
        }
        #expect(m.prefetchedTreeLinkTargets[f.r.path] == [Self.resolved(f.t)],
                "the grafted cache entry does not know it now lists the link's target")
        #expect(m.leftTreeLinkTargets == [Self.resolved(f.t)], "the pane does not know it now lists the link's target")
        await waitUntil("the request clears") { m.columnGraftsInFlightPaths(isLeft: true).isEmpty }
    }

    // MARK: - What clears it

    /// **Both drop verbs take the targets with the entry**, and the one-folder form drops an entry
    /// for a write under its targets alone — `/r` is no prefix of `/t/sub`. Synthetic entries; the
    /// table is empty so the machine's own links never answer.
    @MainActor
    @Test func bothDropVerbsTakeTheTargetsWithTheEntry() {
        let m = FileSyncManager()
        m.linkedFolders = [:]
        m.prefetchedTrees["/r"] = []
        m.prefetchedTreeLinkTargets["/r"] = ["/t"]
        m.prefetchedTrees["/o"] = []
        m.prefetchedTreeLinkTargets["/o"] = ["/u"]
        #expect(m.dropPrefetchedTrees(holding: "/t/sub") == 1)
        #expect(m.prefetchedTrees["/r"] == nil && m.prefetchedTreeLinkTargets["/r"] == nil,
                "the walk that followed a link to the folder survived, or its record did")
        #expect(m.prefetchedTreeLinkTargets["/o"] == ["/u"], "a walk that reaches nothing written lost its record")
        m.dropPrefetchedTrees()
        #expect(m.prefetchedTreeLinkTargets.isEmpty, "emptying the cache left records with no entry")
    }
}

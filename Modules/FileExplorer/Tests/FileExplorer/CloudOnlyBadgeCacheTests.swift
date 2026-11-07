import Testing
import Foundation
@testable import FileExplorer

/// Pins `CloudOnlyBadgeCache`'s invalidation race. The badge stat runs off the main actor, so an
/// invalidation can land while one is in flight; a resuming stat must not write its superseded
/// answer back into the cleared memo, where it would serve the row until the next republish.
/// `forget(_:)` is the sharp case: it runs because a download was requested, so the answer it races
/// is the stale "still cloud-only" one.
///
/// `.serialized` because the cache is process-wide static state and these tests write it.
@Suite(.serialized) struct CloudOnlyBadgeCacheTests {

    /// Clears every root these fixtures use, and nothing else. `.serialized` orders this suite only
    /// against itself; the memo is shared with parallel suites that mount panes, and a whole-table
    /// wipe would clear their entries mid-test. The `memo-` prefixes avoid `/root`, which mounted
    /// pane suites use and clear on republish.
    @MainActor
    private func reset() {
        for root in ["/fixture", "/left", "/right", "/a", "/memo-root", "/memo-rootling", "/scoped"] {
            CloudOnlyBadgeCache.clear(underRoot: root)
        }
    }

    /// A stat that is guaranteed to observe the invalidation, by performing it itself at the exact
    /// point the real one is suspended off-actor.
    @MainActor
    private func statThatInvalidates(_ invalidate: @escaping @MainActor () -> Void)
    -> @MainActor (String) async -> Bool? {
        { _ in
            invalidate()
            return true
        }
    }

    @MainActor
    @Test func aStatSpanningAClearIsNotMemoized() async {
        reset()
        let path = "/fixture/spanning-clear.bin"

        let answer = await CloudOnlyBadgeCache.isCloudOnly(
            atPath: path, stat: statThatInvalidates { reset() })

        // The caller still gets the answer: it is the best truth available.
        #expect(answer)
        // But the memo must not hold it: the clear said everything it knew was stale.
        #expect(CloudOnlyBadgeCache.cached(path) == nil)
    }

    /// With no invalidation in the window the same call does memoize; otherwise the test above would
    /// pass for a cache that never memoizes.
    @MainActor
    @Test func aStatWithNoInvalidationIsMemoized() async {
        reset()
        let path = "/fixture/no-invalidation.bin"

        let answer = await CloudOnlyBadgeCache.isCloudOnly(atPath: path, stat: { _ in true })

        #expect(answer)
        #expect(CloudOnlyBadgeCache.cached(path) == true)
    }

    /// `forget(_:)` invalidates an in-flight stat too. On the download path it drops the
    /// pre-download answer, and a stat started earlier must not put "still cloud-only" back.
    @MainActor
    @Test func aStatSpanningAForgetIsNotMemoized() async {
        reset()
        let path = "/fixture/spanning-forget.bin"

        let answer = await CloudOnlyBadgeCache.isCloudOnly(
            atPath: path, stat: statThatInvalidates { CloudOnlyBadgeCache.forget(path) })

        #expect(answer)
        #expect(CloudOnlyBadgeCache.cached(path) == nil)
    }

    /// A `forget` of a different path also invalidates, on purpose: the generation is one counter,
    /// so a rare extra `lstat` buys a guard with no per-path bookkeeping to get wrong.
    @MainActor
    @Test func aForgetOfAnotherPathAlsoDeclinesToMemoize() async {
        reset()
        let path = "/fixture/mine.bin"

        let answer = await CloudOnlyBadgeCache.isCloudOnly(
            atPath: path, stat: statThatInvalidates { CloudOnlyBadgeCache.forget("/fixture/other.bin") })

        #expect(answer)
        #expect(CloudOnlyBadgeCache.cached(path) == nil)
    }

    /// A hit returns before the stat runs at all, which is the memo's purpose.
    @MainActor
    @Test func aCachedAnswerSkipsTheStatEntirely() async {
        reset()
        let path = "/fixture/hit.bin"
        CloudOnlyBadgeCache.record(path, isCloudOnly: true)

        var statRan = false
        let answer = await CloudOnlyBadgeCache.isCloudOnly(atPath: path, stat: { _ in
            statRan = true
            return false
        })

        #expect(answer)             // served from the memo, not the stat's `false`
        #expect(!statRan)
    }

    /// `record` is unconditional: the download poll calls it with an observation made after any
    /// invalidation it raced, so it is fresher and must land. Only `isCloudOnly`'s memoizing tail is
    /// generation-guarded.
    @MainActor
    @Test func recordIsNotGenerationGuarded() {
        reset()
        let path = "/fixture/poll-result.bin"

        CloudOnlyBadgeCache.forget(path)                       // bumps the generation
        CloudOnlyBadgeCache.record(path, isCloudOnly: false)   // the poll's fresh observation

        #expect(CloudOnlyBadgeCache.cached(path) == false)
    }

    /// An answer recorded while a stat was out beats that stat's later, staler one. `record` doesn't
    /// bump the generation (see below), so the memoizing tail checks the entry itself. The real
    /// case: a watch records `false` as the content lands while the arming re-stat is still out with
    /// the pre-download `true`, which would otherwise keep a cloud badge on a local file.
    @MainActor
    @Test func anAnswerRecordedWhileTheStatWasOutIsNotOverwritten() async {
        reset()
        let path = "/fixture/landed-mid-stat.bin"

        let answer = await CloudOnlyBadgeCache.isCloudOnly(atPath: path, stat: { probed in
            // The download lands while this stat is out.
            CloudOnlyBadgeCache.record(probed, isCloudOnly: false)
            return true    // ...and this is the pre-landing answer, now stale.
        })

        #expect(answer, "the caller must still get its own best available truth")
        #expect(CloudOnlyBadgeCache.cached(path) == false,
                "the resuming stat overwrote an answer that had seen more than it did")
    }

    /// Another path's `record` leaves this stat free to memoize, which is why the check above is
    /// per-entry, not a generation bump in `record`. A `List` realizes rows by the dozen, each
    /// stat-and-record, so a bump would leave the memo writing almost nothing while scrolling.
    /// Contrast `aForgetOfAnotherPathAlsoDeclinesToMemoize`: a forget throws an answer away, so it
    /// is global; a record only adds one.
    @MainActor
    @Test func anotherPathsRecordDoesNotStopThisStatMemoizing() async {
        reset()
        let mine = "/fixture/mine.bin"
        let neighbour = "/fixture/neighbour.bin"

        let answer = await CloudOnlyBadgeCache.isCloudOnly(atPath: mine, stat: { _ in
            // A row beside this one resolves while this stat is out.
            CloudOnlyBadgeCache.record(neighbour, isCloudOnly: true)
            return true
        })

        #expect(answer)
        #expect(CloudOnlyBadgeCache.cached(mine) == true,
                "a neighbouring row's answer cost this one its memo entry")
    }

    // MARK: - A stat that could not answer

    /// A stat that can't answer memoizes nothing. The badge's stat must not fold "can't stat" into
    /// `false`, or a row for a just-vanished path memoizes "local content" for a missing file and is
    /// served it without a syscall. The caller still gets `false` (no badge either way), so this is
    /// purely a caching rule. Uses the production stat, since that mapping is what's under test.
    ///
    /// On a `Table` of its own so it can't go vacuous: the real stat suspends off the main actor,
    /// and on the shared table any parallel `forget` or `clear` (`PaneDownloadWatch.begin` forgets
    /// per request) would bump the generation and make `record(path, answer ?? false)` decline for
    /// the wrong reason. `anInjectedStatWithNoAnswerIsNotMemoized` pins the rule at the seam.
    @MainActor
    @Test func aStatThatCouldNotAnswerIsNotMemoized() async {
        let gone = "/fixture/vanished-\(UUID().uuidString).bin"
        let table = CloudOnlyBadgeCache.Table()

        let answer = await table.isCloudOnly(atPath: gone)

        #expect(!answer, "a path with no answer must still render as un-badged")
        #expect(table.cached(gone) == nil,
                "the memo holds an entry asserting local content for a path with no file behind it")
    }

    /// The same rule at the seam, without the filesystem, beside its guard
    /// `aStatWithNoInvalidationIsMemoized`, which shows a definite answer still memoizes.
    @MainActor
    @Test func anInjectedStatWithNoAnswerIsNotMemoized() async {
        reset()
        let path = "/fixture/no-answer.bin"

        let answer = await CloudOnlyBadgeCache.isCloudOnly(atPath: path, stat: { _ in nil })

        #expect(!answer)
        #expect(CloudOnlyBadgeCache.cached(path) == nil)
    }

    // MARK: - Root-scoped clear (C11)

    /// One pane's republish must not wipe the answers the other pane's rows still serve from.
    @MainActor
    @Test func aScopedClearDropsOnlyEntriesUnderItsRoot() {
        reset()
        CloudOnlyBadgeCache.record("/left/a.bin", isCloudOnly: true)
        CloudOnlyBadgeCache.record("/left/sub/b.bin", isCloudOnly: false)
        CloudOnlyBadgeCache.record("/right/c.bin", isCloudOnly: true)

        CloudOnlyBadgeCache.clear(underRoot: "/left")

        #expect(CloudOnlyBadgeCache.cached("/left/a.bin") == nil)
        #expect(CloudOnlyBadgeCache.cached("/left/sub/b.bin") == nil)
        // The other pane's memo survives.
        #expect(CloudOnlyBadgeCache.cached("/right/c.bin") == true)
    }

    /// Prefixes match per path component: `/a/bc` is not under `/a/b`, though a character-wise
    /// `hasPrefix(root)` would say it is.
    @MainActor
    @Test func aScopedClearDoesNotMatchSiblingsSharingACharacterPrefix() {
        reset()
        CloudOnlyBadgeCache.record("/a/bc", isCloudOnly: true)
        CloudOnlyBadgeCache.record("/a/b/child.bin", isCloudOnly: true)
        CloudOnlyBadgeCache.record("/a/b", isCloudOnly: true)

        CloudOnlyBadgeCache.clear(underRoot: "/a/b")

        #expect(CloudOnlyBadgeCache.cached("/a/bc") == true)          // sibling survives
        #expect(CloudOnlyBadgeCache.cached("/a/b/child.bin") == nil)  // descendant dropped
        #expect(CloudOnlyBadgeCache.cached("/a/b") == nil)            // the root itself dropped
    }

    /// A root handed in with a trailing separator scopes identically to one without.
    @MainActor
    @Test func aScopedClearNormalizesATrailingSeparator() {
        reset()
        CloudOnlyBadgeCache.record("/memo-root/x.bin", isCloudOnly: true)
        CloudOnlyBadgeCache.record("/memo-rootling/y.bin", isCloudOnly: true)

        CloudOnlyBadgeCache.clear(underRoot: "/memo-root/")

        #expect(CloudOnlyBadgeCache.cached("/memo-root/x.bin") == nil)
        #expect(CloudOnlyBadgeCache.cached("/memo-rootling/y.bin") == true)
    }

    /// `SettingsManager.rootPath(for:)` answers `""` for a provider it can't resolve, and
    /// `PaneLogic.fullPath` passes it through. Normalized to the prefix `"/"`, it would match every
    /// key, so that pane's republish would wipe the other pane's answers.
    @MainActor
    @Test func anEmptyRootClearsNothing() {
        reset()
        CloudOnlyBadgeCache.record("/left/a.bin", isCloudOnly: true)
        CloudOnlyBadgeCache.record("/right/c.bin", isCloudOnly: false)

        CloudOnlyBadgeCache.clear(underRoot: "")

        #expect(CloudOnlyBadgeCache.cached("/left/a.bin") == true)
        #expect(CloudOnlyBadgeCache.cached("/right/c.bin") == false)
    }

    /// The same guard as a rule: only an absolute root scopes a clear. A relative string can't
    /// prefix a key the walk produced, so matching it would take nothing or, like `""`, everything.
    @MainActor
    @Test func aRelativeRootClearsNothing() {
        reset()
        CloudOnlyBadgeCache.record("/left/a.bin", isCloudOnly: true)

        CloudOnlyBadgeCache.clear(underRoot: "left")

        #expect(CloudOnlyBadgeCache.cached("/left/a.bin") == true)
    }

    /// A no-op clear doesn't bump the generation: nothing was invalidated, so a stat in flight
    /// across it may memoize. Fails if `clear(underRoot:)` returns early but still bumps, which the
    /// two tests above would miss.
    @MainActor
    @Test func aStatSpanningAnEmptyRootClearIsStillMemoized() async {
        reset()
        let path = "/fixture/spanning-noop.bin"

        let answer = await CloudOnlyBadgeCache.isCloudOnly(
            atPath: path, stat: statThatInvalidates { CloudOnlyBadgeCache.clear(underRoot: "") })

        #expect(answer)
        #expect(CloudOnlyBadgeCache.cached(path) == true)
    }

    /// The filesystem root passes the absolute-path guard: it normalizes to `""`, whose descendant
    /// prefix is `/`, so a pane rooted there covers every absolute entry, truthfully. Asserted on
    /// the scope value, since clearing `/` on the real table would wipe every parallel suite's memo.
    @Test func theFilesystemRootScopesEveryAbsoluteEntry() throws {
        let scope = try #require(CloudOnlyBadgeCache.ClearScope(root: "/"))

        #expect(scope.contains("/left/a.bin"))
        #expect(scope.contains("/right/c.bin"))
    }

    /// The guard as a value: an unusable root has no scope, so there is no filter to run and no
    /// generation to bump.
    @Test func anUnusableRootHasNoScopeAtAll() {
        #expect(CloudOnlyBadgeCache.ClearScope(root: "") == nil)
        #expect(CloudOnlyBadgeCache.ClearScope(root: "left") == nil)
        #expect(CloudOnlyBadgeCache.ClearScope(root: "~/iCloud") == nil)
    }

    /// Every trailing separator is normalized away, not just one; `/root//` trimmed once would
    /// match no key the walk produced, and the clear would silently take nothing.
    @MainActor
    @Test func aScopedClearNormalizesRepeatedTrailingSeparators() {
        reset()
        CloudOnlyBadgeCache.record("/memo-root/x.bin", isCloudOnly: true)
        CloudOnlyBadgeCache.record("/memo-rootling/y.bin", isCloudOnly: true)

        CloudOnlyBadgeCache.clear(underRoot: "/memo-root//")

        #expect(CloudOnlyBadgeCache.cached("/memo-root/x.bin") == nil)
        #expect(CloudOnlyBadgeCache.cached("/memo-rootling/y.bin") == true)
    }

    /// Matching is case-sensitive, by decision: the memo is a dictionary, so `cached(_:)` already
    /// is. Keys come from the tree walk and roots from `PaneLogic.fullPath`, which agree because the
    /// walk starts from that root string; pinned so case-folding either side shows up here, not as
    /// a badge that never refreshes.
    @MainActor
    @Test func aScopedClearIsCaseSensitive() {
        reset()
        CloudOnlyBadgeCache.record("/memo-root/x.bin", isCloudOnly: true)

        CloudOnlyBadgeCache.clear(underRoot: "/Root")

        #expect(CloudOnlyBadgeCache.cached("/memo-root/x.bin") == true)
    }

    /// A scoped clear bumps the generation: a stat in flight when it lands must not memoize its
    /// now-stale answer.
    @MainActor
    @Test func aStatSpanningAScopedClearIsNotMemoized() async {
        reset()
        let path = "/scoped/spanning.bin"

        let answer = await CloudOnlyBadgeCache.isCloudOnly(
            atPath: path, stat: statThatInvalidates { CloudOnlyBadgeCache.clear(underRoot: "/scoped") })

        #expect(answer)
        #expect(CloudOnlyBadgeCache.cached(path) == nil)
    }

    /// The capacity wipe is a bulk invalidation and must bump the generation like any other.
    /// `isCloudOnly` memoizes only if the generation hasn't moved and the entry is still nil. A wipe
    /// can remove an answer written while the stat was out (a watch's landed `false`), leaving the
    /// entry nil; without a bump the stat would write its pre-download `true` back in.
    ///
    /// On a `Table` of its own: reaching the wipe means filling the table, and filling the
    /// process-wide memo would drop entries parallel suites assert on (`docs/flaky-tests.md`, "A
    /// mounted view is a live subscriber, in every suite at once").
    @MainActor
    @Test func aStatSpanningTheCapacityWipeIsNotMemoized() async {
        let table = CloudOnlyBadgeCache.Table(capacity: 2)
        let path = "/capacity/spanning.bin"
        table.record("/capacity/a.bin", isCloudOnly: true)      // 1 of 2

        let answer = await table.isCloudOnly(atPath: path, stat: { _ in
            table.record("/capacity/b.bin", isCloudOnly: true)  // 2 of 2 — now at capacity
            table.record("/capacity/c.bin", isCloudOnly: false) // trips the wipe, then writes c
            return true
        })

        // The caller still gets its answer: it is the best truth available.
        #expect(answer)
        // But the wipe dropped whatever was written while this stat was out, so the answer must not
        // be adopted.
        #expect(table.cached(path) == nil)
    }

    /// With no wipe in the window the same `Table` does memoize; otherwise the test above would pass
    /// for a seam that never memoizes.
    @MainActor
    @Test func aStatOnItsOwnTableWithNoWipeIsMemoized() async {
        let table = CloudOnlyBadgeCache.Table(capacity: 2)
        let path = "/capacity/quiet.bin"

        let answer = await table.isCloudOnly(atPath: path, stat: { _ in true })

        #expect(answer)
        #expect(table.cached(path) == true)
    }
}

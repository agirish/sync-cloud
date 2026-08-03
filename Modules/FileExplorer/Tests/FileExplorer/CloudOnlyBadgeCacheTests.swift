import Testing
import Foundation
@testable import FileExplorer

/// Pins `CloudOnlyBadgeCache`'s invalidation race.
///
/// The badge is resolved by a stat that runs OFF the main actor, so an invalidation can land while
/// one is in flight. Before the generation guard the resuming stat wrote its now-superseded answer
/// straight back into the freshly-cleared memo, where it served every later realization of that row
/// until the next republish. `forget(_:)` is the sharper case: it is called precisely because a
/// download was requested, so the in-flight answer it races is the stale "still cloud-only" one it
/// exists to discard.
///
/// `.serialized` because the cache is process-wide static state and these tests write it.
@Suite(.serialized) struct CloudOnlyBadgeCacheTests {

    /// Every root these fixtures use, and nothing else. `.serialized` orders this suite against
    /// ITSELF; the memo is shared with every OTHER suite running in parallel, several of which
    /// mount panes that record badges and republish. The whole-table reset this replaced (the
    /// parameterless `clear()`, since removed) wiped their entries too — which is how it was found:
    /// `CloudDownloadWatchTests` failed intermittently because this file cleared its memo mid-test.
    ///
    /// The `memo-` prefixes exist for the same reason: `/root` is a fixture root in several mounted
    /// pane suites, whose republishes issue a scoped clear of exactly that.
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

        // The caller still gets the answer — it is their best available truth.
        #expect(answer)
        // But the memo must not hold it: the clear said everything it knew was stale.
        #expect(CloudOnlyBadgeCache.cached(path) == nil)
    }

    /// Mutation guard: with no invalidation in the window, the very same call DOES memoize. Without
    /// this, the assertion above would pass just as well if the cache had stopped memoizing at all.
    @MainActor
    @Test func aStatWithNoInvalidationIsMemoized() async {
        reset()
        let path = "/fixture/no-invalidation.bin"

        let answer = await CloudOnlyBadgeCache.isCloudOnly(atPath: path, stat: { _ in true })

        #expect(answer)
        #expect(CloudOnlyBadgeCache.cached(path) == true)
    }

    /// `forget(_:)` must invalidate an in-flight stat too. This is the download path: the row asked
    /// for the file, `forget` dropped the pre-download answer, and a stat that started before that
    /// must not put "still cloud-only" back — which would undo the poll's whole purpose.
    @MainActor
    @Test func aStatSpanningAForgetIsNotMemoized() async {
        reset()
        let path = "/fixture/spanning-forget.bin"

        let answer = await CloudOnlyBadgeCache.isCloudOnly(
            atPath: path, stat: statThatInvalidates { CloudOnlyBadgeCache.forget(path) })

        #expect(answer)
        #expect(CloudOnlyBadgeCache.cached(path) == nil)
    }

    /// A `forget` of a DIFFERENT path also invalidates. That is deliberate over-invalidation: the
    /// generation is one counter, so the cost of a rare extra `lstat` buys a guard with no
    /// per-path bookkeeping to get wrong.
    @MainActor
    @Test func aForgetOfAnotherPathAlsoDeclinesToMemoize() async {
        reset()
        let path = "/fixture/mine.bin"

        let answer = await CloudOnlyBadgeCache.isCloudOnly(
            atPath: path, stat: statThatInvalidates { CloudOnlyBadgeCache.forget("/fixture/other.bin") })

        #expect(answer)
        #expect(CloudOnlyBadgeCache.cached(path) == nil)
    }

    /// A hit short-circuits before the stat runs at all — the memo's whole reason to exist.
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

    /// `record` stays an unconditional primitive: the download poll calls it with an observation
    /// made AFTER any invalidation it might have raced, so it is fresher than what was cleared and
    /// must land. Only the memoizing tail of `isCloudOnly` is generation-guarded.
    @MainActor
    @Test func recordIsNotGenerationGuarded() {
        reset()
        let path = "/fixture/poll-result.bin"

        CloudOnlyBadgeCache.forget(path)                       // bumps the generation
        CloudOnlyBadgeCache.record(path, isCloudOnly: false)   // the poll's fresh observation

        #expect(CloudOnlyBadgeCache.cached(path) == false)
    }

    /// An answer RECORDED while a stat was out wins over that stat's own, later, staler one.
    ///
    /// The generation counter cannot see this: `record` does not bump it, and must not — bumping
    /// there would have one row's answer invalidate every other row's in-flight stat, and a `List`
    /// realizes rows by the dozen. So the memoizing tail checks the entry itself instead. The case
    /// that matters is narrow and real: a download's watch records `false` the moment the content
    /// lands, while the arming re-stat for the same row is still out carrying the pre-download
    /// `true`. Without this the resuming stat wrote that `true` straight over the landed answer, and
    /// the badge went on claiming cloud-only for a file on disk until the next republish.
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

    /// And ANOTHER path's `record` leaves this stat free to memoize — the reason the check above is
    /// per-entry rather than a generation bump inside `record`.
    ///
    /// Bumping there is the obvious one-line alternative and it is wrong: a `List` realizes rows by
    /// the dozen, every one of them stats and records, so each landing answer would invalidate every
    /// other stat still in flight and the memo would write almost nothing during exactly the
    /// scrolling it exists for. This is the contrast with `aForgetOfAnotherPathAlsoDeclinesToMemoize`
    /// — a forget IS deliberately global, because it throws an answer away; a record only adds one.
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

    /// The memo's other door onto the same defect.
    ///
    /// The harm the download poll's three-way probe closed is "an entry asserting local content for
    /// a file that does not exist" — but the poll was only one of two writers into this table. The
    /// badge's own stat kept calling the two-way `MaterializationStatus.isCloudOnly`, which folds
    /// "cannot stat" into `false`, so a row realized for a path that had just vanished memoized
    /// exactly that entry by the other route, and every later realization of the row was served it
    /// without a syscall.
    ///
    /// The caller still gets `false` — rendering is unchanged, a row for a file that is not there
    /// carries no badge either way — so this is a caching decision and only a caching decision.
    ///
    /// The production default, not an injected stand-in, because that mapping is the whole fix. A
    /// UUID name under `/fixture`, so nothing in the table another suite is asserting on is touched.
    @MainActor
    @Test func aStatThatCouldNotAnswerIsNotMemoized() async {
        let gone = "/fixture/vanished-\(UUID().uuidString).bin"

        let answer = await CloudOnlyBadgeCache.isCloudOnly(atPath: gone)

        #expect(!answer, "a path with no answer must still render as un-badged")
        #expect(CloudOnlyBadgeCache.cached(gone) == nil,
                "the memo holds an entry asserting local content for a path with no file behind it")
    }

    /// The same rule at the seam, so the branch is pinned without depending on the filesystem —
    /// and so the mutation guard for it (`aStatWithNoInvalidationIsMemoized`, which proves a
    /// DEFINITE answer still memoizes) sits beside it on the same injected path.
    @MainActor
    @Test func anInjectedStatWithNoAnswerIsNotMemoized() async {
        reset()
        let path = "/fixture/no-answer.bin"

        let answer = await CloudOnlyBadgeCache.isCloudOnly(atPath: path, stat: { _ in nil })

        #expect(!answer)
        #expect(CloudOnlyBadgeCache.cached(path) == nil)
    }

    // MARK: - Root-scoped clear (C11)

    /// The reason `clear(underRoot:)` exists: one pane's republish must not wipe the answers the
    /// OTHER pane's rows are still serving from.
    @MainActor
    @Test func aScopedClearDropsOnlyEntriesUnderItsRoot() {
        reset()
        CloudOnlyBadgeCache.record("/left/a.bin", isCloudOnly: true)
        CloudOnlyBadgeCache.record("/left/sub/b.bin", isCloudOnly: false)
        CloudOnlyBadgeCache.record("/right/c.bin", isCloudOnly: true)

        CloudOnlyBadgeCache.clear(underRoot: "/left")

        #expect(CloudOnlyBadgeCache.cached("/left/a.bin") == nil)
        #expect(CloudOnlyBadgeCache.cached("/left/sub/b.bin") == nil)
        // The other pane's memo survives — the entire point of the scoping.
        #expect(CloudOnlyBadgeCache.cached("/right/c.bin") == true)
    }

    /// Prefix semantics are per path component: `/a/bc` is NOT under `/a/b`, and a character-wise
    /// `hasPrefix(root)` would have said it was.
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

    /// The regression this guard exists for: `SettingsManager.path(for:)` answers `""` for a
    /// provider id it cannot resolve, `PaneLogic.fullPath` passes `""` through, and the empty root
    /// then normalized to the prefix `"/"` — which EVERY absolute key matches. A pane whose
    /// provider failed to resolve republished its empty tree and wiped the other pane's answers:
    /// the global wipe the scoping was added to remove, through a side door.
    @MainActor
    @Test func anEmptyRootClearsNothing() {
        reset()
        CloudOnlyBadgeCache.record("/left/a.bin", isCloudOnly: true)
        CloudOnlyBadgeCache.record("/right/c.bin", isCloudOnly: false)

        CloudOnlyBadgeCache.clear(underRoot: "")

        #expect(CloudOnlyBadgeCache.cached("/left/a.bin") == true)
        #expect(CloudOnlyBadgeCache.cached("/right/c.bin") == false)
    }

    /// Same guard, stated as a rule rather than as one input: only an ABSOLUTE root scopes a clear.
    /// A relative string cannot be a prefix of a key the walk produced, so matching it would either
    /// take nothing or — as `""` did — take everything.
    @MainActor
    @Test func aRelativeRootClearsNothing() {
        reset()
        CloudOnlyBadgeCache.record("/left/a.bin", isCloudOnly: true)

        CloudOnlyBadgeCache.clear(underRoot: "left")

        #expect(CloudOnlyBadgeCache.cached("/left/a.bin") == true)
    }

    /// A no-op clear must not bump the generation either: nothing was invalidated, so a stat in
    /// flight across it still holds this memo's best available truth and may memoize.
    ///
    /// This is the mutation guard for the two tests above — a `clear(underRoot:)` that returned
    /// early but still bumped would pass them while quietly costing every in-flight stat.
    @MainActor
    @Test func aStatSpanningAnEmptyRootClearIsStillMemoized() async {
        reset()
        let path = "/fixture/spanning-noop.bin"

        let answer = await CloudOnlyBadgeCache.isCloudOnly(
            atPath: path, stat: statThatInvalidates { CloudOnlyBadgeCache.clear(underRoot: "") })

        #expect(answer)
        #expect(CloudOnlyBadgeCache.cached(path) == true)
    }

    /// The filesystem root is exempt from the absolute-path guard rather than special-cased by it:
    /// it normalizes to `""`, whose descendant prefix is `/`, so a pane genuinely rooted there
    /// covers every absolute entry — the truthful answer for that root.
    ///
    /// Asserted against the scope value, NOT by clearing the real table: a test that cleared `/`
    /// to prove `/` covers everything would wipe the memo out from under every suite running in
    /// parallel, which is precisely the class of bug this file is about.
    @Test func theFilesystemRootScopesEveryAbsoluteEntry() throws {
        let scope = try #require(CloudOnlyBadgeCache.ClearScope(root: "/"))

        #expect(scope.contains("/left/a.bin"))
        #expect(scope.contains("/right/c.bin"))
    }

    /// The guard, as a value: an unresolvable provider's root scopes NOTHING, so there is no
    /// filter for it to run and no generation for it to bump.
    @Test func anUnusableRootHasNoScopeAtAll() {
        #expect(CloudOnlyBadgeCache.ClearScope(root: "") == nil)
        #expect(CloudOnlyBadgeCache.ClearScope(root: "left") == nil)
        #expect(CloudOnlyBadgeCache.ClearScope(root: "~/iCloud") == nil)
    }

    /// Every trailing separator is normalized away, not just one: dropping a single character from
    /// `/root//` left the prefix `/root//`, which matches no key the tree walk ever produced — a
    /// clear that silently took nothing.
    @MainActor
    @Test func aScopedClearNormalizesRepeatedTrailingSeparators() {
        reset()
        CloudOnlyBadgeCache.record("/memo-root/x.bin", isCloudOnly: true)
        CloudOnlyBadgeCache.record("/memo-rootling/y.bin", isCloudOnly: true)

        CloudOnlyBadgeCache.clear(underRoot: "/memo-root//")

        #expect(CloudOnlyBadgeCache.cached("/memo-root/x.bin") == nil)
        #expect(CloudOnlyBadgeCache.cached("/memo-rootling/y.bin") == true)
    }

    /// Matching is case-SENSITIVE, and that is a decision rather than an oversight: the memo is a
    /// dictionary, so `cached(_:)` already is. Keys come from the tree walk and roots from
    /// `PaneLogic.fullPath`; today they agree by lineage (the walk descends from that very root
    /// string), which is an accident of plumbing worth pinning so a future case-folding of either
    /// side shows up here rather than as a badge that never refreshes.
    @MainActor
    @Test func aScopedClearIsCaseSensitive() {
        reset()
        CloudOnlyBadgeCache.record("/memo-root/x.bin", isCloudOnly: true)

        CloudOnlyBadgeCache.clear(underRoot: "/Root")

        #expect(CloudOnlyBadgeCache.cached("/memo-root/x.bin") == true)
    }

    /// A scoped clear preserves the generation semantics: a stat in flight when it lands must not
    /// memoize its now-stale answer — same contract as the whole-table `clear()`.
    @MainActor
    @Test func aStatSpanningAScopedClearIsNotMemoized() async {
        reset()
        let path = "/scoped/spanning.bin"

        let answer = await CloudOnlyBadgeCache.isCloudOnly(
            atPath: path, stat: statThatInvalidates { CloudOnlyBadgeCache.clear(underRoot: "/scoped") })

        #expect(answer)
        #expect(CloudOnlyBadgeCache.cached(path) == nil)
    }

    /// The capacity wipe is a bulk invalidation and must bump the generation like every other one.
    ///
    /// This is the door the per-entry check could not see. `isCloudOnly`'s guard is "the generation
    /// has not moved AND this entry is still nil", and its soundness argument is that anything
    /// written while we were out is newer than us. The wipe breaks it from the other side: an
    /// answer written while we were out — a download's watch recording `false` the moment content
    /// arrives — can be REMOVED while we are still out, leaving the entry nil again and the counter
    /// untouched, so the resuming stat wrote its pre-download `true` straight back in. That is
    /// verbatim the defect the per-entry check exists to close.
    ///
    /// Driven on a `Table` of its own because reaching the wipe means filling the table, and
    /// filling the process-wide memo would drop the entries every suite running in PARALLEL is
    /// asserting on — mechanism 9 in `docs/flaky-tests.md`. That is the whole reason the seam
    /// exists; `.serialized` orders this suite against itself only.
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

        // The caller still gets its answer — it is their best available truth.
        #expect(answer)
        // But the wipe threw away everything the memo knew, including whatever was written while
        // this stat was out, so this answer must not be adopted.
        #expect(table.cached(path) == nil)
    }

    /// Mutation guard for the test above: with no wipe in the window, the very same `Table` DOES
    /// memoize. Without this, that assertion would pass just as well if the seam never memoized at
    /// all — which is exactly how a test over a fresh instance goes quietly vacuous.
    @MainActor
    @Test func aStatOnItsOwnTableWithNoWipeIsMemoized() async {
        let table = CloudOnlyBadgeCache.Table(capacity: 2)
        let path = "/capacity/quiet.bin"

        let answer = await table.isCloudOnly(atPath: path, stat: { _ in true })

        #expect(answer)
        #expect(table.cached(path) == true)
    }
}

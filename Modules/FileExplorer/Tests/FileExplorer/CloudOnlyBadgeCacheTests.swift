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

    /// A stat that is guaranteed to observe the invalidation, by performing it itself at the exact
    /// point the real one is suspended off-actor.
    @MainActor
    private func statThatInvalidates(_ invalidate: @escaping @MainActor () -> Void)
    -> @MainActor (String) async -> Bool {
        { _ in
            invalidate()
            return true
        }
    }

    @MainActor
    @Test func aStatSpanningAClearIsNotMemoized() async {
        CloudOnlyBadgeCache.clear()
        let path = "/fixture/spanning-clear.bin"

        let answer = await CloudOnlyBadgeCache.isCloudOnly(
            atPath: path, stat: statThatInvalidates { CloudOnlyBadgeCache.clear() })

        // The caller still gets the answer — it is their best available truth.
        #expect(answer)
        // But the memo must not hold it: the clear said everything it knew was stale.
        #expect(CloudOnlyBadgeCache.cached(path) == nil)
    }

    /// Mutation guard: with no invalidation in the window, the very same call DOES memoize. Without
    /// this, the assertion above would pass just as well if the cache had stopped memoizing at all.
    @MainActor
    @Test func aStatWithNoInvalidationIsMemoized() async {
        CloudOnlyBadgeCache.clear()
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
        CloudOnlyBadgeCache.clear()
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
        CloudOnlyBadgeCache.clear()
        let path = "/fixture/mine.bin"

        let answer = await CloudOnlyBadgeCache.isCloudOnly(
            atPath: path, stat: statThatInvalidates { CloudOnlyBadgeCache.forget("/fixture/other.bin") })

        #expect(answer)
        #expect(CloudOnlyBadgeCache.cached(path) == nil)
    }

    /// A hit short-circuits before the stat runs at all — the memo's whole reason to exist.
    @MainActor
    @Test func aCachedAnswerSkipsTheStatEntirely() async {
        CloudOnlyBadgeCache.clear()
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
        CloudOnlyBadgeCache.clear()
        let path = "/fixture/poll-result.bin"

        CloudOnlyBadgeCache.forget(path)                       // bumps the generation
        CloudOnlyBadgeCache.record(path, isCloudOnly: false)   // the poll's fresh observation

        #expect(CloudOnlyBadgeCache.cached(path) == false)
    }

    // MARK: - Root-scoped clear (C11)

    /// The reason `clear(underRoot:)` exists: one pane's republish must not wipe the answers the
    /// OTHER pane's rows are still serving from.
    @MainActor
    @Test func aScopedClearDropsOnlyEntriesUnderItsRoot() {
        CloudOnlyBadgeCache.clear()
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
        CloudOnlyBadgeCache.clear()
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
        CloudOnlyBadgeCache.clear()
        CloudOnlyBadgeCache.record("/root/x.bin", isCloudOnly: true)
        CloudOnlyBadgeCache.record("/rootling/y.bin", isCloudOnly: true)

        CloudOnlyBadgeCache.clear(underRoot: "/root/")

        #expect(CloudOnlyBadgeCache.cached("/root/x.bin") == nil)
        #expect(CloudOnlyBadgeCache.cached("/rootling/y.bin") == true)
    }

    /// The regression this guard exists for: `SettingsManager.path(for:)` answers `""` for a
    /// provider id it cannot resolve, `PaneLogic.fullPath` passes `""` through, and the empty root
    /// then normalized to the prefix `"/"` — which EVERY absolute key matches. A pane whose
    /// provider failed to resolve republished its empty tree and wiped the other pane's answers:
    /// the global wipe the scoping was added to remove, through a side door.
    @MainActor
    @Test func anEmptyRootClearsNothing() {
        CloudOnlyBadgeCache.clear()
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
        CloudOnlyBadgeCache.clear()
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
        CloudOnlyBadgeCache.clear()
        let path = "/fixture/spanning-noop.bin"

        let answer = await CloudOnlyBadgeCache.isCloudOnly(
            atPath: path, stat: statThatInvalidates { CloudOnlyBadgeCache.clear(underRoot: "") })

        #expect(answer)
        #expect(CloudOnlyBadgeCache.cached(path) == true)
    }

    /// The filesystem root is exempt from the absolute-path guard rather than special-cased by it:
    /// a pane genuinely rooted at `/` covers every absolute entry, and saying so is the truthful
    /// answer for that root. (It is also how the tests above reset the table.)
    @MainActor
    @Test func theFilesystemRootClearsEveryAbsoluteEntry() {
        CloudOnlyBadgeCache.clear()
        CloudOnlyBadgeCache.record("/left/a.bin", isCloudOnly: true)
        CloudOnlyBadgeCache.record("/right/c.bin", isCloudOnly: true)

        CloudOnlyBadgeCache.clear(underRoot: "/")

        #expect(CloudOnlyBadgeCache.cached("/left/a.bin") == nil)
        #expect(CloudOnlyBadgeCache.cached("/right/c.bin") == nil)
    }

    /// Every trailing separator is normalized away, not just one: dropping a single character from
    /// `/root//` left the prefix `/root//`, which matches no key the tree walk ever produced — a
    /// clear that silently took nothing.
    @MainActor
    @Test func aScopedClearNormalizesRepeatedTrailingSeparators() {
        CloudOnlyBadgeCache.clear()
        CloudOnlyBadgeCache.record("/root/x.bin", isCloudOnly: true)
        CloudOnlyBadgeCache.record("/rootling/y.bin", isCloudOnly: true)

        CloudOnlyBadgeCache.clear(underRoot: "/root//")

        #expect(CloudOnlyBadgeCache.cached("/root/x.bin") == nil)
        #expect(CloudOnlyBadgeCache.cached("/rootling/y.bin") == true)
    }

    /// Matching is case-SENSITIVE, and that is a decision rather than an oversight: the memo is a
    /// dictionary, so `cached(_:)` already is. Keys come from the tree walk and roots from
    /// `PaneLogic.fullPath`; today they agree by lineage (the walk descends from that very root
    /// string), which is an accident of plumbing worth pinning so a future case-folding of either
    /// side shows up here rather than as a badge that never refreshes.
    @MainActor
    @Test func aScopedClearIsCaseSensitive() {
        CloudOnlyBadgeCache.clear()
        CloudOnlyBadgeCache.record("/root/x.bin", isCloudOnly: true)

        CloudOnlyBadgeCache.clear(underRoot: "/Root")

        #expect(CloudOnlyBadgeCache.cached("/root/x.bin") == true)
    }

    /// A scoped clear preserves the generation semantics: a stat in flight when it lands must not
    /// memoize its now-stale answer — same contract as the whole-table `clear()`.
    @MainActor
    @Test func aStatSpanningAScopedClearIsNotMemoized() async {
        CloudOnlyBadgeCache.clear()
        let path = "/scoped/spanning.bin"

        let answer = await CloudOnlyBadgeCache.isCloudOnly(
            atPath: path, stat: statThatInvalidates { CloudOnlyBadgeCache.clear(underRoot: "/scoped") })

        #expect(answer)
        #expect(CloudOnlyBadgeCache.cached(path) == nil)
    }
}

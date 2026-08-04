# SyncCloud — Refactoring Candidates (v2.5 / v3.0)

Places where the code is **correct but entangled**: functions whose invariants are held together by
prose comments and careful ordering rather than by structure, so the next change to them is riskier
than it should be. Nothing here is a bug. Nothing here is urgent.

Distinct from `ROADMAP.md` (net-new features) and `DEFERRED_ENHANCEMENTS.md` (behavior/coverage
consciously punted): this is **internal shape**, and the reason to schedule it against a major
release is that every item touches code that runs against real cloud data.

Items 1–7 were compiled from the 2026-07-25 full-codebase review (8-agent fan-out at `88c46ab`; all
findings fixed by `795599a`). The review found **no bugs** in any of these — they are flagged for how
hard they are to reason about, which is a leading indicator, not a defect. Line numbers are
approximate and as of `795599a`; prefer the function names.

Items 8–12 were added by a second sweep on 2026-07-25 (at `b7c8e4a`) that deliberately looked
*outside* the file-operation core the first pass concentrated on — the app layer, the manager's
own cross-cutting state, the Filing spend guardrail, the logging writer, and the duplicate finder.
Same bar, same "no bugs found" caveat.

---

## The rule that decides whether an item belongs here

**Length alone is not a reason to refactor.** A 1500-line view file that is five independent lenses
stacked in one document is tedious, not dangerous — splitting it churns a lot of code to buy
navigation convenience.

The items below qualify because **separate mechanisms interact**: correctness depends on two or more
rules agreeing, and nothing but a comment enforces the agreement. That is the shape that produced
this codebase's actual incidents — the 2026-07-20 bug hunt found that *each round's fixes contained
new defects*, concentrated in exactly these functions.

### Prerequisite for touching any of them

Per `CLAUDE.md`'s correctness bar, a refactor here must be **provably behavior-preserving**:

1. Build the pre-change binary at `HEAD`.
2. Run both binaries against a controlled fixture; diff stdout, exit codes, and resulting file trees.
3. Write characterization tests pinning **full fixture output** *before* changing anything, not
   after — a test written against the new shape only proves the new shape is self-consistent.
4. State the verification in the commit body.

Budget the characterization pass as the majority of the work. For items 1–5 it is most of it.

---

## 1. `FileDiffEngine.computeDifferences` — six interacting suppression mechanisms

**Where:** `Modules/Sync/Sources/Sync/FileDiffEngine.swift:358` (~400 lines; file is 862).

**What interacts:** exact-name matching, case-folded matching, near-name matching with two separate
ambiguity sets, unexplored-ancestor suppression, missing-directory collapse, and near-name
descendant remapping — all over one pass.

**Why it is hard:** essentially every guard exists to patch an interaction between two *other*
mechanisms. The densest knot is the suppression-key trio `suppressionKey` / `readableDirKeys` /
`hasUnexploredFoldedAncestor`; a 2026-07-20 finding was precisely that one of these sets held
own-side spelling and was probed with exact `Set.contains` while the pairing around it was
case-folded, producing phantom actionable rows under a case-variant unreadable folder.

**Risk if left:** low today. The cost is that a **seventh** mechanism cannot be added safely — the
next diff feature (content-hash matching, rename detection) lands here.

**Shape of a fix:** give each mechanism an explicit, named stage with a declared input/output
vocabulary, so suppression decisions stop being ad-hoc set lookups against differently-normalized
keys. Do not attempt without full-fixture golden tests first.

---

## 2. `FileDiffEngine.getFilesInDirectory` — three path vocabularies in one function

**Where:** `Modules/Sync/Sources/Sync/FileDiffEngine.swift:115` (~220 lines).

**What interacts:** manual symlink descent with per-branch visited sets, refusal of links pointing at
an ancestor, and a post-walk re-marking pass for directories that turned out to be unreadable —
while three path forms circulate at once: raw, canonical, and prefix-keyed.

**Why it is hard:** mixing those forms is exactly how sibling-prefix bugs got in historically
(`/root/ab` claiming `/root/abc/x`), which is why `PathBoundary` exists as the one boundary-math
choke point. This function predates that consolidation and still does its own.

**Shape of a fix:** a small wrapper type per vocabulary (or routing every comparison through
`PathBoundary`) so the compiler refuses a raw-vs-canonical comparison.

---

## 3. `registerCopyUndo`'s undo handler — three removal paths plus a must-hold-on-every-exit invariant

**Where:** `Modules/Sync/Sources/Sync/FileSyncManager+Undo.swift:207` (~200 lines).

**What interacts:** duplicate-registration folding (with per-parent case-fold caching and a
nearest-existing-ancestor volume walk), three distinct removal outcomes (item vanished / refused on
size drift / trashed-then-permanently-deleted), and a redo-resolver that **must** be resolved on
every exit path or the redo stack corrupts.

**Why it is hard:** this is the densest function in the module, and the 2026-07-20 hunt found data
loss *inside this function's own fix* twice — once because the permanent-delete loop ignored
`handledDestinations` (real loss on Trash-less volumes, reproduced end to end), once because
case-variant registrations dodged the guard.

**Risk if left:** genuinely the highest-stakes item here, and equally the most dangerous to touch.
Pair any change with `UndoRedoResolutionMatrixTests`, and run the full Sync suite between individual
edits rather than at the end.

---

## 4. `syncAll`'s prepare loop — a staleness protocol crossed with case folding

**Where:** `Modules/Sync/Sources/Sync/FileSyncManager+BulkSync.swift:198` (prepare loop ~270-385).

**What interacts:** the `promptShownSinceStatPass` staleness protocol (re-stat destinations the batch
saw as missing, because a prompt held the run), reserved-target case folding on case-insensitive
volumes, and the directory carve-out from the apply-to-all resolution cache.

**Why it is hard:** the three are independent rules whose combination decides whether a file is
copied, prompted for, or skipped. The bulk-vs-single exclusion window fixed in `1efa298` lived at
this function's entrance.

**Shape of a fix:** separate "resolve every target" from "decide each collision" into two passes with
an explicit intermediate value, instead of interleaving stat, prompt, and cache lookup.

---

## 5. `replaceDestinationByMoving` — four failure regimes, four different preservation duties

**Where:** `Modules/Sync/Sources/Sync/FileOperations+Primitives.swift:288` (~110 lines).

**What interacts:** staging (rename vs cross-volume copy), the atomic replace, the restoring
move-back, and the cross-volume source cleanup — each failure combination carrying a *different*
obligation about which copy of the user's data must survive.

**Why it is hard:** short, but it is the function that decides whether the only copy of a file ends
up recoverable in the Trash or gone. Each branch's safety currently rests on a prose comment;
`tempHoldsOnlyCopyOfSource` is a single bool standing in for a state machine. Two separate review
findings landed here (the unconditional `defer` removal, and the sweeper reaping a live staging
temp, fixed in `1efa298`).

**Shape of a fix:** model the staging lifecycle as an explicit enum (`staged(consumedSource:)`,
`replaced(backup:)`, `holdingOnlyCopy`) so the preservation duty is a property of the state rather
than of which comment you last read.

---

## 6. `mergeDuplicateGroup` + `planMerge` — a plan/drift protocol spanning minutes

**Where:** `Modules/Sync/Sources/Sync/FileSyncManager+Duplicates.swift:341` and `:569`.

**What interacts:** a plan built from two tree walks and a hash pass, a drift snapshot compared
against the world *minutes later*, the retry-idempotence skip rule ("name taken AND bytes already in
the parent"), and the symlinked-directory refusal (`blockedLinkedDirs`).

**Why it is hard:** the skip rule is subtle enough that only its tests make it legible, and the
plan is validated against a filesystem that has had minutes to change underneath it.

**Note:** `2a3a48b` added lazy undo grouping here. If this is refactored, keep the *lazy* opening —
an eagerly opened empty undo group cannot be taken back safely (calling `undo()` to discard it
reverses the user's previous action when the platform already dropped the empty group).

---

## 7. ~~`LogViewer`'s history state — four variables that must move together~~ — **DONE**

**Where:** `Modules/Dashboard/Sources/Dashboard/LogViewer.swift` (831 lines; ~29 references across
`loadedHistory`, `historyLimit`, `isLoadingHistory`, `historyLoadGeneration`).

**What interacts:** whether history has been revealed, how many rows, whether a load is in flight,
and a generation counter that invalidates in-flight loads after a Clear.

**Why this one is different — and why it is the recommended first pick:** it is *view* state.
Nothing here is destructive, nothing touches the filesystem, and a wrong answer shows stale rows
rather than losing data. It is also already bug-adjacent: Clear Logs failing to reset `loadedHistory`
was a shipped bug, and the review found the severity chips still count session entries only while
their filter also applies to revealed history.

**Shape of a fix:** collapse the four into one `HistoryLoadState` enum (`.hidden`, `.loading(generation:)`,
`.loaded(entries:limit:)`) so "loading with history already shown" and similar impossible pairings
stop being representable. Contained, provable, and testable without a fixture.

**Status: landed.** `LogHistoryState` (Dashboard) replaced the four variables with one enum —
`.notLoaded` / `.loading(token:)` / `.loaded(entries:revealed:)`. The load guard moved inside
(`beginLoading` returns nil rather than the view checking a flag), and the generation counter became
a per-load token, so identity belongs to the load instead of to a counter that had to be kept in
step. 13 characterization tests were written from the OLD call sites before the migration, per this
document's own prerequisite; the token guard is mutation-tested and reproduces the original shipped
bug (deleted rows resurrected, reload button gone) when removed.

The one behaviour question that file also carried — the severity chips counting session entries only
while their threshold filters revealed history too — was fixed separately afterwards, deliberately
not folded into the behaviour-preserving refactor.

---

## 8. The freshness family — six hand-rolled counters, three different disciplines

**Where:** `Modules/Sync/Sources/Sync/FileSyncManager.swift:683-703` and `:940-1030`,
`FileSyncManager+Scanning.swift:21` / `:187` / `:372`, `applyFilters` at `:1130`.

**What interacts:** every async producer in the manager guards its publish with its own counter,
and no two use the same rule:

| Counter | Discipline | Failure it prevents |
|---|---|---|
| `scanConfigGeneration` (+ `RefreshKey.config`) | **dedupe key** — a bump makes a refresh *not* collapse into an in-flight one | a forced rescan swallowed as a duplicate |
| `scanRequestGeneration` / `pendingScanRequest` | **queue-forward** — a re-queued request must stay OLDER than any scan that started while it waited | a drain clobbering a newer request |
| `leftLoadGeneration` / `rightLoadGeneration` | **token match** — only the current load may clear its pane's spinner | a superseded load clearing a live spinner |
| `rawTreeGeneration` | **discard on mismatch** | a stale off-main resort clobbering fresh trees |
| `filterGeneration` / `lastPublishedFilterGeneration` | **monotonic publish gate** | an out-of-order filter pass publishing stale rows |
| `publishedLeftTreeVersion` / `publishedRightTreeVersion` | **snapshot validity** — an off-main equality result is trusted only while nothing wrote that pane since | dead clicks from a needless List rebuild |

A seventh lives in another module: `SettingsManager`'s `discoveryGeneration` /
`lastPublishedDiscoveryGeneration` (`SettingsManager.swift:47-54`), whose doc comment says outright
that it copies `applyFilters`' pattern. Copying a pattern by prose is the symptom.

Around them sit two more staleness mechanisms that are *not* counters: `prefetchedTrees` (must be
dropped by every filesystem mutator) and `activeFileOperationsCount` (a manual
`preCountFileOperation` / `cancelPreCountedFileOperation` / unconditional-decrement balance the
quit guard reads).

**Why it is hard:** the vocabulary is uniform ("generation") but the semantics are not — one bump
*forces* work, another *discards* it, a third *orders* it. `applyFilters`'s publish is the knot:
it re-checks the generation, then reconciles its own detached result against live authoritative
state (`rawDifferences`, `syncingDifferenceIds`) because the snapshot can be stale in ways the
generation cannot see, then consults the two per-pane version counters to decide whether to trust
its own off-main equality comparisons. Three staleness mechanisms, one function.

**Risk if left:** low today, but this is what a new async producer has to get right, and there is
no way to tell from the outside which of the six disciplines it should join. The cost already shows
up as a house rule everybody must remember (`prepareForcedRescan` exists purely because
`noteScanConfigChanged` is `internal`).

**Shape of a fix:** name the three disciplines as distinct types (a `DedupeEpoch`, a
`PublishToken`, a `SnapshotVersion`) instead of six bare `Int`s, so a producer picks a semantic
rather than a variable. Do not merge counters that look alike — the point is to make the
differences visible, not to hide them.

---

## 9. The provider-id suppression counter — a balance protocol across three files

**Where:** `MacApp/ContentView.swift:44-50` (declaration), `:397-432` (the two `onChange`
handlers), `:700-730` (swap + bootstrap guard), `:1005`; `MacApp/PaneLogic.swift:15-35`
(`ProviderPinPlan.suppressCount`); `MacApp/DuplicateReviewCoordinator.swift:30-38` and
`compareCopies`.

**What interacts:** a counter of "provider-id `onChange` notifications still expected", the plan
that decides how many writes will actually fire one, the seed-before-write ordering, a bootstrap
guard that returns *without* decrementing, and — for every suppressed change — a hand-copied
replay of the side effects the real handler would have run.

**Why it is hard:** three separate things must agree and nothing checks them together.

1. **The count must match reality.** `ProviderPinPlan` exists specifically so `assignments` and
   `suppressCount` can't drift, and the seed must happen *before* any id is written. A write that
   doesn't change the value fires no `onChange`, so a plan that included it would strand the
   counter permanently — every subsequent genuine provider switch would be silently swallowed.
2. **The bootstrap guard bails first**, without decrementing (documented at `:706`), so a swap
   during discovery strands the counter the other way.
3. **The suppressed side effects must be replayed by hand.** The real handler does six things
   (`dispatchReview`, `clearDuplicates`, `clearFiling`, `clearAutomationDryRun`, the ignore-store
   re-key, `resetNavigation`). `compareCopies` deliberately skips most of them and re-implements
   exactly one — the ignore-store re-key — with a comment noting it is "the ONLY other place it
   happens". Adding a new lens to the app means remembering to clear it in **two** near-identical
   handlers, plus deciding, per suppressed path, whether the replay needs it too.

**Risk if left:** medium. Nothing here is destructive — the failure mode is a stale lens result or
a swallowed switch — but the two handlers are already near-identical copies, which is precisely
the shape that lets a new lens be added to one and forgotten in the other.

**Shape of a fix:** replace the counter with an explicit *reason* on the write —
`setProviders(_:reason: .userSwitch | .paneSwap | .reviewPin | .bootstrap)` — and give each reason
one handler that lists the side effects it runs. Suppression stops being a count that can drift
and becomes a branch that can be read.

---

## 10. Filing's cloud spend guardrail — two enforcement points, three zero meanings

**Where:** `Modules/Sync/Sources/Sync/FileSyncManager+Filing.swift:251-340` (gates, cap keys,
`totalBudgetCap(in:)`, `cloudSpendAllows` at `:303`), `MacApp/CloudFilingClassifier.swift:45-63`
(the second check), `Modules/Settings/Sources/Settings/SettingsView.swift:1200-1201`.

**What interacts:** two independent booleans plus a stored Keychain key decide whether a cloud
call is even possible (`filingUsesAI` × `filingUsesCloud` × key); a preflight builds an estimate
and asks the user; and a **second, independent** cap check inside the classifier re-derives the
same numbers as a belt-and-suspenders backstop. Zero means three different things: monthly `0` =
unlimited, total *absent* = the shipped $5 default, total explicit `0` = off.

**Why it is hard:** the same decision is expressed twice, in two modules, from two call sites that
must read the **same** `UserDefaults` domain — a requirement learned the hard way and now recorded
in the code as a comment ("Spend and caps must come from the SAME store … reading the spend from
the hard-coded default while the caps honoured the injectable one meant only a test could tell
them apart"). On top of that, `defaultTotalBudgetCapUSD` is duplicated as the Settings picker's
`@AppStorage` default, so the shipped cap lives in two places; only `FilingSpendBudgetTests` pins
that they agree.

**Risk if left:** the failure mode is money, not data — a drift between the two checks either
blocks a paid feature the user enabled or lets spend past a cap they set. Both are the kind of bug
that surfaces on someone's bill rather than in a test.

**Shape of a fix:** one `FilingSpendGuard` value that owns the cap semantics (including the
absent-vs-explicit-zero rule), constructed once from a store and consulted by both the preflight
and the classifier, so "may this call run?" has exactly one implementation and the $5 default
exactly one definition.

---

## 11. `LogFileWriter`'s file lifecycle — a cross-process protocol held together by comments

**Where:** `Modules/Events/Sources/Events/Logger.swift:410-584` (`LogFileWriter`), with the line
format contract at `:104-134` (`formattedString` / `parse`).

**What interacts:** an open file handle plus an inode-identity check on every append (the path can
be *replaced* out from under it), an `flock` sidecar serializing trims **across two processes**
(the app and the `synccloud` CLI share `~/sync-cloud.log`), a close-trim-reopen ordering that must
hold or every subsequent line lands in an orphaned inode, a byte-counter trim cadence, a
`clear()` that truncates rather than rewrites (to keep the handle valid), and a fallback path that
rewrites the entire file per line when the handle can't be opened.

**Why it is hard:** it is a small state machine over an external resource that a *second process*
is mutating, and each rule exists to patch an interaction with another: the identity check exists
because trims replace the inode; the trim runs under a lock because two trims race; the size stat
is re-taken *inside* the lock because the winner may already have trimmed. The residual is already
documented as accepted (appends are not under the lock, so one in-flight line can be lost) — which
is the right call, and exactly the kind of decision that needs to stay legible.

**Second mechanism on top:** the single-line format is a contract between four readers —
`formattedString` (disk), `parse` (Activity Log history), the clipboard Copy action (must match
the file byte-for-byte), and `LogGrouping.keyFormatter` (whose locale/calendar pinning must match,
or parsed history is mis-dated). Nothing but prose ties them together.

**Risk if left:** low for data (nobody's files are at stake), but a silent one — a broken writer
loses the breadcrumb trail exactly when a crash makes it valuable, and the tests would still pass
in-process.

**Shape of a fix:** model the handle as an explicit `.closed / .open(inode:) / .trimming` state
with every transition going through one method, and make the line format a single type that owns
both directions (render + parse) so a round-trip test is the only place the shape is written down.

---

## 12. `DuplicateFinder`'s reclaim rule, restated six times

**Where:** `Modules/Sync/Sources/Sync/DuplicateFinder.swift` — construction sites at `:512`,
`:566`, `:584`, `:614`, `:725`; re-derivations in `DuplicateGroup.choosingKeeper` (`:168`) and
`DuplicateGroup.reclaim(after:)` (`:220`).

**What interacts:** "how many bytes does resolving this group actually reclaim?" is answered
per match type at five construction sites inside `findGroups`, and then answered *again* — from
the group's public surface, without the content hashes — whenever a keeper is changed or a copy is
resolved out of band by the Compare review. The second answer is an admitted approximation for
overlapping groups (the per-copy shared fraction isn't retained, so the group average stands in).

**Second, subtler rule:** unknown-content placeholders (`unknownSignature`, `:299-311`) must never
count as evidence that two items are identical **nor** that they differ. That rule has to hold in
grouping, in folder-signature composition, in the overlap fraction, in the `unverified` flag, and
in `DuplicateScanSkips` — five places, enforced by nothing.

**Why it is different from the others here:** the stakes are display numbers, not files — a wrong
reclaim figure misleads, it doesn't delete. It earns a place because a **sixth match type** (the
obvious next feature) means finding all six sites, and because `removingRedundantCopy` is on the
path the Compare duplicate review drives, where the surrounding operations *are* destructive.

**Shape of a fix:** one `reclaimableBytes(matchType:copies:)` function that every site calls,
taking the shared fraction as an explicit parameter so the approximation is visible at the call
site rather than buried in a doc comment.

---

## 13. Three on-disk caches, three copies of the same store

**Where:** `Modules/Sync/Sources/Sync/FilingVerdictCache.swift` (`FilingVerdictStore`),
`ContentHashIndexStore.swift`, `StorageLensStore.swift`.

**What interacts:** each is an `enum` with the same five parts — a `currentSchema` constant, a
`defaultURL(fileManager:)` under `Application Support/SyncCloud`, a `load` that returns empty on
every failure, a serial `DispatchQueue` with `saveInBackground`, and a `waitForPendingWrites()`
barrier that exists only so tests are not racing the write. They were written in that order over
one session, each copying the last.

**Why it is not simply duplication to delete:** the differences are real and deliberate. The
payloads differ (a keyed dictionary, a flat record array, a per-root array with replace-and-cap
semantics), the read-modify-write in `StorageLensStore` has to happen *on* its queue while the
other two hand over a finished value, and the separate queues are a feature rather than an
oversight — funnelling a small verdict write behind a multi-megabyte index write would make the
cheap one wait on the expensive one.

**Risk if left:** low, and it is currently three parallel readable files rather than one clever
one. The cost shows up the next time the shared parts move: the "empty on every failure" rule, the
schema-mismatch decision, and the barrier are each written out three times, and an audit that
corrects one has to remember the other two — which is exactly how the actor/main-actor decode bug
came to exist in two of them at once.

**Shape of a fix:** extract the mechanism, not the policy — a small `BackgroundJSONStore<Payload>`
owning the queue, the atomic write, the barrier and the failure rule, with each store keeping its
own schema constant, URL, and merge semantics. Do NOT unify the queues.

---

## Skipped — long, but not entangled

Recorded so they are not re-flagged by a future review:

| File | Size | Why skipped |
|---|---|---|
| `Modules/FileExplorer/.../TidyView.swift` | 1576 | Five independent lenses in one document. Tedious to navigate, but the lenses do not interact. |
| `Modules/FileExplorer/.../DifferencesView.swift` | 1496 | Header compaction ladder + review mode + search + table. The genuinely coupled part (the collapse rule) was already extracted to `DifferencesView.isCollapsedToHeaderStrip` in `517b1f0`. |
| `Modules/Design/.../LiquidGlassStyle.swift` | 889 | Mostly sprawl — hue table, `GlassLevel`, Clear-glass constants, card modifiers. **Partial exception:** four near-identical card modifiers whose clip/chrome *ordering* differs per path. Worth a look if anyone is in there anyway; not worth a dedicated pass. |
| `MacApp/ContentView.swift` | 1650 | Audited in the second sweep. The genuinely coupled part is item 9 (the suppression counter); the rest is composition — layout modifiers, `.onChange` mirrors of Settings, sheet/inspector plumbing — already thinned by `ContentView+SplitLayout`, `ContentView+Toolbar`, `PaneLogic`, `CompareReviewReducer`, and `DuplicateReviewCoordinator`. Splitting further buys nothing item 9 doesn't. |
| `Modules/Settings/.../SettingsView.swift` | 1584 | Six independent tabs plus `SettingsSearchIndex`, which restates every control's on-screen label ("the single place to keep in sync when a control is added"). The duplication is real, but it is **pinned by `SettingsSearchTests`** rather than by a comment — enforced agreement is the bar, and it clears it. |
| `Modules/Sync/.../FileSyncManager.swift` | 1581 | Six lens subsystems (Sync, Tidy, Storage, Names, Filing, Automations) on one `@MainActor` object, but each already lives in its own `FileSyncManager+*.swift` and touches its own `@Published` set. The parts that genuinely cross the lenses — the freshness counters, `prefetchedTrees`, `activeFileOperationsCount` — are item 8. What's left is stacking. |
| `Modules/Sync/.../FilingEngine.swift` | 797 | Pure and deterministic (no disk reads, no network) — candidates carry their own confidence plus source flags, and each producer is independent. **Partial exception:** the cap `fromContent ? .medium : .high` is written out at three producer sites; if a fourth signal source lands, fold that rule into one place first. |

---

## Partially addressed — action-bar placement

The review flagged the selection action-bar machinery as spanning four units (`PaneBarPlacement`,
`FileTreeView`'s probes, `paneColumn`'s body resolve, `ContentView+Toolbar`'s gate) with **two
`resolveAtTop` committers fed different selection vocabularies**.

`d9b9d2f` closed the half that was actually wrong: the Tidy rail no longer participates at all
(it passes `nil` placement, per `FileTreeView`'s own documented contract). The remaining shape — two
committers, one reading the *resolved bar* selection and one the *raw pane* selection — still exists
for the compare panes, where the two sets are equal by the one-pane-selected invariant.

**If revisited:** collapse to a single selection vocabulary rather than adding a third committer.
`PaneBarPlacementTests` pins the math but not the two-caller interaction, so add that pin first.

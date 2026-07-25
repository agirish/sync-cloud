# SyncCloud — Refactoring Candidates (v2.5 / v3.0)

Places where the code is **correct but entangled**: functions whose invariants are held together by
prose comments and careful ordering rather than by structure, so the next change to them is riskier
than it should be. Nothing here is a bug. Nothing here is urgent.

Distinct from `ROADMAP.md` (net-new features) and `DEFERRED_ENHANCEMENTS.md` (behavior/coverage
consciously punted): this is **internal shape**, and the reason to schedule it against a major
release is that every item touches code that runs against real cloud data.

Compiled from the 2026-07-25 full-codebase review (8-agent fan-out at `88c46ab`; all findings fixed
by `795599a`). The review found **no bugs** in any of these — they are flagged for how hard they are
to reason about, which is a leading indicator, not a defect. Line numbers are approximate and as of
`795599a`; prefer the function names.

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

## 7. `LogViewer`'s history state — four variables that must move together

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

**Recommendation: do this one first**, independently of the rest — it is the only item here whose
risk profile does not argue for waiting.

---

## Skipped — long, but not entangled

Recorded so they are not re-flagged by a future review:

| File | Size | Why skipped |
|---|---|---|
| `Modules/FileExplorer/.../TidyView.swift` | 1576 | Five independent lenses in one document. Tedious to navigate, but the lenses do not interact. |
| `Modules/FileExplorer/.../DifferencesView.swift` | 1496 | Header compaction ladder + review mode + search + table. The genuinely coupled part (the collapse rule) was already extracted to `DifferencesView.isCollapsedToHeaderStrip` in `517b1f0`. |
| `Modules/Design/.../LiquidGlassStyle.swift` | 889 | Mostly sprawl — hue table, `GlassLevel`, Clear-glass constants, card modifiers. **Partial exception:** four near-identical card modifiers whose clip/chrome *ordering* differs per path. Worth a look if anyone is in there anyway; not worth a dedicated pass. |

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

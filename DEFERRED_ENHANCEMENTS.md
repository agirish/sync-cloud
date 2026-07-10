# SyncCloud — Deferred Enhancements & Known Limitations

Enhancements and edge cases that were consciously **deferred** — not bugs, and not oversights.
Everything here is a deliberate decision recorded so it can be picked up later with full context.

Most items came out of the 2026-07-10 data-corruption review of the file-operation layer
(copy / move / cancel / quit), after all five corruption findings and every test/logging gap were
closed. See the commit history around `safeCopyItem`/`safeMoveItem` for the landed work.

Distinct from `ROADMAP.md` (net-new user features); this is hardening / behavior / coverage the
review chose to punt.

---

## 1. Real folder **Merge** (not just wholesale Replace)

**Today:** When a copy/move collides with a same-named **folder** and the user picks **Replace**,
the entire existing destination folder is swapped out (moved to Trash / kept as a `.rollback_`
backup) and the source folder takes its place. Files that existed *only* in the destination folder
are removed from it. This is intentional, Finder-parity behavior; since `23a1ccb` the prompt warns
about it ("Replacing a folder replaces its entire contents…"), and it is Trash-recoverable.

**Enhancement:** Add a fourth collision choice, **Merge**, for folders — recursively copy the
source folder's contents *into* the existing destination folder, resolving per-child collisions
individually, rather than replacing the folder as a unit.

**Why deferred:** This is genuine sync-engine work, not a prompt tweak — it needs a recursive
per-child collision path instead of the single atomic `replaceItem`, plus its own collision
semantics (Merge-all / apply-to-all) and tests. The current behavior is safe (recoverable) and now
clearly warned.

**Pickup notes:** The collision seam already carries `isDirectory`. Add a `.merge` case to
`CollisionResolution`, wire a "Merge" button into `SyncOperationAlerts`, and implement the recursive
merge in the `transferItems` / sync path. **Effort:** medium. **Risk:** medium (new data path).

---

## 2. Sweep aged `.rollback_` replacement backups

**Today:** `OrphanSweeper` (see `d4b17b9`) reaps orphaned `.tmp_<UUID>` staging files left by a
crash, but deliberately **leaves `.rollback_<UUID>` backups** — they are the undo stack's restore
handle and, on Trash-less volumes, may be the only copy of a replaced file. Consequence: a replace
interrupted by a crash can leave a `.rollback_` file (containing the overwritten data) inside a
cloud-synced folder, where it will upload to the cloud and persist indefinitely.

**Enhancement:** Sweep `.rollback_` orphans that are past undo relevance — e.g. older than a
retention window (30 days, matching Trash auto-purge) — or stage them outside the synced folder
where the volume allows it.

**Why deferred:** `.rollback_` is load-bearing for undo and recovery; reaping it too eagerly
destroys the very data it protects. Needs a retention policy and care not to race a live undo.

**Pickup notes:** `OrphanSweeper` already has the age-gate + UUID-validation machinery used for
`.tmp_`; extend it with a longer age gate for `.rollback_`. **Effort:** low–medium. **Risk:** low.

---

## 3. Atomic-replace exotic edge cases (known limitations)

The atomic-replace primitive (`replaceItem`, Finding 1, `0b378e9` + follow-ups) closed the
crash-window where an overwritten file could briefly vanish. Two exotic corners remain, both
**non-corrupting** and documented in `AtomicReplaceTests`:

- **(a) Dangling-symlink destination:** `FileManager.replaceItem` detects the backup via a
  symlink-following `fileExists`, so a destination that is a dangling symlink yields a `nil` backup
  handle and can leak a dangling `.rollback_` symlink.
- **(b) Triple-simultaneous-failure cross-volume corner:** a cross-volume replace where the source
  volume has no Trash **and** the permanent remove is denied **and** the revert's own `replaceItem`
  also fails leaves a recoverable `.rollback_` orphan.

**Why deferred:** Both require pathological conditions (a symlinked destination; three simultaneous
I/O failures) and neither loses data. **Effort:** low. **Value:** low.

---

## 4. Broader parallel bulk-sync integrity test

**Today:** The sharp edge of parallel bulk sync — two items resolving to the same destination — is
pinned by `testSyncAllKeepBothDoesNotCollideWithAnotherBatchTarget` (Finding 2, `8d092b8`).

**Enhancement:** Add a broader stress test that runs many files through the concurrency-4 workers
and asserts every one lands with the correct content (a general "no worker clobbers another"
guarantee beyond the collision case).

**Why deferred:** The real risk (in-batch target collision) is covered; this is added assurance.
**Effort:** low. **Risk:** none.

---

## 5. Cancellable large single-file copy

**Today:** Cancellation is observed only **between** items (`progress.isCancelled` is checked at the
top of each loop iteration — see `CancellationTests`). This is a deliberate safety property: a
single file is never interrupted mid-copy, so a cancel can't produce a half-written file. The
trade-off is that one very large file (e.g. tens of GB) cannot be cancelled once its copy starts.

**Enhancement:** Chunked, cancellable copy for large files — stream in cancellation-checked chunks
into the `.tmp_` staging file, so a cancel can abandon and delete the partial staging copy without
ever touching the destination.

**Why deferred:** Not a correctness/corruption issue — purely a responsiveness limitation. A chunked
copy adds real complexity and must preserve the current atomicity guarantee (partial work stays in
the temp and is discarded on cancel). **Effort:** medium. **Risk:** medium.

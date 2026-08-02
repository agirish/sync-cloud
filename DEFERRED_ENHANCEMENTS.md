# SyncCloud — Deferred Enhancements & Known Limitations

Enhancements and edge cases that were consciously **deferred** — not bugs, and not oversights.
Everything here is a deliberate decision recorded so it can be picked up later with full context.

Items 1–5 came out of the 2026-07-10 data-corruption review of the file-operation layer
(copy / move / cancel / quit), after all five corruption findings and every test/logging gap were
closed. See the commit history around `safeCopyItem`/`safeMoveItem` for the landed work.

Items 6–11 were added on 2026-07-25 by a sweep over the *whole* app for behavior the code already
declares as a deliberate limit — a cap, a skip, a cheap guard, an accepted residual. Each one is
already visible to the user (a skip count, a banner, a log line) or provably harmless; none is a
bug.

Distinct from `ROADMAP.md` (net-new user features we intend to build); this is hardening / behavior
/ coverage the review chose to punt. Whether the two should be one file was asked and settled on
2026-08-02 — they stay separate, because a roadmap is a plan you work down while several entries
here are deliberately low-value and may never be worth scheduling. The reasoning is written out in
full at the end of `ROADMAP.md`.

---

## 1. Real folder **Merge** (not just wholesale Replace)

**Today:** When a copy/move collides with a same-named **folder** and the user picks **Replace**,
the entire existing destination folder is swapped out (moved to Trash / kept as a `.rollback_`
backup) and the source folder takes its place. Files that existed *only* in the destination folder
are removed from it. This is intentional, Finder-parity behavior; since `23a1ccb` the prompt warns
about it ("Replacing a folder replaces its entire contents…"), and it is Trash-recoverable.

**Why it was deferred:** This is genuine sync-engine work, not a prompt tweak — it needs a recursive
per-child collision path instead of the single atomic `replaceItem`, plus its own collision
semantics (Merge-all / apply-to-all) and tests. The current behavior is safe (recoverable) and now
clearly warned, so the review punted it.

**→ It is now planned work: see the folder-Merge item in `ROADMAP.md`,** which carries the full
specification (the `.merge` case on `CollisionResolution`, the `SyncOperationAlerts` button, the
recursive `transferItems` path, and the surfaces to mock). It was promoted out of this file because
it is a feature people ask for rather than an accepted limit, and a spec kept in two places drifts
in one of them. This entry stays only to record *why it sat here first*.

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

---

## 6. Content verification's three blind spots: cloud-only, >100 MB, hard-linked

**Today:** Anything that needs a content hash — Tidy's duplicate detection and Verify All — skips
three classes of file, and the Tidy scan **counts and reports** each reason
(`DuplicateScanSkips`: `tooLarge`, `cloudOnly`, `multiLink`, surfaced in the results view and in a
log line that ends "duplicates among them are not detected"):

- **Cloud-only (dataless) placeholders** — hashing one would force a full download of a file the
  user chose not to keep local. `MaterializationStatus.isCloudOnly` detects them with a single
  `lstat` that does not fetch.
- **Over the size cap** — `FileContentVerifier.maxBytesToHash` is 100 MB.
- **Hard links** (link count > 1) — a directory entry is not the bytes, so no single-path
  duplicate offer about one is truthful. Deliberate, and unlikely to change.

**Enhancement:** For the first two, an opt-in "check these too" pass: materialize-then-hash for
cloud-only files (with a byte/count budget shown up front), and a sampled hash — head + tail +
size — for files over the cap, reported as a weaker claim than a full hash.

**Why deferred:** Materializing costs the user bandwidth and disk, and there is **no public
consumer API to fetch on demand outside iCloud** (`MaterializationStatus.download` uses
`startDownloadingUbiquitousItem`; for Dropbox / Drive / OneDrive it throws and the caller falls
back to Reveal in Finder). A sampled hash is a *different* claim than byte-identical and would
need its own UI vocabulary and its own never-auto-trash rule — the current copies already carry an
`unverified` flag for exactly this kind of weaker evidence. **Effort:** medium. **Risk:** medium
(it widens what "identical" means on a destructive path).

---

## 7. The two scan paths diverge on symlinked directories

**Today:** `executeScan` has two ways to produce the comparison maps: an in-memory fast path from
the prefetched deep trees (near-instant after navigation) and a from-disk double walk. They agree
on everything except one documented case — the tree builder walks **into** a symlinked directory
(as the panes display it), while the disk enumerator reports the linked directory itself but not
its contents. So a comparison over a tree containing a symlinked folder can list different rows
depending on whether the prefetch cache happened to be warm.

**Enhancement:** Make the two paths agree — most cheaply by having the disk walk descend symlinked
directories the way the tree builder does, since that is the behavior the panes already show.

**Why deferred:** It is a visibility difference, not a data one: nothing is copied, moved, or
deleted differently, and every row either path produces is a real row about a real file. The fix
touches `getFilesInDirectory`'s symlink descent — see `REFACTOR.md` item 2, which is the reason
this is not a five-minute change. **Effort:** low–medium. **Risk:** medium (it changes what a scan
reports on trees with symlinks; needs a full-fixture characterization diff first).

**Pickup notes:** The divergence is called out in the comment above the fast path in
`FileSyncManager+Scanning.swift:executeScan`.

---

## 8. Cloud Filing classifies at most 150 files per scan

**Today:** `CloudFilingClassifier.maxFiles` caps a scan's cloud request at 150 files to bound its
cost. Files past the cap keep their on-device / heuristic suggestion, and the log line says so
("capped from N"), but the results view does not distinguish them.

**Enhancement:** Chunk the remainder into further requests, each priced through the same
`cloudSpendAllows` preflight so the user sees (and approves) the real total — or, at minimum,
surface "150 of N classified in the cloud" in the results view rather than only in the log.

**Why deferred:** The cap is doing its job — one runaway folder shouldn't quietly become a large
bill — and the fallback is a real suggestion, not an empty one. Chunking interacts with the spend
guardrail (`REFACTOR.md` item 10), which is the piece to settle first. **Effort:** low–medium.
**Risk:** low (cost, not data).

---

## 9. The content-hash cache is session-scoped

**Today:** `ContentHashCache` is an in-memory actor keyed by (path, mtime, size), capped at 20k
entries with FIFO eviction. It makes a *repeat* Verify All within one session near-instant; a
relaunch re-hashes everything from scratch.

**Enhancement:** Persist it (a small on-disk index) so Verify and Tidy stay fast across launches —
the same index `ROADMAP.md`'s "Content-based diff: a strict-match mode and a persisted index" would
need anyway. (Cited by name: that file's numbering is positional and shifts as items ship.)

**Why deferred:** The key already handles the invalidation correctly (an edit bumps mtime, so a
stale entry is bypassed rather than served), so persistence is purely a speed win, and its one
pathological case — a deliberate mtime reset that preserves size — becomes durable rather than
session-lived. Worth doing **with** the content-diff feature, not before it. **Effort:** medium.
**Risk:** low.

---

## 10. The copy-undo drift guard compares byte size only

**Today:** Undoing a copy refuses to trash the copied item when its byte size no longer matches
the size recorded at registration — the item was replaced or edited since, and trashing it would
destroy work the undo was never asked to reverse. The item is left in place, the user gets a
warning banner, its `overwritten` backup stays in the Trash, and it is kept out of the redo
params. Directories are exempt (they return `nil` and skip the guard).

**Two consequences, both accepted:**

- An edit that **preserves the byte size** passes the guard, and undo trashes the edited file.
  Recoverable from the Trash, and undo is a deliberate user action about a copy they just made.
- When the guard *does* refuse, the banner is the end of it — there is no "show me" or "remove it
  anyway" affordance.

**Enhancement:** Include mtime in the snapshot (cheap, catches the same-size edit), and give the
refusal banner a Reveal action.

**Why deferred:** The guard is the *safe* direction of a cheap check, matching the move-undo's
occupied check and the delete-undo's occupant refusal — it errs toward leaving files alone.
Tightening it to mtime would make undo refuse more often, including for files a cloud provider
touched without changing content, which trades one surprise for a noisier one. **Effort:** low.
**Risk:** low–medium (a stricter guard changes how often undo declines).

---

## 11. One log line can be lost when the app and the CLI trim concurrently

**Today:** The app and the `synccloud` CLI share `~/sync-cloud.log`. Trims are serialized across
processes by an `flock` on a `<log>.lock` sidecar, and each append re-stats the path's inode so a
handle orphaned by another process's trim is reopened rather than written into. **Appends are
deliberately not under the lock**, so a write landing between the other process's tail-read and
its atomic rename is lost — one line, once, and only during a trim.

**Enhancement:** Take a shared lock on append (or hand every writer a single-writer daemon).

**Why deferred:** This is already recorded in the code as an accepted residual: locking every
append puts a cross-process syscall on the hot path of every log line to close a rare, single-line
race in a diagnostic file. Listed here so the trade stays a decision rather than a discovery.
**Effort:** low. **Value:** low.

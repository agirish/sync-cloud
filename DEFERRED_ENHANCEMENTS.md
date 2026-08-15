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

**Today:** Anything that needs a content hash — Organize ▸ Duplicates and Verify All — skips
three classes of file, and the duplicate scan **counts and reports** each reason
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

## 9. ~~The content-hash cache is session-scoped~~ — **DONE**

**Was:** `ContentHashCache` was an in-memory actor keyed by (path, mtime, size). It made a *repeat*
Verify All within one session near-instant; a relaunch re-hashed everything from scratch.

**Landed:** `ContentHashIndexStore` persists the index to
`~/Library/Application Support/SyncCloud/content-hash-index.json`, and Verify and the duplicate scan
save into it after hashing. `ROADMAP.md`'s "Content-based diff: a strict-match mode and a persisted
index" now needs only its strict-match half. (Cited by name: that file's numbering is positional.)

Three things this item asked for, and how each was settled:

- **Schema version** — a file from another schema is discarded, not migrated. Every entry is
  reconstructible by re-hashing, so a migration would be permanent code to avoid one re-scan.
- **The mtime-reset pathology** — a deliberate mtime reset that also preserves the byte count is
  still undetectable, exactly as it was in memory. What persistence changes is how long it can be
  believed, so entries older than `ContentHashCache.maxEntryAge` (30 days) are dropped on load. That
  is a blast-radius bound, not a correctness argument.
- **Enablement** — the location is injected by the app, never defaulted inside `Sync`. `.shared` is
  the DEFAULT argument of both `findDuplicates` and Verify, so an ambient path would have had every
  test that touches either one reading and writing the user's real index.

One thing worth knowing if this is revisited: the persisted `mtime` stays a `TimeInterval` rather
than being quantized, because the reloaded key has to reproduce one built at hashing time from
`attributesOfItem[.modificationDate]` — rounding would make every entry miss the lookup it exists to
serve. That is only safe because `Double` round-trips JSON exactly, which was measured (200 000
realistic sub-millisecond mtimes through `JSONEncoder` and `JSONSerialization`, zero mismatches)
rather than assumed.

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

---

## 12. A declined classification is re-asked on every scan

**Today:** `FilingVerdictCache` records a verdict per file. When the backend returns *no* verdict
for a file — it had no confident home — there is nothing to record, so it is sent again on the
next scan and every scan after it. On the real 150-file scan this was measured against, the
cloud model placed 131, so roughly 13 % of the batch is re-sent indefinitely.

**Enhancement:** Store a tombstone ("this backend, this prompt version, declined this file") and
treat it as a hit, so a declined file is skipped until its bytes, the model, or the prompt change.

**Why deferred:** it is not a pure win, which is why it wants a deliberate decision rather than a
quiet patch. The classifier is not deterministic, so re-asking genuinely gives a declined file
another chance at a home; caching the decline trades that away for a modest saving. The saving is
modest because a decline costs input tokens only — the file's name and possibly an excerpt — and
emits no placement, and output is roughly three quarters of a scan's cost. Files with no confident
home also still get the heuristic engine's suggestion, so nothing is lost to the user meanwhile.

Worth revisiting if the declined share grows, or alongside any work that makes the classifier's
answers more deterministic. **Effort:** low. **Value:** low–medium (cost, not correctness).

---

## 13. A "Try another" verdict is paid for and never cached

**Today:** `tryAnotherFolder`'s re-ask calls the classifier — a paid call on the cloud backend —
and hands the verdict straight to the card without recording it in `FilingVerdictCache`.
`FilingVerdictKey.excludedRelativePaths` exists precisely so this answer is cacheable: the next
ordinary scan builds this file's key WITH its rejections, so an entry recorded here would be a hit
and the file would not be re-billed.

**Enhancement:** Record the re-ask's verdict under its exclusion-carrying key.

**Why deferred:** the recording needs the scan's backend *identity*, which the re-ask path never
resolves (`filingBackendIdentity` is asked once per scan, and a re-ask is not a scan), plus the
pre-await snapshot discipline the function already documents for its taxonomy. Both are solvable;
neither is a one-liner, and the cost today is one file re-billed per "Try another" per scan — small
against the batch. Do it together with any wider verdict-cache work rather than as a patch.
**Effort:** low–medium. **Value:** low (cost, not correctness).

---

Items 14–16 were added on **2026-08-14** when Browse tabs landed. Each is a place where the shipped
feature knowingly stops short of Finder or of its own design; none is a bug, and each was noticed
while using the thing rather than while reading it.

---

## 14. ⌃⇧⇥ does not cycle tabs backwards

**Today:** ⌃⇥ cycles to the next tab **in Browse only** — `switchPaneFocus` keeps it in Compare,
where two panes exist to switch between. Its shifted partner ⌃⇧⇥ is registered nowhere: there is no
backwards cycle on that chord in either workspace. ⇧⌘[ and ⇧⌘] do cycle both directions everywhere,
so nothing is unreachable — this is a missing *second* way, not a missing capability.

**Enhancement:** register ⌃⇧⇥ as the Browse-scoped previous-tab, mirroring ⌃⇥.

**Why deferred:** the pair has to split the same way ⌃⇥ does — backwards-tab in Browse, backwards
*pane focus* in Compare — and `switchPaneFocus` has no reverse today, so the Compare half would have
to be invented to keep the two chords symmetric. Doing only the Browse half leaves ⌃⇥ and ⌃⇧⇥
scoped differently from each other, which is worse than neither. **Effort:** low. **Value:** low —
a third route to something two chords already do.

---

## 15. ⌘-double-click opens a new tab in Columns only

**Today:** ⌘-double-clicking a folder row opens it in a new tab in the **Columns** view. The tree
view has no double-click path at all — `FileTreeView` drives navigation from single taps and
disclosure, and adding a double-click there reopens the gesture competition that got row
`.draggable` removed (see `PaneColumnsView.swift`, and item 1 of `ROADMAP_V4.md` §3's ranking).
Right-click ▸ **Open in New Tab** works in both views, so the tree is not cut off from the feature.

**Enhancement:** a `.simultaneousGesture(TapGesture(count: 2))` on the tree row, matching Columns.

**Why deferred:** the tree's single-tap already carries selection and disclosure, and a second
recognizer on the same row is exactly the shape that broke column navigation before. It needs a
proof that a single click still selects and still discloses — the same proof `.draggable` never
got. **Effort:** low. **Risk:** medium (gesture competition). **Value:** low.

---

## 16. ⌘W closes the window when the focused pane holds one tab, whatever the other pane holds

**Today:** Close Tab closes the **window** when the focused pane is down to its last tab — Finder's
behaviour, and what keeps ⌘W meaning "get rid of this" rather than acquiring an exception nobody
would remember. In Compare that reads oddly in one case: the focused pane has one tab, the *other*
pane has five, and ⌘W takes the window and all six.

**Enhancement:** refuse the window-close while the sibling pane holds more than one tab, or close
that pane's tab instead.

**Why deferred:** every alternative makes ⌘W conditional on state the user cannot see without
looking away from the pane they are in, and "⌘W sometimes closes a tab and sometimes the window,
depending on the other half of the screen" is a worse rule than the Finder one even though this
particular case is worse under it. The header card's own Close Tab item already withholds itself at
one tab rather than offering to close the window, so the *menu* route cannot surprise anyone; this
is the chord only. Revisit if it actually bites. **Effort:** low. **Value:** low.

---

## 17. Compare's right pane restores neither its tabs nor its column stack

**Today:** `PaneTabsStore` persists **one** strip and it is the left pane's — a deliberate line held
since tabs landed, because the right-hand location is Compare's and no Compare workspace has ever
restored where its right pane was. The right pane seeds as a single tab on its stored provider at
every launch. `117af0c6` fixed the *left* pane's column stack across a quit (`stackDepth` in the
stored entry); the right pane has no stored entry to carry one.

**Enhancement:** persist the right pane's strip too — its tabs, and each tab's `stackDepth` — so a
Compare workspace reopens with both halves where they were left.

**What it would take, and the one trap in it:**

- A second defaults key (`browseTabsRight` / `browseSelectedTabRight`, say). The `Entry` format
  needs nothing new; `save`/`restore` are already side-agnostic and take the list as a parameter.
- `saveBrowseTabs(isLeft:)` currently `guard isLeft`s and reads `leftProviderId` /
  `syncManager.leftRelativePath` / `syncManager.leftBrowsePath`. Both halves of that are per-side
  and would need threading, along with `restoreBrowseTabs`'s hard-coded `isLeft: true`.
- **The trap: the right pane's stack cannot be derived from the left, so it has to be stored, not
  recomputed.** The panes are independent unless the seam link is on (`PaneLinkPreference.isLinked`
  is `false` unless the user turns it on — there is no `register(defaults:)`), and *even when it is
  on* the mirror is **pruned**, not copied: `applyColumnNavigation` walks the sibling as deep as its
  own tree genuinely goes and stops at the deepest shared folder. So a linked right pane routinely
  sits shallower than the left, and a restore that replayed the left pane's path onto it would open
  it deeper than the user ever had it — pointing New Folder and paste at a folder that may not exist
  on that side. Store the right pane's own depth; do not infer it.
- Restoring the right pane means restoring what it *walks*, so the launch-time load follows the
  restored scope on both sides rather than only the left.

**Why deferred:** it is a behaviour change to Compare, and it was split off from the left-pane fix
on purpose so that fix stayed contained to Browse. Nothing here is hard; the pane-side threading is
mechanical and the trap above is the only judgement call. **Effort:** medium. **Value:** medium —
it matters exactly as much as Compare workspaces are left set up between sessions.
